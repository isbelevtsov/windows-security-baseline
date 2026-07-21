# Tests/Modules/BitLocker.Tests.ps1
BeforeAll {
    Import-Module "$PSScriptRoot/../../Modules/BitLocker.psm1" -Force

    # Set SystemDrive for cross-platform testing
    $env:SystemDrive = 'C:'

    function New-TestConfig {
        @{
            EncryptionMethod = @{ Value = 'XtsAes256'; Description = 'method' }
            RecoveryKeyPath  = @{ Value = (Join-Path $TestDrive 'RecoveryKeys'); Description = 'key path' }
        }
    }
}

Describe 'Test-BitLockerBaseline' {
    It 'passes when protection status is On' {
        Mock -ModuleName BitLocker -CommandName Get-OsDriveBitLockerVolume { [PSCustomObject]@{ ProtectionStatus = 'On' } }
        (Test-BitLockerBaseline -Config (New-TestConfig))[0].Pass | Should -BeTrue
    }

    It 'fails when protection status is Off' {
        Mock -ModuleName BitLocker -CommandName Get-OsDriveBitLockerVolume { [PSCustomObject]@{ ProtectionStatus = 'Off' } }
        (Test-BitLockerBaseline -Config (New-TestConfig))[0].Pass | Should -BeFalse
    }

    It 'fails without throwing when BitLocker is unavailable on this SKU' {
        Mock -ModuleName BitLocker -CommandName Get-OsDriveBitLockerVolume { throw 'BitLocker is not available on this device.' }
        { Test-BitLockerBaseline -Config (New-TestConfig) } | Should -Not -Throw
        (Test-BitLockerBaseline -Config (New-TestConfig))[0].Pass | Should -BeFalse
    }
}

Describe 'Set-BitLockerBaseline' {
    It 'attempts to enable encryption and saves the recovery key when not yet protected' {
        Mock -ModuleName BitLocker -CommandName Get-OsDriveBitLockerVolume { [PSCustomObject]@{ ProtectionStatus = 'Off' } }
        Mock -ModuleName BitLocker -CommandName Enable-OsDriveBitLocker { }
        Mock -ModuleName BitLocker -CommandName Get-OsDriveRecoveryKey { 'AAAA-1111-BBBB-2222' }

        $changes = Set-BitLockerBaseline -Config (New-TestConfig)

        $changes[0].Changed | Should -BeTrue
        Should -Invoke -ModuleName BitLocker -CommandName Enable-OsDriveBitLocker -Times 1
        $keyFiles = Get-ChildItem -Path (Join-Path $TestDrive 'RecoveryKeys') -Filter '*.txt'
        $keyFiles.Count | Should -Be 1
        Get-Content -Path $keyFiles[0].FullName | Should -Be 'AAAA-1111-BBBB-2222'
    }

    It 'includes a Note warning about the plaintext recovery key when a key is written' {
        Mock -ModuleName BitLocker -CommandName Get-OsDriveBitLockerVolume { [PSCustomObject]@{ ProtectionStatus = 'Off' } }
        Mock -ModuleName BitLocker -CommandName Enable-OsDriveBitLocker { }
        Mock -ModuleName BitLocker -CommandName Get-OsDriveRecoveryKey { 'AAAA-1111-BBBB-2222' }

        $changes = Set-BitLockerBaseline -Config (New-TestConfig)

        $changes[0].Note | Should -Not -BeNullOrEmpty
        $changes[0].Note | Should -Match 'plaintext'
        $changes[0].Note | Should -Match ([regex]::Escape((Join-Path $TestDrive 'RecoveryKeys')))
    }

    It 'does nothing when already protected' {
        Mock -ModuleName BitLocker -CommandName Get-OsDriveBitLockerVolume { [PSCustomObject]@{ ProtectionStatus = 'On' } }
        Mock -ModuleName BitLocker -CommandName Enable-OsDriveBitLocker { }

        $changes = Set-BitLockerBaseline -Config (New-TestConfig)

        $changes[0].Changed | Should -BeFalse
        Should -Invoke -ModuleName BitLocker -CommandName Enable-OsDriveBitLocker -Times 0
        $changes[0].Note | Should -BeNullOrEmpty
    }
}

Describe 'Restore-BitLockerSettings' {
    It 'skips restoring by default' {
        Mock -ModuleName BitLocker -CommandName Disable-OsDriveBitLocker { }
        $backupPath = Join-Path $TestDrive 'BitLockerBackupSkip'
        New-Item -Path $backupPath -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $backupPath 'bitlocker-state.json') -Value (@{ ProtectionStatus = 'Off' } | ConvertTo-Json)

        $result = Restore-BitLockerSettings -BackupPath $backupPath

        $result.Restored | Should -BeFalse
        Should -Invoke -ModuleName BitLocker -CommandName Disable-OsDriveBitLocker -Times 0
    }

    It 'decrypts when -DecryptOnRestore is passed and the backup shows protection was Off' {
        Mock -ModuleName BitLocker -CommandName Disable-OsDriveBitLocker { }
        $backupPath = Join-Path $TestDrive 'BitLockerBackupDecrypt'
        New-Item -Path $backupPath -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $backupPath 'bitlocker-state.json') -Value (@{ ProtectionStatus = 'Off' } | ConvertTo-Json)

        $result = Restore-BitLockerSettings -BackupPath $backupPath -DecryptOnRestore

        $result.Restored | Should -BeTrue
        Should -Invoke -ModuleName BitLocker -CommandName Disable-OsDriveBitLocker -Times 1
    }
}
