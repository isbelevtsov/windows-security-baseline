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
    It 'configures from a freshly-exported working cfg patched with only this module''s own keys, not the raw backup file' {
        # Regression test for a real bug found on Windows hardware:
        # AccountLockout and PasswordPolicy share the same secedit
        # [System Access] section. This module's own backup is taken
        # after PasswordPolicy's Set already committed in the same Apply
        # run, so it silently captures PasswordPolicy's already-applied
        # values instead of the true pre-Apply ones. Restoring by directly
        # /configuring that raw backup file would clobber PasswordPolicy's
        # own restore back to those stale values.
        Mock -ModuleName AccountLockout -CommandName Invoke-SecEditExport { }
        Mock -ModuleName AccountLockout -CommandName Invoke-SecEditConfigure { }
        Mock -ModuleName AccountLockout -CommandName Set-SecurityPolicyValue { }
        Mock -ModuleName AccountLockout -CommandName Get-SecurityPolicyValue {
            param($CfgPath, $Key)
            switch ($Key) {
                'LockoutBadCount'   { '10' }
                'LockoutDuration'   { '10' }
                'ResetLockoutCount' { '10' }
            }
        }

        # Named to avoid colliding with the mocked commands' own $CfgPath
        # parameter inside -ParameterFilter scriptblocks below - PowerShell
        # variable names are case-insensitive, so a same-named outer
        # variable would otherwise be shadowed by the bound parameter,
        # silently turning "-eq" comparisons into tautologies.
        $backupPath = Join-Path $TestDrive 'RestoreAccountLockout'
        New-Item -Path $backupPath -ItemType Directory -Force | Out-Null
        $backupCfgFile = Join-Path $backupPath 'account-lockout.cfg'
        Set-Content -Path $backupCfgFile -Value 'placeholder'
        $expectedWorkingCfgFile = Join-Path $backupPath 'account-lockout-restore-working.cfg'

        Restore-AccountLockoutSettings -BackupPath $backupPath

        Should -Invoke -ModuleName AccountLockout -CommandName Invoke-SecEditExport -ParameterFilter { $CfgPath -eq $expectedWorkingCfgFile } -Times 1
        Should -Invoke -ModuleName AccountLockout -CommandName Get-SecurityPolicyValue -ParameterFilter { $CfgPath -eq $backupCfgFile -and $Key -eq 'LockoutBadCount' } -Times 1
        Should -Invoke -ModuleName AccountLockout -CommandName Set-SecurityPolicyValue -ParameterFilter { $CfgPath -eq $expectedWorkingCfgFile -and $Key -eq 'LockoutBadCount' -and $Value -eq '10' } -Times 1
        Should -Invoke -ModuleName AccountLockout -CommandName Invoke-SecEditConfigure -ParameterFilter { $CfgPath -eq $expectedWorkingCfgFile } -Times 1
        Should -Invoke -ModuleName AccountLockout -CommandName Invoke-SecEditConfigure -ParameterFilter { $CfgPath -eq $backupCfgFile } -Times 0
    }

    It 'throws when no backup cfg exists' {
        { Restore-AccountLockoutSettings -BackupPath (Join-Path $TestDrive 'missing') } | Should -Throw
    }
}
