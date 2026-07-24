#requires -version 5.1
<#
    Http.psm1
    Low level HTTP helpers: mime types, static file serving, JSON
    request/response plumbing and a small multipart/form-data parser
    (System.Net.HttpListener has no built-in one, unlike ASP.NET).
#>

Set-StrictMode -Version Latest

$script:MimeTypes = @{
    '.html' = 'text/html; charset=utf-8'
    '.htm'  = 'text/html; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.js'   = 'application/javascript; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'
    '.svg'  = 'image/svg+xml'
    '.png'  = 'image/png'
    '.jpg'  = 'image/jpeg'
    '.jpeg' = 'image/jpeg'
    '.gif'  = 'image/gif'
    '.ico'  = 'image/x-icon'
    '.woff' = 'font/woff'
    '.woff2'= 'font/woff2'
    '.map'  = 'application/json; charset=utf-8'
    '.txt'  = 'text/plain; charset=utf-8'
}

function Get-MimeType {
    param([Parameter(Mandatory)][string]$Extension)
    $ext = $Extension.ToLowerInvariant()
    if ($script:MimeTypes.ContainsKey($ext)) { return $script:MimeTypes[$ext] }
    return 'application/octet-stream'
}

function Send-Bytes {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][int]$StatusCode,
        [Parameter(Mandatory)][byte[]]$Bytes,
        [string]$ContentType = 'application/octet-stream',
        [hashtable]$Headers = @{}
    )
    $response = $Context.Response
    try {
        $response.StatusCode = $StatusCode
        $response.ContentType = $ContentType
        $response.ContentLength64 = $Bytes.Length
        foreach ($key in $Headers.Keys) { $response.Headers[$key] = $Headers[$key] }
        if ($Bytes.Length -gt 0) {
            $response.OutputStream.Write($Bytes, 0, $Bytes.Length)
        }
    }
    finally {
        $response.OutputStream.Close()
    }
}

function Send-JsonResponse {
    param(
        [Parameter(Mandatory)]$Context,
        [int]$StatusCode = 200,
        $Data = $null
    )
    # -InputObject (not a pipe): piping a bare empty array into ConvertTo-Json
    # unwraps it into zero pipeline items and yields no output at all, which
    # would silently send an empty body instead of "[]" for e.g. an empty
    # room list.
    $json = if ($null -eq $Data) { '{}' } else { ConvertTo-Json -InputObject $Data -Depth 25 -Compress }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    Send-Bytes -Context $Context -StatusCode $StatusCode -Bytes $bytes -ContentType 'application/json; charset=utf-8'
}

function Send-ErrorResponse {
    param(
        [Parameter(Mandatory)]$Context,
        [int]$StatusCode = 400,
        [Parameter(Mandatory)][string]$Message
    )
    Send-JsonResponse -Context $Context -StatusCode $StatusCode -Data ([pscustomobject]@{ error = $Message })
}

