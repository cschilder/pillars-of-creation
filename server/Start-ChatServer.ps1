#requires -version 5.1
<#
    .SYNOPSIS
        Start de afdelings-chatserver (HTML/Canvas client + PowerShell backend).

    .DESCRIPTION
        Host alles lokaal: statische bestanden (wwwroot, incl. de lokaal
        gevendorde Vanilla Framework CSS), een REST API onder /api/* en een
        WebSocket endpoint op /ws voor chat, presence, bestandsmeldingen en
        de relay van gesprek/scherm-delen.

        Dit draait op een gewone System.Net.Sockets.TcpListener, geen
        System.Net.HttpListener - dat laatste vereist altijd ofwel
        Administrator-rechten, ofwel een vooraf door een beheerder
        geregistreerde URL-reservering (netsh http add urlacl), zelfs voor
        "http://localhost/". Met een TcpListener is geen van beide nodig:
        een gewone poort openen was op Windows nooit een beheerdersactie.

        De keerzijde: er is geen Integrated Windows Authentication meer.
        Gebruikers loggen in door zelf hun NETWERK.TLD\gebruikersnaam in te
        typen (zie /api/login) - dat wordt NIET geverifieerd tegen Active
        Directory of een wachtwoord. Gebruik dit alleen binnen een netwerk
        dat je al vertrouwt.

        Elke inkomende verbinding (statisch bestand, API-call of WebSocket)
        krijgt zijn eigen PowerShell Runspace, zodat een lang openstaand
        gesprek of een grote upload nooit andere gebruikers blokkeert.

    .PARAMETER ConfigPath
        Pad naar server.config.json. Standaard: config\server.config.json
        naast dit script.

    .EXAMPLE
        PS> .\Start-ChatServer.ps1
        Start de server met de instellingen uit config\server.config.json.
        Werkt met een gewoon (niet-verhoogd) gebruikersaccount.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config\server.config.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Config inlezen en paden oplossen -------------------------------------

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Configuratiebestand niet gevonden: $ConfigPath"
}
$rawConfig = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

function Resolve-ConfigPath {
    param([string]$RelativeOrAbsolute)
    if ([System.IO.Path]::IsPathRooted($RelativeOrAbsolute)) { return $RelativeOrAbsolute }
    return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot $RelativeOrAbsolute))
}

$resolvedConfig = [pscustomobject]@{
    DepartmentName      = $rawConfig.departmentName
    Port                = [int]$rawConfig.port
    DataDir             = Resolve-ConfigPath $rawConfig.dataDir
    UploadsDir          = Resolve-ConfigPath $rawConfig.uploadsDir
    WwwRootDir          = Resolve-ConfigPath $rawConfig.wwwrootDir
    InitialAdmins       = @($rawConfig.initialAdmins)
    MaxUploadSizeMb     = [int]$rawConfig.maxUploadSizeMb
    MessageHistoryLimit = [int]$rawConfig.messageHistoryLimit
}

if (-not (Test-Path -LiteralPath $resolvedConfig.WwwRootDir)) {
    throw "wwwroot map niet gevonden op: $($resolvedConfig.WwwRootDir)"
}

# --- Modules laden (huidige runspace + sjabloon voor per-verbinding) ------

$modulesDir = Join-Path $PSScriptRoot 'modules'
$moduleFiles = @(
    Join-Path $modulesDir 'MiniHttp.psm1'
    Join-Path $modulesDir 'Http.psm1'
    Join-Path $modulesDir 'Store.psm1'
    Join-Path $modulesDir 'Auth.psm1'
    Join-Path $modulesDir 'WebSocketHub.psm1'
    Join-Path $modulesDir 'Api.psm1'
)
foreach ($m in $moduleFiles) { Import-Module -Name $m -Force -DisableNameChecking }

Initialize-Store -DataDir $resolvedConfig.DataDir -UploadsDir $resolvedConfig.UploadsDir -InitialAdmins $resolvedConfig.InitialAdmins `
    -DepartmentName $resolvedConfig.DepartmentName -MaxUploadSizeMb $resolvedConfig.MaxUploadSizeMb -MessageHistoryLimit $resolvedConfig.MessageHistoryLimit | Out-Null
Initialize-WsHub

$initialSessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
# One call per module, NOT $initialSessionState.ImportPSModule($moduleFiles)
# with the whole array at once: that single-call form silently imports
# nothing at all (confirmed - Get-Module comes back empty in the resulting
# Runspace, with no error anywhere) once more than one module path is
# involved. Calling it once per path works reliably.
foreach ($m in $moduleFiles) { $initialSessionState.ImportPSModule([string[]]@($m)) }

$workerScriptPath = Join-Path $modulesDir 'ConnectionWorker.ps1'

# --- TcpListener opzetten ---------------------------------------------------
# Bewust geen HttpListener: dat vereist altijd Administrator-rechten of een
# vooraf door een beheerder geregistreerde URL-ACL. Een normale TCP-poort
# openen is op Windows nooit een verhoogde actie geweest.

$tcpListener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $resolvedConfig.Port)

try {
    $tcpListener.Start()
}
catch {
    Write-Error @"
Kon niet luisteren op poort $($resolvedConfig.Port).
Meestal betekent dit dat de poort al in gebruik is door een ander
programma. Kies een andere poort in server.config.json (veld "port") en
probeer opnieuw.

Onderliggende fout: $($_.Exception.Message)
"@
    return
}

Write-Host ''
Write-Host "=== $($resolvedConfig.DepartmentName) - chatserver gestart ===" -ForegroundColor Green
Write-Host "Luistert op: http://0.0.0.0:$($resolvedConfig.Port)/ (geen Administrator-rechten nodig)"
Write-Host "wwwroot:     $($resolvedConfig.WwwRootDir)"
Write-Host "data:        $($resolvedConfig.DataDir)"
Write-Host "uploads:     $($resolvedConfig.UploadsDir)"
Write-Host ''
Write-Host 'Let op: gebruikers loggen in door zelf hun NETWERK.TLD\gebruikersnaam' -ForegroundColor Yellow
Write-Host 'in te typen - dit wordt niet tegen Active Directory geverifieerd. Draai' -ForegroundColor Yellow
Write-Host 'deze server alleen binnen een netwerk dat je al vertrouwt.' -ForegroundColor Yellow
Write-Host ''
Write-Host 'Druk op Ctrl+C om te stoppen.'
Write-Host ''

$activeWorkers = New-Object System.Collections.Generic.List[object]

function Remove-CompletedWorkers {
    param([System.Collections.Generic.List[object]]$Workers)
    for ($i = $Workers.Count - 1; $i -ge 0; $i--) {
        $w = $Workers[$i]
        $state = $w.PS.InvocationStateInfo.State
        if ($state -eq [System.Management.Automation.PSInvocationState]::Completed -or
            $state -eq [System.Management.Automation.PSInvocationState]::Failed -or
            $state -eq [System.Management.Automation.PSInvocationState]::Stopped) {
            try {
                if ($w.PS.HadErrors) {
                    foreach ($e in $w.PS.Streams.Error) { Write-Warning "Workerfout: $($e.ToString())" }
                }
                $w.PS.EndInvoke($w.Handle)
            }
            catch { }
            finally {
                $w.PS.Dispose()
                $w.RS.Close()
                $w.RS.Dispose()
                $Workers.RemoveAt($i)
            }
        }
    }
}

try {
    while ($true) {
        $client = $null
        try {
            $client = $tcpListener.AcceptTcpClient()
        }
        catch [System.ObjectDisposedException] {
            break
        }
        catch [System.Net.Sockets.SocketException] {
            Write-Warning "AcceptTcpClient-fout: $($_.Exception.Message)"
            continue
        }

        Remove-CompletedWorkers -Workers $activeWorkers

        $runspace = [runspacefactory]::CreateRunspace($initialSessionState)
        $runspace.Open()
        $psInstance = [powershell]::Create()
        $psInstance.Runspace = $runspace
        [void]$psInstance.AddCommand($workerScriptPath).AddParameter('TcpClient', $client).AddParameter('Config', $resolvedConfig)
        $asyncHandle = $psInstance.BeginInvoke()

        $activeWorkers.Add([pscustomobject]@{ PS = $psInstance; RS = $runspace; Handle = $asyncHandle })
    }
}
finally {
    Write-Host 'Server stopt...' -ForegroundColor Yellow
    try { $tcpListener.Stop() } catch { }
    foreach ($w in $activeWorkers) {
        try { $w.PS.Stop() } catch { }
        try { $w.PS.Dispose() } catch { }
        try { $w.RS.Close() } catch { }
        try { $w.RS.Dispose() } catch { }
    }
}
