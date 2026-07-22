Import-Module (Join-Path $PSScriptRoot '..\Common\Config.psm1') -Force

function Get-OsDriveBitLockerVolume {
    [CmdletBinding()]
    param()
    Get-BitLockerVolume -MountPoint $env:SystemDrive
}

function Invoke-EnableBitLockerWithTpmProtector {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$EncryptionMethod)
    Enable-BitLocker -MountPoint $env:SystemDrive -EncryptionMethod $EncryptionMethod -TpmProtector -SkipHardwareTest -ErrorAction Stop
}

function Invoke-EnableBitLockerWithRecoveryPasswordProtector {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$EncryptionMethod)
    Enable-BitLocker -MountPoint $env:SystemDrive -EncryptionMethod $EncryptionMethod -RecoveryPasswordProtector -SkipHardwareTest -ErrorAction Stop
}

function Add-OsDriveRecoveryPasswordProtector {
    [CmdletBinding()]
    param()
    Add-BitLockerKeyProtector -MountPoint $env:SystemDrive -RecoveryPasswordProtector -ErrorAction Stop
}

function Enable-OsDriveBitLocker {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$EncryptionMethod)

    # Windows commonly pre-stages a TPM key protector on the OS drive before
    # BitLocker is ever turned on (part of "Device Encryption" readiness).
    # Confirmed on real Windows 11 Pro hardware: requesting -TpmProtector again
    # in that state fails with "Only one key protector of this type is allowed
    # for this drive" - and critically, BitLocker.psm1 raises that via a
    # non-terminating Write-Error, not a normal exception, so a plain try/catch
    # never saw it and silently continued as if it had succeeded, while the
    # volume was actually left in "waiting for activation" with encryption
    # never started. Checking for an existing TPM protector first avoids ever
    # hitting that failure; -ErrorAction Stop on every call below ensures any
    # other failure is genuinely catchable.
    $existingProtectorTypes = @((Get-OsDriveBitLockerVolume).KeyProtector | Select-Object -ExpandProperty KeyProtectorType)

    if ($existingProtectorTypes -contains 'Tpm') {
        Invoke-EnableBitLockerWithRecoveryPasswordProtector -EncryptionMethod $EncryptionMethod | Out-Null
        return $true
    }

    try {
        Invoke-EnableBitLockerWithTpmProtector -EncryptionMethod $EncryptionMethod | Out-Null
        Add-OsDriveRecoveryPasswordProtector | Out-Null
        return $true
    }
    catch {
        Invoke-EnableBitLockerWithRecoveryPasswordProtector -EncryptionMethod $EncryptionMethod | Out-Null
        return $false
    }
}

function Disable-OsDriveBitLocker {
    [CmdletBinding()]
    param()
    Disable-BitLocker -MountPoint $env:SystemDrive
}

function Get-OsDriveRecoveryKey {
    [CmdletBinding()]
    param()
    $volume = Get-OsDriveBitLockerVolume
    $protector = $volume.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' } | Select-Object -First 1
    if ($protector) { return $protector.RecoveryPassword }
    return $null
}

function Test-BitLockerBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    try {
        $volume = Get-OsDriveBitLockerVolume
        $actual = ("$($volume.ProtectionStatus)" -eq 'On')
        $description = 'OS drive encryption status (BitLocker or Device Encryption).'
    }
    catch {
        $actual = $false
        $description = "BitLocker/Device Encryption is not available or not queryable on this device: $($_.Exception.Message)"
    }

    @(
        [PSCustomObject]@{
            Module = 'BitLocker'; Setting = 'OSDriveEncrypted'
            Expected = $true; Actual = $actual; Pass = $actual
            Description = $description
        }
    )
}

function Backup-BitLockerSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    New-Item -Path $BackupPath -ItemType Directory -Force | Out-Null
    $statePath = Join-Path -Path $BackupPath -ChildPath 'bitlocker-state.json'

    try {
        $volume = Get-OsDriveBitLockerVolume
        $state = [PSCustomObject]@{ ProtectionStatus = "$($volume.ProtectionStatus)" }
    }
    catch {
        $state = [PSCustomObject]@{ ProtectionStatus = 'Unavailable' }
    }

    $state | ConvertTo-Json | Set-Content -Path $statePath
    return $statePath
}

function Set-BitLockerBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $before = (Test-BitLockerBaseline -Config $Config)[0]
    $method = Get-BaselineValue -Section $Config -Name 'EncryptionMethod'
    $keyFolder = Get-BaselineValue -Section $Config -Name 'RecoveryKeyPath'

    $changed = $false
    $note = $null

    if (-not $before.Pass) {
        $tpmProtectorAdded = Enable-OsDriveBitLocker -EncryptionMethod $method

        if (-not (Test-Path -Path $keyFolder)) {
            New-Item -Path $keyFolder -ItemType Directory -Force | Out-Null
        }
        $recoveryKey = Get-OsDriveRecoveryKey
        if ($recoveryKey) {
            $safeName = $env:SystemDrive.Replace(':', '')
            $keyFile = Join-Path -Path $keyFolder -ChildPath "$safeName-recovery-key.txt"
            Set-Content -Path $keyFile -Value $recoveryKey
            $note = "Recovery key written in plaintext to '$keyFile' - secure or relocate it."
        }

        if (-not $tpmProtectorAdded) {
            $tpmNote = 'Only a recovery-password protector could be added (no usable TPM protector found) - BitLocker may remain in a not-fully-protected state until a protector capable of automatic unlock is configured, or after a restart.'
            $note = $(if ($note) { "$note $tpmNote" } else { $tpmNote })
        }

        $changed = $true
    }

    @(
        [PSCustomObject]@{
            Module  = 'BitLocker'
            Setting = 'OSDriveEncrypted'
            Before  = $before.Actual
            After   = $(if ($changed) { $true } else { $before.Actual })
            Changed = $changed
            Note    = $note
        }
    )
}

function Restore-BitLockerSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BackupPath,
        [switch]$DecryptOnRestore
    )

    if (-not $DecryptOnRestore) {
        return [PSCustomObject]@{
            Module   = 'BitLocker'
            Setting  = 'OSDriveEncrypted'
            Restored = $false
            Reason   = 'BitLocker restore skipped (pass -DecryptOnRestore to include it).'
        }
    }

    $statePath = Join-Path -Path $BackupPath -ChildPath 'bitlocker-state.json'
    if (-not (Test-Path -Path $statePath)) {
        throw "No BitLocker backup found at '$statePath'."
    }
    $saved = Get-Content -Path $statePath -Raw | ConvertFrom-Json

    if ($saved.ProtectionStatus -ne 'On') {
        Disable-OsDriveBitLocker
    }

    return [PSCustomObject]@{ Module = 'BitLocker'; Setting = 'OSDriveEncrypted'; Restored = $true }
}

Export-ModuleMember -Function Test-BitLockerBaseline, Backup-BitLockerSettings, Set-BitLockerBaseline, Restore-BitLockerSettings
