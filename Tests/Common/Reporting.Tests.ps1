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

    It 'correctly round-trips a single-element array' {
        $results = @([PSCustomObject]@{ Module = 'Firewall'; Setting = 'DefaultInboundAction'; Expected = 'Block'; Actual = 'Block'; Pass = $true })
        $reportPath = Join-Path $TestDrive 'audit-single.json'

        $summary = New-BaselineAuditReport -Results $results -ReportPath $reportPath

        Test-Path -Path $reportPath | Should -BeTrue
        $summary.Total | Should -Be 1
        $summary.Passed | Should -Be 1
        $summary.Failed | Should -Be 0

        $parsed = Get-Content -Path $reportPath -Raw | ConvertFrom-Json
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
}
