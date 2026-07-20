<#
.SYNOPSIS
    ADEHM - Active Directory Enterprise Health Monitor
    Main entry point of the monitoring engine.

.DESCRIPTION
    Monitors every domain controller defined in the configuration, collects
    system and Active Directory indicators through CIM/WinRM, generates a
    professional HTML report and sends it by email.

    Execution flow:
    Read Configuration -> Create Logger -> Read DC list -> CIM Connection
    -> Collection -> Report Generation -> Mail Delivery -> Archiving -> End

.PARAMETER ConfigPath
    Path to the ADEHM.config.psd1 configuration file.
    Default: .\Config\ADEHM.config.psd1

.PARAMETER Credential
    Service account used for remote CIM connections to the domain
    controllers. Must hold the minimal delegations described in
    Docs/PERMISSIONS.md (least-privilege principle).

.PARAMETER MailCredential
    Credentials used to authenticate to the SMTP server. Optional and only
    relevant when Config.Mail.Anonymous is $false (default):
      - Omitted: -Credential is reused for mail, which is correct for
        relays that trust the AD service account.
      - Provided: used instead of -Credential, for a mail identity that
        differs from the AD service account (e.g. Gmail, Office 365
        consumer, a dedicated mail-only account).
    For an anonymous internal relay (no credentials expected at all), set
    Mail.Anonymous = $true in the configuration instead — neither
    -Credential nor -MailCredential is then needed for mail delivery.

.PARAMETER DemoMode
    Generates simulated data, with no real network connection, to validate
    the installation, the HTML report rendering and the mail flow. Useful
    for acceptance testing before production rollout.

.EXAMPLE
    .\Start-ADEHM.ps1 -ConfigPath .\Config\ADEHM.config.psd1 -Credential (Get-Credential)

.EXAMPLE
    .\Start-ADEHM.ps1 -DemoMode

.EXAMPLE
    .\Start-ADEHM.ps1 -Credential (Get-Credential DOMAIN\svc-adehm) -MailCredential (Get-Credential yourbox@gmail.com)
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'Config\ADEHM.config.psd1'),
    [System.Management.Automation.PSCredential]$Credential,
    [System.Management.Automation.PSCredential]$MailCredential,
    [switch]$DemoMode
)

$ErrorActionPreference = 'Stop'
$startTime = Get-Date

# ---------------------------------------------------------------------
# 0. Module loading (modular architecture)
# ---------------------------------------------------------------------
$moduleRoot = Join-Path $PSScriptRoot 'Modules'
Get-ChildItem -Path $moduleRoot -Filter '*.psm1' | ForEach-Object {
    # -Global is required so that functions from one internal module (e.g.
    # Write-ADEHMError in ADEHM.Logger.psm1) remain visible from inside a
    # DIFFERENT internal module (e.g. ADEHM.Mail.psm1's catch block).
    # Without it, this works when Start-ADEHM.ps1 is run directly, but
    # breaks when invoked through the PowerShell Gallery module wrapper
    # (Install-Module ADEHM -> Start-ADEHM), because the wrapper's own
    # module session state changes where a plain Import-Module lands.
    Import-Module $_.FullName -Force -Global
}

