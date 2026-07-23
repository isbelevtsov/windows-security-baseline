function New-BaselineAuditReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Results,
        [Parameter(Mandatory)][string]$ReportPath
    )

    $reportDir = Split-Path -Path $ReportPath -Parent
    if ($reportDir -and -not (Test-Path -Path $reportDir)) {
        New-Item -Path $reportDir -ItemType Directory -Force | Out-Null
    }

    if ($Results.Count -eq 0) {
        Set-Content -Path $ReportPath -Value '[]'
    }
    else {
        ConvertTo-Json -InputObject $Results -Depth 5 | Set-Content -Path $ReportPath
    }

    $passed = @($Results | Where-Object { $_.Pass }).Count
    $failed = @($Results | Where-Object { -not $_.Pass }).Count

    return [PSCustomObject]@{
        Total  = $Results.Count
        Passed = $passed
        Failed = $failed
    }
}

function Write-BaselineAuditSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Results
    )

    $Results |
        Sort-Object Module, Setting |
        Format-Table -Property Module, Setting, Expected, Actual, Pass -AutoSize |
        Out-String |
        Write-Host

    $failed = @($Results | Where-Object { -not $_.Pass })
    if ($failed.Count -gt 0) {
        Write-Host "$($failed.Count) setting(s) failed the baseline check."
    }
    else {
        Write-Host 'All settings pass the baseline check.'
    }
}

function Write-BaselineApplySummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$ChangeRecords,
        [Parameter(Mandatory)][string]$BackupPath,
        [Parameter(Mandatory)][string]$LogPath
    )

    $changed = @($ChangeRecords | Where-Object { $_.Changed })
    Write-Host "Applied baseline: $($changed.Count) setting(s) changed."
    Write-Host "Backup saved to: $BackupPath"
    Write-Host "Full log: $LogPath"
    Write-Host "To revert: .\Invoke-SecurityBaseline.ps1 -Mode Restore -Timestamp `"$(Split-Path -Path $BackupPath -Leaf)`""

    # A change record carries a Secret (BitLocker recovery key, a generated
    # LocalAccounts temporary password) only when Set-<Area>Baseline just
    # generated one - these are also written to a file, but that's easy to
    # miss in the console output, so surface the actual value here too,
    # highlighted, right where the operator is already looking.
    $secrets = @($ChangeRecords | Where-Object { $_.Secret })
    if ($secrets.Count -gt 0) {
        Write-Host ''
        Write-Host '=== SAVE THESE NOW - generated secrets ===' -ForegroundColor Black -BackgroundColor Yellow
        foreach ($secret in $secrets) {
            $label = $(if ($secret.SecretLabel) { $secret.SecretLabel } else { $secret.Setting })
            Write-Host "[$($secret.Module)] $label" -ForegroundColor Yellow
            Write-Host "  $($secret.Secret)" -ForegroundColor Black -BackgroundColor Yellow
        }
        Write-Host ''
    }
}

Export-ModuleMember -Function New-BaselineAuditReport, Write-BaselineAuditSummary, Write-BaselineApplySummary
