# ADEHM — Administration Guide

## 1. Day-to-day usage

```powershell
# Standard run
.\Start-ADEHM.ps1

# Alternate configuration file (multi-environment)
.\Start-ADEHM.ps1 -ConfigPath .\Config\ADEHM.prod.psd1

# Explicit service account
.\Start-ADEHM.ps1 -Credential (Get-Credential)

# Demo mode (no real network connection)
.\Start-ADEHM.ps1 -DemoMode
```

The script returns an object with `ReportPath`, `LogPath`, `Results` and
`Errors`, usable for further scripting:

```powershell
$run = .\Start-ADEHM.ps1
if ($run.Errors.Count -gt 0) {
    $run.Errors | Format-Table Server, Module, Exception -AutoSize
}
```

## 2. Reading the HTML report

The report (`Reports/ADEHM_Report_YYYYMMDD_HHMMSS.html`) contains:

1. **Pulse strip**: visual OK / Warning / Critical / Offline proportions.
2. **Dashboard**: date, time, duration, DC count, DC online/offline,
   warning, critical.
3. **Detail table**: 18 columns per DC (Hostname through Boot), with a
   colored side rail reflecting each row's overall status.
4. **Incidents**: present only when errors were logged, each with a
   probable cause and a recommendation.

A sample is available at `Docs/examples/ADEHM_Report_EXAMPLE.html`.

## 3. Reading the log

Line format: `HH:mm:ss LEVEL [Module] Message`

The `DEBUG` level only appears when `General.DebugMode = $true` — enable
it temporarily for fine-grained diagnosis (CIM session open/close,
collection details).

## 4. Adjusting thresholds

Edit `Config/ADEHM.config.psd1` → `Thresholds`. No code change needed.
Thresholds apply to all listed DCs; per-DC thresholds are not part of v1.0
(see the roadmap in `CHANGELOG.md`).

## 5. Adding a domain controller

Add its FQDN to `DomainControllers`. If delegations were granted to the
dedicated group at domain scope, also run the `Tools/` grant scripts so the
new DC receives the WMI/SCM/service ACEs, then restart WinRM on it.

## 6. Adding a monitoring module (extensibility)

1. Create `Modules/ADEHM.MyNewModule.psm1` with `Export-ModuleMember`.
2. `Start-ADEHM.ps1` loads it automatically (loop over `Modules/*.psm1`).
3. Call its functions in the collection loop of `Start-ADEHM.ps1`.
4. Add matching columns in `ADEHM.HTML.psm1` if the result belongs in the
   report.

## 7. SMTP authentication scenarios

Three scenarios are supported; pick one via `Config.Mail.Anonymous` and the
credential parameters passed to `Start-ADEHM.ps1`:

| Scenario | `Mail.Anonymous` | Command |
|---|---|---|
| Anonymous internal relay (IP allow list, no auth expected) | `$true` | `.\Start-ADEHM.ps1 -Credential $adCred` (mail needs nothing extra) |
| Relay that trusts the AD service account | `$false` (default) | `.\Start-ADEHM.ps1 -Credential $adCred` (reused for SMTP automatically) |
| External provider with its own identity (Gmail, Office 365 consumer, ...) | `$false` | `.\Start-ADEHM.ps1 -Credential $adCred -MailCredential $mailCred` |

The log always states which identity (if any) was used for SMTP —
`[Mail] SMTP identity: ...` — useful to confirm the right path was taken
when testing a new relay.

## 8. Email rendering

The mail body uses a dedicated rendering (`New-ADEHMEmailReport`): HTML
tables + inline styles, faithful even in Outlook desktop (Word engine).
The attachment is the full browser-grade report. Hover effects and some
typographic finesse are absent from the body — a Word-engine limitation.
Set `EmbedReportInBody = $false` for a plain-text body with attachment
only.

## 9. Troubleshooting

| Symptom | Probable cause | Action |
|---|---|---|
| All DCs `OFFLINE` | WinRM not enabled / firewall | `Test-WSMan` from the ADEHM host |
| `Site` = N/A everywhere | `nltest.exe` missing on the host | Install the server administration tools (RSAT) |
| CIM "Access denied" | Missing delegation | Run `Tools/Test-ADEHMPermission.ps1` and see `PERMISSIONS.md` |
| Denials persist after a permission fix | Stale WinRM host processes | `Restart-Service WinRM` on the DCs |
| Service shows DOWN but is running | Service invisible: its security descriptor filters the caller | Delegation #5 in `PERMISSIONS.md` |
| Email not received | SMTP/port/SSL, firewall, or relay restrictions | Check `Mail` config; `Test-NetConnection <smtp> -Port <port>` |
| `root\interop` denials in WMI logs | Benign non-blocking probes | Ignore (see `PERMISSIONS.md`) |
