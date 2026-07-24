#requires -version 5.1
<#
    Auth.psm1
    Reads the Windows identity that HttpListener resolved via Integrated
    Windows Authentication (NTLM/Negotiate) and links it to a user profile.
#>

Set-StrictMode -Version Latest

function Resolve-RequestUser {
    <#
        Given an HttpListenerContext, returns the DOMAIN\username of the
        caller and makes sure a profile row exists for them, creating it
        (with sane defaults) on first contact.
    #>
    param([Parameter(Mandatory)]$Context)

    $identity = $Context.User
    if ($null -eq $identity -or $null -eq $identity.Identity -or -not $identity.Identity.IsAuthenticated) {
        return $null
    }

    $username = $identity.Identity.Name
    if ([string]::IsNullOrWhiteSpace($username)) { return $null }

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
