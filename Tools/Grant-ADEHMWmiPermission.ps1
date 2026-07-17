#requires -Version 5.1
<#
.SYNOPSIS
    Grants the ADEHM service account/group the minimal WMI rights
    (Enable Account + Remote Enable) on the required namespaces of each
    domain controller.

.DESCRIPTION
    Run ONCE, as a domain administrator, from a Windows PowerShell 5.1
    console.

    Idempotent: an already-compliant entry returns 'Already configured'.

    Note: WMI-Activity logs may show denials on root\interop during CIM
    sessions. Field testing shows these are benign, non-blocking probes:
    no root\interop grant is required (least privilege). Only root/cimv2
    is granted by default.

.PARAMETER Account
    Account or group in DOMAIN\name format (e.g. DOMAIN\GRP-AD-Monitoring).

.PARAMETER DomainControllers
    DCs to configure. When omitted, read through -ConfigPath.

.PARAMETER ConfigPath
    Path to ADEHM.config.psd1 to extract the DC list.

.PARAMETER Namespaces
    WMI namespaces to process. Default: root/cimv2.

.PARAMETER Remove
    Removes the account/group entries instead of adding them (rollback).

.EXAMPLE
    .\Grant-ADEHMWmiPermission.ps1 -Account 'DOMAIN\GRP-AD-Monitoring' -ConfigPath ..\Config\ADEHM.config.psd1
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[^\\]+\\[^\\]+$')]
    [string]$Account,

    [string[]]$DomainControllers,

    [string]$ConfigPath,

    [string[]]$Namespaces = @('root/cimv2'),

    [switch]$Remove
)

# --- DC list resolution ------------------------------------------------
if (-not $DomainControllers) {
    if (-not $ConfigPath) {
        throw 'Provide -DomainControllers or -ConfigPath (ADEHM.config.psd1 file).'
    }
    $config = Import-PowerShellDataFile -Path $ConfigPath
    $DomainControllers = $config.DomainControllers
}

if (-not $DomainControllers) {
    throw 'No domain controller to configure.'
}

# --- Remote block executed on each DC -----------------------------------
$remoteBlock = {
    param($Account, $Remove, $Namespaces)

    $WBEM_ENABLE        = 0x1     # Enable Account
    $WBEM_REMOTE_ACCESS = 0x20    # Remote Enable
    $targetMask         = $WBEM_ENABLE -bor $WBEM_REMOTE_ACCESS   # 0x21

    # Resolve the account/group SID
    $ntAccount = New-Object System.Security.Principal.NTAccount($Account)
    try {
        $sid = $ntAccount.Translate([System.Security.Principal.SecurityIdentifier])
    }
    catch {
        throw "Account '$Account' not found from $env:COMPUTERNAME : $($_.Exception.Message)"
    }

    $statuses = foreach ($ns in $Namespaces) {

        # The reliable invocation method is Invoke-WmiMethod on the
        # '__SystemSecurity=@' singleton - calling the method directly on
        # the object returned by Get-WmiObject fails on some systems.
        $wmiParams = @{ Namespace = $ns; Path = '__SystemSecurity=@' }

        $getResult = Invoke-WmiMethod @wmiParams -Name 'GetSecurityDescriptor'
        if ($getResult.ReturnValue -ne 0) {
            "$ns : GetSecurityDescriptor failed (code $($getResult.ReturnValue))"
            continue
        }
        $sd = $getResult.Descriptor

        $existing = @($sd.DACL) | Where-Object { $_.Trustee.SIDString -eq $sid.Value }

        if ($Remove) {
            if (-not $existing) { "$ns : no entry to remove"; continue }
            $sd.DACL = @(@($sd.DACL) | Where-Object { $_.Trustee.SIDString -ne $sid.Value })
            $setResult = Invoke-WmiMethod @wmiParams -Name 'SetSecurityDescriptor' -ArgumentList $sd.PSObject.ImmediateBaseObject
            if ($setResult.ReturnValue -ne 0) { "$ns : SetSecurityDescriptor failed (code $($setResult.ReturnValue))"; continue }
            "$ns : entry removed"
            continue
        }

        if ($existing) {
            $hasRights = $existing | Where-Object { ($_.AccessMask -band $targetMask) -eq $targetMask }
            if ($hasRights) { "$ns : already configured"; continue }
            # Entry present but incomplete rights: removed for clean recreation
            $sd.DACL = @(@($sd.DACL) | Where-Object { $_.Trustee.SIDString -ne $sid.Value })
        }

        # New ACE (Allow, this namespace only)
        $trustee = (New-Object System.Management.ManagementClass('root/cimv2:Win32_Trustee')).CreateInstance()
        $trustee.SIDString = $sid.Value

        $ace = (New-Object System.Management.ManagementClass('root/cimv2:Win32_ACE')).CreateInstance()
        $ace.AccessMask = $targetMask
        $ace.AceType    = 0        # ACCESS_ALLOWED
        $ace.AceFlags   = 0        # no inheritance to sub-namespaces
        $ace.Trustee    = $trustee

        $sd.DACL += $ace.PSObject.ImmediateBaseObject

        $setResult = Invoke-WmiMethod @wmiParams -Name 'SetSecurityDescriptor' -ArgumentList $sd.PSObject.ImmediateBaseObject
        if ($setResult.ReturnValue -ne 0) { "$ns : SetSecurityDescriptor failed (code $($setResult.ReturnValue))"; continue }
        "$ns : rights granted (Enable Account + Remote Enable)"
    }

    return ($statuses -join ' | ')
}

# --- Apply to each DC -----------------------------------------------------
$isRemove = [bool]$Remove   # explicit conversion BEFORE the call: an inline
                            # cast in -ArgumentList would be parsed as text

$results = foreach ($dc in $DomainControllers) {
    $action = if ($isRemove) { "Remove WMI rights of $Account ($($Namespaces -join ', '))" }
              else           { "Grant WMI rights to $Account ($($Namespaces -join ', '))" }
    if (-not $PSCmdlet.ShouldProcess($dc, $action)) { continue }

    try {
        $status = Invoke-Command -ComputerName $dc -ScriptBlock $remoteBlock -ArgumentList $Account, $isRemove, $Namespaces -ErrorAction Stop
        [PSCustomObject]@{ DC = $dc; Status = $status; Error = $null }
    }
    catch {
        [PSCustomObject]@{ DC = $dc; Status = 'FAILED'; Error = $_.Exception.Message }
    }
}

$results | Format-Table -AutoSize -Wrap

$failed = @($results | Where-Object { $_.Status -eq 'FAILED' })
if ($failed.Count -gt 0) {
    Write-Host "`nFailure details:" -ForegroundColor Yellow
    foreach ($f in $failed) {
        Write-Host ("  {0}`n    {1}`n" -f $f.DC, $f.Error) -ForegroundColor Yellow
    }
    Write-Warning "$($failed.Count) DC(s) failed. See details above."
    exit 1
}

Write-Host "`nDone. Restart WinRM on the DCs (Restart-Service WinRM) before retesting: stale WinRM host processes serve requests with pre-change access state." -ForegroundColor Green
