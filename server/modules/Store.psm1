#requires -version 5.1
<#
    Store.psm1
    JSON-backed persistence layer for rooms, users, messages and file metadata.
    All read-modify-write operations go through a named OS mutex so concurrent
    runspaces (one per HTTP/WebSocket connection) never corrupt the files.
#>

Set-StrictMode -Version Latest

$script:StoreMutexName = 'PillarsCreationChatStoreMutex'
$script:Paths = $null

function Initialize-Store {
    <#
        Resolves and remembers all data file paths, creates the data
        directory tree and seeds default files on first run.
    #>
    param(
        [Parameter(Mandatory)][string]$DataDir,
        [Parameter(Mandatory)][string]$UploadsDir,
        [Parameter(Mandatory)][string[]]$InitialAdmins,
        [string]$DepartmentName = 'Afdeling Chat',
        [int]$MaxUploadSizeMb = 100,
        [int]$MessageHistoryLimit = 500
    )

    $resolvedData = New-Item -ItemType Directory -Force -Path $DataDir | Select-Object -ExpandProperty FullName
    $resolvedUploads = New-Item -ItemType Directory -Force -Path $UploadsDir | Select-Object -ExpandProperty FullName
    $messagesDir = New-Item -ItemType Directory -Force -Path (Join-Path $resolvedData 'messages') | Select-Object -ExpandProperty FullName

    $script:Paths = [pscustomobject]@{
        DataDir      = $resolvedData
        UploadsDir   = $resolvedUploads
        MessagesDir  = $messagesDir
        RoomsFile    = Join-Path $resolvedData 'rooms.json'
        UsersFile    = Join-Path $resolvedData 'users.json'
        FilesFile    = Join-Path $resolvedData 'files.json'
        AppConfigFile = Join-Path $resolvedData 'app-config.json'
    }

    if (-not (Test-Path $script:Paths.RoomsFile)) {
        $seed = [pscustomobject]@{
            rooms = @(
                [pscustomobject]@{
                    id          = 'algemeen'
                    name        = 'Algemeen'
                    type        = 'public'
                    topic       = 'Afdeling-brede aankondigingen en gesprekken'
                    createdBy   = 'system'
                    createdAt   = (Get-Date).ToUniversalTime().ToString('o')
                    managers    = @()
                    members     = @()
                    archived    = $false
                }
            )
            roomRequests = @()
        }
        Write-JsonFile -Path $script:Paths.RoomsFile -Data $seed
    }

    if (-not (Test-Path $script:Paths.UsersFile)) {
        Write-JsonFile -Path $script:Paths.UsersFile -Data @()
    }

    if (-not (Test-Path $script:Paths.FilesFile)) {
        Write-JsonFile -Path $script:Paths.FilesFile -Data @()
    }

    if (-not (Test-Path $script:Paths.AppConfigFile)) {
        $cfg = [pscustomobject]@{
            departmentName       = $DepartmentName
            maxUploadSizeMb      = $MaxUploadSizeMb
            messageHistoryLimit  = $MessageHistoryLimit
            initialAdmins        = @($InitialAdmins)
        }
        Write-JsonFile -Path $script:Paths.AppConfigFile -Data $cfg
    }
    else {
        # Keep initialAdmins in sync with the bootstrap server config so a
        # redeploy that changes admins.json-equivalent settings still applies.
        $cfg = Read-JsonFile -Path $script:Paths.AppConfigFile -DefaultValue $null
        if ($null -ne $cfg) {
            $cfg | Add-Member -NotePropertyName initialAdmins -NotePropertyValue @($InitialAdmins) -Force
            Write-JsonFile -Path $script:Paths.AppConfigFile -Data $cfg
        }
    }

    return $script:Paths
}

function Get-StorePaths { return $script:Paths }

