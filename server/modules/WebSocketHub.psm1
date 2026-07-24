#requires -version 5.1
<#
    WebSocketHub.psm1
    Tracks connected WebSocket clients (one OS thread/runspace per
    connection) in a process-wide synchronized registry and provides
    broadcast helpers for chat messages, presence and call relay
    (audio chunks / screen-share frames get relayed through the server,
    there is no peer-to-peer WebRTC involved).
#>

Set-StrictMode -Version Latest

function Initialize-WsHub {
    <#
        Each HTTP/WebSocket connection is handled on its own PowerShell
        Runspace, and Runspaces do NOT share $Global: scope with each
        other even inside the same process. To get one registry that is
        truly shared, the synchronized hashtable is stashed in an
        AppDomain data slot (the AppDomain *is* shared by every Runspace
        in this process) and every Runspace fetches/creates it from there.
    #>
    $existing = [System.AppDomain]::CurrentDomain.GetData('PillarsChat.WsClients')
    if ($null -eq $existing) {
        $existing = [hashtable]::Synchronized(@{})
        [System.AppDomain]::CurrentDomain.SetData('PillarsChat.WsClients', $existing)
    }
    $Global:WsClients = $existing
}

function Register-WsClient {
    param(
        [Parameter(Mandatory)][string]$ConnectionId,
        [Parameter(Mandatory)]$Socket,
        [Parameter(Mandatory)][string]$Username,
        [Parameter(Mandatory)][string]$DisplayName
    )
    $Global:WsClients[$ConnectionId] = [pscustomobject]@{
        Socket      = $Socket
        Username    = $Username
        DisplayName = $DisplayName
        Rooms       = New-Object System.Collections.Generic.List[string]
        SendLock    = New-Object System.Object
    }
}

function Unregister-WsClient {
    param([Parameter(Mandatory)][string]$ConnectionId)
    if ($Global:WsClients.ContainsKey($ConnectionId)) {
        $rooms = @($Global:WsClients[$ConnectionId].Rooms)
        $Global:WsClients.Remove($ConnectionId)
        return $rooms
    }
    return @()
}

function Get-WsClient {
    param([Parameter(Mandatory)][string]$ConnectionId)
    if ($Global:WsClients.ContainsKey($ConnectionId)) { return $Global:WsClients[$ConnectionId] }
    return $null
}

function Join-WsRoom {
    param([Parameter(Mandatory)][string]$ConnectionId, [Parameter(Mandatory)][string]$RoomId)
    $client = Get-WsClient -ConnectionId $ConnectionId
    if ($null -eq $client) { return }
    if (-not $client.Rooms.Contains($RoomId)) { $client.Rooms.Add($RoomId) }
}

function Leave-WsRoom {
    param([Parameter(Mandatory)][string]$ConnectionId, [Parameter(Mandatory)][string]$RoomId)
    $client = Get-WsClient -ConnectionId $ConnectionId
    if ($null -eq $client) { return }
    [void]$client.Rooms.Remove($RoomId)
}

function Get-ClientsInRoom {
    param([Parameter(Mandatory)][string]$RoomId)
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($key in @($Global:WsClients.Keys)) {
        $client = $Global:WsClients[$key]
        if ($null -ne $client -and $client.Rooms.Contains($RoomId)) {
            $result.Add(@{ ConnectionId = $key; Client = $client })
        }
    }
    return $result
}

function Get-OnlineUsersInRoom {
    param([Parameter(Mandatory)][string]$RoomId)
    $entries = Get-ClientsInRoom -RoomId $RoomId
    return @($entries | ForEach-Object { $_.Client.Username } | Select-Object -Unique)
}

function Send-WsJson {
    param(
        [Parameter(Mandatory)]$Client,
        [Parameter(Mandatory)]$Data
    )
    $json = ConvertTo-Json -InputObject $Data -Depth 15 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $segment = New-Object System.ArraySegment[byte] (,$bytes)

    [System.Threading.Monitor]::Enter($Client.SendLock)
    try {
        if ($Client.Socket.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            $Client.Socket.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
        }
    }
    catch {
        # Socket likely dropped mid-send; the receive loop for that
        # connection will notice and clean the registry up.
    }
    finally {
        [System.Threading.Monitor]::Exit($Client.SendLock)
    }
}

function Send-WsJsonToConnection {
    param([Parameter(Mandatory)][string]$ConnectionId, [Parameter(Mandatory)]$Data)
    $client = Get-WsClient -ConnectionId $ConnectionId
    if ($null -ne $client) { Send-WsJson -Client $client -Data $Data }
}

function Broadcast-ToRoom {
    param(
        [Parameter(Mandatory)][string]$RoomId,
        [Parameter(Mandatory)]$Data,
        [string]$ExcludeConnectionId = $null
    )
    foreach ($entry in Get-ClientsInRoom -RoomId $RoomId) {
        if ($ExcludeConnectionId -and $entry.ConnectionId -eq $ExcludeConnectionId) { continue }
        Send-WsJson -Client $entry.Client -Data $Data
    }
}

function Send-PresenceUpdate {
    param([Parameter(Mandatory)][string]$RoomId)
    Broadcast-ToRoom -RoomId $RoomId -Data ([pscustomobject]@{
        type   = 'presence'
        roomId = $RoomId
        online = @(Get-OnlineUsersInRoom -RoomId $RoomId)
    })
}

