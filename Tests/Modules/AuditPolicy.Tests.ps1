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
