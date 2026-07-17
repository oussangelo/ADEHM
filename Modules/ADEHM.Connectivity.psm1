#requires -Version 5.1
<#
    ADEHM.Connectivity.psm1
    Basic availability checks: ping, DNS resolution, WinRM and FQDN.
#>

function Test-ADEHMPing {
    <#
        .SYNOPSIS
        Tests ICMP reachability of a server.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ComputerName,
        [int]$TimeoutSeconds = 5
    )

    try {
        return [bool](Test-Connection -ComputerName $ComputerName -Count 2 -Quiet -ErrorAction Stop)
    }
    catch {
        return $false
    }
}

function Resolve-ADEHMDns {
    <#
        .SYNOPSIS
        Resolves a server's DNS name and returns its IP address.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ComputerName
    )

    try {
        $resolved = Resolve-DnsName -Name $ComputerName -ErrorAction Stop
        $record = $resolved | Where-Object { $_.Type -in @('A', 'AAAA') } | Select-Object -First 1
        return [PSCustomObject]@{
            Success   = $true
            IPAddress = $record.IPAddress
        }
    }
    catch {
        return [PSCustomObject]@{
            Success   = $false
            IPAddress = $null
        }
    }
}

function Test-ADEHMWinRM {
    <#
        .SYNOPSIS
        Checks that the WinRM service responds on the target server.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ComputerName,
        [int]$TimeoutSeconds = 10
    )

    try {
        $null = Test-WSMan -ComputerName $ComputerName -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Get-ADEHMFQDN {
    <#
        .SYNOPSIS
        Returns the resolved FQDN of a server.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ComputerName
    )

    try {
        return ([System.Net.Dns]::GetHostEntry($ComputerName)).HostName
    }
    catch {
        return $ComputerName
    }
}

Export-ModuleMember -Function Test-ADEHMPing, Resolve-ADEHMDns, Test-ADEHMWinRM, Get-ADEHMFQDN
