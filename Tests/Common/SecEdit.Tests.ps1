BeforeAll {
    Import-Module "$PSScriptRoot/../../Common/SecEdit.psm1" -Force
}

Describe 'Get-SecurityPolicyValue' {
    It 'extracts an existing key value' {
        $cfgPath = Join-Path $TestDrive 'policy.cfg'
        Set-Content -Path $cfgPath -Encoding Unicode -Value @(
            '[Unicode]'
            'Unicode=yes'
            '[System Access]'
            'MinimumPasswordLength = 0'
            'PasswordComplexity = 0'
        )
        Get-SecurityPolicyValue -CfgPath $cfgPath -Key 'MinimumPasswordLength' | Should -Be '0'
    }

    It 'returns $null for a key that is not present' {
        $cfgPath = Join-Path $TestDrive 'policy2.cfg'
        Set-Content -Path $cfgPath -Encoding Unicode -Value @('[System Access]', 'PasswordComplexity = 0')
        Get-SecurityPolicyValue -CfgPath $cfgPath -Key 'MinimumPasswordLength' | Should -BeNullOrEmpty
    }
}

Describe 'Set-SecurityPolicyValue' {
    It 'updates an existing key in place' {
        $cfgPath = Join-Path $TestDrive 'policy3.cfg'
        Set-Content -Path $cfgPath -Encoding Unicode -Value @('[System Access]', 'MinimumPasswordLength = 0')

        Set-SecurityPolicyValue -CfgPath $cfgPath -Key 'MinimumPasswordLength' -Value '14'

        Get-SecurityPolicyValue -CfgPath $cfgPath -Key 'MinimumPasswordLength' | Should -Be '14'
    }

    It 'inserts a missing key under [System Access]' {
        $cfgPath = Join-Path $TestDrive 'policy4.cfg'
        Set-Content -Path $cfgPath -Encoding Unicode -Value @('[System Access]', 'PasswordComplexity = 0', '[Event Audit]', 'AuditSystemEvents = 0')

        Set-SecurityPolicyValue -CfgPath $cfgPath -Key 'MinimumPasswordLength' -Value '14'

        Get-SecurityPolicyValue -CfgPath $cfgPath -Key 'MinimumPasswordLength' | Should -Be '14'
        (Get-Content -Path $cfgPath -Encoding Unicode) | Should -Contain 'AuditSystemEvents = 0'
    }

    It 'throws if the cfg has no [System Access] section and the key is missing' {
        $cfgPath = Join-Path $TestDrive 'policy5.cfg'
        Set-Content -Path $cfgPath -Encoding Unicode -Value @('[Event Audit]', 'AuditSystemEvents = 0')

        { Set-SecurityPolicyValue -CfgPath $cfgPath -Key 'MinimumPasswordLength' -Value '14' } | Should -Throw
    }
}

Describe 'Invoke-SecEditExport / Invoke-SecEditConfigure' {
    BeforeAll {
        Import-Module "$PSScriptRoot/../../Common/SecEdit.psm1" -Force
    }

    It 'Invoke-SecEditExport calls the secedit binary wrapper with /export and the cfg path' {
        Mock -ModuleName SecEdit -CommandName Invoke-SecEditBinary { }
        Invoke-SecEditExport -CfgPath 'C:\temp\policy.cfg'
        Should -Invoke -ModuleName SecEdit -CommandName Invoke-SecEditBinary -ParameterFilter {
            $Arguments -contains '/export' -and $Arguments -contains 'C:\temp\policy.cfg'
        } -Times 1
    }

    It 'Invoke-SecEditConfigure calls the secedit binary wrapper with /configure and /areas SECURITYPOLICY' {
        Mock -ModuleName SecEdit -CommandName Invoke-SecEditBinary { }
        Invoke-SecEditConfigure -CfgPath 'C:\temp\policy.cfg'
        Should -Invoke -ModuleName SecEdit -CommandName Invoke-SecEditBinary -ParameterFilter {
            $Arguments -contains '/configure' -and $Arguments -contains 'SECURITYPOLICY'
        } -Times 1
    }
}
