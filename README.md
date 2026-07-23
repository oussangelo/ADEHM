# ADEHM — Active Directory Enterprise Health Monitor

Agentless health monitoring for Active Directory domain controllers.
**Pure PowerShell + CIM/WinRM. No agents, no database, no admin rights.**

ADEHM is the monitoring component of the **AD Enterprise Suite**, a growing
family of Active Directory tooling.

[![PowerShell Gallery](https://img.shields.io/powershellgallery/v/ADEHM)](https://www.powershellgallery.com/packages/ADEHM)
[![Downloads](https://img.shields.io/powershellgallery/dt/ADEHM)](https://www.powershellgallery.com/packages/ADEHM)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

![ADEHM HTML report](Docs/images/report.png)

## Why ADEHM

Most AD monitoring options are either heavyweight platforms (per-sensor
licensing, agents, databases) or ad-hoc scripts built on legacy WMI/DCOM.
ADEHM sits in between:

- **Agentless** — one CIM session per DC over WinRM, nothing to install on
  the controllers
- **Least privilege by design** — runs with a read-only service account;
  ships with the tooling and the documented delegation map to make that
  work even on **hardened DCs** (security baselines)
- **Auditable** — plain PowerShell you can read, MIT licensed
- **Complete output** — professional HTML report, email delivery with an
  Outlook-safe body rendering, detailed logs, structured incidents with
  probable cause and recommendation

## What it checks

| Category | Checks |
|---|---|
| Availability | Ping, DNS resolution, WinRM, IP, FQDN |
| AD services | NTDS, DNS, DFSR, Netlogon, KDC, ADWS |
| Shares | SYSVOL, NETLOGON |
| System | CPU, RAM, disks (all fixed volumes), uptime, last boot |
| Identity | Server name, Windows version/build, AD site, domain, forest |

Each DC gets an overall status — OK / Warning / Critical / Offline — with
configurable thresholds.
 
## Quick start

mkdir C:\ADEHM    ## Create your folder to start.

**Option A — PowerShell Gallery (recommended):**

```powershell
Install-Module ADEHM
# Copy the sample config AND the stylesheet somewhere writable, then adjust
# DCs/thresholds/SMTP. Assets/ must sit next to the config file, or the
# report falls back to a minimal, unstyled rendering. The trailing \*
# copies the folder's CONTENTS — safe even if C:\ADEHM\Assets already
# exists (e.g. auto-created by a previous run); without it, Copy-Item
# would nest the source folder one level too deep.
$moduleBase = (Get-Module ADEHM -ListAvailable | Select-Object -First 1).ModuleBase
Copy-Item "$moduleBase\Config\ADEHM.config.psd1" C:\ADEHM\my.config.psd1
mkdir C:\ADEHM\Assets\
Copy-Item "$moduleBase\Assets\*" C:\ADEHM\Assets\ -Recurse -Force
Start-ADEHM -ConfigPath C:\ADEHM\my.config.psd1 -DemoMode        # dry run, simulated data
Start-ADEHM -ConfigPath C:\ADEHM\my.config.psd1 -Credential (Get-Credential)
```

**Option B — Git clone:**

```powershell
git clone https://github.com/oussangelo/ADEHM.git C:\ADEHM\
cd C:\ADEHM
notepad .\Config\ADEHM.config.psd1     # DCs, thresholds, SMTP
.\Start-ADEHM.ps1 -DemoMode             # dry run, simulated data
.\Start-ADEHM.ps1 -Credential (Get-Credential)
```

Sample output: [example report](Docs/examples/ADEHM_Report_EXAMPLE.html) ·
[example log](Docs/examples/ADEHM_EXAMPLE.log)

Mail identity different from the AD service account (Gmail, Office 365
consumer) or a fully anonymous internal relay? See
[SMTP authentication scenarios](Docs/ADMIN_GUIDE.md#7-smtp-authentication-scenarios)
in the Administration Guide.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7 on a domain-joined host
- WinRM (5985/5986) and ICMP open toward the monitored DCs
- A dedicated, non-admin service account — see the
  [Permissions Guide](Docs/PERMISSIONS.md) for the complete delegation map
  (including hardened environments) and the automation scripts in `Tools/`
- `nltest.exe` on the host for AD site detection (included with RSAT)

## Documentation

- [Installation Guide](Docs/INSTALL.md)
- [Administration Guide](Docs/ADMIN_GUIDE.md)
- [Permissions Guide](Docs/PERMISSIONS.md) — the five delegations, hardened-DC edition
- [Architecture](Docs/ARCHITECTURE.md)
- [Changelog](CHANGELOG.md)

## What's next

- **v1.1** *(next release)* — Plugin system, AD replication health, FSMO roles,  Global Catalog, LDAP/LDAPS bind and certificate health
- **v1.2** — DNS health, zone checks, aging & scavenging
- **v1.3** — Windows event log analysis, critical AD events
- **v1.4** — Parallel collection, structured export (JSON/CSV) for
  Grafana, Splunk and Power BI

**The monitoring engine and every check listed above are MIT and stay MIT.**
That applies to what is already released and to everything on this list — it will not be moved behind a licence later.

This project ships regularly rather than by roadmap; see
[Releases](../../releases) for what actually landed.

### Writing your own checks

v1.1 introduces a plugin system: drop an `ADEHM.Plugin.*.psm1` file into the plugin folder and it is picked up on the next run — no core changes, no rebuild, no entry in any registry. A defective plugin is logged and skipped; it cannot interrupt a monitoring run or prevent the report from being delivered.

The contract will be documented in the Plugin Development Guide shipped with that release, and will stay stable within a major version.

Plugins are yours. Publish them, keep them internal, or sell them.

### Commercial add-ons

**AD Enterprise Suite — Security Pack** is a paid plugin bundle covering AD security and hygiene: krbtgt password age, lingering objects, SYSVOL replication backlog, privileged group drift, trust health, uncovered subnets, time synchronisation. First release is planned alongside v1.2.

It is licensed per year and versioned independently of this module — it runs on ADEHM 1.1 and later, and new checks are added to it over time rather than tied to engine releases. A pack purchased today keeps working as the engine moves forward.

None of these checks appear on the free roadmap above, and none will be removed from the free product to make room for them. The engine that runs them is, and remains, the MIT one in this repository.

## License

MIT — © 2026 Angelo OUSSATCHEDJI. See [LICENSE](LICENSE).
