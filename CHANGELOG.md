# Changelog — ADEHM

## [1.0.3] — 2026-07

### Fixed
- **Config path resolution**: a standalone configuration file (e.g. copied
  out of a PowerShell Gallery install and kept anywhere) is now correctly
  used as the base for relative `Reports`/`Logs`/`Archive` paths. Previously,
  only the standard `<root>\Config\ADEHM.config.psd1` project layout worked;
  any other location silently resolved output paths too far up the
  directory tree.
- **Cross-module function visibility**: internal modules are now imported
  with `-Global`, fixing a crash (`Write-ADEHMError` not recognized) that
  occurred specifically when ADEHM was run through the PowerShell Gallery
  module wrapper (`Install-Module` + `Start-ADEHM`) and an error occurred
  inside a module other than the one that triggered collection — most
  commonly a failed mail delivery.
- **Mail vs. AD service account confusion**: `-Credential` was silently
  reused both for CIM connections to the domain controllers and for SMTP
  authentication, which breaks as soon as the mail identity differs from
  the AD service account (any external provider: Gmail, Office 365
  consumer, ...). Added an optional `-MailCredential` parameter to
  `Start-ADEHM.ps1`; when omitted, behavior is unchanged (falls back to
  `-Credential`), so existing setups keep working as-is.

## [1.0.0] — 2026-07

First public release. Battle-tested through a full acceptance cycle on a
hardened multi-DC environment before publication.

### Added
- Modular architecture: 7 independent modules (Configuration, Logger,
  Connectivity, System, ActiveDirectory, HTML, Mail)
- Collection via CIM sessions / WinRM exclusively (no legacy WMI/DCOM)
- Availability checks: ping, DNS resolution, WinRM, IP address, FQDN
- Active Directory checks: NTDS, DNS, DFSR, Netlogon, KDC, ADWS services;
  SYSVOL and NETLOGON shares
- System collection: CPU, RAM, disks (all fixed volumes), uptime, last
  boot time
- System identity: server name, Windows version/build, AD site, domain
- Professional self-contained HTML report (dashboard + 18-column detail
  table + color coding + incident section)
- Automatic email delivery with a dedicated Outlook-safe body rendering
  (HTML tables + inline styles) alongside the full report attachment
- Detailed execution log and structured error log (Date / Server / Module /
  Exception / Probable cause / Recommendation) with error-type-aware
  probable causes
- Least-privilege service account support, including on hardened DCs —
  with the full delegation map (Docs/PERMISSIONS.md) and automation:
  `Grant-ADEHMWmiPermission.ps1`, `Grant-ADEHMServiceReadPermission.ps1`,
  `Test-ADEHMPermission.ps1`
- Central configuration (ADEHM.config.psd1), automatic archiving,
  `-DemoMode` for installation validation without an AD infrastructure

## Roadmap

### v1.1 — Active Directory replication
Replication health, FSMO roles, Global Catalog, LDAP/LDAPS health.

### v1.2 — DNS health
In-depth DNS checks, zone verification, aging & scavenging.

### v1.3 — Windows event logs
Event log analysis, critical AD events.

### v2.0 — Web platform
Web dashboard, REST API, authentication, execution history.
