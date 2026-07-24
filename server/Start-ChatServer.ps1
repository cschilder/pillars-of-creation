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
        Gebruikers loggen in door zelf een nickname te typen (zie
        /api/login) - dat wordt NIET geverifieerd tegen Active Directory of
        een wachtwoord. Wie er in initialAdmins (server.config.json) staat,
        is na het inloggen met die exacte nickname automatisch admin.
        Gebruik dit alleen binnen een netwerk dat je al vertrouwt.

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

# Handmatig opgehoogd bij elke merged fix - NIET automatisch uit git, want
# dit script draait vaak vanuit een losse kopie zonder .git-map. Print dit
# als allereerste regel, voor de configuratie zelfs is ingelezen, zodat een
# screenshot van de opstart altijd meteen laat zien of dit wel/niet de
# nieuwste versie is (dit voorkomt de "zelfde bug na de fix" verwarring die
# ontstaat als een oude kopie van de bestanden per ongeluk blijft draaien).
$script:AppBuildVersion = '2026-07-24.4-ps51-login-fix'
Write-Host "Build: $script:AppBuildVersion" -ForegroundColor DarkGray

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

# --- Ctrl+C nette afsluiting ------------------------------------------------
# $tcpListener.AcceptTcpClient() is een synchrone, blokkerende .NET-aanroep
# zonder enig "yield point" voor de PowerShell-engine. Twee dingen zijn
# empirisch getest (los van elkaar geverifieerd) om hier een nette Ctrl+C-
# afsluiting op te bouwen:
#   1. Register-ObjectEvent op Console.CancelKeyPress WERKT NIET hiervoor:
#      de .NET-event vuurt zelf meteen af, maar de PowerShell-eventing-
#      engine kan de bijbehorende -Action pas UITVOEREN zodra de eigen
#      Runspace weer even "vrij" is (een yield point heeft) - en die is
#      hier juist voor onbepaalde tijd vast in AcceptTcpClient(). Getest:
#      de Action vuurde pas af nadat er alsnog een client binnenkwam.
#   2. Een aparte PowerShell Runspace/thread heeft dit probleem niet en kan
#      gewoon parallel blijven draaien terwijl de hoofdthread vastzit. Door
#      Ctrl+C zelf als toetsaanslag te lezen (in plaats van als OS-signaal)
#      via [Console]::TreatControlCAsInput + een blokkerende
#      [Console]::ReadKey() in zo'n aparte Runspace, en van daaruit
#      $tcpListener.Stop() aan te roepen, wordt de vastzittende
#      AcceptTcpClient()-aanroep wel degelijk ontgrendeld (getest: binnen
#      ~2 seconde), met een SocketException als gevolg - die PowerShell's
#      typed "catch [System.Net.Sockets.SocketException]" gewoon matcht,
#      ook al wordt hij onderweg in een MethodInvocationException verpakt.
# Elke Runspace heeft zijn EIGEN global scope - $global: in het
# ReadKey-scriptblock hieronder zou dus NIET terugschrijven naar deze
# (hoofd-)Runspace. Een [hashtable]::Synchronized(...) is wel een gedeeld
# .NET-object: SetVariable geeft de child-Runspace een referentie naar
# hetzelfde object, dus wijzigingen daarin zijn ook hier zichtbaar.
$stopFlag = [hashtable]::Synchronized(@{ Requested = $false })
[Console]::TreatControlCAsInput = $true
$ctrlCRunspace = [runspacefactory]::CreateRunspace()
$ctrlCRunspace.Open()
$ctrlCRunspace.SessionStateProxy.SetVariable('listener', $tcpListener)
$ctrlCRunspace.SessionStateProxy.SetVariable('stopFlag', $stopFlag)
$ctrlCWatcher = [powershell]::Create()
$ctrlCWatcher.Runspace = $ctrlCRunspace
[void]$ctrlCWatcher.AddScript({
    while ($true) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq [ConsoleKey]::C -and ($key.Modifiers -band [ConsoleModifiers]::Control)) {
            $stopFlag.Requested = $true
            $listener.Stop()
            break
        }
    }
})
$ctrlCHandle = $ctrlCWatcher.BeginInvoke()