function Invoke-WithStoreLock {
    <#
        PowerShell unrolls arrays it emits across a function/scriptblock
        return boundary (an empty array becomes $null, a 1-item array
        becomes a bare scalar) *every time* the value crosses such a
        boundary - wrapping with @() earlier does not survive a later,
        unprotected return. Every layer in the call chain that might carry
        an array therefore re-wraps with the unary comma operator before
        handing it back, and this function is the innermost one.
    #>
    param([Parameter(Mandatory)][scriptblock]$Action)
    $mutex = New-Object System.Threading.Mutex($false, $script:StoreMutexName)
    $acquired = $false
    try {
        $acquired = $mutex.WaitOne(15000)
        if (-not $acquired) {
            throw 'Kon de store-lock niet verkrijgen (timeout na 15s).'
        }
        $result = & $Action
        if ($result -is [array]) { , $result } else { $result }
    }
    finally {
        if ($acquired) { [void]$mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Read-JsonFile {
    <#
        Returns whatever was stored at $Path: a real array when the JSON
        was an array (always, even for "[]" - see the inline comment on
        why that needs care), or a single object when the JSON was an
        object. Every caller can rely on a plain "$x = Read-JsonFile ..."
        to get the right shape back; none of them need to re-wrap the
        result themselves.

        NOTE: a helper like "if array, `,$Value` else $Value" cannot be
        factored out into its own function here - PowerShell re-unrolls
        an array *again* at every further return boundary it crosses, so
        the comma has to be written at each literal `return` below, not
        delegated.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        $DefaultValue = $null
    )
    if (-not (Test-Path $Path)) {
        if ($DefaultValue -is [array]) { return , $DefaultValue } else { return $DefaultValue }
    }
    $raw = Get-Content -Path $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        if ($DefaultValue -is [array]) { return , $DefaultValue } else { return $DefaultValue }
    }

    if ($raw.TrimStart().StartsWith('[')) {
        # ConvertFrom-Json behaves OPPOSITELY on the two PowerShell versions
        # this must run on. PowerShell 7 emits each JSON-array element as a
        # separate pipeline object (so "[]" is zero objects and a bare
        # assignment collapses to $null - hence the @() wrap). Windows
        # PowerShell 5.1 instead emits the WHOLE array as ONE pipeline
        # object, so on 5.1 a bare @(...) wrap NESTS it: you get a
        # 1-element array whose only element is the real element array.
        # Every later "$x | Where-Object { $_.prop }" then receives that
        # inner array as $_ and dies under StrictMode with "The property
        # '...' cannot be found on this object" - the production login-500
        # crash. ForEach-Object { $_ } re-emits (and thereby flattens)
        # exactly one collection level on both versions, so combined with
        # @() this yields a flat 0/1/N-element array everywhere. The
        # leading comma still protects the result across this function's
        # own return boundary, which would otherwise unroll it right back.
        return , @($raw | ConvertFrom-Json | ForEach-Object { $_ })
    }
    return $raw | ConvertFrom-Json
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Data
    )
    $tmpPath = "$Path.tmp"
    # -InputObject (not a pipe) is required here: an empty array piped into
    # ConvertTo-Json is unwrapped into zero pipeline items and produces no
    # output at all, silently truncating the file to empty.
    $json = ConvertTo-Json -InputObject $Data -Depth 25
    Set-Content -Path $tmpPath -Value $json -Encoding UTF8
    Move-Item -Path $tmpPath -Destination $Path -Force
}

function Update-JsonStore {
    <#
        Locked read-transform-write. $Transform receives the current data
        (or $DefaultValue) and must return the new data to persist.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][scriptblock]$Transform,
        $DefaultValue = $null
    )
    Invoke-WithStoreLock -Action {
        $current = Read-JsonFile -Path $Path -DefaultValue $DefaultValue
        $updated = & $Transform $current
        Write-JsonFile -Path $Path -Data $updated
        if ($updated -is [array]) { , $updated } else { $updated }
    }
}

# ---------------------------------------------------------------------------
# App configuration
# ---------------------------------------------------------------------------

