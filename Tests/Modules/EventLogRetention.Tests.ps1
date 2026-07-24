# Tests/Modules/EventLogRetention.Tests.ps1
BeforeAll {
    Import-Module "$PSScriptRoot/../../Modules/EventLogRetention.psm1" -Force

    function New-TestConfig {
        @{
            MinimumMaxSizeBytes = @{ Value = 104857600; Description = 'minimum log size' }
        }
    }
}

Describe 'Test-EventLogRetentionBaseline' {
    It 'checks Application, Security, and System logs' {
        Mock -ModuleName EventLogRetention -CommandName Get-EventLogMaxSizeBytes { 104857600 }

        $results = @(Test-EventLogRetentionBaseline -Config (New-TestConfig))

        $results.Count | Should -Be 3
        ($results | Where-Object Setting -eq 'Application.MaxSizeBytes') | Should -Not -BeNullOrEmpty
        ($results | Where-Object Setting -eq 'Security.MaxSizeBytes') | Should -Not -BeNullOrEmpty
        ($results | Where-Object Setting -eq 'System.MaxSizeBytes') | Should -Not -BeNullOrEmpty
    }

    It 'flags a log below the configured minimum size' {
        Mock -ModuleName EventLogRetention -CommandName Get-EventLogMaxSizeBytes {
            param($LogName)
            if ($LogName -eq 'Security') { return 20971520 }
            return 104857600
        }

        $results = Test-EventLogRetentionBaseline -Config (New-TestConfig)

        ($results | Where-Object Setting -eq 'Security.MaxSizeBytes').Pass | Should -BeFalse
        ($results | Where-Object Setting -eq 'Application.MaxSizeBytes').Pass | Should -BeTrue
    }

    It 'passes a log already above the configured minimum size' {
        Mock -ModuleName EventLogRetention -CommandName Get-EventLogMaxSizeBytes { 209715200 }

        $results = Test-EventLogRetentionBaseline -Config (New-TestConfig)

        ($results | Where-Object Pass -eq $false).Count | Should -Be 0
    }
}

Describe 'Set-EventLogRetentionBaseline' {
    It 'only resizes logs that are below the configured minimum' {
        Mock -ModuleName EventLogRetention -CommandName Get-EventLogMaxSizeBytes {
            param($LogName)
            if ($LogName -eq 'Security') { return 20971520 }
            return 104857600
        }
        Mock -ModuleName EventLogRetention -CommandName Set-EventLogMaxSizeBytes { }

        $changes = Set-EventLogRetentionBaseline -Config (New-TestConfig)

        ($changes | Where-Object Setting -eq 'Security.MaxSizeBytes').Changed | Should -BeTrue
        ($changes | Where-Object Setting -eq 'Application.MaxSizeBytes').Changed | Should -BeFalse
        Should -Invoke -ModuleName EventLogRetention -CommandName Set-EventLogMaxSizeBytes -Times 1 -ParameterFilter { $LogName -eq 'Security' -and $Bytes -eq 104857600 }
    }
}

Describe 'Backup-EventLogRetentionSettings / Restore-EventLogRetentionSettings' {
    It 'round-trips each log''s current max size' {
        Mock -ModuleName EventLogRetention -CommandName Get-EventLogMaxSizeBytes {
            param($LogName)
            switch ($LogName) {
                'Application' { 20971520 }
                'Security'    { 20971520 }
                'System'      { 20971520 }
            }
        }

        $backupPath = Join-Path $TestDrive 'EventLogRetention'
        Backup-EventLogRetentionSettings -BackupPath $backupPath

        Mock -ModuleName EventLogRetention -CommandName Set-EventLogMaxSizeBytes { }

        Restore-EventLogRetentionSettings -BackupPath $backupPath

        Should -Invoke -ModuleName EventLogRetention -CommandName Set-EventLogMaxSizeBytes -Times 1 -ParameterFilter { $LogName -eq 'Application' -and $Bytes -eq 20971520 }
        Should -Invoke -ModuleName EventLogRetention -CommandName Set-EventLogMaxSizeBytes -Times 1 -ParameterFilter { $LogName -eq 'Security' -and $Bytes -eq 20971520 }
        Should -Invoke -ModuleName EventLogRetention -CommandName Set-EventLogMaxSizeBytes -Times 1 -ParameterFilter { $LogName -eq 'System' -and $Bytes -eq 20971520 }
    }

    It 'throws when restoring without a prior backup' {
        { Restore-EventLogRetentionSettings -BackupPath (Join-Path $TestDrive 'missing') } | Should -Throw
    }
}
