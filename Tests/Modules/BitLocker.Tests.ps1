# Tests/Modules/BitLocker.Tests.ps1
BeforeAll {
    # Stand-in stub, same pattern Tests/Common/Orchestrator.Tests.ps1 uses
    # for the per-area functions it mocks. Without it, mocking the real
    # Enable-BitLocker cmdlet below forces PowerShell's command-auto-load
    # to import the actual Windows "BitLocker" module to resolve it - which
    # happens to share the exact same name as this project's own
    # Modules/BitLocker.psm1, so Pester then finds two distinct modules
    # both named "BitLocker" and refuses to pick one for InModuleScope.
    # Pre-defining the stub means the command already resolves without
    # ever needing to auto-load the real module.
    function global:Enable-BitLocker {
        param(
            [string]$MountPoint,
            [string]$EncryptionMethod,
            [switch]$TpmProtector,
            [switch]$RecoveryPasswordProtector,
            [switch]$SkipHardwareTest,
            [switch]$UsedSpaceOnly
        )
    }

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

Describe 'Invoke-EnableBitLockerWith* wrapper functions' {
    It 'passes -UsedSpaceOnly on every Enable-BitLocker call' {
        # Regression test for a real failure on Windows hardware (a QEMU
        # VM's thin-provisioned virtual disk): Enable-BitLocker defaults to
        # full-volume encryption unless -UsedSpaceOnly is passed, which
        # thin-provisioned storage rejects outright with "BitLocker Drive
        # Encryption only supports Used Space Only encryption on thin
        # provisioned storage" (HRESULT 0x803100A5). This went unnoticed
        # for a long time because Windows' own automatic Device Encryption
        # had already started the volume as Used Space Only before this
        # module ever needed to decide - it only surfaced once the volume
        # was fully decrypted and Enable-BitLocker had to start completely
        # fresh.
        InModuleScope -ModuleName BitLocker {
            Mock -CommandName Enable-BitLocker { }

            Invoke-EnableBitLockerWithTpmProtector -EncryptionMethod 'XtsAes256'
            Invoke-EnableBitLockerWithRecoveryPasswordProtector -EncryptionMethod 'XtsAes256'
            Invoke-EnableBitLockerWithRecoveryPasswordProtectorOnly

            Should -Invoke -CommandName Enable-BitLocker -Times 3 -ParameterFilter { $UsedSpaceOnly -eq $true }
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
        Mock -ModuleName BitLocker -CommandName Get-OsDriveBitLockerVolume { [PSCustomObject]@{ VolumeStatus = 'FullyEncrypted' } }
        $backupPath = Join-Path $TestDrive 'BitLockerBackupDecrypt'
        New-Item -Path $backupPath -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $backupPath 'bitlocker-state.json') -Value (@{ ProtectionStatus = 'Off' } | ConvertTo-Json)

        $result = Restore-BitLockerSettings -BackupPath $backupPath -DecryptOnRestore

        $result.Restored | Should -BeTrue
        Should -Invoke -ModuleName BitLocker -CommandName Disable-OsDriveBitLocker -Times 1
    }

    It 'does not call Disable-BitLocker again when the volume is already decrypting' {
        # Regression test for a real error on Windows hardware: calling
        # Disable-BitLocker on a volume that's already decrypting (e.g.
        # from an earlier -DecryptOnRestore run) throws "BitLocker Drive
        # Encryption is not enabled on this drive" - harmless in effect,
        # but a needless scary error on a repeated restore.
        Mock -ModuleName BitLocker -CommandName Disable-OsDriveBitLocker { }
        Mock -ModuleName BitLocker -CommandName Get-OsDriveBitLockerVolume { [PSCustomObject]@{ VolumeStatus = 'DecryptionInProgress' } }
        $backupPath = Join-Path $TestDrive 'BitLockerBackupAlreadyDecrypting'
        New-Item -Path $backupPath -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $backupPath 'bitlocker-state.json') -Value (@{ ProtectionStatus = 'Off' } | ConvertTo-Json)

        $result = Restore-BitLockerSettings -BackupPath $backupPath -DecryptOnRestore

        $result.Restored | Should -BeTrue
        Should -Invoke -ModuleName BitLocker -CommandName Disable-OsDriveBitLocker -Times 0
    }

    It 'deletes the saved recovery key file once decryption succeeds' {
        Mock -ModuleName BitLocker -CommandName Disable-OsDriveBitLocker { }
        Mock -ModuleName BitLocker -CommandName Get-OsDriveBitLockerVolume { [PSCustomObject]@{ VolumeStatus = 'FullyEncrypted' } }
        $config = New-TestConfig
        New-Item -Path $config.RecoveryKeyPath.Value -ItemType Directory -Force | Out-Null
        $keyFile = Join-Path $config.RecoveryKeyPath.Value 'C-recovery-key.txt'
        Set-Content -Path $keyFile -Value 'some-recovery-key'
        $backupPath = Join-Path $TestDrive 'BitLockerBackupCleanup'
        New-Item -Path $backupPath -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $backupPath 'bitlocker-state.json') -Value (@{ ProtectionStatus = 'Off' } | ConvertTo-Json)

        $result = Restore-BitLockerSettings -BackupPath $backupPath -Config $config -DecryptOnRestore

        $result.Restored | Should -BeTrue
        Test-Path -Path $keyFile | Should -BeFalse
    }

    It 'keeps the saved recovery key file when decryption throws' {
        Mock -ModuleName BitLocker -CommandName Disable-OsDriveBitLocker { throw 'decryption failed' }
        Mock -ModuleName BitLocker -CommandName Get-OsDriveBitLockerVolume { [PSCustomObject]@{ VolumeStatus = 'FullyEncrypted' } }
        $config = New-TestConfig
        New-Item -Path $config.RecoveryKeyPath.Value -ItemType Directory -Force | Out-Null
        $keyFile = Join-Path $config.RecoveryKeyPath.Value 'C-recovery-key.txt'
        Set-Content -Path $keyFile -Value 'some-recovery-key'
        $backupPath = Join-Path $TestDrive 'BitLockerBackupCleanupFailure'
        New-Item -Path $backupPath -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $backupPath 'bitlocker-state.json') -Value (@{ ProtectionStatus = 'Off' } | ConvertTo-Json)

        { Restore-BitLockerSettings -BackupPath $backupPath -Config $config -DecryptOnRestore } | Should -Throw

        Test-Path -Path $keyFile | Should -BeTrue
    }

    It 'does not attempt cleanup when -Config is not supplied' {
        Mock -ModuleName BitLocker -CommandName Disable-OsDriveBitLocker { }
        Mock -ModuleName BitLocker -CommandName Get-OsDriveBitLockerVolume { [PSCustomObject]@{ VolumeStatus = 'FullyEncrypted' } }
        $backupPath = Join-Path $TestDrive 'BitLockerBackupNoConfig'
        New-Item -Path $backupPath -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $backupPath 'bitlocker-state.json') -Value (@{ ProtectionStatus = 'Off' } | ConvertTo-Json)

        { Restore-BitLockerSettings -BackupPath $backupPath -DecryptOnRestore } | Should -Not -Throw
    }
}
