#requires -version 5.1
<#
    Api.psm1
    REST route dispatcher for everything under /api/*. Real-time chat,
    presence and call relay go over the WebSocket hub instead - see
    WebSocketHub.psm1 and the connection loop in Start-ChatServer.ps1.
#>

Set-StrictMode -Version Latest

function Invoke-ApiRequest {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$User
    )

    $request = $Context.Request
    $method = $request.HttpMethod.ToUpperInvariant()
    $path = $request.Url.AbsolutePath

    try {
        switch -Regex ($path) {
            '^/api/me$' {
                if ($method -eq 'GET') { return Get-Me -Context $Context -User $User }
                break
            }
            '^/api/me/settings$' {
                if ($method -eq 'PUT') { return Set-MySettings -Context $Context -User $User }
                break
            }
            '^/api/rooms$' {
                if ($method -eq 'GET')  { return Get-RoomsForUser -Context $Context -User $User }
                if ($method -eq 'POST') { return New-RoomAsAdmin -Context $Context -User $User }
                break
            }
            '^/api/room-requests$' {
                if ($method -eq 'GET')  { return Get-PendingRoomRequests -Context $Context -User $User }
                if ($method -eq 'POST') { return New-RoomRequest -Context $Context -User $User }
                break
            }
            '^/api/room-requests/(?<id>[^/]+)/approve$' {
                if ($method -eq 'POST') { return Approve-RoomRequestApi -Context $Context -User $User -RequestId $Matches['id'] }
                break
            }
            '^/api/room-requests/(?<id>[^/]+)/reject$' {
                if ($method -eq 'POST') { return Reject-RoomRequestApi -Context $Context -User $User -RequestId $Matches['id'] }
                break
            }
            '^/api/rooms/(?<id>[^/]+)/messages$' {
                if ($method -eq 'GET') { return Get-Messages -Context $Context -User $User -RoomId $Matches['id'] }
                break
            }
            '^/api/rooms/(?<id>[^/]+)/files$' {
                if ($method -eq 'POST') { return New-RoomFileUpload -Context $Context -User $User -RoomId $Matches['id'] }
                break
            }
            '^/api/rooms/(?<id>[^/]+)/members/(?<username>[^/]+)$' {
                if ($method -eq 'DELETE') { return Remove-RoomMemberApi -Context $Context -User $User -RoomId $Matches['id'] -Username ([uri]::UnescapeDataString($Matches['username'])) }
                break
            }
            '^/api/rooms/(?<id>[^/]+)/members$' {
                if ($method -eq 'POST') { return Add-RoomMemberApi -Context $Context -User $User -RoomId $Matches['id'] }
                break
            }
            '^/api/rooms/(?<id>[^/]+)$' {
                if ($method -eq 'PATCH')  { return Update-RoomApi -Context $Context -User $User -RoomId $Matches['id'] }
                if ($method -eq 'DELETE') { return Remove-RoomApi -Context $Context -User $User -RoomId $Matches['id'] }
                break
            }
            '^/api/files/(?<id>[^/]+)$' {
                if ($method -eq 'GET') { return Get-FileDownload -Context $Context -User $User -FileId $Matches['id'] }
                break
            }
            '^/api/admin/config$' {
                if ($method -eq 'GET') { return Get-AdminConfig -Context $Context -User $User }
                if ($method -eq 'PUT') { return Set-AdminConfig -Context $Context -User $User }
                break
            }
            '^/api/admin/users$' {
                if ($method -eq 'GET') { return Get-AdminUsers -Context $Context -User $User }
                break
            }
            '^/api/admin/users/(?<username>[^/]+)/admin$' {
                if ($method -eq 'PUT') { return Set-AdminUserRole -Context $Context -User $User -Username ([uri]::UnescapeDataString($Matches['username'])) }
                break
            }
        }
        Send-ErrorResponse -Context $Context -StatusCode 404 -Message "Onbekende route: $method $path"
    }
    catch {
        Send-ErrorResponse -Context $Context -StatusCode 500 -Message "Serverfout: $($_.Exception.Message)"
    }
}

function Assert-Admin {
    param($User, $Context)
    if (-not $User.IsAdmin) {
        Send-ErrorResponse -Context $Context -StatusCode 403 -Message 'Alleen beheerders mogen dit.'
        return $false
    }
    return $true
}

function Get-BodyValue {
    <#
        Safe property read from a client-supplied JSON body. Under
        Set-StrictMode, "$body.foo" THROWS when the client didn't send
        "foo" at all (instead of returning $null) - which turned optional
        request fields into 500s (the settings form never sends
        "displayName", so every settings save crashed on exactly that).
        Every $body access in this module goes through this helper so a
        missing field is always just its default, never an exception.
    #>
    param($Body, [Parameter(Mandatory)][string]$Name, $Default = $null)
    # Deliberately NO comma-protection on these returns, unlike the store
    # helpers: every caller that expects an array already wraps the call in
    # @(...), and @( <comma-protected return> ) double-wraps into a nested
    # array (verified: the members list then arrives as 1 element of type
    # Object[] instead of N strings). A plain return + @() at the call site
    # handles 0/1/N elements correctly; scalar values are unaffected.
    if ($null -eq $Body) { return $Default }
    if (Get-Member -InputObject $Body -Name $Name -ErrorAction SilentlyContinue) {
        return $Body.$Name
    }
    return $Default
}

# ---------------------------------------------------------------------------
# Login / logout - handled before any user is resolved (see
# ConnectionWorker.ps1), since there is no user yet at login time. There is
# deliberately no password or Active Directory check: the caller just
# states DOMAIN\username and is trusted at face value (see Auth.psm1).
# ---------------------------------------------------------------------------

function Invoke-Login {
    param($Context)
    $body = Read-RequestJson -Context $Context
    $username = "$(Get-BodyValue -Body $body -Name 'username' -Default '')".Trim()

    if (-not (Test-ValidUsernameFormat -Username $username)) {
        Send-ErrorResponse -Context $Context -StatusCode 400 -Message 'Vul een nickname in (bijvoorbeeld "jansen").'
        return
    }

    Get-UserProfile -Username $username -CreateIfMissing | Out-Null
    $cookieValue = [uri]::EscapeDataString($username)
    $Context.Response.Headers['Set-Cookie'] = "chatuser=$cookieValue; Path=/; HttpOnly; SameSite=Lax"
    Send-JsonResponse -Context $Context -Data ([pscustomobject]@{ ok = $true; username = $username })
}

function Invoke-Logout {
    param($Context)
    $Context.Response.Headers['Set-Cookie'] = 'chatuser=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0'
    Send-JsonResponse -Context $Context -Data ([pscustomobject]@{ ok = $true })
}

# ---------------------------------------------------------------------------
# Profile / settings
# ---------------------------------------------------------------------------

function Get-Me {
    param($Context, $User)
    $cfg = Get-AppConfig
    Send-JsonResponse -Context $Context -Data ([pscustomobject]@{
        username       = $User.Username
        displayName    = $User.DisplayName
        isAdmin        = $User.IsAdmin
        settings       = $User.Profile.settings
        departmentName = $cfg.departmentName
    })
}

function Set-MySettings {
    param($Context, $User)
    $body = Read-RequestJson -Context $Context
    $nSound = $null
    if ($null -ne $body -and (Get-Member -InputObject $body -Name notificationsSound -ErrorAction SilentlyContinue)) {
        $nSound = [bool](Get-BodyValue -Body $body -Name 'notificationsSound')
    }
    $override = $null
    $hasOverride = $false
    if ($null -ne $body -and (Get-Member -InputObject $body -Name displayNameOverride -ErrorAction SilentlyContinue)) {
        $override = Get-BodyValue -Body $body -Name 'displayNameOverride'
        $hasOverride = $true
    }
    $params = @{ Username = $User.Username }
    $displayName = Get-BodyValue -Body $body -Name 'displayName'
    if ($displayName) { $params.DisplayName = $displayName }
    $theme = Get-BodyValue -Body $body -Name 'theme'
    if ($theme) { $params.Theme = $theme }
    if ($null -ne $nSound) { $params.NotificationsSound = $nSound }
    if ($hasOverride) { $params.DisplayNameOverride = $override }
    Set-UserSettings @params | Out-Null
    $updated = Get-UserProfile -Username $User.Username -CreateIfMissing
    Send-JsonResponse -Context $Context -Data $updated
}

# ---------------------------------------------------------------------------
# Rooms
# ---------------------------------------------------------------------------

function ConvertTo-RoomSummary {
    param($Room, $Username)
    [pscustomobject]@{
        id       = $Room.id
        name     = $Room.name
        type     = $Room.type
        topic    = $Room.topic
        archived = $Room.archived
        managers = @($Room.managers)
        members  = @($Room.members)
        isManager = (Test-IsRoomManager -Room $Room -Username $Username)
    }
}

function Get-RoomsForUser {
    param($Context, $User)
    # Capture into a variable before piping - see the comment on Get-Room
    # in Store.psm1 for why "Get-Rooms | Where-Object" directly would be
    # wrong (Get-Rooms comma-protects its array return). The Where-Object
    # and ForEach-Object stay in one wrapped @(...) expression rather than
    # an intermediate "$visible = ..." assignment, so a zero- or
    # one-match result doesn't collapse to $null/a bare scalar before
    # ForEach-Object gets to see it.
    $allRooms = Get-Rooms
    # Explicit, version-independent normalization - see the comment on
    # Get-UserProfile in Store.psm1 for why this can't be left implicit.
    if ($null -eq $allRooms) { $allRooms = @() } elseif ($allRooms -isnot [array]) { $allRooms = @($allRooms) }
    $summaries = @($allRooms | Where-Object { Test-CanAccessRoom -Room $_ -Username $User.Username } | ForEach-Object { ConvertTo-RoomSummary -Room $_ -Username $User.Username })
    Send-JsonResponse -Context $Context -Data $summaries
}

function New-RoomAsAdmin {
    param($Context, $User)
    if (-not (Assert-Admin -User $User -Context $Context)) { return }
    $body = Read-RequestJson -Context $Context
    $name = Get-BodyValue -Body $body -Name 'name'
    if (-not $name) {
        Send-ErrorResponse -Context $Context -StatusCode 400 -Message 'Naam is verplicht.'; return
    }
    $topic = Get-BodyValue -Body $body -Name 'topic' -Default ''
    if ((Get-BodyValue -Body $body -Name 'type') -eq 'private') {
        $room = New-PrivateRoom -Name $name -Topic $topic -CreatedBy $User.Username `
            -Managers (@(Get-BodyValue -Body $body -Name 'managers' -Default @())) `
            -Members (@(Get-BodyValue -Body $body -Name 'members' -Default @()))
    }
    else {
        $room = New-PublicRoom -Name $name -Topic $topic -CreatedBy $User.Username
    }
    Send-JsonResponse -Context $Context -StatusCode 201 -Data (ConvertTo-RoomSummary -Room $room -Username $User.Username)
}

function Update-RoomApi {
    param($Context, $User, $RoomId)
    $room = Get-Room -RoomId $RoomId
    if (-not $room) { Send-ErrorResponse -Context $Context -StatusCode 404 -Message 'Chatroom niet gevonden.'; return }
    if (-not (Test-IsRoomManager -Room $room -Username $User.Username)) {
        Send-ErrorResponse -Context $Context -StatusCode 403 -Message 'Alleen managers van deze room mogen dit wijzigen.'; return
    }
    $body = Read-RequestJson -Context $Context
    $archived = $null
    if ($null -ne $body -and (Get-Member -InputObject $body -Name archived -ErrorAction SilentlyContinue)) {
        $archived = [bool](Get-BodyValue -Body $body -Name 'archived')
    }
    $updated = Update-RoomDetails -RoomId $RoomId -Name (Get-BodyValue -Body $body -Name 'name') -Topic (Get-BodyValue -Body $body -Name 'topic') -Archived $archived
    Send-JsonResponse -Context $Context -Data (ConvertTo-RoomSummary -Room $updated -Username $User.Username)
}

function Remove-RoomApi {
    param($Context, $User, $RoomId)
    if (-not (Assert-Admin -User $User -Context $Context)) { return }
    Remove-Room -RoomId $RoomId
    Send-JsonResponse -Context $Context -Data ([pscustomobject]@{ ok = $true })
}

function Add-RoomMemberApi {
    param($Context, $User, $RoomId)
    $room = Get-Room -RoomId $RoomId
    if (-not $room) { Send-ErrorResponse -Context $Context -StatusCode 404 -Message 'Chatroom niet gevonden.'; return }
    if (-not (Test-IsRoomManager -Room $room -Username $User.Username)) {
        Send-ErrorResponse -Context $Context -StatusCode 403 -Message 'Alleen managers mogen leden toevoegen.'; return
    }
    $body = Read-RequestJson -Context $Context
    $memberName = Get-BodyValue -Body $body -Name 'username'
    if (-not $memberName) {
        Send-ErrorResponse -Context $Context -StatusCode 400 -Message 'username is verplicht.'; return
    }
    $asManager = [bool](Get-BodyValue -Body $body -Name 'asManager' -Default $false)
    $updated = Add-RoomMember -RoomId $RoomId -Username $memberName -AsManager:$asManager
    Send-JsonResponse -Context $Context -Data (ConvertTo-RoomSummary -Room $updated -Username $User.Username)
}

function Remove-RoomMemberApi {
    param($Context, $User, $RoomId, $Username)
    $room = Get-Room -RoomId $RoomId
    if (-not $room) { Send-ErrorResponse -Context $Context -StatusCode 404 -Message 'Chatroom niet gevonden.'; return }
    if (-not (Test-IsRoomManager -Room $room -Username $User.Username)) {
        Send-ErrorResponse -Context $Context -StatusCode 403 -Message 'Alleen managers mogen leden verwijderen.'; return
    }
    $updated = Remove-RoomMember -RoomId $RoomId -Username $Username
    Send-JsonResponse -Context $Context -Data (ConvertTo-RoomSummary -Room $updated -Username $User.Username)
}

# ---------------------------------------------------------------------------
# Room requests (private rooms "op verzoek")
# ---------------------------------------------------------------------------

function New-RoomRequest {
    param($Context, $User)
    $body = Read-RequestJson -Context $Context
    $name = Get-BodyValue -Body $body -Name 'name'
    if (-not $name) {
        Send-ErrorResponse -Context $Context -StatusCode 400 -Message 'Naam is verplicht.'; return
    }
    $purpose = Get-BodyValue -Body $body -Name 'purpose' -Default ''
    $req = Add-RoomRequest -Name $name -Purpose $purpose -RequestedBy $User.Username -ProposedMembers (@(Get-BodyValue -Body $body -Name 'proposedMembers' -Default @()))
    Send-JsonResponse -Context $Context -StatusCode 201 -Data $req
}

function Get-PendingRoomRequests {
    param($Context, $User)
    if (-not (Assert-Admin -User $User -Context $Context)) { return }
    # See the comment in Get-RoomsForUser: capture before piping, and keep
    # the filter wrapped in one @(...) expression.
    $allRequests = Get-RoomRequests
    if ($null -eq $allRequests) { $allRequests = @() } elseif ($allRequests -isnot [array]) { $allRequests = @($allRequests) }
    $pending = @($allRequests | Where-Object { $_.status -eq 'pending' })
    Send-JsonResponse -Context $Context -Data $pending
}

function Approve-RoomRequestApi {
    param($Context, $User, $RequestId)
    if (-not (Assert-Admin -User $User -Context $Context)) { return }
    $body = Read-RequestJson -Context $Context
    $managers = @(Get-BodyValue -Body $body -Name 'managers' -Default @())
    $members  = @(Get-BodyValue -Body $body -Name 'members' -Default @())
    $room = Approve-RoomRequest -RequestId $RequestId -Managers $managers -Members $members
    Send-JsonResponse -Context $Context -Data (ConvertTo-RoomSummary -Room $room -Username $User.Username)
}

function Reject-RoomRequestApi {
    param($Context, $User, $RequestId)
    if (-not (Assert-Admin -User $User -Context $Context)) { return }
    Deny-RoomRequest -RequestId $RequestId
    Send-JsonResponse -Context $Context -Data ([pscustomobject]@{ ok = $true })
}

# ---------------------------------------------------------------------------
# Messages
# ---------------------------------------------------------------------------

function Get-Messages {
    param($Context, $User, $RoomId)
    $room = Get-Room -RoomId $RoomId
    if (-not $room) { Send-ErrorResponse -Context $Context -StatusCode 404 -Message 'Chatroom niet gevonden.'; return }
    if (-not (Test-CanAccessRoom -Room $room -Username $User.Username)) {
        Send-ErrorResponse -Context $Context -StatusCode 403 -Message 'Geen toegang tot deze chatroom.'; return
    }
    $limit = 100
    $qs = $Context.Request.QueryString
    if ($qs['limit']) { [void][int]::TryParse($qs['limit'], [ref]$limit) }
    $messages = Get-RoomMessages -RoomId $RoomId -Limit $limit
    Send-JsonResponse -Context $Context -Data @($messages)
}

# ---------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------

function New-RoomFileUpload {
    param($Context, $User, $RoomId)
    $room = Get-Room -RoomId $RoomId
    if (-not $room) { Send-ErrorResponse -Context $Context -StatusCode 404 -Message 'Chatroom niet gevonden.'; return }
    if (-not (Test-CanAccessRoom -Room $room -Username $User.Username)) {
        Send-ErrorResponse -Context $Context -StatusCode 403 -Message 'Geen toegang tot deze chatroom.'; return
    }

    $cfg = Get-AppConfig
    $maxBytes = [long]($cfg.maxUploadSizeMb) * 1MB
    if ($Context.Request.ContentLength64 -gt $maxBytes) {
        Send-ErrorResponse -Context $Context -StatusCode 413 -Message "Bestand is groter dan de limiet van $($cfg.maxUploadSizeMb) MB."; return
    }

    $bodyBytes = Read-RequestBodyBytes -Context $Context
    $parts = ConvertFrom-MultipartFormData -BodyBytes $bodyBytes -ContentTypeHeader $Context.Request.ContentType
    $filePart = $parts | Where-Object { $_.FileName } | Select-Object -First 1
    if (-not $filePart) {
        Send-ErrorResponse -Context $Context -StatusCode 400 -Message 'Geen bestand aangetroffen in upload.'; return
    }

    $paths = Get-StorePaths
    $roomUploadDir = Join-Path $paths.UploadsDir $RoomId
    New-Item -ItemType Directory -Force -Path $roomUploadDir | Out-Null

    $safeName = [System.IO.Path]::GetFileName($filePart.FileName)
    $storedName = "$([guid]::NewGuid().ToString()).bin"
    $fullPath = Join-Path $roomUploadDir $storedName
    [System.IO.File]::WriteAllBytes($fullPath, $filePart.Bytes)

    $record = Add-FileRecord -RoomId $RoomId -OriginalName $safeName -StoredName $storedName -Size $filePart.Bytes.Length -UploadedBy $User.Username -ContentType $filePart.ContentType
    $msg = Add-RoomMessage -RoomId $RoomId -Author $User.Username -Type 'file' -Text $safeName -FileMeta $record

    Broadcast-ToRoom -RoomId $RoomId -Data ([pscustomobject]@{ type = 'chat_message'; roomId = $RoomId; message = $msg })

    Send-JsonResponse -Context $Context -StatusCode 201 -Data $msg
}

function Get-FileDownload {
    param($Context, $User, $FileId)
    $record = Get-FileRecord -FileId $FileId
    if (-not $record) { Send-ErrorResponse -Context $Context -StatusCode 404 -Message 'Bestand niet gevonden.'; return }
    $room = Get-Room -RoomId $record.roomId
    if (-not $room -or -not (Test-CanAccessRoom -Room $room -Username $User.Username)) {
        Send-ErrorResponse -Context $Context -StatusCode 403 -Message 'Geen toegang tot dit bestand.'; return
    }
    $paths = Get-StorePaths
    $fullPath = Join-Path (Join-Path $paths.UploadsDir $record.roomId) $record.storedName
    Send-FileResponse -Context $Context -FilePath $fullPath -DownloadName $record.originalName
}

# ---------------------------------------------------------------------------
# Admin
# ---------------------------------------------------------------------------

function Get-AdminConfig {
    param($Context, $User)
    if (-not (Assert-Admin -User $User -Context $Context)) { return }
    Send-JsonResponse -Context $Context -Data (Get-AppConfig)
}

function Set-AdminConfig {
    param($Context, $User)
    if (-not (Assert-Admin -User $User -Context $Context)) { return }
    $body = Read-RequestJson -Context $Context
    $maxUpload = $null
    $historyLimit = $null
    if ($body -and (Get-Member -InputObject $body -Name maxUploadSizeMb -ErrorAction SilentlyContinue)) { $maxUpload = [int](Get-BodyValue -Body $body -Name 'maxUploadSizeMb') }
    if ($body -and (Get-Member -InputObject $body -Name messageHistoryLimit -ErrorAction SilentlyContinue)) { $historyLimit = [int](Get-BodyValue -Body $body -Name 'messageHistoryLimit') }
    $updated = Set-AppConfig -DepartmentName (Get-BodyValue -Body $body -Name 'departmentName') -MaxUploadSizeMb $maxUpload -MessageHistoryLimit $historyLimit
    Send-JsonResponse -Context $Context -Data $updated
}

function Get-AdminUsers {
    param($Context, $User)
    if (-not (Assert-Admin -User $User -Context $Context)) { return }
    $online = @()
    if ($Global:WsClients) {
        $online = @($Global:WsClients.Values | ForEach-Object { $_.Username } | Select-Object -Unique)
    }
    # Capture into a variable before piping - see the comment on Get-Room
    # in Store.psm1 for why "Get-Users | ForEach-Object" directly would be
    # wrong (Get-Users comma-protects its array return).
    $allUsers = Get-Users
    if ($null -eq $allUsers) { $allUsers = @() } elseif ($allUsers -isnot [array]) { $allUsers = @($allUsers) }
    $users = @($allUsers | ForEach-Object {
        [pscustomobject]@{
            username    = $_.username
            displayName = $_.displayName
            isAdmin     = $_.isAdmin
            lastSeen    = $_.lastSeen
            online      = $online -contains $_.username
        }
    })
    Send-JsonResponse -Context $Context -Data $users
}

function Set-AdminUserRole {
    param($Context, $User, $Username)
    if (-not (Assert-Admin -User $User -Context $Context)) { return }
    $body = Read-RequestJson -Context $Context
    $isAdmin = if ($body -and (Get-Member -InputObject $body -Name isAdmin -ErrorAction SilentlyContinue)) { [bool]$body.isAdmin } else { $false }
    Set-UserAdmin -Username $Username -IsAdmin $isAdmin | Out-Null
    Send-JsonResponse -Context $Context -Data ([pscustomobject]@{ ok = $true })
}

Export-ModuleMember -Function Invoke-ApiRequest, Invoke-Login, Invoke-Logout
