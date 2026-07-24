#requires -version 5.1
<#
    ConnectionWorker.ps1
    Entry point executed inside a dedicated Runspace for exactly one
    accepted HttpListenerContext (static file, /api/* call, or a
    long-lived WebSocket). One Runspace per connection means a slow
    upload or an open call never blocks any other user.
#>
param(
    [Parameter(Mandatory)]$Context,
    [Parameter(Mandatory)]$Config
)

Set-StrictMode -Version Latest

try {
    Initialize-Store -DataDir $Config.DataDir -UploadsDir $Config.UploadsDir -InitialAdmins $Config.InitialAdmins | Out-Null
    Initialize-WsHub

    $user = Resolve-RequestUser -Context $Context
    if ($null -eq $user) {
        $Context.Response.StatusCode = 401
        $Context.Response.Close()
        return
    }

    if ($Context.Request.IsWebSocketRequest) {
        Start-WsConnection -Context $Context -User $user
        return
    }

    $path = $Context.Request.Url.AbsolutePath
    if ($path -like '/api/*') {
        Invoke-ApiRequest -Context $Context -User $user
        return
    }

    $filePath = Resolve-StaticFilePath -WwwRoot $Config.WwwRootDir -UrlPath $path
    if ($null -eq $filePath) {
        Send-ErrorResponse -Context $Context -StatusCode 404 -Message 'Niet gevonden.'
    }
    else {
        Send-FileResponse -Context $Context -FilePath $filePath
    }
}
catch {
    Write-Warning "Verbindingsfout: $($_.Exception.Message)"
    try {
        if ($Context.Response.OutputStream.CanWrite) {
            $Context.Response.StatusCode = 500
            $Context.Response.Close()
        }
    }
    catch { }
}
