@{
    RootModule        = 'ADEHM.psm1'
    ModuleVersion     = '1.0.1'
    GUID              = '216930bd-1250-4625-8d41-09b686a44356'
    Author            = 'Angelo OUSSATCHEDJI'
    Copyright         = '(c) 2026 Angelo OUSSATCHEDJI. MIT License.'
    Description       = 'ADEHM - Active Directory Enterprise Health Monitor. Agentless health monitoring for Active Directory domain controllers: pure PowerShell + CIM/WinRM, no agents, no database, least-privilege by design (works on hardened DCs). Professional HTML report, Outlook-safe email delivery, structured incident log. Part of the AD Enterprise Suite.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @('Start-ADEHM')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('ActiveDirectory', 'Monitoring', 'DomainController', 'WinRM', 'CIM', 'HealthCheck', 'Windows', 'sysadmin', 'Report')
            LicenseUri   = 'https://github.com/oussangelo/ADEHM/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/oussangelo/ADEHM'
            ReleaseNotes = 'First public release. See CHANGELOG.md.'
        }
    }
}
