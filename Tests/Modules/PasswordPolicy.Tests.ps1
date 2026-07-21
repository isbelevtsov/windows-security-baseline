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
    It 'configures from the backed-up cfg file' {
        Mock -ModuleName PasswordPolicy -CommandName Invoke-SecEditConfigure { }
        $backupPath = Join-Path $TestDrive 'RestorePasswordPolicy'
        New-Item -Path $backupPath -ItemType Directory -Force | Out-Null
        $cfgPath = Join-Path $backupPath 'password-policy.cfg'
        Set-Content -Path $cfgPath -Value 'placeholder'

        Restore-PasswordPolicySettings -BackupPath $backupPath

        Should -Invoke -ModuleName PasswordPolicy -CommandName Invoke-SecEditConfigure -ParameterFilter { $CfgPath -eq $cfgPath } -Times 1
    }

    It 'throws when no backup cfg exists' {
        { Restore-PasswordPolicySettings -BackupPath (Join-Path $TestDrive 'missing') } | Should -Throw
    }
}
