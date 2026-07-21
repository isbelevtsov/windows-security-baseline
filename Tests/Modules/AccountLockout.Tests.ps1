BeforeAll {
    Import-Module "$PSScriptRoot/../../Modules/AccountLockout.psm1" -Force

    function New-TestConfig {
        @{
            LockoutThreshold         = @{ Value = 5; Description = 'threshold' }
            LockoutDurationMinutes   = @{ Value = 15; Description = 'duration' }
            ObservationWindowMinutes = @{ Value = 15; Description = 'window' }
        }
    }
}

Describe 'Test-AccountLockoutBaseline' {
    It 'flags settings that do not match the config' {
        Mock -ModuleName AccountLockout -CommandName Invoke-SecEditExport { }
        Mock -ModuleName AccountLockout -CommandName Get-SecurityPolicyValue {
            param($CfgPath, $Key)
            switch ($Key) {
                'LockoutBadCount'   { '0' }
                'LockoutDuration'   { '15' }
                'ResetLockoutCount' { '15' }
            }
        }

        $results = Test-AccountLockoutBaseline -Config (New-TestConfig) -WorkingCfgPath 'C:\temp\working.cfg'

        ($results | Where-Object Setting -eq 'LockoutThreshold').Pass | Should -BeFalse
        ($results | Where-Object Setting -eq 'LockoutDurationMinutes').Pass | Should -BeTrue
    }
}

Describe 'Backup-AccountLockoutSettings' {
    It 'exports the current policy to account-lockout.cfg under the backup path' {
        Mock -ModuleName AccountLockout -CommandName Invoke-SecEditExport { }
        $backupPath = Join-Path $TestDrive 'AccountLockout'

        $cfgPath = Backup-AccountLockoutSettings -BackupPath $backupPath

        $cfgPath | Should -Be (Join-Path $backupPath 'account-lockout.cfg')
    }
}

Describe 'Set-AccountLockoutBaseline' {
    It 'only writes settings that differ from config' {
        Mock -ModuleName AccountLockout -CommandName Invoke-SecEditExport { }
        Mock -ModuleName AccountLockout -CommandName Invoke-SecEditConfigure { }
        Mock -ModuleName AccountLockout -CommandName Set-SecurityPolicyValue { }
        Mock -ModuleName AccountLockout -CommandName Get-SecurityPolicyValue {
            param($CfgPath, $Key)
            switch ($Key) {
                'LockoutBadCount'   { '0' }
                'LockoutDuration'   { '15' }
                'ResetLockoutCount' { '15' }
            }
        }

        $changes = Set-AccountLockoutBaseline -Config (New-TestConfig) -WorkingCfgPath 'C:\temp\working.cfg'

        ($changes | Where-Object Setting -eq 'LockoutThreshold').Changed | Should -BeTrue
        ($changes | Where-Object Setting -eq 'LockoutDurationMinutes').Changed | Should -BeFalse
        Should -Invoke -ModuleName AccountLockout -CommandName Set-SecurityPolicyValue -Times 1
    }
}

Describe 'Restore-AccountLockoutSettings' {
    It 'configures from the backed-up cfg file' {
        Mock -ModuleName AccountLockout -CommandName Invoke-SecEditConfigure { }
        $backupPath = Join-Path $TestDrive 'RestoreAccountLockout'
        New-Item -Path $backupPath -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $backupPath 'account-lockout.cfg') -Value 'placeholder'

        Restore-AccountLockoutSettings -BackupPath $backupPath

        Should -Invoke -ModuleName AccountLockout -CommandName Invoke-SecEditConfigure -Times 1
    }

    It 'throws when no backup cfg exists' {
        { Restore-AccountLockoutSettings -BackupPath (Join-Path $TestDrive 'missing') } | Should -Throw
    }
}
