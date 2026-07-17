# Contributing to ADEHM

Thank you for considering a contribution!

## Reporting bugs

Open an issue with:
- The exact error message and the relevant lines of the `Logs/ADEHM_*.log` file
- Your PowerShell version (`$PSVersionTable.PSVersion`) and Windows Server version
- Whether the environment is hardened (security baselines applied to the DCs)

For permission issues, attach the full output of
`Tools/Test-ADEHMPermission.ps1` — it captures everything needed for a
diagnosis in a single run.

## Proposing changes

1. Fork, create a feature branch.
2. Keep the modular architecture: one responsibility per module, no
   cross-module coupling, all tunables in `Config/ADEHM.config.psd1`.
3. Target PowerShell 5.1 compatibility (no PS7-only operators such as `??`).
4. Validate with `.\Start-ADEHM.ps1 -DemoMode` before opening a PR.

## Known PowerShell pitfalls in this codebase

Hard-won lessons, please do not reintroduce them:
- Hashtable keys are case-insensitive: `Netlogon` (service) vs `NETLOGON`
  (share) collide — the share is named `NetlogonShare` internally.
- An empty `List[object]` returned from a function unrolls to `$null`; use
  the comma operator (`return , $list`).
- `-OperationTimeoutSec` belongs to `New-CimSession`, not
  `New-CimSessionOption`.
- Inline casts inside `-ArgumentList` are parsed as text; convert to a
  variable first.
- .NET APIs resolve relative paths against the process working directory,
  not the PowerShell location; keep all output paths absolute.
