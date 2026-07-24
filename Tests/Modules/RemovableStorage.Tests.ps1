# Tests/Modules/RemovableStorage.Tests.ps1
BeforeAll {
    Import-Module "$PSScriptRoot/../../Modules/RemovableStorage.psm1" -Force

    function New-TestConfig {
        @{
            DenyAllAccess = @{ Value = $true; Description = 'deny all removable storage access' }
        }
    }
}

Describe 'Test-RemovableStorageBaseline' {
    It 'flags removable storage access as non-compliant when not denied' {
        Mock -ModuleName RemovableStorage -CommandName Get-RegistryDwordOrDefault { param($Path, $Name, $Default) 0 }

        $results = Test-RemovableStorageBaseline -Config (New-TestConfig)

        $results[0].Pass | Should -BeFalse
    }

    It 'passes when removable storage access is already denied' {
        Mock -ModuleName RemovableStorage -CommandName Get-RegistryDwordOrDefault { param($Path, $Name, $Default) 1 }

        $results = Test-RemovableStorageBaseline -Config (New-TestConfig)

        $results[0].Pass | Should -BeTrue
    }
}

Describe 'Set-RemovableStorageBaseline' {
    It 'sets Deny_All when not yet compliant' {
        Mock -ModuleName RemovableStorage -CommandName Get-RegistryDwordOrDefault { param($Path, $Name, $Default) 0 }
        Mock -ModuleName RemovableStorage -CommandName Set-RegistryDword { }

        $changes = Set-RemovableStorageBaseline -Config (New-TestConfig)

        $changes[0].Changed | Should -BeTrue
        Should -Invoke -ModuleName RemovableStorage -CommandName Set-RegistryDword -Times 1 -ParameterFilter { $Name -eq 'Deny_All' -and $Value -eq 1 }
    }

    It 'does nothing when already compliant' {
        Mock -ModuleName RemovableStorage -CommandName Get-RegistryDwordOrDefault { param($Path, $Name, $Default) 1 }
        Mock -ModuleName RemovableStorage -CommandName Set-RegistryDword { }

        $changes = Set-RemovableStorageBaseline -Config (New-TestConfig)

        $changes[0].Changed | Should -BeFalse
        Should -Invoke -ModuleName RemovableStorage -CommandName Set-RegistryDword -Times 0
    }
}

Describe 'Backup-RemovableStorageSettings / Restore-RemovableStorageSettings' {
    It 'removes Deny_All on restore when it did not exist at backup time' {
        Mock -ModuleName RemovableStorage -CommandName Test-RegistryValueExists { $false }
        Mock -ModuleName RemovableStorage -CommandName Get-RegistryDwordOrDefault { param($Path, $Name, $Default) $Default }

        $backupPath = Join-Path $TestDrive 'RemovableStorage'
        Backup-RemovableStorageSettings -BackupPath $backupPath

        Mock -ModuleName RemovableStorage -CommandName Set-RegistryDword { }
        Mock -ModuleName RemovableStorage -CommandName Remove-RegistryValue { }

        Restore-RemovableStorageSettings -BackupPath $backupPath

        Should -Invoke -ModuleName RemovableStorage -CommandName Remove-RegistryValue -Times 1 -ParameterFilter { $Name -eq 'Deny_All' }
        Should -Invoke -ModuleName RemovableStorage -CommandName Set-RegistryDword -Times 0
    }

    It 'restores the exact backed-up value when it existed' {
        Mock -ModuleName RemovableStorage -CommandName Test-RegistryValueExists { $true }
        Mock -ModuleName RemovableStorage -CommandName Get-RegistryDwordOrDefault { param($Path, $Name, $Default) 1 }

        $backupPath = Join-Path $TestDrive 'RemovableStorageExisting'
        Backup-RemovableStorageSettings -BackupPath $backupPath

        Mock -ModuleName RemovableStorage -CommandName Set-RegistryDword { }
        Mock -ModuleName RemovableStorage -CommandName Remove-RegistryValue { }

        Restore-RemovableStorageSettings -BackupPath $backupPath

        Should -Invoke -ModuleName RemovableStorage -CommandName Set-RegistryDword -Times 1 -ParameterFilter { $Name -eq 'Deny_All' -and $Value -eq 1 }
    }

    It 'throws when restoring without a prior backup' {
        { Restore-RemovableStorageSettings -BackupPath (Join-Path $TestDrive 'missing') } | Should -Throw
    }
}