function Start-WsConnection {
    <#
        Accepts the WebSocket handshake for an already-authenticated
        HttpListenerContext and runs the blocking receive loop for that
        connection's lifetime. Meant to run inside its own dedicated
        Runspace so it can block without stalling the accept loop or any
        other connection.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$User
    )

    $wsContext = $Context.AcceptWebSocketAsync($null).GetAwaiter().GetResult()
    $socket = $wsContext.WebSocket
    $connectionId = [guid]::NewGuid().ToString()

    Register-WsClient -ConnectionId $connectionId -Socket $socket -Username $User.Username -DisplayName $User.DisplayName
    $client = Get-WsClient -ConnectionId $connectionId
    Send-WsJson -Client $client -Data ([pscustomobject]@{ type = 'hello'; connectionId = $connectionId; username = $User.Username; displayName = $User.DisplayName })

    $bufferSize = 16384
    $buffer = New-Object byte[] $bufferSize

    try {
        while ($socket.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            $ms = New-Object System.IO.MemoryStream
            $endOfMessage = $false
            $closeReceived = $false
            while (-not $endOfMessage) {
                $segment = New-Object System.ArraySegment[byte] (,$buffer)
                $result = $socket.ReceiveAsync($segment, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
                if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                    $closeReceived = $true
                    $endOfMessage = $true
                    break
                }
                if ($result.Count -gt 0) { $ms.Write($buffer, 0, $result.Count) }
                $endOfMessage = $result.EndOfMessage
            }
            if ($closeReceived) { break }

            $text = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
            $ms.Dispose()
            if ([string]::IsNullOrWhiteSpace($text)) { continue }

            try {
                $payload = $text | ConvertFrom-Json
                Invoke-WsMessage -ConnectionId $connectionId -User $User -Payload $payload
            }
            catch {
                Send-WsJson -Client $client -Data ([pscustomobject]@{ type = 'error'; message = "Ongeldig bericht: $($_.Exception.Message)" })
            }
        }
    }
    finally {
        $rooms = Unregister-WsClient -ConnectionId $connectionId
        foreach ($roomId in $rooms) { Send-PresenceUpdate -RoomId $roomId }
        try {
            $closeableStates = @([System.Net.WebSockets.WebSocketState]::Open, [System.Net.WebSockets.WebSocketState]::CloseReceived)
            if ($closeableStates -contains $socket.State) {
                $socket.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'bye', [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
            }
        }
        catch { }
        $socket.Dispose()
    }
}

function Invoke-WsMessage {
    <#
        Dispatches one parsed client -> server WebSocket message. Handles
        chat/presence itself via the Store module and relays call_signal
        (audio chunks, screen-share frames, join/leave) to the other
        participants currently viewing the same room - this is a
        server-relayed model, not peer-to-peer WebRTC.
    #>
    param(
        [Parameter(Mandatory)][string]$ConnectionId,
        [Parameter(Mandatory)]$User,
        [Parameter(Mandatory)]$Payload
    )
    $client = Get-WsClient -ConnectionId $ConnectionId
    if ($null -eq $client) { return }

    $msgType = if (Get-Member -InputObject $Payload -Name type -ErrorAction SilentlyContinue) { $Payload.type } else { $null }

    switch ($msgType) {
        'join_room' {
            $room = Get-Room -RoomId $Payload.roomId
            if (-not $room -or -not (Test-CanAccessRoom -Room $room -Username $User.Username)) {
                Send-WsJson -Client $client -Data ([pscustomobject]@{ type = 'error'; message = 'Geen toegang tot deze chatroom.' })
                return
            }
            Join-WsRoom -ConnectionId $ConnectionId -RoomId $Payload.roomId
            $history = Get-RoomMessages -RoomId $Payload.roomId -Limit 100
            Send-WsJson -Client $client -Data ([pscustomobject]@{ type = 'room_history'; roomId = $Payload.roomId; messages = @($history) })
            Send-PresenceUpdate -RoomId $Payload.roomId
        }
        'leave_room' {
            Leave-WsRoom -ConnectionId $ConnectionId -RoomId $Payload.roomId
            Send-PresenceUpdate -RoomId $Payload.roomId
        }
        'chat_message' {
            $room = Get-Room -RoomId $Payload.roomId
            if (-not $room -or -not (Test-CanAccessRoom -Room $room -Username $User.Username)) { return }
            $text = "$($Payload.text)".Trim()
            if ([string]::IsNullOrWhiteSpace($text)) { return }
            if ($text.Length -gt 8000) { $text = $text.Substring(0, 8000) }
            $msg = Add-RoomMessage -RoomId $Payload.roomId -Author $User.Username -Type 'text' -Text $text
            Broadcast-ToRoom -RoomId $Payload.roomId -Data ([pscustomobject]@{ type = 'chat_message'; roomId = $Payload.roomId; message = $msg })
        }
        'typing' {
            Broadcast-ToRoom -RoomId $Payload.roomId -ExcludeConnectionId $ConnectionId -Data ([pscustomobject]@{
                type     = 'typing'
                roomId   = $Payload.roomId
                username = $User.Username
                isTyping = [bool]$Payload.isTyping
            })
        }
        'call_signal' {
            $room = Get-Room -RoomId $Payload.roomId
            if (-not $room -or -not (Test-CanAccessRoom -Room $room -Username $User.Username)) { return }
            Broadcast-ToRoom -RoomId $Payload.roomId -ExcludeConnectionId $ConnectionId -Data ([pscustomobject]@{
                type            = 'call_signal'
                roomId          = $Payload.roomId
                callId          = $Payload.callId
                kind            = $Payload.kind
                from            = $User.Username
                fromDisplayName = $User.DisplayName
                data            = $Payload.data
            })
        }
        default {
            Send-WsJson -Client $client -Data ([pscustomobject]@{ type = 'error'; message = "Onbekend berichttype: $msgType" })
        }
    }
}

Export-ModuleMember -Function *-*