function Get-AppConfig {
    return Read-JsonFile -Path $script:Paths.AppConfigFile
}

function Set-AppConfig {
    param(
        [string]$DepartmentName,
        [Nullable[int]]$MaxUploadSizeMb,
        [Nullable[int]]$MessageHistoryLimit
    )
    return Update-JsonStore -Path $script:Paths.AppConfigFile -Transform {
        param($cfg)
        if ($DepartmentName)                    { $cfg.departmentName = $DepartmentName }
        if ($null -ne $MaxUploadSizeMb)          { $cfg.maxUploadSizeMb = $MaxUploadSizeMb }
        if ($null -ne $MessageHistoryLimit)      { $cfg.messageHistoryLimit = $MessageHistoryLimit }
        return $cfg
    }
}

function Test-IsAdmin {
    param([Parameter(Mandatory)][string]$Username)
    $cfg = Get-AppConfig
    $initial = @($cfg.initialAdmins) | Where-Object { $_ -and $_.ToLowerInvariant() -eq $Username.ToLowerInvariant() }
    if ($initial) { return $true }
    $user = Get-UserProfile -Username $Username -CreateIfMissing:$false
    if ($null -ne $user -and $user.isAdmin) { return $true }
    return $false
}

# ---------------------------------------------------------------------------
# Users
# ---------------------------------------------------------------------------

function Get-Users {
    # No @() here: Read-JsonFile already returns a properly comma-protected
    # array by itself - wrapping its call in @() again would collect that
    # one already-correct array as a single element of a *new* array,
    # nesting it one level too deep.
    return , (Read-JsonFile -Path $script:Paths.UsersFile -DefaultValue @())
}

function Get-UserProfile {
    param(
        [Parameter(Mandatory)][string]$Username,
        [switch]$CreateIfMissing
    )
    $users = Get-Users
    # Defensive, explicit normalization rather than relying on comma-operator
    # array-boundary behavior: that was verified against PowerShell 7/.NET 8
    # in this environment, but this project's actual target is Windows
    # PowerShell 5.1/.NET Framework, which has been observed (see git log)
    # to collapse an empty Get-Users result differently, breaking a bare
    # "$users | Where-Object ..." with a StrictMode "property not found"
    # error. This check is unambiguous regardless of PowerShell version.
    if ($null -eq $users) { $users = @() } elseif ($users -isnot [array]) { $users = @($users) }
    $existing = $users | Where-Object { $_.username -eq $Username } | Select-Object -First 1
    if ($existing) { return $existing }
    if (-not $CreateIfMissing) { return $null }

    $created = Update-JsonStore -Path $script:Paths.UsersFile -DefaultValue @() -Transform {
        param($list)
        # Explicit normalization (see Get-UserProfile's comment on why):
        # a bare @($list) would turn a genuine $null into a 1-element
        # array *containing* null instead of an empty array.
        if ($null -eq $list) { $list = @() } elseif ($list -isnot [array]) { $list = @($list) }
        $already = $list | Where-Object { $_.username -eq $Username }
        if ($already) { return , $list }
        $newUser = [pscustomobject]@{
            username    = $Username
            displayName = ($Username -split '\\')[-1]
            isAdmin     = $false
            settings    = [pscustomobject]@{
                theme               = 'light'
                notificationsSound  = $true
                displayNameOverride = $null
            }
            firstSeen = (Get-Date).ToUniversalTime().ToString('o')
            lastSeen  = (Get-Date).ToUniversalTime().ToString('o')
        }
        , ($list + $newUser)
    }
    return $created | Where-Object { $_.username -eq $Username } | Select-Object -First 1
}

