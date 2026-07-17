# ADEHM — Technical Architecture

## 1. Software architecture

The engine is split into 7 independent modules (`Modules/*.psm1`), loaded
dynamically by `Start-ADEHM.ps1`. Each module has a single responsibility
and no hard cross-module coupling, so a new module can be added without
touching the others.

| Module | File | Responsibility |
|---|---|---|
| Configuration | `ADEHM.Configuration.psm1` | Loading and validating `ADEHM.config.psd1` |
| Logger | `ADEHM.Logger.psm1` | Logging, traces, structured error log |
| Connectivity | `ADEHM.Connectivity.psm1` | Ping, DNS resolution, WinRM, FQDN |
| System | `ADEHM.System.psm1` | CIM sessions, CPU, RAM, disk, OS, uptime |
| ActiveDirectory | `ADEHM.ActiveDirectory.psm1` | AD services, SYSVOL/NETLOGON shares, site/domain |
| HTML | `ADEHM.HTML.psm1` | HTML report + email-optimized rendering |
| Mail | `ADEHM.Mail.psm1` | SMTP delivery |

`Start-ADEHM.ps1` is the single orchestration point: no business logic,
only the sequencing of module calls. This is what enables future
integrations (Grafana/Splunk/Power BI, web UI) without rewriting the
collection engine.

## 2. Execution flow

```
Read Configuration
        |
Create Logger
        |
Read DC list
        |
   +----+---------------------------+
   |  For each DC:                   |
   |  Connectivity (Ping/DNS/WinRM)  |
   |  CIM connection (1 session)     |
   |  Collection (System + AD)       |
   |  CIM session close              |
   +----+---------------------------+
        |
Report Generation (HTML + email body)
        |
Mail Delivery
        |
Archiving
        |
End
```

Any error on one DC (connectivity, permissions, unavailable service) is
recorded in the structured log and **does not interrupt** the other DCs:
the affected DC appears as `OFFLINE` or `CRITICAL` in the report, with the
incident details.

## 3. Collected data model

| Field | Type | Source |
|---|---|---|
| `Hostname`, `Site`, `IPAddress` | string | Connectivity / ActiveDirectory |
| `Ping`, `WinRM` | bool | Connectivity |
| `NTDS`, `DNS`, `DFSR`, `Netlogon`, `KDC`, `ADWS` | bool | ActiveDirectory (`Win32_Service`) |
| `SYSVOL`, `NetlogonShare` | bool | ActiveDirectory (share access test) |
| `CpuPercent`, `RamPercent` | double | System (`Win32_Processor`, `Win32_OperatingSystem`) |
| `DiskFreePercent`, `DiskDetail` | double / array | System (`Win32_LogicalDisk`) |
| `OSCaption`, `BuildNumber` | string | System (`Win32_OperatingSystem`) |
| `LastBootTime`, `UptimeDays` | datetime / double | System (`Win32_OperatingSystem`) |

Note: the NETLOGON share is `NetlogonShare` internally because PowerShell
hashtable keys are case-insensitive — `NETLOGON` would collide with the
`Netlogon` service property.

## 4. Structured error log

Every incident captured by `Write-ADEHMError` carries:

```
Date | Server | Module | Exception | ProbableCause | Recommendation
```

Probable causes are inferred from the error type (client-side bug vs
permission vs timeout vs unreachable) to avoid misleading diagnostics.
Incidents appear both in the text log (`Logs/*.log`) and in a dedicated
report section.

## 5. Status classification (color coding)

`Get-ADEHMRowStatus` computes one status per DC:

1. **OFFLINE** (gray) — ping or WinRM failed: no further collection
   possible.
2. **CRITICAL** (red) — an AD service is down, a share is unreachable, or
   a critical CPU/RAM/disk threshold is crossed.
3. **WARNING** (orange) — a warning threshold is crossed.
4. **OK** (green) — all checks pass.

All thresholds live in `Config/ADEHM.config.psd1` (`Thresholds`).

## 6. Report generation

`New-ADEHMHtmlReport` builds a self-contained HTML document (embedded CSS,
no external resource): pulse strip, 8-indicator dashboard, 18-column
detail table with a status side rail, and an incident section. The
stylesheet lives in `Assets/report-style.css` and is re-read at every
generation — customizable without touching PowerShell code.

`New-ADEHMEmailReport` produces the email-body twin: same data, HTML
tables + inline styles only, reliable in Word-engine clients (Outlook).

## 7. Known limitations (v1.0)

- `Get-ADEHMDomainInfo` relies on `nltest.exe` for the AD site (included
  with RSAT; absent from a minimal Windows install).
- No parallel DC collection (planned).
- The email body cannot be pixel-identical to the browser report — a
  Word-engine constraint.
