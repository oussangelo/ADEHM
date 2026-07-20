#requires -Version 5.1
<#
    ADEHM.HTML.psm1
    Generates the professional HTML report: summary dashboard, detailed
    per-DC table, color coding, and incident section. Also provides an
    email-client-optimized rendering for the message body.
#>

$script:FallbackCss = @'
body{font-family:Segoe UI,Arial,sans-serif;background:#eef1f5;color:#101720;}
.badge{padding:2px 8px;border-radius:2px;font-size:11px;font-weight:600;}
.badge-ok{background:#e3f5ec;color:#1f8a5f;} .badge-warn{background:#fbf0da;color:#b9770e;}
.badge-crit{background:#fbe6e6;color:#b93a3a;} .badge-gray{background:#eceff2;color:#8a94a0;}
'@

function Get-ADEHMRowStatus {
    <#
        .SYNOPSIS
        Computes a domain controller's overall status from the collected
        indicators: OFFLINE, CRITICAL, WARNING or OK.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [psobject]$Row,
        [Parameter(Mandatory)] [hashtable]$Thresholds
    )

    if (-not $Row.Ping -or -not $Row.WinRM) {
        return 'OFFLINE'
    }

    $serviceKeys = @('NTDS', 'DNS', 'DFSR', 'Netlogon', 'KDC', 'ADWS')
    $criticalServiceDown = $serviceKeys | Where-Object { $Row.$_ -eq $false }
    $shareDown = (-not $Row.SYSVOL) -or (-not $Row.NetlogonShare)

    $cpuCrit  = ($null -ne $Row.CpuPercent) -and ($Row.CpuPercent -ge $Thresholds.CpuCriticalPercent)
    $ramCrit  = ($null -ne $Row.RamPercent) -and ($Row.RamPercent -ge $Thresholds.RamCriticalPercent)
    $diskCrit = ($null -ne $Row.DiskFreePercent) -and ($Row.DiskFreePercent -le $Thresholds.DiskCriticalFreePct)

    if ($criticalServiceDown -or $shareDown -or $cpuCrit -or $ramCrit -or $diskCrit) {
        return 'CRITICAL'
    }

    $cpuWarn  = ($null -ne $Row.CpuPercent) -and ($Row.CpuPercent -ge $Thresholds.CpuWarningPercent)
    $ramWarn  = ($null -ne $Row.RamPercent) -and ($Row.RamPercent -ge $Thresholds.RamWarningPercent)
    $diskWarn = ($null -ne $Row.DiskFreePercent) -and ($Row.DiskFreePercent -le $Thresholds.DiskWarningFreePct)

    if ($cpuWarn -or $ramWarn -or $diskWarn) {
        return 'WARNING'
    }

    return 'OK'
}

function ConvertTo-ADEHMBoolBadge {
    param($Value)
    if ($null -eq $Value) { return '<span class="badge badge-gray">N/A</span>' }
    if ($Value) { return '<span class="badge badge-ok">OK</span>' }
    return '<span class="badge badge-crit">DOWN</span>'
}

function ConvertTo-ADEHMMetricBadge {
    param(
        [Nullable[double]]$Value,
        [double]$Warn,
        [double]$Crit,
        [switch]$Invert,      # $true => a low value is unfavorable (e.g. disk free %)
        [string]$Suffix = '%'
    )
    if ($null -eq $Value) { return '<span class="badge badge-gray">N/A</span>' }

    $class = 'badge-ok'
    if ($Invert) {
        if ($Value -le $Crit) { $class = 'badge-crit' }
        elseif ($Value -le $Warn) { $class = 'badge-warn' }
    }
    else {
        if ($Value -ge $Crit) { $class = 'badge-crit' }
        elseif ($Value -ge $Warn) { $class = 'badge-warn' }
    }

    return '<span class="badge {0}">{1}{2}</span>' -f $class, $Value, $Suffix
}

function New-ADEHMHtmlReport {
    <#
        .SYNOPSIS
        Generates the professional HTML report from the collected results.

        .PARAMETER Config
        Configuration hashtable (from Import-ADEHMConfig).

        .PARAMETER Results
        Collection of objects (one per DC) holding the collected indicators.

        .PARAMETER ErrorLog
        Structured incident collection (from Get-ADEHMErrorLog).

        .PARAMETER OutputPath
        Path of the HTML file to produce.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable]$Config,
        [Parameter(Mandatory)] [System.Collections.Generic.List[object]]$Results,
        [Parameter(Mandatory)] [datetime]$StartTime,
        [Parameter(Mandatory)] [datetime]$EndTime,
        [AllowNull()]
        [System.Collections.Generic.List[object]]$ErrorLog,
        [AllowNull()]
        [System.Collections.Generic.List[object]]$PluginResults,
        [Parameter(Mandatory)] [string]$OutputPath
    )

    if ($null -eq $ErrorLog) {
        $ErrorLog = New-Object System.Collections.Generic.List[object]
    }

    $thresholds = $Config.Thresholds

    # --- Row classification + dashboard aggregates ---------------------
    $statuses = foreach ($row in $Results) {
        [PSCustomObject]@{ Row = $row; Status = (Get-ADEHMRowStatus -Row $row -Thresholds $thresholds) }
    }

    $total    = $Results.Count
    $offline  = ($statuses | Where-Object { $_.Status -eq 'OFFLINE' }).Count
    $critical = ($statuses | Where-Object { $_.Status -eq 'CRITICAL' }).Count
    $warning  = ($statuses | Where-Object { $_.Status -eq 'WARNING' }).Count
    $ok       = ($statuses | Where-Object { $_.Status -eq 'OK' }).Count
    $online   = $total - $offline
    $duration = $EndTime - $StartTime

    # --- Pulse strip (visual status proportions) ------------------------
    $pulseSegments = ''
    if ($total -gt 0) {
        foreach ($pair in @(@('ok', $ok), @('warn', $warning), @('crit', $critical), @('off', $offline))) {
            $pct = [math]::Round(($pair[1] / $total) * 100, 2)
            if ($pct -gt 0) {
                $pulseSegments += '<div class="pulse-seg pulse-{0}" style="width:{1}%"></div>' -f $pair[0], $pct
            }
        }
    }

    # --- CSS: read from Assets/report-style.css, embedded fallback otherwise
    $cssPath = Join-Path $Config.Paths.Assets 'report-style.css'
    $css = if (Test-Path -LiteralPath $cssPath) { Get-Content -LiteralPath $cssPath -Raw -Encoding UTF8 } else { $script:FallbackCss }

    # --- Detail table rows -----------------------------------------------
    $tableRows = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $statuses) {
        $row = $entry.Row
        $railClass = switch ($entry.Status) {
            'OK'       { 'rail-ok' }
            'WARNING'  { 'rail-warn' }
            'CRITICAL' { 'rail-crit' }
            default    { 'rail-off' }
        }

        $bootText = if ($row.LastBootTime) {
            '{0} ({1} d)' -f $row.LastBootTime.ToString('yyyy-MM-dd HH:mm'), $row.UptimeDays
        } else { 'N/A' }

        $winText  = if ($row.OSCaption) { '{0} (build {1})' -f $row.OSCaption, $row.BuildNumber } else { 'N/A' }
        $siteText = if ($row.Site) { [string]$row.Site } else { 'N/A' }
        $ipText   = if ($row.IPAddress) { [string]$row.IPAddress } else { 'N/A' }

        # Cells after the Hostname column (handled separately with its CSS class)
        $remainingCells = @(
            $siteText
            $ipText
            (ConvertTo-ADEHMBoolBadge $row.Ping)
            (ConvertTo-ADEHMBoolBadge $row.WinRM)
            (ConvertTo-ADEHMBoolBadge $row.NTDS)
            (ConvertTo-ADEHMBoolBadge $row.DNS)
            (ConvertTo-ADEHMBoolBadge $row.DFSR)
            (ConvertTo-ADEHMBoolBadge $row.Netlogon)
            (ConvertTo-ADEHMBoolBadge $row.KDC)
            (ConvertTo-ADEHMBoolBadge $row.ADWS)
            (ConvertTo-ADEHMBoolBadge $row.SYSVOL)
            (ConvertTo-ADEHMBoolBadge $row.NetlogonShare)
            (ConvertTo-ADEHMMetricBadge -Value $row.CpuPercent -Warn $thresholds.CpuWarningPercent -Crit $thresholds.CpuCriticalPercent)
            (ConvertTo-ADEHMMetricBadge -Value $row.RamPercent -Warn $thresholds.RamWarningPercent -Crit $thresholds.RamCriticalPercent)
            (ConvertTo-ADEHMMetricBadge -Value $row.DiskFreePercent -Warn $thresholds.DiskWarningFreePct -Crit $thresholds.DiskCriticalFreePct -Invert)
            $winText
            $bootText
        )

        $remainingTds = ($remainingCells | ForEach-Object { "<td>$_</td>" }) -join ''

        $tableRows.Add(('<tr><td class="status-rail {0}"></td><td class="col-hostname">{1}</td>{2}</tr>' -f `
            $railClass, $row.Hostname, $remainingTds))
    }

    # --- Plugin sections ---------------------------------------------------
    # Each plugin returns: Name, optional Summary, and Rows = objects with
    # Hostname + Cells (ordered dictionary label -> @{ Text; Status }) where
    # Status is one of OK / WARN / CRIT / NA / INFO.
    $pluginHtml = ''
    if ($PluginResults -and $PluginResults.Count -gt 0) {
        $statusClass = @{ OK = 'badge-ok'; WARN = 'badge-warn'; CRIT = 'badge-crit'; NA = 'badge-gray'; INFO = 'badge-gray' }
        foreach ($plugin in $PluginResults) {
            if (-not $plugin.Rows -or $plugin.Rows.Count -eq 0) { continue }
            $labels = @($plugin.Rows[0].Cells.Keys)
            $pHeader = "<th></th><th>Hostname</th>" + (($labels | ForEach-Object { "<th>$_</th>" }) -join '')
            $pRows = foreach ($r in $plugin.Rows) {
                $worst = 'OK'
                foreach ($c in $r.Cells.Values) {
                    if ($c.Status -eq 'CRIT') { $worst = 'CRIT'; break }
                    elseif ($c.Status -eq 'WARN' -and $worst -ne 'CRIT') { $worst = 'WARN' }
                }
                $rail = switch ($worst) { 'CRIT' { 'rail-crit' } 'WARN' { 'rail-warn' } default { 'rail-ok' } }
                $tds = foreach ($label in $labels) {
                    $cell = $r.Cells[$label]
                    $cls = $statusClass[[string]$cell.Status]
                    if (-not $cls) { $cls = 'badge-gray' }
                    "<td><span class=""badge $cls"">$($cell.Text)</span></td>"
                }
                '<tr><td class="status-rail {0}"></td><td class="col-hostname">{1}</td>{2}</tr>' -f $rail, $r.Hostname, ($tds -join '')
            }
            $summaryHtml = if ($plugin.Summary) { "<div style=""margin:0 32px 10px 32px;font-size:13px;color:#5b6b7c;"">$($plugin.Summary)</div>" } else { '' }
            $pluginHtml += @"
<div class="section-title">$($plugin.Name)</div>
$summaryHtml
<div class="table-wrap">
  <table class="adehm-table">
    <thead><tr>$pHeader</tr></thead>
    <tbody>
      $($pRows -join "`n")
    </tbody>
  </table>
</div>
"@
        }
    }

    # --- Incident section -------------------------------------------------
    $incidentsHtml = ''
    if ($ErrorLog.Count -gt 0) {
        $items = foreach ($e in $ErrorLog) {
            @"
<div class="incident">
  <div class="incident-head">$($e.Server) &middot; $($e.Module)</div>
  <div>$($e.Exception)</div>
  <div class="incident-meta">Probable cause: $($e.ProbableCause)<br/>Recommendation: $($e.Recommendation)<br/>$($e.Date.ToString('yyyy-MM-dd HH:mm:ss'))</div>
</div>
"@
        }
        $incidentsHtml = @"
<div class="section-title">Incidents ($($ErrorLog.Count))</div>
<div class="incident-list">$($items -join "`n")</div>
"@
    }

    $columns = @('Hostname','Site','IP','Ping','WinRM','NTDS','DNS','DFSR','Netlogon','KDC','ADWS','SYSVOL','NETLOGON','CPU','RAM','Disk','Windows','Boot')
    $headerCells = ($columns | ForEach-Object { "<th>$_</th>" }) -join ''

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<title>ADEHM - Active Directory Health Report</title>
<style>
$css
</style>
</head>
<body>
<div class="adehm-shell">

  <div class="adehm-header">
    <div class="brand">
      <span class="brand-mark">ADEHM</span>
      <h1>Active Directory Enterprise Health Monitor</h1>
    </div>
    <div class="subtitle">$($Config.General.CompanyName) &middot; Generated $($StartTime.ToString('yyyy-MM-dd')) at $($StartTime.ToString('HH:mm:ss')) &middot; Duration $([math]::Round($duration.TotalSeconds,1)) s</div>
    <div class="pulse-strip">$pulseSegments</div>
    <div class="pulse-legend">
      <span><i style="background:#1f8a5f"></i> OK ($ok)</span>
      <span><i style="background:#b9770e"></i> Warning ($warning)</span>
      <span><i style="background:#b93a3a"></i> Critical ($critical)</span>
      <span><i style="background:#3a4757"></i> Offline ($offline)</span>
    </div>
  </div>

  <div class="dashboard">
    <div class="stat-card"><div class="stat-label">Date</div><div class="stat-value">$($StartTime.ToString('yyyy-MM-dd'))</div></div>
    <div class="stat-card"><div class="stat-label">Time</div><div class="stat-value">$($StartTime.ToString('HH:mm:ss'))</div></div>
    <div class="stat-card"><div class="stat-label">Duration</div><div class="stat-value">$([math]::Round($duration.TotalSeconds,1)) s</div></div>
    <div class="stat-card"><div class="stat-label">DC Count</div><div class="stat-value">$total</div></div>
    <div class="stat-card accent-ok"><div class="stat-label">DC Online</div><div class="stat-value">$online</div></div>
    <div class="stat-card accent-off"><div class="stat-label">DC Offline</div><div class="stat-value">$offline</div></div>
    <div class="stat-card accent-warn"><div class="stat-label">Warning</div><div class="stat-value">$warning</div></div>
    <div class="stat-card accent-crit"><div class="stat-label">Critical</div><div class="stat-value">$critical</div></div>
  </div>

  <div class="section-title">Domain Controller Details</div>
  <div class="table-wrap">
    <table class="adehm-table">
      <thead><tr><th></th>$headerCells</tr></thead>
      <tbody>
        $($tableRows -join "`n")
      </tbody>
    </table>
  </div>

  $pluginHtml

  $incidentsHtml

  <div class="adehm-footer">
    <span>ADEHM &middot; Active Directory Enterprise Health Monitor</span>
    <span>Automatically generated report &mdash; do not reply to this email</span>
  </div>

</div>
</body>
</html>
"@

    Set-Content -LiteralPath $OutputPath -Value $html -Encoding UTF8
    return $OutputPath
}

