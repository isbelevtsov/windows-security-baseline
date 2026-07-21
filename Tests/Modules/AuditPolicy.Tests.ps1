BeforeAll {
    Import-Module "$PSScriptRoot/../../Modules/AuditPolicy.psm1" -Force

    function New-TestConfig {
        @{
            Categories = @{
                Value       = @{ 'Logon' = 'SuccessAndFailure'; 'Logoff' = 'Success' }
                Description = 'subcategories'
            }
        }
    }
}

Describe 'Test-AuditPolicyBaseline' {
    It 'flags subcategories that do not match the config' {
        Mock -ModuleName AuditPolicy -CommandName Get-AuditSubcategorySetting {
            param($Subcategory)
            switch ($Subcategory) {
                'Logon'  { 'NoAuditing' }
                'Logoff' { 'Success' }
            }
        }

        $results = Test-AuditPolicyBaseline -Config (New-TestConfig)

        ($results | Where-Object Setting -eq 'Logon').Pass | Should -BeFalse
        ($results | Where-Object Setting -eq 'Logoff').Pass | Should -BeTrue
    }
}

Describe 'Set-AuditPolicyBaseline' {
    It 'only sets subcategories that differ from config' {
        Mock -ModuleName AuditPolicy -CommandName Get-AuditSubcategorySetting {
            param($Subcategory)
            switch ($Subcategory) {
                'Logon'  { 'NoAuditing' }
                'Logoff' { 'Success' }
            }
        }
        Mock -ModuleName AuditPolicy -CommandName Set-AuditSubcategorySetting { }

        $changes = Set-AuditPolicyBaseline -Config (New-TestConfig)

        ($changes | Where-Object Setting -eq 'Logon').Changed | Should -BeTrue
        ($changes | Where-Object Setting -eq 'Logoff').Changed | Should -BeFalse
        Should -Invoke -ModuleName AuditPolicy -CommandName Set-AuditSubcategorySetting -Times 1 -ParameterFilter { $Subcategory -eq 'Logon' }
    }
}

Describe 'ConvertTo-AuditPolFlags' {
    It 'converts Success to enable/disable' {
        InModuleScope -ModuleName AuditPolicy {
            $result = ConvertTo-AuditPolFlags -Outcome 'Success'
            $result.Success | Should -Be 'enable'
            $result.Failure | Should -Be 'disable'
        }
    }

    It 'converts Failure to disable/enable' {
        InModuleScope -ModuleName AuditPolicy {
            $result = ConvertTo-AuditPolFlags -Outcome 'Failure'
            $result.Success | Should -Be 'disable'
            $result.Failure | Should -Be 'enable'
        }
    }

    It 'converts SuccessAndFailure to enable/enable' {
        InModuleScope -ModuleName AuditPolicy {
            $result = ConvertTo-AuditPolFlags -Outcome 'SuccessAndFailure'
            $result.Success | Should -Be 'enable'
            $result.Failure | Should -Be 'enable'
        }
    }

    It 'converts NoAuditing to disable/disable' {
        InModuleScope -ModuleName AuditPolicy {
            $result = ConvertTo-AuditPolFlags -Outcome 'NoAuditing'
            $result.Success | Should -Be 'disable'
            $result.Failure | Should -Be 'disable'
        }
    }
}

Describe 'Get-AuditSubcategorySetting' {
    It 'parses "Success and Failure" to SuccessAndFailure' {
        InModuleScope -ModuleName AuditPolicy {
            Mock -CommandName Invoke-AuditPolBinary {
                @(
                    'Machine Name,Policy Target,Subcategory,Subcategory GUID,Inclusion Setting,Exclusion Setting'
                    'HOST,System,Logon,{guid},Success and Failure,'
                )
            }

            $result = Get-AuditSubcategorySetting -Subcategory 'Logon'
            $result | Should -Be 'SuccessAndFailure'
        }
    }

    It 'parses "Success" to Success' {
        InModuleScope -ModuleName AuditPolicy {
            Mock -CommandName Invoke-AuditPolBinary {
                @(
                    'Machine Name,Policy Target,Subcategory,Subcategory GUID,Inclusion Setting,Exclusion Setting'
                    'HOST,System,Logon,{guid},Success,'
                )
            }

            $result = Get-AuditSubcategorySetting -Subcategory 'Logon'
            $result | Should -Be 'Success'
        }
    }

    It 'parses "Failure" to Failure' {
        InModuleScope -ModuleName AuditPolicy {
            Mock -CommandName Invoke-AuditPolBinary {
                @(
                    'Machine Name,Policy Target,Subcategory,Subcategory GUID,Inclusion Setting,Exclusion Setting'
                    'HOST,System,Logon,{guid},Failure,'
                )
            }

            $result = Get-AuditSubcategorySetting -Subcategory 'Logon'
            $result | Should -Be 'Failure'
        }
    }

    It 'defaults unrecognized setting to NoAuditing' {
        InModuleScope -ModuleName AuditPolicy {
            Mock -CommandName Invoke-AuditPolBinary {
                @(
                    'Machine Name,Policy Target,Subcategory,Subcategory GUID,Inclusion Setting,Exclusion Setting'
                    'HOST,System,Logon,{guid},UnknownSetting,'
                )
            }

            $result = Get-AuditSubcategorySetting -Subcategory 'Logon'
            $result | Should -Be 'NoAuditing'
        }
    }
}

Describe 'Backup-AuditPolicySettings / Restore-AuditPolicySettings' {
    It 'backs up via the native auditpol /backup flag' {
        Mock -ModuleName AuditPolicy -CommandName Invoke-AuditPolBinary { }
        $backupPath = Join-Path $TestDrive 'AuditPolicy'

        $csvPath = Backup-AuditPolicySettings -BackupPath $backupPath

        $csvPath | Should -Be (Join-Path $backupPath 'audit-policy.csv')
        Should -Invoke -ModuleName AuditPolicy -CommandName Invoke-AuditPolBinary -ParameterFilter {
            $Arguments -contains '/backup'
        } -Times 1
    }

    It 'restores via the native auditpol /restore flag' {
        Mock -ModuleName AuditPolicy -CommandName Invoke-AuditPolBinary { }
        $backupPath = Join-Path $TestDrive 'RestoreAuditPolicy'
        New-Item -Path $backupPath -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $backupPath 'audit-policy.csv') -Value 'placeholder'

        Restore-AuditPolicySettings -BackupPath $backupPath

        Should -Invoke -ModuleName AuditPolicy -CommandName Invoke-AuditPolBinary -ParameterFilter {
            $Arguments -contains '/restore'
        } -Times 1
    }

    It 'throws when restoring without a prior backup' {
        { Restore-AuditPolicySettings -BackupPath (Join-Path $TestDrive 'missing') } | Should -Throw
    }
}
