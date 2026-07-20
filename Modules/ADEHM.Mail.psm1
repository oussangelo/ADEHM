#requires -Version 5.1
<#
    ADEHM.Mail.psm1
    Sends the report by email (SMTP).

    Uses System.Net.Mail directly (rather than Send-MailMessage, obsolete
    since PowerShell 7.x) to remain compatible with PowerShell 5.1 / 7.
#>

function Send-ADEHMReport {
    <#
        .SYNOPSIS
        Emails the HTML report according to the Mail section of the
        configuration.

        .PARAMETER BodyHtml
        Optional email-optimized HTML body (from New-ADEHMEmailReport).
        Used when EmbedReportInBody is enabled; the raw report file is only
        a fallback (degraded rendering in Outlook).

        .PARAMETER Credential
        SMTP service account credentials. When omitted, the default Windows
        credentials of the execution context are used.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable]$Config,
        [Parameter(Mandatory)] [string]$ReportPath,
        [Parameter(Mandatory)] [datetime]$RunDate,
        [string]$BodyHtml,
        [System.Management.Automation.PSCredential]$Credential
    )

    if (-not $Config.Mail.Enabled) {
        Write-ADEHMLog -Level INFO -Module Mail -Message 'Mail delivery disabled in configuration.'
        return $false
    }

    if (-not (Test-Path -LiteralPath $ReportPath)) {
        Write-ADEHMError -Server 'localhost' -Module 'Mail' -Exception "Report not found: $ReportPath" `
            -ProbableCause 'HTML report generation failed before sending.' `
            -Recommendation 'Review HTML module errors in the log.'
        return $false
    }

    # ABSOLUTE path required: the .NET Attachment constructor resolves
    # relative paths against the process working directory (often
    # C:\Windows\system32), not the current PowerShell location.
    $ReportPath = (Resolve-Path -LiteralPath $ReportPath).ProviderPath

    $attachment = $null
    $mail       = $null
    $smtp       = $null

    try {
        $smtp = New-Object System.Net.Mail.SmtpClient($Config.Mail.SmtpServer, $Config.Mail.Port)
        $smtp.EnableSsl = [bool]$Config.Mail.UseSsl

        if ($Config.Mail.Anonymous) {
            # Explicit anonymous relay (e.g. IP-based allow list): send no
            # authentication at all. UseDefaultCredentials would still
            # offer the current Windows identity to the server, which some
            # anonymous relays do not expect.
            Write-ADEHMLog -Level DEBUG -Module Mail -Message 'SMTP: anonymous relay (Mail.Anonymous = $true), no credentials sent.'
        }
        elseif ($Credential) {
            $smtp.Credentials = $Credential.GetNetworkCredential()
        }
        else {
            $smtp.UseDefaultCredentials = $true
        }

        $mail = New-Object System.Net.Mail.MailMessage
        $mail.From = $Config.Mail.From
        foreach ($to in $Config.Mail.To) { $mail.To.Add($to) }
        foreach ($cc in $Config.Mail.Cc) { $mail.CC.Add($cc) }

        $mail.Subject    = ($Config.Mail.Subject -f $RunDate.ToString('yyyy-MM-dd HH:mm'))
        $mail.IsBodyHtml = $true

        if ($Config.Mail.EmbedReportInBody) {
            if ($BodyHtml) {
                # Email-optimized rendering (tables + inline styles) from
                # New-ADEHMEmailReport: the only reliable option in Outlook
                # (Word rendering engine).
                $mail.Body = $BodyHtml
            }
            else {
                # Fallback: raw file (degraded rendering in Outlook)
                $mail.Body = Get-Content -LiteralPath $ReportPath -Raw -Encoding UTF8
            }
        }
        else {
            $mail.Body = "The ADEHM report of $($RunDate.ToString('yyyy-MM-dd HH:mm')) is attached."
        }

        if ($Config.Mail.AttachReport) {
            $attachment = New-Object System.Net.Mail.Attachment($ReportPath)
            $mail.Attachments.Add($attachment)
        }

        $smtp.Send($mail)

        Write-ADEHMLog -Level INFO -Module Mail -Message "Report sent to $($Config.Mail.To -join ', ')"
        return $true
    }
    catch {
        $msg = $_.Exception.Message

        if ($msg -match 'path|find') {
            $cause = 'Client-side file path error (BEFORE any SMTP contact): the report was not found at the expected location.'
            $reco  = 'Check the report path in the log; use absolute paths in the configuration.'
        }
        elseif ($msg -match 'authent|credential|5\.7') {
            $cause = 'The SMTP server rejected authentication or the sender address.'
            $reco  = 'Check the SMTP account, the allowed From address, and the server relay restrictions.'
        }
        else {
            $cause = 'SMTP server unreachable, port blocked by a firewall, or incorrect SSL/port setting.'
            $reco  = 'Check SmtpServer/Port/UseSsl in the configuration and run Test-NetConnection <smtp> -Port <port>.'
        }

        Write-ADEHMError -Server 'localhost' -Module 'Mail' -Exception $msg `
            -ProbableCause $cause -Recommendation $reco
        return $false
    }
    finally {
        if ($attachment) { $attachment.Dispose() }
        if ($mail)       { $mail.Dispose() }
        if ($smtp)       { $smtp.Dispose() }
    }
}

Export-ModuleMember -Function Send-ADEHMReport
