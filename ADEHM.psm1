#requires -Version 5.1
<#
    ADEHM.psm1
    Thin module wrapper for PowerShell Gallery distribution. Exposes the
    Start-ADEHM command, which invokes the engine script unchanged.
#>

function Start-ADEHM {
    <#
        .SYNOPSIS
        Runs the ADEHM Active Directory health monitoring engine.

        .DESCRIPTION
        Wrapper around Start-ADEHM.ps1 for module-based installs
        (Install-Module ADEHM). When installed from the PowerShell Gallery,
        the module folder is read-only under Program Files: always provide
        -ConfigPath pointing to your own configuration copy.

        .EXAMPLE
        Copy-Item "$(Split-Path (Get-Module ADEHM).Path)\Config\ADEHM.config.psd1" C:\ADEHM\my.config.psd1
        Start-ADEHM -ConfigPath C:\ADEHM\my.config.psd1 -Credential (Get-Credential)

        .EXAMPLE
        Start-ADEHM -ConfigPath C:\ADEHM\my.config.psd1 -DemoMode
    #>
    [CmdletBinding()]
    param(
        [string]$ConfigPath,
        [System.Management.Automation.PSCredential]$Credential,
        [switch]$DemoMode
    )

    $scriptPath = Join-Path $PSScriptRoot 'Start-ADEHM.ps1'

    $params = @{}
    if ($ConfigPath) { $params.ConfigPath = $ConfigPath }
    if ($Credential) { $params.Credential = $Credential }
    if ($DemoMode)   { $params.DemoMode   = $true }

    & $scriptPath @params
}

Export-ModuleMember -Function Start-ADEHM
