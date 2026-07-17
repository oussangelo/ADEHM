#requires -Version 5.1
<#
    ADEHM.ActiveDirectory.psm1
    Active Directory-specific checks: service state (NTDS, DNS, DFSR,
    Netlogon, KDC, ADWS), SYSVOL/NETLOGON share availability, and
    site/domain information.

    This module does not require the RSAT ActiveDirectory module: it relies
    solely on CIM and lightweight LDAP queries (RootDSE) to minimize
    prerequisites on the execution host.
#>

function Get-ADEHMServiceStatus {
    <#
        .SYNOPSIS
        Queries the state of a list of services through the open CIM session.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [Microsoft.Management.Infrastructure.CimSession]$CimSession,
        [Parameter(Mandatory)] [string[]]$ServiceNames
    )

    $filter = ($ServiceNames | ForEach-Object { "Name='$_'" }) -join ' OR '
    $services = Get-CimInstance -CimSession $CimSession -ClassName Win32_Service -Filter $filter -ErrorAction Stop

    $result = @{}
    foreach ($name in $ServiceNames) {
        $svc = $services | Where-Object { $_.Name -eq $name }
        if ($svc) {
            $result[$name] = [PSCustomObject]@{
                Name      = $svc.Name
                State     = $svc.State
                StartMode = $svc.StartMode
                Running   = ($svc.State -eq 'Running')
            }
        }
        else {
            # Note: on hardened systems a service may be INVISIBLE (not just
            # stopped) when its security descriptor denies read access to the
            # caller. See Docs/PERMISSIONS.md, delegation #5.
            $result[$name] = [PSCustomObject]@{
                Name      = $name
                State     = 'NotFound'
                StartMode = $null
                Running   = $false
            }
        }
    }

    return $result
}

function Test-ADEHMShare {
    <#
        .SYNOPSIS
        Checks that a network share (e.g. SYSVOL, NETLOGON) is reachable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ComputerName,
        [Parameter(Mandatory)] [string]$ShareName
    )

    $path = '\\{0}\{1}' -f $ComputerName, $ShareName
    try {
        return [bool](Test-Path -LiteralPath $path -ErrorAction Stop)
    }
    catch {
        return $false
    }
}

function Get-ADEHMDomainInfo {
    <#
        .SYNOPSIS
        Retrieves the domain (via LDAP RootDSE) and the Active Directory
        site (via nltest) of a domain controller, with no dependency on the
        RSAT ActiveDirectory module.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ComputerName
    )

    $domain = $null
    try {
        $rootDse = [ADSI]"LDAP://$ComputerName/RootDSE"
        $dn = $rootDse.Properties['defaultNamingContext'][0]
        if ($dn) {
            $domain = (($dn -split ',') | ForEach-Object { $_ -replace '^DC=', '' }) -join '.'
        }
    }
    catch {
        $domain = $null
    }

    $site = $null
    try {
        $nltestOutput = & nltest.exe /server:$ComputerName /dsgetsite 2>$null
        if ($LASTEXITCODE -eq 0 -and $nltestOutput) {
            $site = ($nltestOutput | Select-Object -First 1).ToString().Trim()
        }
    }
    catch {
        $site = $null
    }

    return [PSCustomObject]@{
        Domain = $domain
        Site   = $site
    }
}

Export-ModuleMember -Function Get-ADEHMServiceStatus, Test-ADEHMShare, Get-ADEHMDomainInfo
