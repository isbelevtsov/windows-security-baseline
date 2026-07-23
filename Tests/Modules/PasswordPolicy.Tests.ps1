BeforeAll {
    Import-Module "$PSScriptRoot/../../Modules/PasswordPolicy.psm1" -Force

    function New-TestConfig {
        @{
            MinimumPasswordLength  = @{ Value = 14; Description = 'min length' }
            PasswordComplexity     = @{ Value = $true; Description = 'complexity' }
            PasswordHistorySize    = @{ Value = 24; Description = 'history' }
            MaximumPasswordAgeDays = @{ Value = 90; Description = 'max age' }
            MinimumPasswordAgeDays = @{ Value = 1; Description = 'min age' }
        }
    }
}

Describe 'Test-PasswordPolicyBaseline' {
    It 'flags settings that do not match the config' {
        Mock -ModuleName PasswordPolicy -CommandName Invoke-SecEditExport { }
        Mock -ModuleName PasswordPolicy -CommandName Get-SecurityPolicyValue {
            param($CfgPath, $Key)
            switch ($Key) {
                'MinimumPasswordLength' { '7' }
                'PasswordComplexity'    { '0' }
                'PasswordHistorySize'   { '24' }
                'MaximumPasswordAge'    { '90' }
                'MinimumPasswordAge'    { '1' }
            }
        }

        $results = Test-PasswordPolicyBaseline -Config (New-TestConfig) -WorkingCfgPath 'C:\temp\working.cfg'

        ($results | Where-Object Setting -eq 'MinimumPasswordLength').Pass | Should -BeFalse
        ($results | Where-Object Setting -eq 'PasswordComplexity').Pass | Should -BeFalse
        ($results | Where-Object Setting -eq 'PasswordHistorySize').Pass | Should -BeTrue
    }
}

Describe 'Backup-PasswordPolicySettings' {
    It 'exports the current policy to password-policy.cfg under the backup path' {
        Mock -ModuleName PasswordPolicy -CommandName Invoke-SecEditExport { }
        $backupPath = Join-Path $TestDrive 'PasswordPolicy'

        $cfgPath = Backup-PasswordPolicySettings -BackupPath $backupPath

        $cfgPath | Should -Be (Join-Path $backupPath 'password-policy.cfg')
        Should -Invoke -ModuleName PasswordPolicy -CommandName Invoke-SecEditExport -ParameterFilter { $CfgPath -eq $cfgPath } -Times 1
    }
}

Describe 'Set-PasswordPolicyBaseline' {
    It 'only writes settings that differ from config, and always configures once at the end' {
        Mock -ModuleName PasswordPolicy -CommandName Invoke-SecEditExport { }
        Mock -ModuleName PasswordPolicy -CommandName Invoke-SecEditConfigure { }
        Mock -ModuleName PasswordPolicy -CommandName Set-SecurityPolicyValue { }
        Mock -ModuleName PasswordPolicy -CommandName Get-SecurityPolicyValue {
            param($CfgPath, $Key)
            switch ($Key) {
                'MinimumPasswordLength' { '7' }
                'PasswordComplexity'    { '1' }
                'PasswordHistorySize'   { '24' }
                'MaximumPasswordAge'    { '90' }
                'MinimumPasswordAge'    { '1' }
            }
        }

        $changes = Set-PasswordPolicyBaseline -Config (New-TestConfig) -WorkingCfgPath 'C:\temp\working.cfg'

        ($changes | Where-Object Setting -eq 'MinimumPasswordLength').Changed | Should -BeTrue
        ($changes | Where-Object Setting -eq 'PasswordHistorySize').Changed | Should -BeFalse
        Should -Invoke -ModuleName PasswordPolicy -CommandName Set-SecurityPolicyValue -Times 1
        Should -Invoke -ModuleName PasswordPolicy -CommandName Invoke-SecEditConfigure -Times 1
    }
}

