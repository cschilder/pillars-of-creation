#requires -version 5.1
<#
    MiniHttp.psm1
    A tiny hand-rolled HTTP/1.1 + WebSocket (RFC 6455) layer on top of a raw
    System.Net.Sockets.TcpListener/TcpClient - deliberately NOT
    System.Net.HttpListener.

    Why: HttpListener is backed by http.sys, and ANY prefix registration
    (even "http://localhost:PORT/") requires either running elevated or a
    one-time "netsh http add urlacl" reservation made by an administrator.
    When nobody with admin rights is available at all, that's a dead end.
    A plain TcpListener needs neither - binding a normal TCP port on
    Windows has never required elevation - so this module re-implements
    just enough of HTTP and the WebSocket opening handshake by hand to
    keep everything else (Http.psm1, Api.psm1, WebSocketHub.psm1) working
    against an HttpListener-shaped fake context, unchanged.

    Trade-off accepted for this: no keep-alive (every request is its own
    TCP connection, closed after the response) and no chunked request
    bodies (Content-Length only) - both fine for a small LAN app talking
    to a handful of browsers.
#>

Set-StrictMode -Version Latest

$script:StatusTexts = @{
    200 = 'OK'; 201 = 'Created'; 204 = 'No Content'
    400 = 'Bad Request'; 401 = 'Unauthorized'; 403 = 'Forbidden'
    404 = 'Not Found'; 413 = 'Payload Too Large'; 500 = 'Internal Server Error'
}

function Get-HttpStatusText {
    param([int]$Code)
    if ($script:StatusTexts.ContainsKey($Code)) { return $script:StatusTexts[$Code] }
    return 'OK'
}

function Read-RawHttpLine {
    <#
        Reads one CRLF-terminated line directly off the stream, one byte
        at a time. Deliberately avoids StreamReader here: StreamReader
        reads ahead into its own internal buffer, which would silently
        swallow bytes belonging to the request body that follows the
        headers - there would be no way to hand those already-consumed
        bytes back to a later raw Stream.Read() call for the body.
    #>
    param([Parameter(Mandatory)][System.IO.Stream]$Stream)
    $bytes = New-Object System.Collections.Generic.List[byte]
    while ($true) {
        $b = $Stream.ReadByte()
        if ($b -eq -1) {
            if ($bytes.Count -eq 0) { return $null }
            break
        }
        if ($b -eq 10) { break }
        if ($b -ne 13) { $bytes.Add([byte]$b) }
    }
    return [System.Text.Encoding]::ASCII.GetString($bytes.ToArray())
}

function Read-RawExactBytes {
    param([Parameter(Mandatory)][System.IO.Stream]$Stream, [Parameter(Mandatory)][long]$Count)
    $buffer = New-Object byte[] $Count
    $offset = 0
    while ($offset -lt $Count) {
        $read = $Stream.Read($buffer, $offset, $Count - $offset)
        if ($read -le 0) { break }
        $offset += $read
    }
    return $buffer
}

function New-HttpContextFromStream {
    <#
        Parses one HTTP request off $Stream and returns an object shaped
        just enough like an HttpListenerContext (.Request.*, .Response.*)
        that the rest of the codebase doesn't need to know the difference.
        Returns $null if the peer closed the connection before sending a
        request line (e.g. an idle keep-alive probe).
    #>
    param([Parameter(Mandatory)][System.IO.Stream]$Stream)

    $requestLine = Read-RawHttpLine -Stream $Stream
    if ([string]::IsNullOrEmpty($requestLine)) { return $null }
    $lineParts = $requestLine.Split(' ')
    if ($lineParts.Count -lt 2) { return $null }
    $method = $lineParts[0]
    $target = $lineParts[1]

    $headers = @{}
    while ($true) {
        $line = Read-RawHttpLine -Stream $Stream
        if ([string]::IsNullOrEmpty($line)) { break }
        $sep = $line.IndexOf(':')
        if ($sep -gt 0) {
            $key = $line.Substring(0, $sep).Trim().ToLowerInvariant()
            $value = $line.Substring($sep + 1).Trim()
            $headers[$key] = $value
        }
    }

    $contentLength = 0L
    if ($headers.ContainsKey('content-length')) {
        [void][long]::TryParse($headers['content-length'], [ref]$contentLength)
    }
    # [byte[]] type constraint matters: an if/else expression whose "no
    # body" branch is a bare empty array is just as prone to collapsing to
    # $null as the array-return patterns documented in Store.psm1 - forcing
    # the variable's type keeps it a real (possibly zero-length) array.
    [byte[]]$bodyBytes = if ($contentLength -gt 0) { Read-RawExactBytes -Stream $Stream -Count $contentLength } else { , @() }

    $uri = [uri]("http://localhost$target")
    $queryHash = @{}
    if ($uri.Query) {
        foreach ($pair in $uri.Query.TrimStart('?').Split('&')) {
            if (-not $pair) { continue }
            $kv = $pair.Split('=', 2)
            $k = [uri]::UnescapeDataString($kv[0])
            $v = if ($kv.Count -gt 1) { [uri]::UnescapeDataString($kv[1]) } else { '' }
            $queryHash[$k] = $v
        }
    }

    $connectionHeader = if ($headers.ContainsKey('connection')) { $headers['connection'] } else { '' }
    $upgradeHeader = if ($headers.ContainsKey('upgrade')) { $headers['upgrade'] } else { '' }
    $isWebSocket = ($upgradeHeader -match '(?i)websocket') -and ($connectionHeader -match '(?i)upgrade')

    $request = [pscustomobject]@{
        HttpMethod         = $method
        Url                = $uri
        Headers            = $headers
        ContentType        = if ($headers.ContainsKey('content-type')) { $headers['content-type'] } else { '' }
        ContentLength64    = $contentLength
        InputStream        = [System.IO.MemoryStream]::new($bodyBytes)
        QueryString        = $queryHash
        IsWebSocketRequest = $isWebSocket
    }

    $response = [pscustomobject]@{
        StatusCode      = 200
        ContentType     = 'text/plain'
        ContentLength64 = 0
        Headers         = @{}
        OutputStream    = New-Object System.IO.MemoryStream
    }

    return [pscustomobject]@{
        Request   = $request
        Response  = $response
        RawStream = $Stream
    }
}

