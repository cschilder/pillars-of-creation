#requires -version 5.1
<#
    ConnectionWorker.ps1
    Entry point executed inside a dedicated Runspace for exactly one
    accepted TcpClient. One Runspace per connection means a slow upload
    or an open call never blocks any other user.

    /api/login and static files (including index.html itself) are
    reachable without a "chatuser" cookie - you need the page and the
    login form before you can log in at all. Everything else under
    /api/* and the /ws WebSocket both require the cookie.
#>
param(
    [Parameter(Mandatory)]$TcpClient,
    [Parameter(Mandatory)]$Config
)

Set-StrictMode -Version Latest

$Context = $null
$wsHandshakeDone = $false

try {
    Initialize-Store -DataDir $Config.DataDir -UploadsDir $Config.UploadsDir -InitialAdmins $Config.InitialAdmins `
        -DepartmentName $Config.DepartmentName -MaxUploadSizeMb $Config.MaxUploadSizeMb -MessageHistoryLimit $Config.MessageHistoryLimit | Out-Null
    Initialize-WsHub

    $stream = $TcpClient.GetStream()
    $Context = New-HttpContextFromStream -Stream $stream
    if ($null -eq $Context) { return }

    if ($Context.Request.IsWebSocketRequest) {
        $user = Resolve-RequestUser -Context $Context
        if ($null -eq $user) {
            $Context.Response.StatusCode = 401
            Send-RawHttpResponse -Context $Context
            return
        }
        # Set *before* the call: Start-WebSocketHandshake writes the 101
        # response to the raw socket as its first step, so even if it
        # throws partway through (e.g. while wrapping the stream), the
        # client has already received it and must not also get a second,
        # plain-HTTP response layered on top from the catch block below.
        $wsHandshakeDone = $true
        $socket = Start-WebSocketHandshake -Context $Context
        try {
            Start-WsConnection -Socket $socket -User $user
        }
        finally {
            try { $socket.Dispose() } catch { }
        }
        return
    }

    $path = $Context.Request.Url.AbsolutePath

    if ($path -eq '/api/login') {
        if ($Context.Request.HttpMethod -eq 'POST') { Invoke-Login -Context $Context }
        else { Send-ErrorResponse -Context $Context -StatusCode 404 -Message 'Onbekende route.' }
    }
    elseif ($path -eq '/api/logout') {
        if ($Context.Request.HttpMethod -eq 'POST') { Invoke-Logout -Context $Context }
        else { Send-ErrorResponse -Context $Context -StatusCode 404 -Message 'Onbekende route.' }
    }
    elseif ($path -like '/api/*') {
        $user = Resolve-RequestUser -Context $Context
        if ($null -eq $user) {
            Send-ErrorResponse -Context $Context -StatusCode 401 -Message 'Niet ingelogd.'
        }
        else {
            Invoke-ApiRequest -Context $Context -User $user
        }
    }
    else {
        $filePath = Resolve-StaticFilePath -WwwRoot $Config.WwwRootDir -UrlPath $path
        if ($null -eq $filePath) {
            Send-ErrorResponse -Context $Context -StatusCode 404 -Message 'Niet gevonden.'
        }
        else {
            Send-FileResponse -Context $Context -FilePath $filePath
        }
    }

    Send-RawHttpResponse -Context $Context
}
catch {
    $errPosition = "$($_.InvocationInfo.PositionMessage)".Replace("`r", ' ').Replace("`n", ' ')
    $errStack = "$($_.ScriptStackTrace)".Replace("`r", ' ').Replace("`n", ' > ')
    Write-Warning "Verbindingsfout: $($_.Exception.Message) | Bij: $errPosition | Stack: $errStack"
    # Once the WebSocket opening handshake has been written to the socket,
    # the stream is speaking the WebSocket framing protocol from the
    # client's point of view - writing a second, plain-text HTTP response
    # into it at that point doesn't get rejected by anything, it just gets
    # misparsed as garbled/corrupt WebSocket frames. Only attempt the
    # ordinary HTTP error response for requests that never left HTTP.
    if ($null -ne $Context -and -not $wsHandshakeDone) {
        try {
            $Context.Response.StatusCode = 500
            $Context.Response.ContentType = 'text/plain; charset=utf-8'
            $Context.Response.OutputStream = New-Object System.IO.MemoryStream
            $errBytes = [System.Text.Encoding]::UTF8.GetBytes('Serverfout.')
            $Context.Response.OutputStream.Write($errBytes, 0, $errBytes.Length)
            Send-RawHttpResponse -Context $Context
        }
        catch { }
    }
}
finally {
    try { $TcpClient.Close() } catch { }
}
