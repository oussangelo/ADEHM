#requires -Version 5.1
<#
    ADEHM.Configuration.psm1
    Loads, validates and path-resolves the central configuration file
    (Config/ADEHM.config.psd1).
#>

function Import-ADEHMConfig {
    <#
        .SYNOPSIS
        Loads and validates the ADEHM configuration file.

        .PARAMETER Path
        Path to the .psd1 configuration file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Configuration file not found: $Path"
    }

    # Resolve to an ABSOLUTE path before any computation: a relative
    # ConfigPath would yield relative output paths, which .NET APIs (e.g.
    # the mail attachment constructor) resolve against the process working
    # directory (often C:\Windows\system32) rather than the current
    # PowerShell location.
    $Path = (Resolve-Path -LiteralPath $Path).ProviderPath

    try {
        $config = Import-PowerShellDataFile -Path $Path
    }
    catch {
        throw "Unable to load configuration '$Path': $($_.Exception.Message)"
    }

    # --- Required sections -------------------------------------------
    $requiredKeys = @('General', 'DomainControllers', 'Thresholds', 'Services', 'Shares', 'Paths', 'Mail')
    foreach ($key in $requiredKeys) {
        if (-not $config.ContainsKey($key)) {
            throw "Missing configuration section: '$key'"
        }
    }

    if (-not $config.DomainControllers -or $config.DomainControllers.Count -eq 0) {
        throw 'No domain controller defined in the configuration (DomainControllers).'
    }

    # --- Relative path resolution -------------------------------------
    # The project root is the parent folder of Config/
    $root = Split-Path -Parent (Split-Path -Parent $Path)

    foreach ($pathKey in @('Reports', 'Logs', 'Assets', 'Archive')) {
        if ($config.Paths.ContainsKey($pathKey)) {
            $p = $config.Paths[$pathKey]
            if (-not [System.IO.Path]::IsPathRooted($p)) {
                $clean = $p -replace '^\.\\', '' -replace '^\./', ''
                $config.Paths[$pathKey] = Join-Path $root $clean
            }
        }
    }

    # --- Create missing directories ------------------------------------
    foreach ($dir in $config.Paths.Values) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    return $config
}

Export-ModuleMember -Function Import-ADEHMConfig
