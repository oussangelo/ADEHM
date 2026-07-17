# ADEHM — Installation Guide

## 1. Prerequisites

| Item | Detail |
|---|---|
| PowerShell | Windows PowerShell 5.1 (Windows Server 2012 R2+) or PowerShell 7.x |
| Execution host | Domain-joined member server, or a DC itself |
| Connectivity | WinRM (5985/5986) and ICMP allowed toward all monitored DCs |
| Service account | Dedicated, non-administrator AD account (see `PERMISSIONS.md`) |
| `nltest.exe` | Provided by the server administration tools (RSAT) — used to identify each DC's AD site |
| SMTP relay | Internal SMTP server allowing the ADEHM host/account to send |

## 2. Deploying the project

Copy the `ADEHM/` folder to the execution host, for example:

```
D:\Scripts\ADEHM\
```

No third-party module is required: ADEHM only uses built-in cmdlets
(`CimCmdlets`, `Microsoft.PowerShell.Management`, ...).

If the files were downloaded from the Internet, unblock them once:

```powershell
Get-ChildItem -Path D:\Scripts\ADEHM -Recurse | Unblock-File
```

## 3. Execution policy

```powershell
Get-ExecutionPolicy -List
# If needed, on the execution host only:
Set-ExecutionPolicy -Scope LocalMachine -ExecutionPolicy RemoteSigned
```

## 4. WinRM on the target DCs

On each monitored DC (once, ideally via GPO):

```powershell
Enable-PSRemoting -Force
winrm quickconfig -quiet
```

Verify from the ADEHM host:

```powershell
Test-WSMan -ComputerName DC01.domain.local
```

## 5. Service account and delegations

Follow `PERMISSIONS.md` — it contains the complete delegation map (two
Builtin group memberships, WMI namespace rights, and the extra layers
required on hardened DCs) plus the automation scripts under `Tools/`.

Prefer a group Managed Service Account (gMSA) so no password ever needs
managing, and grant everything through a dedicated security group.

## 6. Configuration

Edit `Config/ADEHM.config.psd1`:

- `DomainControllers`: FQDNs of your domain controllers
- `Thresholds`: CPU / RAM / disk thresholds for your context
- `Mail`: SMTP server, sender, recipients
- `Paths`: output directories (default: project-relative subfolders)

**Never store a clear-text password in this file.** Use
`-Credential (Get-Credential)` interactively, Windows Credential Manager,
or a gMSA.

## 7. Dry run (demo mode)

Before any real connection, validate the installation with simulated data:

```powershell
cd D:\Scripts\ADEHM
.\Start-ADEHM.ps1 -DemoMode
```

This produces an HTML report in `Reports/` and a log in `Logs/` without
any network access, validating: configuration loading, write access to the
project folders, report rendering, and (when `Mail.Enabled = $true`) an
actual test email.

## 8. First real run

```powershell
$cred = Get-Credential  # the service account
.\Start-ADEHM.ps1 -ConfigPath .\Config\ADEHM.config.psd1 -Credential $cred
```

On any anomaly, check the log in `Logs\`: every error includes a probable
cause and a recommendation.

## 9. Scheduling (scheduled task)

```powershell
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument '-NoProfile -File "D:\Scripts\ADEHM\Start-ADEHM.ps1"' `
    -WorkingDirectory 'D:\Scripts\ADEHM'
$trigger = New-ScheduledTaskTrigger -Daily -At 7:00AM
$principal = New-ScheduledTaskPrincipal -UserId 'DOMAIN\svc-adehm' -LogonType Password
Register-ScheduledTask -TaskName 'ADEHM - AD Monitoring' `
    -Action $action -Trigger $trigger -Principal $principal
```

Scheduled tasks use the *batch* logon type: on hardened hosts, ensure the
service account (or its group) holds *Log on as a batch job* on the
execution host (see `PERMISSIONS.md`). A gMSA removes password management
entirely (recommended).