function Update-UserLastSeen {
    param([Parameter(Mandatory)][string]$Username)
    [void](Update-JsonStore -Path $script:Paths.UsersFile -DefaultValue @() -Transform {
        param($list)
        # Explicit normalization (see Get-UserProfile's comment on why):
        # a bare @($list) would turn a genuine $null into a 1-element
        # array *containing* null instead of an empty array.
        if ($null -eq $list) { $list = @() } elseif ($list -isnot [array]) { $list = @($list) }
        foreach ($u in $list) {
            if ($u.username -eq $Username) { $u.lastSeen = (Get-Date).ToUniversalTime().ToString('o') }
        }
        return , $list
    })
}

function Set-UserSettings {
    param(
        [Parameter(Mandatory)][string]$Username,
        [string]$DisplayName,
        [string]$Theme,
        [Nullable[bool]]$NotificationsSound,
        [string]$DisplayNameOverride
    )
    # $PSBoundParameters is itself an automatic variable: the nested
    # -Transform scriptblock below has its own param() block, so it gets
    # its *own* fresh $PSBoundParameters (containing only "list") rather
    # than inheriting this function's - unlike regular variables such as
    # $DisplayNameOverride, which normal lexical scoping does carry into
    # the scriptblock. Capture the ContainsKey() check here, in a plain
    # variable, before the nested scriptblock needs it.
    $hasDisplayNameOverride = $PSBoundParameters.ContainsKey('DisplayNameOverride')
    return Update-JsonStore -Path $script:Paths.UsersFile -DefaultValue @() -Transform {
        param($list)
        # Explicit normalization (see Get-UserProfile's comment on why):
        # a bare @($list) would turn a genuine $null into a 1-element
        # array *containing* null instead of an empty array.
        if ($null -eq $list) { $list = @() } elseif ($list -isnot [array]) { $list = @($list) }
        foreach ($u in $list) {
            if ($u.username -eq $Username) {
                if ($DisplayName) { $u.displayName = $DisplayName }
                if ($Theme) { $u.settings.theme = $Theme }
                if ($null -ne $NotificationsSound) { $u.settings.notificationsSound = $NotificationsSound }
                if ($hasDisplayNameOverride) { $u.settings.displayNameOverride = $DisplayNameOverride }
            }
        }
        return , $list
    }
}

function Set-UserAdmin {
    param(
        [Parameter(Mandatory)][string]$Username,
        [Parameter(Mandatory)][bool]$IsAdmin
    )
    return Update-JsonStore -Path $script:Paths.UsersFile -DefaultValue @() -Transform {
        param($list)
        # Explicit normalization (see Get-UserProfile's comment on why):
        # a bare @($list) would turn a genuine $null into a 1-element
        # array *containing* null instead of an empty array.
        if ($null -eq $list) { $list = @() } elseif ($list -isnot [array]) { $list = @($list) }
        foreach ($u in $list) {
            if ($u.username -eq $Username) { $u.isAdmin = $IsAdmin }
        }
        return , $list
    }
}

# ---------------------------------------------------------------------------
# Rooms
# ---------------------------------------------------------------------------

function Get-RoomsData {
    return Read-JsonFile -Path $script:Paths.RoomsFile -DefaultValue ([pscustomobject]@{ rooms = @(); roomRequests = @() })
}

function Get-Rooms { return , @((Get-RoomsData).rooms) }
function Get-RoomRequests { return , @((Get-RoomsData).roomRequests) }

function Get-Room {
    param([Parameter(Mandatory)][string]$RoomId)
    # Capture into a variable before piping: Get-Rooms comma-protects its
    # array return (see Read-JsonFile's comment), which means a *direct*
    # "Get-Rooms | Where-Object" would hand Where-Object the whole rooms
    # array as a single input item (matched via member-enumeration against
    # every room's id) instead of iterating room-by-room, so it would
    # return the entire array back out instead of the one matching room.
    # Piping an already-assigned array *variable* does not have this
    # problem - only a live function-call-to-pipe does.
    $rooms = Get-Rooms
    # See the normalization comment in Get-UserProfile: explicit rather
    # than relying on comma-operator behavior across PowerShell versions.
    if ($null -eq $rooms) { $rooms = @() } elseif ($rooms -isnot [array]) { $rooms = @($rooms) }
    return $rooms | Where-Object { $_.id -eq $RoomId } | Select-Object -First 1
}

