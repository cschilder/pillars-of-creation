#requires -version 5.1
<#
    .SYNOPSIS
        Start de afdelings-chatserver (HTML/Canvas client + PowerShell backend).

    .DESCRIPTION
        Host alles lokaal: statische bestanden (wwwroot, incl. de lokaal
        gevendorde Vanilla Framework CSS), een REST API onder /api/* en een
        WebSocket endpoint op /ws voor chat, presence, bestandsmeldingen en
        de relay van gesprek/scherm-delen. Gebruikers loggen in met hun
        huidige Windows-sessie (Integrated Windows Authentication); er is
        geen apart wachtwoordscherm.

        Elke inkomende verbinding (statisch bestand, API-call of WebSocket)
        krijgt zijn eigen PowerShell Runspace, zodat een lang openstaand
        gesprek of een grote upload nooit andere gebruikers blokkeert.

    .PARAMETER ConfigPath
        Pad naar server.config.json. Standaard: config\server.config.json
        naast dit script.

    .EXAMPLE
        PS> .\Start-ChatServer.ps1
        Start de server met de instellingen uit config\server.config.json.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config\server.config.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsElevatedAdministrator {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsElevatedAdministrator)) {
    Write-Warning @'
Dit script draait niet als Administrator. HttpListener heeft voor een
"http://+:<poort>/" binding en Integrated Windows Authentication meestal
verhoogde rechten nodig (of een vooraf geregistreerde URL-ACL). Start dit
script als Administrator, of registreer eenmalig een ACL, bijvoorbeeld:

    netsh http add urlacl url=http://+:8080/ user=NETWERK.TLD\gebruikersnaam

Zie README.md voor de volledige uitleg.
'@
}

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
    DepartmentName = $rawConfig.departmentName
    Prefixes       = @($rawConfig.prefixes)
    DataDir        = Resolve-ConfigPath $rawConfig.dataDir
    UploadsDir     = Resolve-ConfigPath $rawConfig.uploadsDir
    WwwRootDir     = Resolve-ConfigPath $rawConfig.wwwrootDir
    InitialAdmins  = @($rawConfig.initialAdmins)
}

if (-not (Test-Path -LiteralPath $resolvedConfig.WwwRootDir)) {
    throw "wwwroot map niet gevonden op: $($resolvedConfig.WwwRootDir)"
}

# --- Modules laden (huidige runspace + sjabloon voor per-verbinding) ------

$modulesDir = Join-Path $PSScriptRoot 'modules'
$moduleFiles = @(
    Join-Path $modulesDir 'Http.psm1'
    Join-Path $modulesDir 'Store.psm1'
    Join-Path $modulesDir 'Auth.psm1'
    Join-Path $modulesDir 'WebSocketHub.psm1'
    Join-Path $modulesDir 'Api.psm1'
)
foreach ($m in $moduleFiles) { Import-Module -Name $m -Force -DisableNameChecking }

Initialize-Store -DataDir $resolvedConfig.DataDir -UploadsDir $resolvedConfig.UploadsDir -InitialAdmins $resolvedConfig.InitialAdmins | Out-Null
Initialize-WsHub

$initialSessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$initialSessionState.ImportPSModule($moduleFiles)

$workerScriptPath = Join-Path $modulesDir 'ConnectionWorker.ps1'

# --- HttpListener opzetten --------------------------------------------------

Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue

$listener = New-Object System.Net.HttpListener
foreach ($prefix in $resolvedConfig.Prefixes) { $listener.Prefixes.Add($prefix) }
$listener.AuthenticationSchemes = [System.Net.AuthenticationSchemes]::IntegratedWindowsAuthentication

try {
    $listener.Start()
}
catch {
    Write-Error @"
Kon de HttpListener niet starten op $($resolvedConfig.Prefixes -join ', ').
Meestal betekent dit dat de poort al in gebruik is, of dat er geen
rechten/URL-ACL zijn voor deze binding. Zie README.md.

Onderliggende fout: $($_.Exception.Message)
"@
    return
}

Write-Host ''
Write-Host "=== $($resolvedConfig.DepartmentName) - chatserver gestart ===" -ForegroundColor Green
Write-Host "Luistert op: $($resolvedConfig.Prefixes -join ', ')"
Write-Host "wwwroot:     $($resolvedConfig.WwwRootDir)"
Write-Host "data:        $($resolvedConfig.DataDir)"
Write-Host "uploads:     $($resolvedConfig.UploadsDir)"
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
    while ($listener.IsListening) {
        $context = $null
        try {
            $context = $listener.GetContext()
        }
        catch [System.Net.HttpListenerException] {
            if ($listener.IsListening) { Write-Warning "GetContext-fout: $($_.Exception.Message)" }
            continue
        }
        catch [System.ObjectDisposedException] {
            break
        }

        Remove-CompletedWorkers -Workers $activeWorkers

        $runspace = [runspacefactory]::CreateRunspace($initialSessionState)
        $runspace.Open()
        $psInstance = [powershell]::Create()
        $psInstance.Runspace = $runspace
        [void]$psInstance.AddCommand($workerScriptPath).AddParameter('Context', $context).AddParameter('Config', $resolvedConfig)
        $asyncHandle = $psInstance.BeginInvoke()

        $activeWorkers.Add([pscustomobject]@{ PS = $psInstance; RS = $runspace; Handle = $asyncHandle })
    }
}
finally {
    Write-Host 'Server stopt...' -ForegroundColor Yellow
    try { $listener.Stop() } catch { }
    try { $listener.Close() } catch { }
    foreach ($w in $activeWorkers) {
        try { $w.PS.Stop() } catch { }
        try { $w.PS.Dispose() } catch { }
        try { $w.RS.Close() } catch { }
        try { $w.RS.Dispose() } catch { }
    }
}
