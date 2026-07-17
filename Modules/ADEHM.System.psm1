#requires -Version 5.1
<#
    ADEHM.System.psm1
    Collects system resources (CPU, RAM, disk, Windows version, uptime)
    through CIM/WinRM sessions. No legacy WMI/DCOM dependency.
#>

function New-ADEHMCimSession {
    <#
        .SYNOPSIS
        Opens a CIM session (WSMan protocol) to a domain controller.

        .DESCRIPTION
        A single session is created per server and must be closed with
        Remove-CimSession as soon as collection is complete.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ComputerName,
        [int]$TimeoutSeconds = 15,
        [System.Management.Automation.PSCredential]$Credential
    )

    # -OperationTimeoutSec belongs to New-CimSession, NOT New-CimSessionOption
    $sessionOption = New-CimSessionOption -Protocol Wsman

    $params = @{
        ComputerName        = $ComputerName
        SessionOption       = $sessionOption
        OperationTimeoutSec = $TimeoutSeconds
        ErrorAction         = 'Stop'
    }
    if ($Credential) { $params.Credential = $Credential }

    return New-CimSession @params
}

function Get-ADEHMSystemInfo {
    <#
        .SYNOPSIS
        Collects essential system information (CPU, RAM, OS, uptime).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [Microsoft.Management.Infrastructure.CimSession]$CimSession
    )

    $os  = Get-CimInstance -CimSession $CimSession -ClassName Win32_OperatingSystem -ErrorAction Stop
    $cpu = Get-CimInstance -CimSession $CimSession -ClassName Win32_Processor -ErrorAction Stop
    $cs  = Get-CimInstance -CimSession $CimSession -ClassName Win32_ComputerSystem -ErrorAction Stop

    $cpuLoad = [math]::Round((($cpu | Measure-Object -Property LoadPercentage -Average).Average), 1)
    $ramUsedPct = [math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100, 1)

    $lastBoot = $os.LastBootUpTime
    $uptime   = (Get-Date) - $lastBoot

    return [PSCustomObject]@{
        OSCaption      = $os.Caption
        OSVersion      = $os.Version
        BuildNumber    = $os.BuildNumber
        TotalRamGB     = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
        FreeRamGB      = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
        RamUsedPercent = $ramUsedPct
        CpuLoadPercent = $cpuLoad
        LastBootTime   = $lastBoot
        UptimeDays     = [math]::Round($uptime.TotalDays, 2)
        Domain         = $cs.Domain
    }
}

function Get-ADEHMDiskInfo {
    <#
        .SYNOPSIS
        Collects free space for all fixed volumes (C: and others).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [Microsoft.Management.Infrastructure.CimSession]$CimSession
    )

    $disks = Get-CimInstance -CimSession $CimSession -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop

    foreach ($disk in $disks) {
        $freePct = if ($disk.Size -gt 0) { [math]::Round(($disk.FreeSpace / $disk.Size) * 100, 1) } else { 0 }
        [PSCustomObject]@{
            DeviceID    = $disk.DeviceID
            SizeGB      = [math]::Round($disk.Size / 1GB, 2)
            FreeGB      = [math]::Round($disk.FreeSpace / 1GB, 2)
            FreePercent = $freePct
        }
    }
}

Export-ModuleMember -Function New-ADEHMCimSession, Get-ADEHMSystemInfo, Get-ADEHMDiskInfo