function Test-CanAccessRoom {
    param([Parameter(Mandatory)]$Room, [Parameter(Mandatory)][string]$Username)
    if ($Room.type -eq 'public') { return $true }
    if (Test-IsAdmin -Username $Username) { return $true }
    if (@($Room.managers) -contains $Username) { return $true }
    if (@($Room.members) -contains $Username) { return $true }
    return $false
}

function Test-IsRoomManager {
    param([Parameter(Mandatory)]$Room, [Parameter(Mandatory)][string]$Username)
    if ($Room.type -eq 'public') { return $true }
    if (Test-IsAdmin -Username $Username) { return $true }
    return (@($Room.managers) -contains $Username)
}

function New-PublicRoom {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Topic = '',
        [Parameter(Mandatory)][string]$CreatedBy
    )
    $result = Update-JsonStore -Path $script:Paths.RoomsFile -Transform {
        param($data)
        $room = [pscustomobject]@{
            id        = [guid]::NewGuid().ToString()
            name      = $Name
            type      = 'public'
            topic     = $Topic
            createdBy = $CreatedBy
            createdAt = (Get-Date).ToUniversalTime().ToString('o')
            managers  = @()
            members   = @()
            archived  = $false
        }
        $data.rooms = @($data.rooms) + $room
        return $data
    }
    return $result.rooms | Select-Object -Last 1
}

function New-PrivateRoom {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Topic = '',
        [Parameter(Mandatory)][string]$CreatedBy,
        [string[]]$Managers = @(),
        [string[]]$Members = @()
    )
    $allManagers = @($Managers) | Where-Object { $_ }
    if ($allManagers -notcontains $CreatedBy) { $allManagers += $CreatedBy }
    $allMembers = (@($Members) + $allManagers) | Select-Object -Unique

    $result = Update-JsonStore -Path $script:Paths.RoomsFile -Transform {
        param($data)
        $room = [pscustomobject]@{
            id        = [guid]::NewGuid().ToString()
            name      = $Name
            type      = 'private'
            topic     = $Topic
            createdBy = $CreatedBy
            createdAt = (Get-Date).ToUniversalTime().ToString('o')
            managers  = @($allManagers)
            members   = @($allMembers)
            archived  = $false
        }
        $data.rooms = @($data.rooms) + $room
        return $data
    }
    return $result.rooms | Select-Object -Last 1
}

function Add-RoomRequest {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Purpose = '',
        [Parameter(Mandatory)][string]$RequestedBy,
        [string[]]$ProposedMembers = @()
    )
    $result = Update-JsonStore -Path $script:Paths.RoomsFile -Transform {
        param($data)
        $req = [pscustomobject]@{
            id              = [guid]::NewGuid().ToString()
            name            = $Name
            purpose         = $Purpose
            requestedBy     = $RequestedBy
            proposedMembers = @($ProposedMembers)
            requestedAt     = (Get-Date).ToUniversalTime().ToString('o')
            status          = 'pending'
        }
        $data.roomRequests = @($data.roomRequests) + $req
        return $data
    }
    return $result.roomRequests | Select-Object -Last 1
}