function New-ADEHMEmailReport {
    <#
        .SYNOPSIS
        Generates a report rendering optimized for an email body.

        .DESCRIPTION
        Mail clients based on the Word rendering engine (Outlook desktop)
        ignore the modern CSS of the main report (grid, CSS variables,
        flexbox). This function produces a second rendering of the SAME
        data, built exclusively with HTML tables and inline styles - the
        only reliable dialect in email. The attachment remains the full
        browser-grade report.

        .OUTPUTS
        [string] The HTML email body.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable]$Config,
        [Parameter(Mandatory)] [System.Collections.Generic.List[object]]$Results,
        [Parameter(Mandatory)] [datetime]$StartTime,
        [Parameter(Mandatory)] [datetime]$EndTime,
        [AllowNull()]
        [System.Collections.Generic.List[object]]$ErrorLog,
        [AllowNull()]
        [System.Collections.Generic.List[object]]$PluginResults
    )

    if ($null -eq $ErrorLog) { $ErrorLog = New-Object System.Collections.Generic.List[object] }

    $thresholds = $Config.Thresholds

    # Palette (hard-coded values: CSS variables do not work in email)
    $ink   = '#101720'; $inkSoft = '#1b2531'; $steel = '#5b6b7c'; $line = '#dde3ea'
    $okFg  = '#1f8a5f'; $okBg   = '#e3f5ec'
    $wFg   = '#b9770e'; $wBg    = '#fbf0da'
    $cFg   = '#b93a3a'; $cBg    = '#fbe6e6'
    $gFg   = '#8a94a0'; $gBg    = '#eceff2'
    $offFg = '#3a4757'
    $font  = "font-family:'Segoe UI',Arial,sans-serif;"

    # --- Status cells (color carried by the TD: reliable in Word) --------
    function Script:_EmailBoolTd {
        param($Value)
        if ($null -eq $Value) { return "<td align=""center"" bgcolor=""$gBg"" style=""$font font-size:11px;color:$gFg;padding:5px 6px;border-bottom:1px solid $line;"">N/A</td>" }
        if ($Value) { return "<td align=""center"" bgcolor=""$okBg"" style=""$font font-size:11px;color:$okFg;font-weight:bold;padding:5px 6px;border-bottom:1px solid $line;"">OK</td>" }
        return "<td align=""center"" bgcolor=""$cBg"" style=""$font font-size:11px;color:$cFg;font-weight:bold;padding:5px 6px;border-bottom:1px solid $line;"">DOWN</td>"
    }

    function Script:_EmailMetricTd {
        param([Nullable[double]]$Value, [double]$Warn, [double]$Crit, [switch]$Invert)
        if ($null -eq $Value) { return "<td align=""center"" bgcolor=""$gBg"" style=""$font font-size:11px;color:$gFg;padding:5px 6px;border-bottom:1px solid $line;"">N/A</td>" }
        $fg = $okFg; $bg = $okBg
        if ($Invert) {
            if ($Value -le $Crit) { $fg = $cFg; $bg = $cBg } elseif ($Value -le $Warn) { $fg = $wFg; $bg = $wBg }
        }
        else {
            if ($Value -ge $Crit) { $fg = $cFg; $bg = $cBg } elseif ($Value -ge $Warn) { $fg = $wFg; $bg = $wBg }
        }
        return "<td align=""center"" bgcolor=""$bg"" style=""$font font-size:11px;color:$fg;font-weight:bold;padding:5px 6px;border-bottom:1px solid $line;"">$Value%</td>"
    }

    # --- Classification + aggregates ---------------------------------------
    $statuses = foreach ($row in $Results) {
        [PSCustomObject]@{ Row = $row; Status = (Get-ADEHMRowStatus -Row $row -Thresholds $thresholds) }
    }
    $total    = $Results.Count
    $offline  = ($statuses | Where-Object { $_.Status -eq 'OFFLINE' }).Count
    $critical = ($statuses | Where-Object { $_.Status -eq 'CRITICAL' }).Count
    $warning  = ($statuses | Where-Object { $_.Status -eq 'WARNING' }).Count
    $ok       = ($statuses | Where-Object { $_.Status -eq 'OK' }).Count
    $online   = $total - $offline
    $duration = [math]::Round(($EndTime - $StartTime).TotalSeconds, 1)

    # --- Pulse strip: nested table with colored cells -----------------------
    $pulseCells = ''
    if ($total -gt 0) {
        foreach ($pair in @(@($okFg, $ok), @($wFg, $warning), @($cFg, $critical), @($offFg, $offline))) {
            if ($pair[1] -gt 0) {
                $pct = [math]::Round(($pair[1] / $total) * 100, 2)
                $pulseCells += "<td width=""$pct%"" bgcolor=""$($pair[0])"" style=""font-size:1px;line-height:8px;"">&nbsp;</td>"
            }
        }
    }

    # --- Summary cards: 4 x 2 table ------------------------------------------
    function Script:_StatTd {
        param($Label, $Value, $Accent)
        return "<td width=""25%"" bgcolor=""#ffffff"" style=""$font border:1px solid $line;border-left:3px solid $Accent;padding:10px 12px;""><span style=""font-size:10px;color:$steel;text-transform:uppercase;letter-spacing:1px;"">$Label</span><br/><span style=""font-size:20px;color:$ink;font-weight:bold;"">$Value</span></td>"
    }

    $statsRow1 = (_StatTd 'Date' $StartTime.ToString('yyyy-MM-dd') $ink) + (_StatTd 'Time' $StartTime.ToString('HH:mm:ss') $ink) + (_StatTd 'Duration' "$duration s" $ink) + (_StatTd 'DC Count' $total $ink)
    $statsRow2 = (_StatTd 'DC Online' $online $okFg) + (_StatTd 'DC Offline' $offline $gFg) + (_StatTd 'Warning' $warning $wFg) + (_StatTd 'Critical' $critical $cFg)

    # --- Detail table -----------------------------------------------------------
    $headers = @('','Hostname','Site','IP','Ping','WinRM','NTDS','DNS','DFSR','Netlogon','KDC','ADWS','SYSVOL','NETLOGON','CPU','RAM','Disk','Windows','Boot')
    $headerTds = ($headers | ForEach-Object {
        "<td bgcolor=""$inkSoft"" style=""$font font-size:10px;color:#e8ecf1;font-weight:bold;text-transform:uppercase;padding:7px 6px;white-space:nowrap;"">$_</td>"
    }) -join ''

    $railColor = @{ OK = $okFg; WARNING = $wFg; CRITICAL = $cFg; OFFLINE = $gFg }

    $bodyRows = foreach ($entry in $statuses) {
        $row = $entry.Row
        $bootText = if ($row.LastBootTime) { '{0} ({1} d)' -f $row.LastBootTime.ToString('yyyy-MM-dd HH:mm'), $row.UptimeDays } else { 'N/A' }
        $winText  = if ($row.OSCaption) { '{0} (build {1})' -f $row.OSCaption, $row.BuildNumber } else { 'N/A' }
        $siteText = if ($row.Site) { [string]$row.Site } else { 'N/A' }
        $ipText   = if ($row.IPAddress) { [string]$row.IPAddress } else { 'N/A' }
        $txtTd    = "style=""$font font-size:11px;color:$ink;padding:5px 6px;border-bottom:1px solid $line;white-space:nowrap;"""

        '<tr>' +
        "<td width=""4"" bgcolor=""$($railColor[$entry.Status])"" style=""font-size:1px;"">&nbsp;</td>" +
        "<td $txtTd><b>$($row.Hostname)</b></td>" +
        "<td $txtTd>$siteText</td>" +
        "<td $txtTd>$ipText</td>" +
        (_EmailBoolTd $row.Ping) + (_EmailBoolTd $row.WinRM) +
        (_EmailBoolTd $row.NTDS) + (_EmailBoolTd $row.DNS) + (_EmailBoolTd $row.DFSR) +
        (_EmailBoolTd $row.Netlogon) + (_EmailBoolTd $row.KDC) + (_EmailBoolTd $row.ADWS) +
        (_EmailBoolTd $row.SYSVOL) + (_EmailBoolTd $row.NetlogonShare) +
        (_EmailMetricTd -Value $row.CpuPercent -Warn $thresholds.CpuWarningPercent -Crit $thresholds.CpuCriticalPercent) +
        (_EmailMetricTd -Value $row.RamPercent -Warn $thresholds.RamWarningPercent -Crit $thresholds.RamCriticalPercent) +
        (_EmailMetricTd -Value $row.DiskFreePercent -Warn $thresholds.DiskWarningFreePct -Crit $thresholds.DiskCriticalFreePct -Invert) +
        "<td $txtTd>$winText</td>" +
        "<td $txtTd>$bootText</td>" +
        '</tr>'
    }

    # --- Plugin sections (email rendering) --------------------------------------
    $pluginEmailHtml = ''
    if ($PluginResults -and $PluginResults.Count -gt 0) {
        $emailStatus = @{
            OK   = @{ Fg = $okFg; Bg = $okBg }
            WARN = @{ Fg = $wFg;  Bg = $wBg }
            CRIT = @{ Fg = $cFg;  Bg = $cBg }
            NA   = @{ Fg = $gFg;  Bg = $gBg }
            INFO = @{ Fg = $gFg;  Bg = $gBg }
        }
        foreach ($plugin in $PluginResults) {
            if (-not $plugin.Rows -or $plugin.Rows.Count -eq 0) { continue }
            $labels = @($plugin.Rows[0].Cells.Keys)
            $pHeaderTds = ("<td bgcolor=""$inkSoft"" style=""$font font-size:10px;color:#e8ecf1;font-weight:bold;text-transform:uppercase;padding:7px 6px;white-space:nowrap;"">Hostname</td>") + `
                (($labels | ForEach-Object { "<td bgcolor=""$inkSoft"" style=""$font font-size:10px;color:#e8ecf1;font-weight:bold;text-transform:uppercase;padding:7px 6px;white-space:nowrap;"">$_</td>" }) -join '')
            $pBodyRows = foreach ($r in $plugin.Rows) {
                $tds = foreach ($label in $labels) {
                    $cell = $r.Cells[$label]
                    $st = $emailStatus[[string]$cell.Status]
                    if (-not $st) { $st = $emailStatus['NA'] }
                    "<td align=""center"" bgcolor=""$($st.Bg)"" style=""$font font-size:11px;color:$($st.Fg);font-weight:bold;padding:5px 6px;border-bottom:1px solid $line;"">$($cell.Text)</td>"
                }
                "<tr><td style=""$font font-size:11px;color:$ink;padding:5px 6px;border-bottom:1px solid $line;white-space:nowrap;""><b>$($r.Hostname)</b></td>$($tds -join '')</tr>"
            }
            $pSummary = if ($plugin.Summary) { "<tr><td style=""$font font-size:12px;color:$steel;padding:0 0 6px 0;"">$($plugin.Summary)</td></tr>" } else { '' }
            $pluginEmailHtml += "<tr><td style=""$font font-size:12px;color:$steel;text-transform:uppercase;letter-spacing:1px;padding:20px 0 8px 0;"">$($plugin.Name)</td></tr>$pSummary<tr><td><table width=""100%"" cellpadding=""0"" cellspacing=""0"" bgcolor=""#ffffff"" style=""border:1px solid $line;""><tr>$pHeaderTds</tr>$($pBodyRows -join '')</table></td></tr>"
        }
    }

    # --- Incidents ------------------------------------------------------------
    $incidentsHtml = ''
    if ($ErrorLog.Count -gt 0) {
        $items = foreach ($e in $ErrorLog) {
            "<table width=""100%"" cellpadding=""0"" cellspacing=""0"" style=""margin-bottom:8px;""><tr>" +
            "<td width=""3"" bgcolor=""$cFg"" style=""font-size:1px;"">&nbsp;</td>" +
            "<td bgcolor=""#ffffff"" style=""$font border:1px solid $line;padding:10px 14px;font-size:12px;color:$ink;"">" +
            "<b style=""color:$cFg;"">$($e.Server) &middot; $($e.Module)</b><br/>$($e.Exception)<br/>" +
            "<span style=""color:$steel;font-size:11px;"">Probable cause: $($e.ProbableCause)<br/>Recommendation: $($e.Recommendation)<br/>$($e.Date.ToString('yyyy-MM-dd HH:mm:ss'))</span>" +
            '</td></tr></table>'
        }
        $incidentsHtml = "<tr><td style=""$font font-size:12px;color:$steel;text-transform:uppercase;letter-spacing:1px;padding:20px 0 8px 0;"">Incidents ($($ErrorLog.Count))</td></tr><tr><td>$($items -join '')</td></tr>"
    }

    # --- Assembly ---------------------------------------------------------------
    return @"
<!DOCTYPE html>
<html lang="en">
<head><meta charset="UTF-8" /></head>
<body style="margin:0;padding:0;" bgcolor="#eef1f5">
<table width="100%" cellpadding="0" cellspacing="0" bgcolor="#eef1f5"><tr><td align="center" style="padding:16px 8px;">
<table width="980" cellpadding="0" cellspacing="0">

  <tr><td bgcolor="$ink" style="padding:20px 24px;">
    <span style="font-family:Consolas,'Courier New',monospace;font-size:12px;letter-spacing:3px;color:#7fd6ab;border:1px solid #33455a;padding:2px 7px;">ADEHM</span>
    &nbsp;<span style="$font font-size:19px;color:#f2f4f7;font-weight:bold;">Active Directory Enterprise Health Monitor</span><br/>
    <span style="font-family:Consolas,'Courier New',monospace;font-size:11px;color:#9fb0c3;">$($Config.General.CompanyName) &middot; Generated $($StartTime.ToString('yyyy-MM-dd')) at $($StartTime.ToString('HH:mm:ss')) &middot; Duration $duration s</span>
    <table width="100%" cellpadding="0" cellspacing="0" style="margin-top:14px;"><tr>$pulseCells</tr></table>
    <span style="font-family:Consolas,'Courier New',monospace;font-size:10px;color:#9fb0c3;">OK ($ok) &nbsp; Warning ($warning) &nbsp; Critical ($critical) &nbsp; Offline ($offline)</span>
  </td></tr>

  <tr><td style="padding:14px 0 0 0;">
    <table width="100%" cellpadding="0" cellspacing="4">
      <tr>$statsRow1</tr>
      <tr>$statsRow2</tr>
    </table>
  </td></tr>

  <tr><td style="$font font-size:12px;color:$steel;text-transform:uppercase;letter-spacing:1px;padding:20px 0 8px 0;">Domain Controller Details</td></tr>
  <tr><td>
    <table width="100%" cellpadding="0" cellspacing="0" bgcolor="#ffffff" style="border:1px solid $line;">
      <tr>$headerTds</tr>
      $($bodyRows -join "`n")
    </table>
  </td></tr>

  $pluginEmailHtml

  $incidentsHtml

  <tr><td style="$font font-size:10px;color:$steel;padding:18px 0 4px 0;border-top:1px solid $line;">
    ADEHM v1.0 &middot; Active Directory Enterprise Health Monitor &mdash; Full report attached &mdash; do not reply to this email
  </td></tr>

</table>
</td></tr></table>
</body>
</html>
"@
}

Export-ModuleMember -Function New-ADEHMHtmlReport, New-ADEHMEmailReport, Get-ADEHMRowStatus
