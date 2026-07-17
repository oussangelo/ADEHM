#requires -Version 5.1
<#
.SYNOPSIS
    Grants the ADEHM group/account READ-ONLY access to the monitored
    Windows services on each domain controller.

.DESCRIPTION
    On a hardened system, permission to enumerate services (Service Control
    Manager SDDL) is not enough: each service then filters callers through
    its own security descriptor. A service whose SD does not grant read to
    the caller becomes INVISIBLE in WMI results (query accepted, empty
    result).

    This script adds the standard read ACE (A;;CCLCSWLOCRRC;;;<SID>) - the
    same right set granted by default to interactive users: configuration
    and status query only, NO start/stop/modify rights.

    Idempotent; each service's previous SDDL is backed up under
    C:\Windows\Temp\ on the DC before modification.

.PARAMETER Account
    Account or group in DOMAIN\name format (e.g. DOMAIN\GRP-AD-Monitoring).

.PARAMETER Services
    Services to process. When omitted and -ConfigPath is provided, the list
    is read from the Services section of the ADEHM configuration.

.EXAMPLE
    .\Grant-ADEHMServiceReadPermission.ps1 -Account 'DOMAIN\GRP-AD-Monitoring' -ConfigPath ..\Config\ADEHM.config.psd1
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[^\\]+\\[^\\]+$')]
    [string]$Account,

    [string[]]$DomainControllers,

    [string]$ConfigPath,

    [string[]]$Services
)

# --- DC and service list resolution from configuration -------------------
if (-not $DomainControllers -or -not $Services) {
    if (-not $ConfigPath) {
        throw 'Provide -ConfigPath, or both -DomainControllers and -Services.'
    }
    $config = Import-PowerShellDataFile -Path $ConfigPath
    if (-not $DomainControllers) { $DomainControllers = $config.DomainControllers }
    if (-not $Services)          { $Services = $config.Services | ForEach-Object { $_.Name } }
}

# --- SID resolution -------------------------------------------------------
$sid = (New-Object System.Security.Principal.NTAccount($Account)).Translate([System.Security.Principal.SecurityIdentifier]).Value

# --- Remote block ---------------------------------------------------------
$remoteBlock = {
    param($sid, $services)

    $ace = "(A;;CCLCSWLOCRRC;;;$sid)"   # read only (same set as the Interactive Users default)

    $statuses = foreach ($svc in $services) {
        $raw = & sc.exe sdshow $svc 2>&1
        if ($LASTEXITCODE -ne 0) {
            "$svc : cannot read SDDL ($(($raw | Select-Object -First 1)))"
            continue
        }
        $current = ($raw | Where-Object { $_ -match '\S' }) -join ''

        if ($current -match [regex]::Escape(";;;$sid)")) {
            "$svc : already present"
            continue
        }

        $backup = "C:\Windows\Temp\svc_sddl_{0}_{1}.txt" -f $svc, (Get-Date -Format 'yyyyMMdd_HHmmss')
        Set-Content -Path $backup -Value $current

        # Insert at end of DACL, before the SACL when present
        $idx = $current.IndexOf('S:')
        $new = if ($idx -ge 0) { $current.Insert($idx, $ace) } else { $current + $ace }

        $out = & sc.exe sdset $svc $new 2>&1
        if ($LASTEXITCODE -ne 0) {
            "$svc : sdset failed ($out)"
        }
        else {
            "$svc : read granted"
        }
    }

    return ($statuses -join ' | ')
}

# --- Apply ----------------------------------------------------------------
$results = foreach ($dc in $DomainControllers) {
    if (-not $PSCmdlet.ShouldProcess($dc, "Grant service read ($($Services -join ', ')) to $Account")) { continue }

    try {
        $status = Invoke-Command -ComputerName $dc -ScriptBlock $remoteBlock -ArgumentList $sid, $Services -ErrorAction Stop
        [PSCustomObject]@{ DC = $dc; Status = $status; Error = $null }
    }
    catch {
        [PSCustomObject]@{ DC = $dc; Status = 'FAILED'; Error = $_.Exception.Message }
    }
}

$results | Format-Table -AutoSize -Wrap

$failed = @($results | Where-Object { $_.Status -eq 'FAILED' })
if ($failed.Count -gt 0) {
    Write-Host "`nFailure details:" -ForegroundColor Yellow
    foreach ($f in $failed) {
        Write-Host ("  {0}`n    {1}`n" -f $f.DC, $f.Error) -ForegroundColor Yellow
    }
    exit 1
}

Write-Host "`nDone. Restart WinRM on the DCs (Restart-Service WinRM) before retesting." -ForegroundColor Green