function Approve-RoomRequest {
    param(
        [Parameter(Mandatory)][string]$RequestId,
        [string[]]$Managers = @(),
        [string[]]$Members = @()
    )
    # See the comment in Get-Room: capture before piping, not "FunctionCall | Where-Object" directly.
    $allRequests = Get-RoomRequests
    # See the normalization comment in Get-UserProfile.
    if ($null -eq $allRequests) { $allRequests = @() } elseif ($allRequests -isnot [array]) { $allRequests = @($allRequests) }
    $request = $allRequests | Where-Object { $_.id -eq $RequestId } | Select-Object -First 1
    if (-not $request) { throw "Aanvraag $RequestId niet gevonden." }
    if ($request.status -ne 'pending') { throw "Aanvraag $RequestId is al verwerkt." }

    $mgrs = if ($Managers.Count -gt 0) { $Managers } else { @($request.requestedBy) }
    $mbrs = if ($Members.Count -gt 0) { $Members } else { @($request.proposedMembers) }

    $room = New-PrivateRoom -Name $request.name -Topic $request.purpose -CreatedBy $request.requestedBy -Managers $mgrs -Members $mbrs

    [void](Update-JsonStore -Path $script:Paths.RoomsFile -Transform {
        param($data)
        foreach ($r in $data.roomRequests) {
            if ($r.id -eq $RequestId) { $r.status = 'approved' }
        }
        return $data
    })
    return $room
}

function Deny-RoomRequest {
    param([Parameter(Mandatory)][string]$RequestId)
    [void](Update-JsonStore -Path $script:Paths.RoomsFile -Transform {
        param($data)
        foreach ($r in $data.roomRequests) {
            if ($r.id -eq $RequestId) { $r.status = 'rejected' }
        }
        return $data
    })
}

function Update-RoomDetails {
    param(
        [Parameter(Mandatory)][string]$RoomId,
        [string]$Name,
        [string]$Topic,
        [Nullable[bool]]$Archived
    )
    # See the comment in Set-UserSettings: $PSBoundParameters does not
    # flow into a nested scriptblock that has its own param() block, so
    # the ContainsKey() check is captured here instead.
    $hasTopic = $PSBoundParameters.ContainsKey('Topic')
    $result = Update-JsonStore -Path $script:Paths.RoomsFile -Transform {
        param($data)
        foreach ($r in $data.rooms) {
            if ($r.id -eq $RoomId) {
                if ($Name) { $r.name = $Name }
                if ($hasTopic) { $r.topic = $Topic }
                if ($null -ne $Archived) { $r.archived = $Archived }
            }
        }
        return $data
    }
    return $result.rooms | Where-Object { $_.id -eq $RoomId } | Select-Object -First 1
}

function Remove-Room {
    param([Parameter(Mandatory)][string]$RoomId)
    [void](Update-JsonStore -Path $script:Paths.RoomsFile -Transform {
        param($data)
        $data.rooms = @($data.rooms | Where-Object { $_.id -ne $RoomId })
        return $data
    })
    $msgFile = Join-Path $script:Paths.MessagesDir "$RoomId.json"
    if (Test-Path $msgFile) { Remove-Item -Path $msgFile -Force }
}

function Add-RoomMember {
    param(
        [Parameter(Mandatory)][string]$RoomId,
        [Parameter(Mandatory)][string]$Username,
        [switch]$AsManager
    )
    $result = Update-JsonStore -Path $script:Paths.RoomsFile -Transform {
        param($data)
        foreach ($r in $data.rooms) {
            if ($r.id -eq $RoomId) {
                if (@($r.members) -notcontains $Username) { $r.members = @($r.members) + $Username }
                if ($AsManager -and (@($r.managers) -notcontains $Username)) { $r.managers = @($r.managers) + $Username }
            }
        }
        return $data
    }
    return $result.rooms | Where-Object { $_.id -eq $RoomId } | Select-Object -First 1
}

function Remove-RoomMember {
    param(
        [Parameter(Mandatory)][string]$RoomId,
        [Parameter(Mandatory)][string]$Username
    )
    $result = Update-JsonStore -Path $script:Paths.RoomsFile -Transform {
        param($data)
        foreach ($r in $data.rooms) {
            if ($r.id -eq $RoomId) {
                $r.members = @($r.members | Where-Object { $_ -ne $Username })
                $r.managers = @($r.managers | Where-Object { $_ -ne $Username })
            }
        }
        return $data
    }
    return $result.rooms | Where-Object { $_.id -eq $RoomId } | Select-Object -First 1
}