Describe 'Restore-PasswordPolicySettings' {
    It 'configures from a freshly-exported working cfg patched with only this module''s own keys, not the raw backup file' {
        # Regression test for a real bug found on Windows hardware:
        # PasswordPolicy and AccountLockout share the same secedit
        # [System Access] section. Restoring by directly /configuring the
        # raw backup file reasserted whatever else was in that section at
        # backup time - and since AccountLockout's own backup is taken
        # later in the same Apply run (after PasswordPolicy's Set already
        # committed), it silently captures PasswordPolicy's already-applied
        # values rather than the true pre-Apply ones. Restoring
        # PasswordPolicy from its own snapshot was then immediately
        # clobbered back to those stale values the moment AccountLockout's
        # restore ran its own full /configure afterward. Confirmed
        # directly: PasswordPolicy's own backup showed
        # MinimumPasswordLength=0 (true original), while AccountLockout's
        # backup from the same snapshot showed MinimumPasswordLength=14
        # (PasswordPolicy's post-Set value, baked in by accident).
        Mock -ModuleName PasswordPolicy -CommandName Invoke-SecEditExport { }
        Mock -ModuleName PasswordPolicy -CommandName Invoke-SecEditConfigure { }
        Mock -ModuleName PasswordPolicy -CommandName Set-SecurityPolicyValue { }
        Mock -ModuleName PasswordPolicy -CommandName Get-SecurityPolicyValue {
            param($CfgPath, $Key)
            switch ($Key) {
                'MinimumPasswordLength' { '0' }
                'PasswordComplexity'    { '0' }
                'PasswordHistorySize'   { '0' }
                'MaximumPasswordAge'    { '42' }
                'MinimumPasswordAge'    { '0' }
            }
        }

        # Named to avoid colliding with the mocked commands' own $CfgPath
        # parameter inside -ParameterFilter scriptblocks below - PowerShell
        # variable names are case-insensitive, so a same-named outer
        # variable would otherwise be shadowed by the bound parameter,
        # silently turning "-eq" comparisons into tautologies.
        $backupPath = Join-Path $TestDrive 'RestorePasswordPolicy'
        New-Item -Path $backupPath -ItemType Directory -Force | Out-Null
        $backupCfgFile = Join-Path $backupPath 'password-policy.cfg'
        Set-Content -Path $backupCfgFile -Value 'placeholder'
        $expectedWorkingCfgFile = Join-Path $backupPath 'password-policy-restore-working.cfg'

        Restore-PasswordPolicySettings -BackupPath $backupPath

        # A fresh export of the CURRENT live policy, not a read of the
        # historical backup.
        Should -Invoke -ModuleName PasswordPolicy -CommandName Invoke-SecEditExport -ParameterFilter { $CfgPath -eq $expectedWorkingCfgFile } -Times 1
        # Each of this module's own keys is read from the backup file...
        Should -Invoke -ModuleName PasswordPolicy -CommandName Get-SecurityPolicyValue -ParameterFilter { $CfgPath -eq $backupCfgFile -and $Key -eq 'MinimumPasswordLength' } -Times 1
        # ...and written into the fresh working cfg, not the backup file.
        Should -Invoke -ModuleName PasswordPolicy -CommandName Set-SecurityPolicyValue -ParameterFilter { $CfgPath -eq $expectedWorkingCfgFile -and $Key -eq 'MinimumPasswordLength' -and $Value -eq '0' } -Times 1
        # The live policy is configured from the patched working cfg -
        # never directly from the raw backup file.
        Should -Invoke -ModuleName PasswordPolicy -CommandName Invoke-SecEditConfigure -ParameterFilter { $CfgPath -eq $expectedWorkingCfgFile } -Times 1
        Should -Invoke -ModuleName PasswordPolicy -CommandName Invoke-SecEditConfigure -ParameterFilter { $CfgPath -eq $backupCfgFile } -Times 0
    }

    It 'throws when no backup cfg exists' {
        { Restore-PasswordPolicySettings -BackupPath (Join-Path $TestDrive 'missing') } | Should -Throw
    }
}
