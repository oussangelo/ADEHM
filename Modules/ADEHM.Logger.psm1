#requires -Version 5.1
<#
    ADEHM.Logger.psm1
    Execution logging, traces, and the structured error log
    (Date / Server / Module / Exception / Probable cause / Recommendation).
#>

$script:LogFilePath = $null
$script:DebugMode    = $false
$script:ErrorLog     = New-Object System.Collections.Generic.List[object]

function Initialize-ADEHMLogger {
    <#
        .SYNOPSIS
        Initializes the execution log for the current run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LogDirectory,

        [switch]$DebugMode
    )

    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $script:LogFilePath = Join-Path $LogDirectory "ADEHM_$timestamp.log"
    $script:DebugMode   = [bool]$DebugMode
    $script:ErrorLog.Clear()

    New-Item -ItemType File -Path $script:LogFilePath -Force | Out-Null

    return $script:LogFilePath
}

function Write-ADEHMLog {
    <#
        .SYNOPSIS
        Writes a line to the execution log.

        .PARAMETER Level
        INFO, WARN, ERROR or DEBUG. DEBUG entries are only written when
        debug mode is active (General.DebugMode = $true).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')]
        [string]$Level = 'INFO',

        [string]$Module = 'Core'
    )

    if ($Level -eq 'DEBUG' -and -not $script:DebugMode) {
        return
    }

    $line = '{0} {1,-5} [{2}] {3}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Module, $Message

    if ($script:LogFilePath) {
        Add-Content -LiteralPath $script:LogFilePath -Value $line -Encoding UTF8
    }

    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'DEBUG' { Write-Host $line -ForegroundColor DarkGray }
        default { Write-Host $line }
    }
}

function Write-ADEHMError {
    <#
        .SYNOPSIS
        Records a structured error (log file + in-memory collection used by
        the HTML report).

        .DESCRIPTION
        Every error carries: Date, Server, Module, Exception, Probable
        cause, Recommendation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Server,
        [Parameter(Mandatory)] [string]$Module,
        [Parameter(Mandatory)] [string]$Exception,
        [string]$ProbableCause = 'Undetermined',
        [string]$Recommendation = 'Review the detailed log and check network connectivity.'
    )

    $errorEntry = [PSCustomObject]@{
        Date           = Get-Date
        Server         = $Server
        Module         = $Module
        Exception      = $Exception
        ProbableCause  = $ProbableCause
        Recommendation = $Recommendation
    }

    $script:ErrorLog.Add($errorEntry)

    Write-ADEHMLog -Level ERROR -Module $Module -Message "$Server : $Exception (Probable cause: $ProbableCause)"
}

function Get-ADEHMErrorLog {
    # The comma operator is essential: without it, PowerShell "unrolls" the
    # collection on function return, and an EMPTY list becomes $null, which
    # breaks binding of the HTML module's -ErrorLog parameter.
    return , $script:ErrorLog
}

function Get-ADEHMLogPath {
    return $script:LogFilePath
}

Export-ModuleMember -Function Initialize-ADEHMLogger, Write-ADEHMLog, Write-ADEHMError, Get-ADEHMErrorLog, Get-ADEHMLogPath