# ---------------------------------------------------------------------------
# Messages
# ---------------------------------------------------------------------------

function Get-RoomMessageFile {
    param([Parameter(Mandatory)][string]$RoomId)
    return Join-Path $script:Paths.MessagesDir "$RoomId.json"
}

function Get-RoomMessages {
    param(
        [Parameter(Mandatory)][string]$RoomId,
        [int]$Limit = 100
    )
    $path = Get-RoomMessageFile -RoomId $RoomId
    $all = Read-JsonFile -Path $path -DefaultValue @()
    # See the normalization comment in Get-UserProfile. $all.Count below
    # would throw (or on PowerShell 7+ only, silently read as 0 - not a
    # guarantee to rely on) if $all collapsed to $null instead of a real
    # empty array.
    if ($null -eq $all) { $all = @() } elseif ($all -isnot [array]) { $all = @($all) }
    if ($all.Count -le $Limit) { return , $all }
    return , $all[($all.Count - $Limit)..($all.Count - 1)]
}

function Add-RoomMessage {
    param(
        [Parameter(Mandatory)][string]$RoomId,
        [Parameter(Mandatory)][string]$Author,
        [Parameter(Mandatory)][string]$Type,
        [string]$Text = '',
        $FileMeta = $null
    )
    $cfg = Get-AppConfig
    $limit = if ($cfg -and $cfg.messageHistoryLimit) { [int]$cfg.messageHistoryLimit } else { 500 }
    $path = Get-RoomMessageFile -RoomId $RoomId

    $message = [pscustomobject]@{
        id        = [guid]::NewGuid().ToString()
        roomId    = $RoomId
        author    = $Author
        type      = $Type
        text      = $Text
        file      = $FileMeta
        createdAt = (Get-Date).ToUniversalTime().ToString('o')
    }

    [void](Update-JsonStore -Path $path -DefaultValue @() -Transform {
        param($list)
        # Explicit normalization (see Get-UserProfile's comment on why):
        # a bare @($list) would turn a genuine $null into a 1-element
        # array *containing* null instead of an empty array.
        if ($null -eq $list) { $list = @() } elseif ($list -isnot [array]) { $list = @($list) }
        $list = $list + $message
        if ($list.Count -gt $limit) { $list = $list[($list.Count - $limit)..($list.Count - 1)] }
        return , $list
    })
    return $message
}

# ---------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------

function Add-FileRecord {
    param(
        [Parameter(Mandatory)][string]$RoomId,
        [Parameter(Mandatory)][string]$OriginalName,
        [Parameter(Mandatory)][string]$StoredName,
        [Parameter(Mandatory)][long]$Size,
        [Parameter(Mandatory)][string]$UploadedBy,
        [string]$ContentType = 'application/octet-stream'
    )
    $record = [pscustomobject]@{
        id           = [guid]::NewGuid().ToString()
        roomId       = $RoomId
        originalName = $OriginalName
        storedName   = $StoredName
        size         = $Size
        uploadedBy   = $UploadedBy
        contentType  = $ContentType
        uploadedAt   = (Get-Date).ToUniversalTime().ToString('o')
    }
    [void](Update-JsonStore -Path $script:Paths.FilesFile -DefaultValue @() -Transform {
        param($list)
        if ($null -eq $list) { $list = @() } elseif ($list -isnot [array]) { $list = @($list) }
        return , ($list + $record)
    })
    return $record
}

function Get-FileRecord {
    param([Parameter(Mandatory)][string]$FileId)
    $all = Read-JsonFile -Path $script:Paths.FilesFile -DefaultValue @()
    # See the normalization comment in Get-UserProfile.
    if ($null -eq $all) { $all = @() } elseif ($all -isnot [array]) { $all = @($all) }
    return $all | Where-Object { $_.id -eq $FileId } | Select-Object -First 1
}

Export-ModuleMember -Function *-*
