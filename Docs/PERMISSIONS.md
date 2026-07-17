# ADEHM — Permissions Guide

ADEHM runs with a **dedicated, non-administrator service account** holding
only the delegations strictly required for monitoring. This guide is the
complete, field-tested map of those delegations — including the ones that
only surface on **hardened domain controllers** (Microsoft Security
Baseline, CIS, ANSSI or equivalent).

## The five delegations

On a default installation, delegations 2–3 are usually sufficient. On
hardened DCs, all five are typically required.

| # | Layer | What to grant | How |
|---|-------|---------------|-----|
| 1 | **Network logon right** (`SeNetworkLogonRight`) | Add the monitoring group to *Access this computer from the network* | In the hardening GPO applied to the Domain Controllers OU (hardening baselines restrict this right; a local change would be overwritten at the next GPO refresh) |
| 2 | **WinRM root access** (RootSDDL) | The monitoring group, or membership in Builtin *Remote Management Users* (covered by the `RM` entry of the default RootSDDL) | Default on Windows Server 2012+; hardened/upgraded systems may carry a stripped RootSDDL — see below |
| 3 | **WMI namespace `root\cimv2`** | *Enable Account* + *Remote Enable* (mask `0x21`), nothing else | `Tools/Grant-ADEHMWmiPermission.ps1` (idempotent, supports `-WhatIf` and `-Remove`) |
| 4 | **Service Control Manager SDDL** | Read/enumerate ACE `(A;;CCLCRPRC;;;<SID>)` | Snippet below; hardened systems deny remote service enumeration to non-admins |
| 5 | **Per-service security descriptors** | Read-only ACE `(A;;CCLCSWLOCRRC;;;<SID>)` on each monitored service | `Tools/Grant-ADEHMServiceReadPermission.ps1` (idempotent, with SDDL backups) |

Two Builtin group memberships complete the setup (one command each — DCs
have no local groups, their "local" groups are the domain Builtin groups,
so a single membership covers every DC):

```powershell
Add-ADGroupMember -Identity 'Performance Monitor Users' -Members 'GRP-AD-Monitoring'
Add-ADGroupMember -Identity 'Remote Management Users'   -Members 'GRP-AD-Monitoring'
```

## Recommended design: a dedicated security group

Grant everything to a dedicated group (e.g. `GRP-AD-Monitoring`) rather
than to the account directly: the delegation becomes self-documenting,
auditable, and revocable by removing a member — without touching the DCs.
Group memberships are only read at logon: any change requires a **fresh
logon token** (new session / new network logon).

## Operational rules learned in the field

- **Restart WinRM after any ACL change.** WinRM keeps per-user host
  processes (`WsmProvHost.exe`) alive between sessions; stale processes
  serve requests with pre-change access state and produce inexplicable
  denials hours after a correct fix. `Restart-Service WinRM` on the DCs
  clears them (low impact: only active remote-management sessions drop).
- **`root\interop` denials in WMI-Activity logs are benign.** The WinRM
  WMI plugin probes `root\interop` and logs `0x80041003` denials even on
  fully working setups. Field-verified: no `root\interop` grant is needed.
  Do not chase this red herring.
- **An "invisible" service is a permission symptom.** When a WMI service
  query is accepted but returns nothing, the service's own security
  descriptor is filtering the caller (delegation #5) — the service is not
  stopped.
- **Interactive logon is deliberately denied.** Hardened baselines deny
  service accounts local/interactive logon (`runas` fails with error 1385)
  — this is correct. Test with explicit credentials instead:
  `New-CimSession -Credential`, `Test-WSMan -Credential -Authentication
  Default`. Scheduled tasks use the *batch* logon type: grant *Log on as a
  batch job* on the execution host only (not on the DCs) if the baseline
  restricts it.
- **`Test-WSMan` without `-Authentication Default` proves nothing**: the
  default probe is unauthenticated and succeeds for any account.

## Fixing a stripped WinRM RootSDDL

Symptom: everything works when the account is an administrator, nothing
works otherwise, and the RootSDDL lacks the `(A;;GA;;;RM)` entry:

```powershell
$sid = (Get-ADGroup 'GRP-AD-Monitoring').SID.Value
Invoke-Command -ComputerName $dcs -ScriptBlock {
    param($sid)
    $current = (Get-Item WSMan:\localhost\Service\RootSDDL).Value
    if ($current -match [regex]::Escape(";;;$sid)")) { return 'Already present' }
    Set-Content "C:\Windows\Temp\RootSDDL_backup_$(Get-Date -Format yyyyMMdd_HHmmss).txt" -Value $current
    $ace = "(A;;GA;;;$sid)"
    $idx = $current.IndexOf('S:')
    $new = if ($idx -ge 0) { $current.Insert($idx, $ace) } else { $current + $ace }
    Set-Item WSMan:\localhost\Service\RootSDDL -Value $new -Force
    'Updated'
} -ArgumentList $sid
```

If a hardening GPO manages this value, codify the change **in the GPO**,
not on the machines, or it will be reverted at the next refresh.

## Granting SCM read access (delegation #4)

```powershell
$sid = (Get-ADGroup 'GRP-AD-Monitoring').SID.Value
Invoke-Command -ComputerName $dcs -ScriptBlock {
    param($sid)
    $current = ((& sc.exe sdshow scmanager) | Where-Object { $_ -match '\S' }) -join ''
    if ($current -match [regex]::Escape(";;;$sid)")) { return 'Already present' }
    Set-Content "C:\Windows\Temp\scmanager_sddl_backup_$(Get-Date -Format yyyyMMdd_HHmmss).txt" -Value $current
    $ace = "(A;;CCLCRPRC;;;$sid)"
    $idx = $current.IndexOf('S:')
    $new = if ($idx -ge 0) { $current.Insert($idx, $ace) } else { $current + $ace }
    "$(& sc.exe sdset scmanager $new)"
} -ArgumentList $sid
```

`CCLCRPRC` = connect, enumerate, query status, read control — the same set
Windows grants interactive users by default. No start/stop/modify rights.

## Diagnosing

`Tools/Test-ADEHMPermission.ps1` captures, in a single run and at the same
instant: the functional chain step by step (which link fails), the actual
namespace DACL, the WMI-Activity denials (with User/Namespace/Operation),
and the SCM SDDL. Attach its full output to any permission-related issue.

## What this account must never be able to do

- Log on interactively (RDP) to a DC.
- Modify any AD object, group policy, or service.
- Write to SYSVOL or NETLOGON.
- Belong to any administration group, local or domain. If a test fails
  with *Access denied*, the fix is the minimal missing right above —
  never elevating the account to administrator.