function Send-FileResponse {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$FilePath,
        [string]$DownloadName = $null
    )
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        Send-ErrorResponse -Context $Context -StatusCode 404 -Message 'Bestand niet gevonden.'
        return
    }
    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    $ext = [System.IO.Path]::GetExtension($FilePath)
    $headers = @{}
    if ($DownloadName) {
        $headers['Content-Disposition'] = "attachment; filename=`"$DownloadName`""
    }
    Send-Bytes -Context $Context -StatusCode 200 -Bytes $bytes -ContentType (Get-MimeType -Extension $ext) -Headers $headers
}

function Resolve-StaticFilePath {
    <#
        Maps a URL path onto wwwroot, defends against path traversal and
        falls back to index.html for SPA client-side routes.
    #>
    param(
        [Parameter(Mandatory)][string]$WwwRoot,
        [Parameter(Mandatory)][string]$UrlPath
    )
    $rootFull = (Resolve-Path -LiteralPath $WwwRoot).ProviderPath
    $relative = $UrlPath.TrimStart('/')
    if ([string]::IsNullOrWhiteSpace($relative)) { $relative = 'index.html' }
    $relative = $relative -replace '\.\.', ''
    $candidate = Join-Path $rootFull $relative

    try {
        $full = [System.IO.Path]::GetFullPath($candidate)
    }
    catch { return $null }

    if (-not $full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }
    if (Test-Path -LiteralPath $full -PathType Leaf) { return $full }

    # SPA fallback for client-side tab routes without a file extension.
    if (-not [System.IO.Path]::HasExtension($full)) {
        $indexPath = Join-Path $rootFull 'index.html'
        if (Test-Path -LiteralPath $indexPath -PathType Leaf) { return $indexPath }
    }
    return $null
}

function Read-RequestBodyBytes {
    param([Parameter(Mandatory)]$Context)
    $request = $Context.Request
    $ms = New-Object System.IO.MemoryStream
    try {
        $request.InputStream.CopyTo($ms)
        return $ms.ToArray()
    }
    finally {
        $ms.Dispose()
    }
}

function Read-RequestBodyAsString {
    param([Parameter(Mandatory)]$Context)
    $bytes = Read-RequestBodyBytes -Context $Context
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Read-RequestJson {
    param([Parameter(Mandatory)]$Context)
    $raw = Read-RequestBodyAsString -Context $Context
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return $raw | ConvertFrom-Json
}

function ConvertFrom-MultipartFormData {
    <#
        Minimal multipart/form-data parser for browser FormData uploads.
        Returns an array of parts: @{ Name; FileName; ContentType; Bytes }
    #>
    param(
        [Parameter(Mandatory)][byte[]]$BodyBytes,
        [Parameter(Mandatory)][string]$ContentTypeHeader
    )
    if ($ContentTypeHeader -notmatch 'boundary=(.+)$') {
        throw 'Geen multipart boundary gevonden in Content-Type header.'
    }
    $boundaryText = $Matches[1].Trim('"')
    $boundaryBytes = [System.Text.Encoding]::UTF8.GetBytes("--$boundaryText")
    $crlf = [byte[]](13, 10)

    $parts = New-Object System.Collections.Generic.List[object]
    $positions = New-Object System.Collections.Generic.List[int]

    $i = 0
    while ($true) {
        $idx = Find-ByteSequence -Haystack $BodyBytes -Needle $boundaryBytes -Start $i
        if ($idx -lt 0) { break }
        $positions.Add($idx)
        $i = $idx + $boundaryBytes.Length
    }

    for ($p = 0; $p -lt $positions.Count - 1; $p++) {
        $segStart = $positions[$p] + $boundaryBytes.Length
        $segEnd = $positions[$p + 1]
        if ($segEnd -le $segStart) { continue }

        # Skip the CRLF right after the boundary marker, and stop before the
        # CRLF that precedes the next boundary marker.
        if ($segStart + 1 -lt $BodyBytes.Length -and $BodyBytes[$segStart] -eq 13 -and $BodyBytes[$segStart + 1] -eq 10) {
            $segStart += 2
        }
        $segLen = $segEnd - $segStart
        if ($segLen -ge 2 -and $BodyBytes[$segEnd - 2] -eq 13 -and $BodyBytes[$segEnd - 1] -eq 10) {
            $segLen -= 2
        }
        if ($segLen -le 0) { continue }

        $headerEnd = Find-ByteSequence -Haystack $BodyBytes -Needle ([byte[]](13, 10, 13, 10)) -Start $segStart
        if ($headerEnd -lt 0 -or $headerEnd -ge $segStart + $segLen) { continue }

        $headerBytes = $BodyBytes[$segStart..($headerEnd - 1)]
        $headerText = [System.Text.Encoding]::UTF8.GetString($headerBytes)
        $contentStart = $headerEnd + 4
        $contentLen = ($segStart + $segLen) - $contentStart
        if ($contentLen -lt 0) { $contentLen = 0 }
        $content = if ($contentLen -gt 0) { $BodyBytes[$contentStart..($contentStart + $contentLen - 1)] } else { [byte[]]@() }

        $name = $null
        $fileName = $null
        if ($headerText -match 'name="([^"]*)"') { $name = $Matches[1] }
        if ($headerText -match 'filename="([^"]*)"') { $fileName = $Matches[1] }
        $partContentType = 'application/octet-stream'
        if ($headerText -match 'Content-Type:\s*([^\r\n]+)') { $partContentType = $Matches[1].Trim() }

        $parts.Add([pscustomobject]@{
            Name        = $name
            FileName    = $fileName
            ContentType = $partContentType
            Bytes       = $content
        })
    }

    return $parts
}

function Find-ByteSequence {
    param(
        [Parameter(Mandatory)][byte[]]$Haystack,
        [Parameter(Mandatory)][byte[]]$Needle,
        [int]$Start = 0
    )
    if ($Needle.Length -eq 0 -or $Haystack.Length -eq 0) { return -1 }
    $limit = $Haystack.Length - $Needle.Length
    for ($x = $Start; $x -le $limit; $x++) {
        $matchFound = $true
        for ($y = 0; $y -lt $Needle.Length; $y++) {
            if ($Haystack[$x + $y] -ne $Needle[$y]) { $matchFound = $false; break }
        }
        if ($matchFound) { return $x }
    }
    return -1
}

Export-ModuleMember -Function *-*
