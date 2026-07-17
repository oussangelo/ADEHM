#requires -Version 5.1
<#
.SYNOPSIS
    Complete ADEHM permission diagnostic against the domain controllers.

.DESCRIPTION
    Run from an ADMIN console (your own account), providing the service
    account credentials via -Credential. For each DC, the script captures
    AT THE SAME MOMENT:

      1. The functional test, step by step (WinRM -> CIM session -> OS
         read -> service read), to pinpoint the failing link;
      2. The actual DACL of the root\cimv2 WMI namespace for the service
         account and the dedicated group;
      3. The denials recorded in the DC's WMI-Activity log
         (0x80041003 = WBEM_E_ACCESS_DENIED) with User, Namespace and
         Operation;
      4. The Service Control Manager SDDL and whether the group is present.

    The output is a text report to copy-paste in full.

    Note: root\interop denials in the WMI-Activity log are benign,
    non-blocking probes of the WinRM WMI plugin - field-verified. They do
    not require any grant.

.EXAMPLE
    .\Test-ADEHMPermission.ps1 -Credential (Get-Credential DOMAIN\svc-adehm) `
        -GroupName 'GRP-AD-Monitoring' -ConfigPath ..\Config\ADEHM.config.psd1
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [System.Management.Automation.PSCredential]$Credential,

    [string]$GroupName,

    [string[]]$DomainControllers,

    [string]$ConfigPath
)

$ErrorActionPreference = 'Continue'

# --- DC list resolution ------------------------------------------------
if (-not $DomainControllers) {
    if (-not $ConfigPath) { throw 'Provide -DomainControllers or -ConfigPath.' }
    $DomainControllers = (Import-PowerShellDataFile -Path $ConfigPath).DomainControllers
}

# --- Resolve the SIDs to watch ------------------------------------------
$sids = @{}
$acctName = $Credential.UserName -replace '^.*\\', ''
try {
    $sids[(New-Object System.Security.Principal.NTAccount($Credential.UserName)).Translate([System.Security.Principal.SecurityIdentifier]).Value] = "Account : $($Credential.UserName)"
} catch { Write-Warning "Cannot resolve account SID: $($_.Exception.Message)" }

if ($GroupName) {
    try {
        $g = New-Object System.Security.Principal.NTAccount($GroupName)
        $sids[$g.Translate([System.Security.Principal.SecurityIdentifier]).Value] = "Group   : $GroupName"
    } catch { Write-Warning "Cannot resolve group SID: $($_.Exception.Message)" }
}

$sep = '=' * 78

foreach ($dc in $DomainControllers) {

    Write-Host "`n$sep" -ForegroundColor Cyan
    Write-Host "DC : $dc    ($(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Cyan
    Write-Host $sep -ForegroundColor Cyan

    # ==================================================================
    # 1. FUNCTIONAL TEST WITH THE SERVICE ACCOUNT, STEP BY STEP
    # ==================================================================
    Write-Host "`n[1] Functional test (identity: $($Credential.UserName))" -ForegroundColor Yellow

    # 1a. Authenticated WinRM
    try {
        $null = Test-WSMan -ComputerName $dc -Credential $Credential -Authentication Default -ErrorAction Stop
        Write-Host '  1a. Authenticated WinRM .......... OK'
    }
    catch {
        Write-Host "  1a. Authenticated WinRM .......... FAILED: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host '      -> Blocked BEFORE WMI (network logon right or RootSDDL). Next steps skipped.'
        continue
    }

    # 1b. CIM session opening
    $cim = $null
    try {
        $cim = New-CimSession -ComputerName $dc -Credential $Credential -ErrorAction Stop
        Write-Host '  1b. CIM session .................. OK'
    }
    catch {
        Write-Host "  1b. CIM session .................. FAILED: $($_.Exception.Message)" -ForegroundColor Red
    }

    # 1c. Win32_OperatingSystem read
    if ($cim) {
        try {
            $os = Get-CimInstance -CimSession $cim -ClassName Win32_OperatingSystem -ErrorAction Stop
            Write-Host "  1c. Win32_OperatingSystem read ... OK ($($os.Caption))"
        }
        catch {
            Write-Host "  1c. Win32_OperatingSystem read ... FAILED: $($_.Exception.Message)" -ForegroundColor Red
        }

        # 1d. Win32_Service read
        try {
            $svc = Get-CimInstance -CimSession $cim -ClassName Win32_Service -Filter "Name='NTDS'" -ErrorAction Stop
            if ($svc -and $svc.State) {
                Write-Host "  1d. Win32_Service read ........... OK (NTDS = $($svc.State))"
            }
            else {
                Write-Host '  1d. Win32_Service read ........... FAILED: query accepted but NTDS INVISIBLE (the service security descriptor does not grant read to the account/group)' -ForegroundColor Red
            }
        }
        catch {
            Write-Host "  1d. Win32_Service read ........... FAILED: $($_.Exception.Message)" -ForegroundColor Red
        }

        Remove-CimSession $cim -ErrorAction SilentlyContinue
    }

    # ==================================================================
    # 2. ACTUAL root\cimv2 DACL (same instant, via YOUR admin account)
    # ==================================================================
    Write-Host "`n[2] WMI namespace DACL (ADEHM account/group entries)" -ForegroundColor Yellow
    foreach ($ns in @('root/cimv2')) {
        try {
            $dacl = Invoke-Command -ComputerName $dc -ScriptBlock {
                param($ns)
                (Invoke-WmiMethod -Namespace $ns -Path '__SystemSecurity=@' -Name GetSecurityDescriptor).Descriptor.DACL |
                    ForEach-Object {
                        [PSCustomObject]@{
                            SID           = $_.Trustee.SIDString
                            Name          = '{0}\{1}' -f $_.Trustee.Domain, $_.Trustee.Name
                            AceType       = $_.AceType          # 0 = Allow, 1 = Deny
                            EnableAccount = [bool]($_.AccessMask -band 0x1)
                            RemoteEnable  = [bool]($_.AccessMask -band 0x20)
                        }
                    }
            } -ArgumentList $ns -ErrorAction Stop

            $relevant = $dacl | Where-Object { $_.SID -in $sids.Keys }
            if ($relevant) {
                foreach ($r in $relevant) {
                    $type = if ($r.AceType -eq 1) { 'DENY !!' } else { 'Allow' }
                    Write-Host ("  {0,-12} {1}  [{2}]  EnableAccount={3}  RemoteEnable={4}" -f $ns, $sids[$r.SID], $type, $r.EnableAccount, $r.RemoteEnable)
                }
            }
            else {
                Write-Host "  $ns  NO entry for the account or the group on this DC." -ForegroundColor Red
            }
        }
        catch {
            Write-Host "  $ns  Cannot read: $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    # ==================================================================
    # 3. DENIALS RECORDED IN THE DC WMI LOG (last 15 minutes)
    # ==================================================================
    Write-Host "`n[3] DC WMI-Activity log (0x80041003 denials, last 15 minutes)" -ForegroundColor Yellow
    try {
        $events = Invoke-Command -ComputerName $dc -ScriptBlock {
            param($acct)
            Get-WinEvent -LogName 'Microsoft-Windows-WMI-Activity/Operational' -MaxEvents 200 -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.TimeCreated -gt (Get-Date).AddMinutes(-15) -and
                    ($_.Message -match '0x80041003' -or $_.Message -match [regex]::Escape($acct))
                } |
                Select-Object -First 5 TimeCreated, Message
        } -ArgumentList $acctName -ErrorAction Stop

        if ($events) {
            foreach ($e in $events) {
                Write-Host "  --- $($e.TimeCreated) ---"
                $compact = ($e.Message -split "`n" | Where-Object { $_ -match 'User|Namespace|Operation|ResultCode|ClientProcessId' }) -join '; '
                if (-not $compact) { $compact = $e.Message.Substring(0, [math]::Min(400, $e.Message.Length)) }
                Write-Host "  $compact"
            }
            Write-Host '  Reminder: root\interop denials are benign non-blocking probes.'
        }
        else {
            Write-Host '  No WMI denial recorded in the last 15 minutes.'
        }
    }
    catch {
        Write-Host "  Cannot read the log: $($_.Exception.Message)" -ForegroundColor Red
    }

    # ==================================================================
    # 4. SERVICE CONTROL MANAGER SDDL (right to enumerate services)
    # ==================================================================
    Write-Host "`n[4] Service Control Manager SDDL" -ForegroundColor Yellow
    try {
        $scSddl = Invoke-Command -ComputerName $dc -ScriptBlock {
            ((& sc.exe sdshow scmanager) | Where-Object { $_ -match '\S' }) -join ''
        } -ErrorAction Stop

        $found = $false
        foreach ($s in $sids.Keys) {
            if ($scSddl -match [regex]::Escape(";;;$s)")) {
                Write-Host "  $($sids[$s]) PRESENT in the SCM SDDL"
                $found = $true
            }
        }
        if (-not $found) {
            Write-Host '  Neither the account nor the group appears in the SCM SDDL.' -ForegroundColor Red
        }
        Write-Host "  Raw SDDL: $scSddl"
    }
    catch {
        Write-Host "  Cannot read: $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host "`n$sep"
Write-Host 'Diagnostic complete. Copy-paste the FULL output above.' -ForegroundColor Green
Write-Host $sep
