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

Describe 'Enable-OsDriveBitLocker' {
    BeforeEach {
        # Mocked so every existing test in this Describe doesn't invoke the
        # real Resume-BitLocker cmdlet against this machine's actual system
        # drive - tests that specifically care about this call mock/assert
        # it themselves below.
        Mock -ModuleName BitLocker -CommandName Resume-OsDriveBitLocker { }
    }

    It 'activates with RecoveryPasswordProtector only, without attempting to add a TPM protector, when a TPM protector already exists' {
        # Regression test for a real Windows 11 Pro failure: requesting -TpmProtector
        # when one already exists throws "Only one key protector of this type is
        # allowed for this drive" via a non-terminating Write-Error that a plain
        # try/catch never sees - so this path must never even attempt it.
        Mock -ModuleName BitLocker -CommandName Get-OsDriveBitLockerVolume {
            [PSCustomObject]@{ KeyProtector = @([PSCustomObject]@{ KeyProtectorType = 'Tpm' }) }
        }
        Mock -ModuleName BitLocker -CommandName Invoke-EnableBitLockerWithTpmProtector { }
        Mock -ModuleName BitLocker -CommandName Invoke-EnableBitLockerWithRecoveryPasswordProtector { }
        Mock -ModuleName BitLocker -CommandName Add-OsDriveRecoveryPasswordProtector { }

        $result = InModuleScope -ModuleName BitLocker { Enable-OsDriveBitLocker -EncryptionMethod 'XtsAes256' }

        $result | Should -BeTrue
        Should -Invoke -ModuleName BitLocker -CommandName Invoke-EnableBitLockerWithTpmProtector -Times 0
        Should -Invoke -ModuleName BitLocker -CommandName Invoke-EnableBitLockerWithRecoveryPasswordProtector -Times 1
    }

    It 'adds a fresh TPM protector plus a recovery password protector when no protectors exist yet' {
        Mock -ModuleName BitLocker -CommandName Get-OsDriveBitLockerVolume {
            [PSCustomObject]@{ KeyProtector = @() }
        }
        Mock -ModuleName BitLocker -CommandName Invoke-EnableBitLockerWithTpmProtector { }
        Mock -ModuleName BitLocker -CommandName Add-OsDriveRecoveryPasswordProtector { }
        Mock -ModuleName BitLocker -CommandName Invoke-EnableBitLockerWithRecoveryPasswordProtector { }

        $result = InModuleScope -ModuleName BitLocker { Enable-OsDriveBitLocker -EncryptionMethod 'XtsAes256' }

        $result | Should -BeTrue
        Should -Invoke -ModuleName BitLocker -CommandName Invoke-EnableBitLockerWithTpmProtector -Times 1
        Should -Invoke -ModuleName BitLocker -CommandName Add-OsDriveRecoveryPasswordProtector -Times 1
        Should -Invoke -ModuleName BitLocker -CommandName Invoke-EnableBitLockerWithRecoveryPasswordProtector -Times 0
    }

    It 'falls back to RecoveryPasswordProtector-only when adding a fresh TPM protector throws' {
        Mock -ModuleName BitLocker -CommandName Get-OsDriveBitLockerVolume {
            [PSCustomObject]@{ KeyProtector = @() }
        }
        Mock -ModuleName BitLocker -CommandName Invoke-EnableBitLockerWithTpmProtector { throw 'no usable TPM' }
        Mock -ModuleName BitLocker -CommandName Invoke-EnableBitLockerWithRecoveryPasswordProtector { }

        $result = InModuleScope -ModuleName BitLocker { Enable-OsDriveBitLocker -EncryptionMethod 'XtsAes256' }

        $result | Should -BeFalse
        Should -Invoke -ModuleName BitLocker -CommandName Invoke-EnableBitLockerWithRecoveryPasswordProtector -Times 1
    }

    It 'falls back to omitting -EncryptionMethod when a TPM protector already exists and specifying it throws' {
        # Regression test for a real Windows 11 Pro failure: on a volume that
        # already has a TPM protector, Enable-BitLocker -EncryptionMethod ...
        # -RecoveryPasswordProtector threw "Value does not fall within the
        # expected range." (an enum-validation error from the cmdletization
        # layer) - this branch was also completely unguarded by try/catch, so
        # the exception propagated all the way out of Enable-OsDriveBitLocker.
        Mock -ModuleName BitLocker -CommandName Get-OsDriveBitLockerVolume {
            [PSCustomObject]@{ KeyProtector = @([PSCustomObject]@{ KeyProtectorType = 'Tpm' }) }
        }
        Mock -ModuleName BitLocker -CommandName Invoke-EnableBitLockerWithRecoveryPasswordProtector { throw 'Value does not fall within the expected range.' }
        Mock -ModuleName BitLocker -CommandName Invoke-EnableBitLockerWithRecoveryPasswordProtectorOnly { }

        $result = InModuleScope -ModuleName BitLocker { Enable-OsDriveBitLocker -EncryptionMethod 'XtsAes256' }

        $result | Should -BeTrue
        Should -Invoke -ModuleName BitLocker -CommandName Invoke-EnableBitLockerWithRecoveryPasswordProtectorOnly -Times 1
    }

    It 'falls back to omitting -EncryptionMethod when both the fresh-TPM and with-method recovery attempts throw' {
        Mock -ModuleName BitLocker -CommandName Get-OsDriveBitLockerVolume {
            [PSCustomObject]@{ KeyProtector = @() }
        }
        Mock -ModuleName BitLocker -CommandName Invoke-EnableBitLockerWithTpmProtector { throw 'no usable TPM' }
        Mock -ModuleName BitLocker -CommandName Invoke-EnableBitLockerWithRecoveryPasswordProtector { throw 'Value does not fall within the expected range.' }
        Mock -ModuleName BitLocker -CommandName Invoke-EnableBitLockerWithRecoveryPasswordProtectorOnly { }

        $result = InModuleScope -ModuleName BitLocker { Enable-OsDriveBitLocker -EncryptionMethod 'XtsAes256' }

        $result | Should -BeFalse
        Should -Invoke -ModuleName BitLocker -CommandName Invoke-EnableBitLockerWithRecoveryPasswordProtectorOnly -Times 1
    }

    It 'does not add a duplicate recovery password protector when the with-method call throws after already committing one' {
        # Regression test for a real bug found on a volume where Windows had
        # already started "Device Encryption" automatically: the BitLocker-API
        # event log showed the recovery password protector was created
        # successfully, but Invoke-EnableBitLockerWithRecoveryPasswordProtector
        # still raised a terminating error (EncryptionMethod conflicting with
        # the in-progress conversion). The old code blindly retried on any
        # throw, adding a second, untracked recovery password protector.
        Mock -ModuleName BitLocker -CommandName Get-OsDriveBitLockerVolume {
            [PSCustomObject]@{ KeyProtector = @([PSCustomObject]@{ KeyProtectorType = 'RecoveryPassword' }) }
        }
        Mock -ModuleName BitLocker -CommandName Invoke-EnableBitLockerWithTpmProtector { throw 'no usable TPM' }
        Mock -ModuleName BitLocker -CommandName Invoke-EnableBitLockerWithRecoveryPasswordProtector { throw 'Value does not fall within the expected range.' }
        Mock -ModuleName BitLocker -CommandName Invoke-EnableBitLockerWithRecoveryPasswordProtectorOnly { }

        $result = InModuleScope -ModuleName BitLocker { Enable-OsDriveBitLocker -EncryptionMethod 'XtsAes256' }

        $result | Should -BeFalse
        Should -Invoke -ModuleName BitLocker -CommandName Invoke-EnableBitLockerWithRecoveryPasswordProtectorOnly -Times 0
    }

    It 'does not add a duplicate recovery password protector when the TPM-already-present with-method call throws after already committing one' {
        Mock -ModuleName BitLocker -CommandName Get-OsDriveBitLockerVolume {
            [PSCustomObject]@{ KeyProtector = @([PSCustomObject]@{ KeyProtectorType = 'Tpm' }, [PSCustomObject]@{ KeyProtectorType = 'RecoveryPassword' }) }
        }
        Mock -ModuleName BitLocker -CommandName Invoke-EnableBitLockerWithRecoveryPasswordProtector { throw 'Value does not fall within the expected range.' }
        Mock -ModuleName BitLocker -CommandName Invoke-EnableBitLockerWithRecoveryPasswordProtectorOnly { }

        $result = InModuleScope -ModuleName BitLocker { Enable-OsDriveBitLocker -EncryptionMethod 'XtsAes256' }

        $result | Should -BeTrue
        Should -Invoke -ModuleName BitLocker -CommandName Invoke-EnableBitLockerWithRecoveryPasswordProtectorOnly -Times 0
    }

    It 'does not add a duplicate recovery password protector when the fresh-TPM call itself already committed one before throwing' {
        Mock -ModuleName BitLocker -CommandName Get-OsDriveBitLockerVolume {
            [PSCustomObject]@{ KeyProtector = @([PSCustomObject]@{ KeyProtectorType = 'RecoveryPassword' }) }
        }
        Mock -ModuleName BitLocker -CommandName Invoke-EnableBitLockerWithTpmProtector { throw 'no usable TPM' }
        Mock -ModuleName BitLocker -CommandName Invoke-EnableBitLockerWithRecoveryPasswordProtector { }
        Mock -ModuleName BitLocker -CommandName Invoke-EnableBitLockerWithRecoveryPasswordProtectorOnly { }

        $result = InModuleScope -ModuleName BitLocker { Enable-OsDriveBitLocker -EncryptionMethod 'XtsAes256' }

        $result | Should -BeFalse
        Should -Invoke -ModuleName BitLocker -CommandName Invoke-EnableBitLockerWithRecoveryPasswordProtector -Times 0
        Should -Invoke -ModuleName BitLocker -CommandName Invoke-EnableBitLockerWithRecoveryPasswordProtectorOnly -Times 0
    }

    It 'does not add a redundant recovery password protector when the fresh-TPM call succeeds but already carried one along' {
        Mock -ModuleName BitLocker -CommandName Get-OsDriveBitLockerVolume {
            [PSCustomObject]@{ KeyProtector = @([PSCustomObject]@{ KeyProtectorType = 'RecoveryPassword' }) }
        }
        Mock -ModuleName BitLocker -CommandName Invoke-EnableBitLockerWithTpmProtector { }
        Mock -ModuleName BitLocker -CommandName Add-OsDriveRecoveryPasswordProtector { }

        $result = InModuleScope -ModuleName BitLocker { Enable-OsDriveBitLocker -EncryptionMethod 'XtsAes256' }

        $result | Should -BeTrue
        Should -Invoke -ModuleName BitLocker -CommandName Add-OsDriveRecoveryPasswordProtector -Times 0
    }

    It 'attempts to resume BitLocker protection after configuring protectors' {
        # Regression test for a real finding: a volume can sit at 100%
        # encrypted with valid TPM + recovery password protectors and still
        # show ProtectionStatus "Off" - manage-bde's text output doesn't
        # distinguish a suspended protection state from one that was never
        # activated, but Resume-BitLocker immediately flipped it to "On" on
        # real hardware. This must be attempted every time, regardless of
        # which protector path was taken.
        Mock -ModuleName BitLocker -CommandName Get-OsDriveBitLockerVolume {
            [PSCustomObject]@{ KeyProtector = @() }
        }
        Mock -ModuleName BitLocker -CommandName Invoke-EnableBitLockerWithTpmProtector { }
        Mock -ModuleName BitLocker -CommandName Add-OsDriveRecoveryPasswordProtector { }

        InModuleScope -ModuleName BitLocker { Enable-OsDriveBitLocker -EncryptionMethod 'XtsAes256' } | Out-Null

        Should -Invoke -ModuleName BitLocker -CommandName Resume-OsDriveBitLocker -Times 1
    }

    It 'does not propagate an error when Resume-BitLocker fails' {
        Mock -ModuleName BitLocker -CommandName Get-OsDriveBitLockerVolume {
            [PSCustomObject]@{ KeyProtector = @() }
        }
        Mock -ModuleName BitLocker -CommandName Invoke-EnableBitLockerWithTpmProtector { }
        Mock -ModuleName BitLocker -CommandName Add-OsDriveRecoveryPasswordProtector { }
        Mock -ModuleName BitLocker -CommandName Resume-OsDriveBitLocker { throw 'not in a resumable state' }

        { InModuleScope -ModuleName BitLocker { Enable-OsDriveBitLocker -EncryptionMethod 'XtsAes256' } } | Should -Not -Throw
    }
}

