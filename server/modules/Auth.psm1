#requires -version 5.1
<#
    Auth.psm1
    Identity for this deployment is a self-declared "chatuser" cookie set
    by /api/login (see Api.psm1) - there is NO Integrated Windows
    Authentication and NO password check here.

    Why: HttpListener's IntegratedWindowsAuthentication (and http.sys in
    general) requires either running elevated or a one-time
    "netsh http add urlacl" reservation made by an administrator. When
    nobody with admin rights is available, that path is closed, so this
    server runs on a plain TcpListener instead (see MiniHttp.psm1) and
    identity is just whatever DOMAIN\username someone typed into the
    login form.

    This means anyone who can reach the server can claim to be anyone -
    there is no verification against Active Directory or anything else.
    Only run this on a network you already trust, and make sure everyone
    using it understands the login name is not authenticated.
#>

Set-StrictMode -Version Latest

# Accepts either the classic "NETWERK.TLD\gebruikersnaam" form, or a plain
# nickname with no backslash at all. Since there is no verification against
# Active Directory either way (see module docstring above), the domain
# prefix was never doing real work - it just made initialAdmins entries
# and login harder to type. A plain nickname set in server.config.json's
# initialAdmins (matched case-insensitively, see Store.psm1 Test-IsAdmin)
# is now enough to make whoever types that exact name an admin.
$script:UsernamePattern = '^[^\\]{1,64}(\\[^\\]{1,64})?$'

function Test-ValidUsernameFormat {
    param([string]$Username)
    if ([string]::IsNullOrWhiteSpace($Username)) { return $false }
    return $Username -match $script:UsernamePattern
}

function Get-RequestCookie {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Name)
    if (-not $Context.Request.Headers.ContainsKey('cookie')) { return $null }
    $raw = $Context.Request.Headers['cookie']
    foreach ($pair in $raw -split ';') {
        $kv = $pair.Trim().Split('=', 2)
        if ($kv.Count -eq 2 -and $kv[0] -eq $Name) {
            return [uri]::UnescapeDataString($kv[1])
        }
    }
    return $null
}

function Resolve-RequestUser {
    <#
        Reads the self-declared identity from the "chatuser" cookie set by
        POST /api/login, and makes sure a profile row exists for them,
        creating it (with sane defaults) on first contact. Returns $null
        if there is no cookie or it doesn't look like DOMAIN\name.
    #>
    param([Parameter(Mandatory)]$Context)

    $username = Get-RequestCookie -Context $Context -Name 'chatuser'
    if (-not (Test-ValidUsernameFormat -Username $username)) { return $null }

    $profile = Get-UserProfile -Username $username -CreateIfMissing
    Update-UserLastSeen -Username $username

    return [pscustomobject]@{
        Username    = $username
        DisplayName = if ($profile.settings.displayNameOverride) { $profile.settings.displayNameOverride } else { $profile.displayName }
        IsAdmin     = (Test-IsAdmin -Username $username)
        Profile     = $profile
    }
}

Export-ModuleMember -Function *-*