function Send-RawHttpResponse {
    <#
        Flushes the buffered $Context.Response (built up via the ordinary
        Http.psm1 Send-*Response helpers, which only ever touch
        .Response.StatusCode/.ContentType/.Headers/.OutputStream) out over
        the real socket as an actual HTTP response, then the caller closes
        the connection (no keep-alive).
    #>
    param([Parameter(Mandatory)]$Context)

    $resp = $Context.Response
    $bodyBytes = $resp.OutputStream.ToArray()
    $statusText = Get-HttpStatusText -Code $resp.StatusCode

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("HTTP/1.1 $($resp.StatusCode) $statusText`r`n")
    [void]$sb.Append("Content-Type: $($resp.ContentType)`r`n")
    [void]$sb.Append("Content-Length: $($bodyBytes.Length)`r`n")
    foreach ($key in $resp.Headers.Keys) {
        [void]$sb.Append("${key}: $($resp.Headers[$key])`r`n")
    }
    [void]$sb.Append("Connection: close`r`n")
    [void]$sb.Append("`r`n")

    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($sb.ToString())
    $Context.RawStream.Write($headerBytes, 0, $headerBytes.Length)
    if ($bodyBytes.Length -gt 0) { $Context.RawStream.Write($bodyBytes, 0, $bodyBytes.Length) }
    $Context.RawStream.Flush()
}

function Start-WebSocketHandshake {
    <#
        Performs the RFC 6455 opening handshake by hand (HttpListener's
        AcceptWebSocketAsync isn't available here - there is no
        HttpListener) and hands back a real, standard
        System.Net.WebSockets.WebSocket wrapping the same underlying
        stream, via WebSocket.CreateFromStream (.NET Framework 4.7.1+,
        present on any currently-patched Windows 10/11). Every other
        WebSocket-handling function in this codebase (WebSocketHub.psm1)
        works with that object exactly as if HttpListener had produced it.
    #>
    param([Parameter(Mandatory)]$Context)

    $key = $Context.Request.Headers['sec-websocket-key']
    if ([string]::IsNullOrWhiteSpace($key)) {
        throw 'Ontbrekende Sec-WebSocket-Key header.'
    }
    $magic = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try {
        $hash = $sha1.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($key + $magic))
    }
    finally {
        $sha1.Dispose()
    }
    $acceptKey = [Convert]::ToBase64String($hash)

    $responseText = "HTTP/1.1 101 Switching Protocols`r`nUpgrade: websocket`r`nConnection: Upgrade`r`nSec-WebSocket-Accept: $acceptKey`r`n`r`n"
    $responseBytes = [System.Text.Encoding]::ASCII.GetBytes($responseText)
    $Context.RawStream.Write($responseBytes, 0, $responseBytes.Length)
    $Context.RawStream.Flush()

    # .NET Framework's CreateFromStream(stream, isServer, subProtocol,
    # keepAliveInterval) documents subProtocol as fine to leave null. On
    # .NET (Core) 5+ the same overload got a stricter guard and throws
    # ArgumentException for null/empty instead (confirmed while testing
    # this module) - fall back to the newer options-object overload there,
    # since it isn't present at all on older .NET Framework.
    try {
        return [System.Net.WebSockets.WebSocket]::CreateFromStream($Context.RawStream, $true, $null, [TimeSpan]::FromSeconds(60))
    }
    catch [System.Management.Automation.MethodInvocationException] {
        $creationOptions = New-Object System.Net.WebSockets.WebSocketCreationOptions
        $creationOptions.IsServer = $true
        $creationOptions.KeepAliveInterval = [TimeSpan]::FromSeconds(60)
        return [System.Net.WebSockets.WebSocket]::CreateFromStream($Context.RawStream, $creationOptions)
    }
}

Export-ModuleMember -Function *-*