Describe 'Set-BitLockerBaseline' {
    It 'attempts to enable encryption and saves the recovery key when not yet protected' {
        Mock -ModuleName BitLocker -CommandName Get-OsDriveBitLockerVolume { [PSCustomObject]@{ ProtectionStatus = 'Off' } }
        Mock -ModuleName BitLocker -CommandName Enable-OsDriveBitLocker { $true }
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
        Mock -ModuleName BitLocker -CommandName Enable-OsDriveBitLocker { $true }
        Mock -ModuleName BitLocker -CommandName Get-OsDriveRecoveryKey { 'AAAA-1111-BBBB-2222' }

        $changes = Set-BitLockerBaseline -Config (New-TestConfig)

        $changes[0].Note | Should -Not -BeNullOrEmpty
        $changes[0].Note | Should -Match 'plaintext'
        $changes[0].Note | Should -Match ([regex]::Escape((Join-Path $TestDrive 'RecoveryKeys')))
    }

    It 'adds a Note about the missing TPM protector when Enable-OsDriveBitLocker falls back to recovery-password-only' {
        Mock -ModuleName BitLocker -CommandName Get-OsDriveBitLockerVolume { [PSCustomObject]@{ ProtectionStatus = 'Off' } }
        Mock -ModuleName BitLocker -CommandName Enable-OsDriveBitLocker { $false }
        Mock -ModuleName BitLocker -CommandName Get-OsDriveRecoveryKey { 'AAAA-1111-BBBB-2222' }

        $changes = Set-BitLockerBaseline -Config (New-TestConfig)

        $changes[0].Note | Should -Match 'TPM'
        $changes[0].Note | Should -Match 'plaintext'
    }

    It 'does nothing when already protected' {
        Mock -ModuleName BitLocker -CommandName Get-OsDriveBitLockerVolume { [PSCustomObject]@{ ProtectionStatus = 'On' } }
        Mock -ModuleName BitLocker -CommandName Enable-OsDriveBitLocker { }

        $changes = Set-BitLockerBaseline -Config (New-TestConfig)

        $changes[0].Changed | Should -BeFalse
        Should -Invoke -ModuleName BitLocker -CommandName Enable-OsDriveBitLocker -Times 0
        $changes[0].Note | Should -BeNullOrEmpty
    }

    It 'attaches the recovery key as a highlightable Secret when one is written' {
        Mock -ModuleName BitLocker -CommandName Get-OsDriveBitLockerVolume { [PSCustomObject]@{ ProtectionStatus = 'Off' } }
        Mock -ModuleName BitLocker -CommandName Enable-OsDriveBitLocker { $true }
        Mock -ModuleName BitLocker -CommandName Get-OsDriveRecoveryKey { 'AAAA-1111-BBBB-2222' }

        $changes = Set-BitLockerBaseline -Config (New-TestConfig)

        $changes[0].Secret | Should -Be 'AAAA-1111-BBBB-2222'
        $changes[0].SecretLabel | Should -Match 'recovery key'
    }

    It 'does not attach a Secret when already protected' {
        Mock -ModuleName BitLocker -CommandName Get-OsDriveBitLockerVolume { [PSCustomObject]@{ ProtectionStatus = 'On' } }
        Mock -ModuleName BitLocker -CommandName Enable-OsDriveBitLocker { }

        $changes = Set-BitLockerBaseline -Config (New-TestConfig)

        $changes[0].Secret | Should -BeNullOrEmpty
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