try {
    # -------------------------------------------------------------
    # 1. Read Configuration
    # -------------------------------------------------------------
    $config = Import-ADEHMConfig -Path $ConfigPath

    # -------------------------------------------------------------
    # 2. Create Logger
    # -------------------------------------------------------------
    $logPath = Initialize-ADEHMLogger -LogDirectory $config.Paths.Logs -DebugMode:$config.General.DebugMode
    Write-ADEHMLog -Level INFO -Module Core -Message 'ADEHM Started'
    Write-ADEHMLog -Level INFO -Module Core -Message 'Reading Configuration'
    if ($DemoMode) {
        Write-ADEHMLog -Level WARN -Module Core -Message 'DemoMode active: simulated data, no real network connection.'
    }

    # -------------------------------------------------------------
    # 3. Read DC list
    # -------------------------------------------------------------
    $dcList = $config.DomainControllers
    Write-ADEHMLog -Level INFO -Module Core -Message "Domain Controllers to check: $($dcList.Count)"

    $results = New-Object System.Collections.Generic.List[object]
    $svcNames = $config.Services | ForEach-Object { $_.Name }

    if (-not $DemoMode) {
        $adIdentity = if ($Credential) { $Credential.UserName } else { "$env:USERDOMAIN\$env:USERNAME (current context)" }
        Write-ADEHMLog -Level INFO -Module Core -Message "AD/CIM identity: $adIdentity"
    }

    foreach ($dc in $dcList) {

        Write-ADEHMLog -Level INFO -Module Core -Message "Connecting $dc"

        $row = [ordered]@{
            Hostname        = $dc
            Site            = $null
            IPAddress       = $null
            Ping            = $false
            WinRM           = $false
            NTDS            = $null
            DNS             = $null
            DFSR            = $null
            Netlogon        = $null
            KDC             = $null
            ADWS            = $null
            SYSVOL          = $false
            NetlogonShare   = $false   # \\DC\NETLOGON share (distinct from the Netlogon service: PowerShell hashtable keys are case-insensitive)
            CpuPercent      = $null
            RamPercent      = $null
            DiskFreePercent = $null
            DiskDetail      = @()
            OSCaption       = $null
            BuildNumber     = $null
            LastBootTime    = $null
            UptimeDays      = $null
        }

        if ($DemoMode) {
            # -----------------------------------------------------
            # Simulated data: validates the HTML report and the mail
            # flow without a real AD infrastructure.
            # -----------------------------------------------------
            $row.Site      = 'Default-First-Site-Name'
            $row.IPAddress = '10.10.{0}.{1}' -f (Get-Random -Minimum 0 -Maximum 5), (Get-Random -Minimum 2 -Maximum 254)
            $row.Ping      = $true
            $row.WinRM     = $true
            foreach ($svc in $svcNames) {
                $row[$svc] = ((Get-Random -Minimum 0 -Maximum 10) -gt 0)
            }
            $row.SYSVOL        = $true
            $row.NetlogonShare = $true
            $row.CpuPercent = Get-Random -Minimum 5 -Maximum 95
            $row.RamPercent = Get-Random -Minimum 20 -Maximum 95
            $row.DiskFreePercent = Get-Random -Minimum 2 -Maximum 80
            $row.DiskDetail = @([PSCustomObject]@{
                DeviceID    = 'C:'
                SizeGB      = 120
                FreeGB      = [math]::Round(120 * $row.DiskFreePercent / 100, 1)
                FreePercent = $row.DiskFreePercent
            })
            $row.OSCaption   = 'Microsoft Windows Server 2022 Standard'
            $row.BuildNumber = '20348'
            $row.LastBootTime = (Get-Date).AddDays(-(Get-Random -Minimum 1 -Maximum 90))
            $row.UptimeDays   = [math]::Round(((Get-Date) - $row.LastBootTime).TotalDays, 1)

            Write-ADEHMLog -Level INFO -Module Connectivity -Message "$dc Ping OK (demo)"
            Write-ADEHMLog -Level INFO -Module System -Message "$dc CPU OK (demo)"
            Write-ADEHMLog -Level INFO -Module System -Message "$dc RAM OK (demo)"
        }
        else {
            # -----------------------------------------------------
            # 4a. Basic connectivity
            # -----------------------------------------------------
            $row.Ping  = Test-ADEHMPing -ComputerName $dc -TimeoutSeconds $config.General.TimeoutSeconds
            $dns       = Resolve-ADEHMDns -ComputerName $dc
            $row.IPAddress = $dns.IPAddress
            $row.WinRM = Test-ADEHMWinRM -ComputerName $dc -TimeoutSeconds $config.General.TimeoutSeconds

            if (-not $row.Ping -or -not $row.WinRM) {
                Write-ADEHMError -Server $dc -Module 'Connectivity' `
                    -Exception 'Ping or WinRM unavailable' `
                    -ProbableCause 'Server down, firewall blocking ICMP/WinRM, or WinRM service stopped.' `
                    -Recommendation "Check the state of $dc and the WinRM configuration (winrm quickconfig) / firewall."
                $results.Add([PSCustomObject]$row)
                continue
            }

            # -----------------------------------------------------
            # 4b. CIM connection (one single session per server)
            # -----------------------------------------------------
            $cim = $null
            try {
                $cim = New-ADEHMCimSession -ComputerName $dc -TimeoutSeconds $config.General.TimeoutSeconds -Credential $Credential
                Write-ADEHMLog -Level DEBUG -Module System -Message "$dc CIM session opened"

                # -------------------------------------------------
                # 4c. Collection
                # -------------------------------------------------
                $sysInfo    = Get-ADEHMSystemInfo -CimSession $cim
                $diskInfo   = Get-ADEHMDiskInfo -CimSession $cim
                $services   = Get-ADEHMServiceStatus -CimSession $cim -ServiceNames $svcNames
                $domainInfo = Get-ADEHMDomainInfo -ComputerName $dc

                $row.Site         = $domainInfo.Site
                $row.CpuPercent   = $sysInfo.CpuLoadPercent
                $row.RamPercent   = $sysInfo.RamUsedPercent
                $row.OSCaption    = $sysInfo.OSCaption
                $row.BuildNumber  = $sysInfo.BuildNumber
                $row.LastBootTime = $sysInfo.LastBootTime
                $row.UptimeDays   = $sysInfo.UptimeDays
                $row.DiskDetail   = $diskInfo

                $cDisk = $diskInfo | Where-Object { $_.DeviceID -eq 'C:' } | Select-Object -First 1
                $row.DiskFreePercent = if ($cDisk) { $cDisk.FreePercent } else { ($diskInfo | Sort-Object FreePercent | Select-Object -First 1).FreePercent }

                foreach ($svc in $svcNames) {
                    $row[$svc] = $services[$svc].Running
                }

                $row.SYSVOL        = Test-ADEHMShare -ComputerName $dc -ShareName 'SYSVOL'
                $row.NetlogonShare = Test-ADEHMShare -ComputerName $dc -ShareName 'NETLOGON'

                Write-ADEHMLog -Level INFO -Module System -Message "$dc CPU OK"
                Write-ADEHMLog -Level INFO -Module System -Message "$dc RAM OK"
            }
            catch {
                $msg = $_.Exception.Message

                # The probable cause is inferred from the error type to avoid
                # sending the diagnosis down the wrong path.
                if ($msg -match 'parameter') {
                    $cause = 'Client-side error (ADEHM host), raised BEFORE any connection to the DC: cmdlet incompatibility or engine bug.'
                    $reco  = "The issue concerns neither $dc nor permissions. Check the host PowerShell version and report the error."
                }
                elseif ($msg -match 'denied|access') {
                    $cause = "Insufficient rights for the service account on $dc."
                    $reco  = 'Check the CIM/WMI and WinRM delegations of the service account (see Docs/PERMISSIONS.md).'
                }
                elseif ($msg -match 'timeout|timed out') {
                    $cause = "Response timeout: $dc overloaded, or WinRM traffic (5985) filtered by a firewall."
                    $reco  = "Run Test-NetConnection $dc -Port 5985 and raise General.TimeoutSeconds if the server is slow."
                }
                else {
                    $cause = "CIM/WinRM service unavailable on $dc, or unexpected error."
                    $reco  = 'Review the exception message above and the debug-level log (General.DebugMode = $true).'
                }

                Write-ADEHMError -Server $dc -Module 'System/ActiveDirectory' -Exception $msg `
                    -ProbableCause $cause -Recommendation $reco
            }
            finally {
                # Systematic session cleanup
                if ($cim) {
                    Remove-CimSession -CimSession $cim -ErrorAction SilentlyContinue
                    Write-ADEHMLog -Level DEBUG -Module System -Message "$dc CIM session closed"
                }
            }
        }

        $results.Add([PSCustomObject]$row)
    }

    # -------------------------------------------------------------
    # 5. Report Generation
    # -------------------------------------------------------------
    $endTime = Get-Date
    $reportFileName = 'ADEHM_Report_{0}.html' -f (Get-Date -Format 'yyyyMMdd_HHmmss')
    $reportPath = Join-Path $config.Paths.Reports $reportFileName

    New-ADEHMHtmlReport -Config $config -Results $results -StartTime $startTime -EndTime $endTime `
        -ErrorLog (Get-ADEHMErrorLog) -OutputPath $reportPath | Out-Null
    Write-ADEHMLog -Level INFO -Module Report -Message 'Report Generated'

    # -------------------------------------------------------------
    # 6. Mail Delivery
    # -------------------------------------------------------------
    $emailBody = $null
    if ($config.Mail.Enabled -and $config.Mail.EmbedReportInBody) {
        # Email-optimized twin rendering: same data, built with HTML tables
        # + inline styles for faithful display in Outlook.
        $emailBody = New-ADEHMEmailReport -Config $config -Results $results `
            -StartTime $startTime -EndTime $endTime -ErrorLog (Get-ADEHMErrorLog)
    }

    $mailAuth = if ($MailCredential) { $MailCredential } else { $Credential }
    if ($config.Mail.Anonymous) {
        Write-ADEHMLog -Level INFO -Module Mail -Message 'SMTP identity: none (anonymous relay, Mail.Anonymous = $true)'
    }
    else {
        $mailIdentity = if ($mailAuth) { $mailAuth.UserName } else { "$env:USERDOMAIN\$env:USERNAME (current context)" }
        $reused = if (-not $MailCredential -and $Credential) { ' (reused from -Credential; pass -MailCredential to use a different identity)' } else { '' }
        Write-ADEHMLog -Level INFO -Module Mail -Message "SMTP identity: $mailIdentity$reused"
    }

    $sent = Send-ADEHMReport -Config $config -ReportPath $reportPath -RunDate $startTime `
        -BodyHtml $emailBody -Credential $mailAuth
    if ($sent) {
        Write-ADEHMLog -Level INFO -Module Mail -Message 'Mail Sent'
    }

    # -------------------------------------------------------------
    # 7. Archiving
    # -------------------------------------------------------------
    if ($config.General.ArchiveReports) {
        $cutoff = (Get-Date).AddDays(-$config.General.ArchiveDays)

        Get-ChildItem -Path $config.Paths.Reports -Filter 'ADEHM_Report_*.html' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            ForEach-Object { Move-Item -LiteralPath $_.FullName -Destination $config.Paths.Archive -Force }

        Get-ChildItem -Path $config.Paths.Logs -Filter 'ADEHM_*.log' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            ForEach-Object { Move-Item -LiteralPath $_.FullName -Destination $config.Paths.Archive -Force }

        Write-ADEHMLog -Level DEBUG -Module Core -Message "Archiving: items older than $($cutoff.ToString('yyyy-MM-dd')) moved."
    }

    # -------------------------------------------------------------
    # 8. End
    # -------------------------------------------------------------
    Write-ADEHMLog -Level INFO -Module Core -Message 'ADEHM Finished'

    return [PSCustomObject]@{
        ReportPath = $reportPath
        LogPath    = $logPath
        Results    = $results
        Errors     = Get-ADEHMErrorLog
    }
}
catch {
    Write-Host "FATAL ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if (Get-Command Write-ADEHMLog -ErrorAction SilentlyContinue) {
        Write-ADEHMLog -Level ERROR -Module Core -Message "Fatal error: $($_.Exception.Message)"
    }
    exit 1
}
