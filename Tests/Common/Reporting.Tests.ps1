BeforeAll {
    Import-Module "$PSScriptRoot/../../Common/Reporting.psm1" -Force
}

Describe 'New-BaselineAuditReport' {
    It 'writes a JSON report and returns pass/fail counts' {
        $results = @(
            [PSCustomObject]@{ Module = 'Firewall'; Setting = 'DefaultInboundAction'; Expected = 'Block'; Actual = 'Block'; Pass = $true }
            [PSCustomObject]@{ Module = 'Defender'; Setting = 'RealTimeProtection'; Expected = $true; Actual = $false; Pass = $false }
        )
        $reportPath = Join-Path $TestDrive 'audit.json'

        $summary = New-BaselineAuditReport -Results $results -ReportPath $reportPath

        Test-Path -Path $reportPath | Should -BeTrue
        $summary.Total | Should -Be 2
        $summary.Passed | Should -Be 1
        $summary.Failed | Should -Be 1

        (Get-Content -Path $reportPath -Raw | ConvertFrom-Json).Count | Should -Be 2
    }

    It 'correctly round-trips a single-element array (not unwrapped to a bare object)' {
        $results = @([PSCustomObject]@{ Module = 'Firewall'; Setting = 'DefaultInboundAction'; Expected = 'Block'; Actual = 'Block'; Pass = $true })
        $reportPath = Join-Path $TestDrive 'audit-one.json'

        $summary = New-BaselineAuditReport -Results $results -ReportPath $reportPath

        Test-Path -Path $reportPath | Should -BeTrue
        $summary.Total | Should -Be 1
        $summary.Passed | Should -Be 1
        $summary.Failed | Should -Be 0

        $content = (Get-Content -Path $reportPath -Raw).Trim()
        $content.StartsWith('[') | Should -BeTrue
        $content.EndsWith(']') | Should -BeTrue

        $parsed = $content | ConvertFrom-Json
        @($parsed).Count | Should -Be 1
    }

    It 'correctly round-trips an empty array' {
        $results = @()
        $reportPath = Join-Path $TestDrive 'audit-empty.json'

        $summary = New-BaselineAuditReport -Results $results -ReportPath $reportPath

        Test-Path -Path $reportPath | Should -BeTrue
        $summary.Total | Should -Be 0
        $summary.Passed | Should -Be 0
        $summary.Failed | Should -Be 0

        $content = Get-Content -Path $reportPath -Raw
        $content.Trim() | Should -Be '[]'
        $parsed = $content | ConvertFrom-Json
        @($parsed).Count | Should -Be 0
    }
}

Describe 'Write-BaselineAuditSummary' {
    It 'reports when all settings pass' {
        $results = @([PSCustomObject]@{ Module = 'Firewall'; Setting = 'DefaultInboundAction'; Expected = 'Block'; Actual = 'Block'; Pass = $true })
        $output = Write-BaselineAuditSummary -Results $results 6>&1 | Out-String
        $output | Should -Match 'All settings pass'
    }

    It 'reports the failure count when settings fail' {
        $results = @([PSCustomObject]@{ Module = 'Defender'; Setting = 'RealTimeProtection'; Expected = $true; Actual = $false; Pass = $false })
        $output = Write-BaselineAuditSummary -Results $results 6>&1 | Out-String
        $output | Should -Match '1 setting\(s\) failed'
    }
}

Describe 'Write-BaselineApplySummary' {
    It 'includes the changed count, backup path, and restore command' {
        $records = @(
            [PSCustomObject]@{ Setting = 'MinimumPasswordLength'; Before = 7; After = 14; Changed = $true }
            [PSCustomObject]@{ Setting = 'PasswordComplexity'; Before = $true; After = $true; Changed = $false }
        )
        $output = Write-BaselineApplySummary -ChangeRecords $records -BackupPath 'C:\ProgramData\SecurityBaseline\Backups\2026-07-21_120000' -LogPath 'C:\ProgramData\SecurityBaseline\Logs\2026-07-21_120000.log' 6>&1 | Out-String
        $output | Should -Match '1 setting\(s\) changed'
        $output | Should -Match '2026-07-21_120000'
    }

    It 'highlights a generated secret in the console output' {
        $records = @(
            [PSCustomObject]@{
                Module = 'BitLocker'; Setting = 'OSDriveEncrypted'; Before = $false; After = $true; Changed = $true
                Secret = '123456-654321-111111-222222-333333-444444-555555-666666'; SecretLabel = 'BitLocker recovery key'
            }
        )
        $output = Write-BaselineApplySummary -ChangeRecords $records -BackupPath 'C:\ProgramData\SecurityBaseline\Backups\2026-07-21_120000' -LogPath 'C:\ProgramData\SecurityBaseline\Logs\2026-07-21_120000.log' 6>&1 | Out-String
        $output | Should -Match 'SAVE THESE NOW'
        $output | Should -Match 'BitLocker recovery key'
        $output | Should -Match '123456-654321-111111-222222-333333-444444-555555-666666'
    }

    It 'shows nothing extra when no change record carries a secret' {
        $records = @(
            [PSCustomObject]@{ Setting = 'MinimumPasswordLength'; Before = 7; After = 14; Changed = $true }
        )
        $output = Write-BaselineApplySummary -ChangeRecords $records -BackupPath 'C:\ProgramData\SecurityBaseline\Backups\2026-07-21_120000' -LogPath 'C:\ProgramData\SecurityBaseline\Logs\2026-07-21_120000.log' 6>&1 | Out-String
        $output | Should -Not -Match 'SAVE THESE NOW'
    }

    It 'highlights multiple secrets when more than one change record carries one' {
        $records = @(
            [PSCustomObject]@{
                Module = 'BitLocker'; Setting = 'OSDriveEncrypted'; Before = $false; After = $true; Changed = $true
                Secret = 'RECOVERY-KEY-VALUE'; SecretLabel = 'BitLocker recovery key'
            }
            [PSCustomObject]@{
                Module = 'LocalAccounts'; Setting = 'alice.PasswordRequired'; Before = $false; After = $true; Changed = $true
                Secret = 'TEMP-PASSWORD-VALUE'; SecretLabel = "Temporary password for 'alice'"
            }
        )
        $output = Write-BaselineApplySummary -ChangeRecords $records -BackupPath 'C:\ProgramData\SecurityBaseline\Backups\2026-07-21_120000' -LogPath 'C:\ProgramData\SecurityBaseline\Logs\2026-07-21_120000.log' 6>&1 | Out-String
        $output | Should -Match 'RECOVERY-KEY-VALUE'
        $output | Should -Match 'TEMP-PASSWORD-VALUE'
    }
}