function Get-LocalIPv4Addresses {
    # PowerShell unrolls an array crossing a function return boundary (0
    # matches becomes $null, 1 match becomes a bare scalar instead of a
    # 1-element array) - wrap the whole pipeline in @() in one go and
    # comma-protect the return so callers reliably get a real array back,
    # even with zero or one matching address.
    try {
        $addresses = @([System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
            Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and -not [System.Net.IPAddress]::IsLoopback($_) } |
            ForEach-Object { $_.ToString() })
        return , $addresses
    }
    catch { return , @() }
}

Write-Host ''
Write-Host "=== $($resolvedConfig.DepartmentName) - chatserver gestart (build $script:AppBuildVersion) ===" -ForegroundColor Green
# 0.0.0.0 (IPAddress.Any) is het bind-adres - "luister op alle netwerk-
# interfaces van deze machine" - en is zelf GEEN adres om in de browser te
# openen; dat geeft een lege/mislukte pagina. Print daarom de daadwerkelijk
# bruikbare URL's.
Write-Host "Luistert op poort $($resolvedConfig.Port) (geen Administrator-rechten nodig). Open in de browser:"
Write-Host "  - Op deze machine:       http://localhost:$($resolvedConfig.Port)/" -ForegroundColor Cyan
$localIps = Get-LocalIPv4Addresses
if ($localIps.Count -gt 0) {
    foreach ($ip in $localIps) {
        Write-Host "  - Vanaf een andere pc:   http://${ip}:$($resolvedConfig.Port)/" -ForegroundColor Cyan
    }
}
else {
    Write-Host "  - Vanaf een andere pc:   http://<hostnaam-of-IP-van-deze-pc>:$($resolvedConfig.Port)/" -ForegroundColor Cyan
}
Write-Host "wwwroot:     $($resolvedConfig.WwwRootDir)"
Write-Host "data:        $($resolvedConfig.DataDir)"
Write-Host "uploads:     $($resolvedConfig.UploadsDir)"
Write-Host ''
Write-Host 'Let op: gebruikers loggen in met alleen een zelfgekozen nickname - dit' -ForegroundColor Yellow
Write-Host 'wordt niet tegen Active Directory geverifieerd. Wie in initialAdmins' -ForegroundColor Yellow
Write-Host '(server.config.json) staat, is na inloggen met die exacte nickname admin.' -ForegroundColor Yellow
Write-Host 'Draai deze server alleen binnen een netwerk dat je al vertrouwt.' -ForegroundColor Yellow
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
                # ConnectionWorker.ps1 runs in this Runspace and can only write
                # to *its own* streams, not directly to this console - Write-
                # Warning there lands in $w.PS.Streams.Warning, not the Error
                # stream, so it must be drained separately or it's silently
                # lost (HadErrors only reflects the Error stream).
                if ($w.PS.HadErrors) {
                    foreach ($e in $w.PS.Streams.Error) { Write-Warning "Workerfout: $($e.ToString())" }
                }
                if ($w.PS.Streams.Warning.Count -gt 0) {
                    foreach ($wm in $w.PS.Streams.Warning) { Write-Warning "Workerwaarschuwing: $($wm.Message)" }
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
            if ($stopFlag.Requested) {
                break
            }
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
    try { [Console]::TreatControlCAsInput = $false } catch { }
    # Als de lus stopte doordat de gebruiker Ctrl+C indrukte, is het
    # ReadKey()-scriptblock in $ctrlCWatcher daardoor al vanzelf gestopt (de
    # "break" hierboven in de watcher) en is Dispose() hier meteen klaar. Als
    # de lus om een andere reden stopte, zit die watcher nog vast in een
    # blokkerende ReadKey()-aanroep - dat is een background thread die het
    # afsluiten van het proces niet tegenhoudt, dus bewust geen blokkerende
    # .Close() hier (die zou zelf kunnen blijven hangen).
    try { $ctrlCWatcher.Dispose() } catch { }
    foreach ($w in $activeWorkers) {
        try { $w.PS.Stop() } catch { }
        try { $w.PS.Dispose() } catch { }
        try { $w.RS.Close() } catch { }
        try { $w.RS.Dispose() } catch { }
    }
}
