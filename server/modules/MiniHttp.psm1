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

# ---------------------------------------------------------------------------
# Server-side WebSocket implementation (RFC 6455 framing), compiled from C#
# at first module load.
#
# Why hand-rolled: the obvious [System.Net.WebSockets.WebSocket]::
# CreateFromStream(...) API only exists on .NET Core 2.1+/.NET 5+. Windows
# PowerShell 5.1 runs on .NET Framework, which has NO in-box way to wrap a
# raw stream in a server-side WebSocket at all: HttpListener's
# AcceptWebSocketAsync needs http.sys URL-ACLs (admin rights - the very
# thing this whole server exists to avoid) and ClientWebSocket masks its
# outgoing frames, which browsers reject from a server. So the framing
# layer is implemented here and used on BOTH PowerShell versions - one
# code path, and the PS7 test suite (driving it with a real ClientWebSocket)
# is then genuinely testing what production runs.
#
# The C# class duck-types the exact WebSocket API surface WebSocketHub.psm1
# already uses (State/ReceiveAsync/SendAsync/CloseAsync/Dispose), so the
# hub code is identical for both. C# 5 syntax only: PowerShell 5.1's
# Add-Type compiles with the legacy csc, which rejects string
# interpolation, "?."  and other C# 6+ features.
#
# The type-exists guard matters: Runspaces share one AppDomain, so the
# first Import-Module compiles the assembly once and every later Runspace
# (one per connection) just reuses it - Add-Type would otherwise throw
# "type name already exists" on every connection after the first.
if (-not ('PillarsChat.MiniServerWebSocket' -as [type])) {
    $miniWsSource = @'
using System;
using System.IO;
using System.Net.WebSockets;
using System.Threading;
using System.Threading.Tasks;

namespace PillarsChat
{
    public class MiniServerWebSocket : IDisposable
    {
        private readonly Stream _stream;
        private volatile int _state; // 0=Open 1=CloseReceived 2=Closed/Aborted
        private readonly object _writeLock = new object();

        // Frame payload already read off the wire but not yet handed to the
        // caller (their buffer was smaller than the frame).
        private byte[] _pending;
        private int _pendingOffset;
        private WebSocketMessageType _pendingType;
        private bool _pendingFin;

        // Message type carried across continuation frames of a fragmented
        // message (opcode 0 frames reuse the type of the frame that opened
        // the message).
        private WebSocketMessageType _fragmentType;
        private bool _inFragmentedMessage;

        private const int MaxFramePayload = 20 * 1024 * 1024;

        public MiniServerWebSocket(Stream stream)
        {
            _stream = stream;
            _state = 0;
        }

        public WebSocketState State
        {
            get
            {
                if (_state == 0) { return WebSocketState.Open; }
                if (_state == 1) { return WebSocketState.CloseReceived; }
                return WebSocketState.Closed;
            }
        }

        public Task<WebSocketReceiveResult> ReceiveAsync(ArraySegment<byte> buffer, CancellationToken token)
        {
            return Task.FromResult(ReceiveCore(buffer));
        }

        public Task SendAsync(ArraySegment<byte> buffer, WebSocketMessageType messageType, bool endOfMessage, CancellationToken token)
        {
            byte opcode = messageType == WebSocketMessageType.Binary ? (byte)0x2 : (byte)0x1;
            // The hub only ever sends complete messages (endOfMessage=true);
            // honor the flag anyway for correctness.
            WriteFrame(opcode, buffer.Array, buffer.Offset, buffer.Count, endOfMessage);
            return (Task)Task.FromResult(0);
        }

        public Task CloseAsync(WebSocketCloseStatus closeStatus, string statusDescription, CancellationToken token)
        {
            byte[] reason = string.IsNullOrEmpty(statusDescription)
                ? new byte[0]
                : System.Text.Encoding.UTF8.GetBytes(statusDescription);
            byte[] payload = new byte[2 + reason.Length];
            int code = (int)closeStatus;
            payload[0] = (byte)((code >> 8) & 0xFF);
            payload[1] = (byte)(code & 0xFF);
            Array.Copy(reason, 0, payload, 2, reason.Length);
            try { WriteFrame(0x8, payload, 0, payload.Length, true); }
            catch (IOException) { }
            catch (ObjectDisposedException) { }
            _state = 2;
            return (Task)Task.FromResult(0);
        }

        public void Dispose()
        {
            _state = 2;
            try { _stream.Dispose(); } catch (Exception) { }
        }

        private WebSocketReceiveResult ReceiveCore(ArraySegment<byte> buffer)
        {
            // Hand out leftover payload from a previous, larger frame first.
            if (_pending != null)
            {
                return DrainPending(buffer);
            }

            while (true)
            {
                int b0 = ReadByteChecked();
                int b1 = ReadByteChecked();
                bool fin = (b0 & 0x80) != 0;
                int opcode = b0 & 0x0F;
                bool masked = (b1 & 0x80) != 0;
                long length = b1 & 0x7F;

                if (length == 126)
                {
                    byte[] ext = ReadExact(2);
                    length = ((long)ext[0] << 8) | ext[1];
                }
                else if (length == 127)
                {
                    byte[] ext = ReadExact(8);
                    length = 0;
                    for (int i = 0; i < 8; i++) { length = (length << 8) | ext[i]; }
                }
                if (length < 0 || length > MaxFramePayload)
                {
                    throw new IOException("WebSocket frame te groot: " + length + " bytes.");
                }

                // RFC 6455: client-to-server frames MUST be masked.
                byte[] mask = null;
                if (masked) { mask = ReadExact(4); }

                byte[] payload = length > 0 ? ReadExact((int)length) : new byte[0];
                if (mask != null)
                {
                    for (int i = 0; i < payload.Length; i++)
                    {
                        payload[i] = (byte)(payload[i] ^ mask[i & 3]);
                    }
                }

                if (opcode == 0x8) // close
                {
                    _state = 1;
                    WebSocketCloseStatus status = WebSocketCloseStatus.NormalClosure;
                    if (payload.Length >= 2)
                    {
                        int code = (payload[0] << 8) | payload[1];
                        if (Enum.IsDefined(typeof(WebSocketCloseStatus), code))
                        {
                            status = (WebSocketCloseStatus)code;
                        }
                    }
                    return new WebSocketReceiveResult(0, WebSocketMessageType.Close, true, status, null);
                }
                if (opcode == 0x9) // ping -> reply pong, keep reading
                {
                    try { WriteFrame(0xA, payload, 0, payload.Length, true); }
                    catch (IOException) { }
                    continue;
                }
                if (opcode == 0xA) // pong (e.g. ClientWebSocket keep-alive) -> ignore
                {
                    continue;
                }

                WebSocketMessageType msgType;
                if (opcode == 0x0) // continuation of a fragmented message
                {
                    msgType = _inFragmentedMessage ? _fragmentType : WebSocketMessageType.Text;
                }
                else
                {
                    msgType = opcode == 0x2 ? WebSocketMessageType.Binary : WebSocketMessageType.Text;
                    _fragmentType = msgType;
                }
                _inFragmentedMessage = !fin;

                _pending = payload;
                _pendingOffset = 0;
                _pendingType = msgType;
                _pendingFin = fin;
                return DrainPending(buffer);
            }
        }

        private WebSocketReceiveResult DrainPending(ArraySegment<byte> buffer)
        {
            int available = _pending.Length - _pendingOffset;
            int toCopy = Math.Min(available, buffer.Count);
            Array.Copy(_pending, _pendingOffset, buffer.Array, buffer.Offset, toCopy);
            _pendingOffset += toCopy;
            bool frameDone = _pendingOffset >= _pending.Length;
            WebSocketMessageType type = _pendingType;
            bool endOfMessage = frameDone && _pendingFin;
            if (frameDone)
            {
                _pending = null;
                _pendingOffset = 0;
            }
            return new WebSocketReceiveResult(toCopy, type, endOfMessage);
        }

        private void WriteFrame(byte opcode, byte[] payload, int offset, int count, bool fin)
        {
            // Server-to-client frames are NOT masked (RFC 6455; browsers
            // reject masked server frames).
            byte b0 = (byte)((fin ? 0x80 : 0x00) | opcode);
            byte[] header;
            if (count <= 125)
            {
                header = new byte[] { b0, (byte)count };
            }
            else if (count <= 65535)
            {
                header = new byte[] { b0, 126, (byte)((count >> 8) & 0xFF), (byte)(count & 0xFF) };
            }
            else
            {
                header = new byte[10];
                header[0] = b0;
                header[1] = 127;
                long len = count;
                for (int i = 0; i < 8; i++)
                {
                    header[9 - i] = (byte)(len & 0xFF);
                    len >>= 8;
                }
            }
            // One lock around the whole frame: a pong reply from the receive
            // loop must never interleave bytes with a data frame being sent
            // by another Runspace via the hub.
            lock (_writeLock)
            {
                _stream.Write(header, 0, header.Length);
                if (count > 0) { _stream.Write(payload, offset, count); }
                _stream.Flush();
            }
        }

        private int ReadByteChecked()
        {
            int b = _stream.ReadByte();
            if (b < 0)
            {
                _state = 2;
                throw new IOException("WebSocket-verbinding onverwacht gesloten.");
            }
            return b;
        }

        private byte[] ReadExact(int count)
        {
            byte[] buf = new byte[count];
            int off = 0;
            while (off < count)
            {
                int read = _stream.Read(buf, off, count - off);
                if (read <= 0)
                {
                    _state = 2;
                    throw new IOException("WebSocket-verbinding onverwacht gesloten.");
                }
                off += read;
            }
            return buf;
        }
    }
}
'@
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        # .NET (Core): the WebSocket types live in their own reference
        # assemblies that Add-Type doesn't include by default - and giving
        # -ReferencedAssemblies at all REPLACES the default set, so the
        # basics (System.Runtime, System.Threading for lock, ...) have to
        # be spelled out again too.
        Add-Type -TypeDefinition $miniWsSource -ReferencedAssemblies 'System.Net.WebSockets', 'System.Net.Primitives', 'System.Runtime', 'System.Threading', 'System.Threading.Tasks'
    }
    else {
        # .NET Framework: System.Net.WebSockets lives in System.dll, which
        # is in Add-Type's default reference set.
        Add-Type -TypeDefinition $miniWsSource
    }
}

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
        HttpListener) and hands back a PillarsChat.MiniServerWebSocket
        (the C# framing implementation compiled at the top of this module)
        wrapping the same underlying stream. That class exposes the same
        State/ReceiveAsync/SendAsync/CloseAsync/Dispose surface as
        System.Net.WebSockets.WebSocket, so WebSocketHub.psm1 works with
        it unchanged.

        NOT WebSocket.CreateFromStream: that method only exists on .NET
        Core 2.1+/.NET 5+ and is simply absent from .NET Framework, so on
        Windows PowerShell 5.1 (this app's actual production runtime) it
        fails with "does not contain a method named CreateFromStream" -
        a production incident, not a hypothetical.
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

    return New-Object PillarsChat.MiniServerWebSocket($Context.RawStream)
}

Export-ModuleMember -Function *-*
