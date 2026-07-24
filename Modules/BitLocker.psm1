Import-Module (Join-Path $PSScriptRoot '..\Common\Config.psm1') -Force

$script:BitLockerKnownApiLimitations = @(
    @{
        # HRESULT 0x8031005A ("This version of Windows does not support this
        # feature of BitLocker Drive Encryption. To use this feature, upgrade
        # the operating system.") is documented as an edition/SKU restriction,
        # but real testing on a Windows 11 Home VM found it is not a reliable
        # signal of that by itself - it surfaced for at least two distinct,
        # confirmed root causes on the same machine:
        #
        # 1. A bootable CD/DVD (a mounted ISO) present in an optical drive.
        #    Ejecting it made Enable-BitLocker succeed immediately on a volume
        #    that already had prior BitLocker metadata (KeyProtector-capable,
        #    MetadataVersion > 0) - added a TPM + recovery-password protector,
        #    reached ProtectionStatus=On, no other change.
        # 2. A volume with NO prior BitLocker metadata at all (MetadataVersion
        #    = 0, e.g. immediately after a full Disable-BitLocker/decrypt).
        #    On this same VM/edition/hardware, with no optical media mounted,
        #    Enable-BitLocker - and the raw Win32_EncryptableVolume WMI
        #    PrepareVolume method directly, bypassing every cmdlet layer -
        #    both threw this identical HRESULT. A reboot (to let Windows'
        #    background Device Encryption readiness process re-stage the
        #    volume, which is the likely explanation for why case 1's volume
        #    had metadata to begin with) did not change the outcome either.
        #
        # So case 1 is a real, retriable condition worth checking first; case
        # 2 looks like a genuine per-volume/hardware limitation this toolkit
        # cannot route around via any API it can reach - confirmed at the
        # lowest possible layer, not just the cmdlet. Both are still handled
        # gracefully rather than left to crash the module.
        HResult = -2144272294
        Note    = "Enable-BitLocker returned HRESULT 0x8031005A ('This version of Windows does not support this feature of BitLocker Drive Encryption'). This is not a reliable signal of a hard edition block by itself - on real Windows 11 Home hardware it was confirmed to also occur (a) whenever a CD/DVD, including a mounted ISO, was present in any optical drive, resolved by ejecting it and retrying, and separately (b) on a volume with no prior BitLocker metadata at all (e.g. right after a full decrypt), where it persisted even with no media present and after a reboot - the lowest-level Win32_EncryptableVolume.PrepareVolume WMI call failed identically, with no cmdlet involved. First: eject any mounted CD/DVD/ISO from every optical drive and re-run Apply. If it still recurs with no media present, this may be a per-volume/hardware limitation with no further scriptable fix - Home's automatic Device Encryption (Settings > Privacy & security > Device encryption) may or may not succeed either, since it relies on the same underlying mechanism."
    }
    @{
        # HRESULT 0x80310030 ("BitLocker Drive Encryption detected bootable
        # media (CD or DVD) in the computer. Remove the media and restart
        # the computer before configuring BitLocker.") - confirmed on real
        # hardware with a virtual optical drive holding a mounted ISO.
        # Windows' own pre-flight check refuses to proceed while any
        # bootable-looking optical media is present, independent of edition
        # or hardware eligibility - a real, re-triggerable condition (a
        # forgotten install disc or mounted ISO), not just a VM artifact, so
        # it deserves the same graceful non-crash treatment as the edition
        # restriction above rather than propagating to the Orchestrator's
        # generic per-module failure handling.
        HResult = -2144272336
        Note    = 'BitLocker Drive Encryption detected bootable media (a CD/DVD drive, including a mounted ISO) and refuses to configure while one is present - eject the media (or unmount the ISO) and re-run Apply; a restart may also be required. This is a pre-flight check Windows enforces itself, unrelated to hardware eligibility or Windows edition.'
    }
)

function Get-BitLockerKnownApiLimitationNote {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ErrorRecord)
    $match = $script:BitLockerKnownApiLimitations | Where-Object { $_.HResult -eq $ErrorRecord.Exception.HResult }
    if ($match) { return $match.Note }
    return $null
}

function Get-OsDriveBitLockerVolume {
    [CmdletBinding()]
    param()
    Get-BitLockerVolume -MountPoint $env:SystemDrive
}

function Invoke-EnableBitLockerWithTpmProtector {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$EncryptionMethod)
    # -UsedSpaceOnly is required on thin-provisioned storage (confirmed on
    # real hardware: a QEMU virtual disk here) - without it, Enable-BitLocker
    # defaults to full-volume encryption, which throws "BitLocker Drive
    # Encryption only supports Used Space Only encryption on thin
    # provisioned storage" (HRESULT 0x803100A5). Windows' own automatic
    # Device Encryption already defaults to Used Space Only, which is why
    # this was never hit until the volume was fully decrypted and this
    # module had to enable it completely fresh.
    Enable-BitLocker -MountPoint $env:SystemDrive -EncryptionMethod $EncryptionMethod -TpmProtector -SkipHardwareTest -UsedSpaceOnly -ErrorAction Stop
}

function Invoke-EnableBitLockerWithRecoveryPasswordProtector {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$EncryptionMethod)
    Enable-BitLocker -MountPoint $env:SystemDrive -EncryptionMethod $EncryptionMethod -RecoveryPasswordProtector -SkipHardwareTest -UsedSpaceOnly -ErrorAction Stop
}

function Invoke-EnableBitLockerWithRecoveryPasswordProtectorOnly {
    [CmdletBinding()]
    param()
    # Omits -EncryptionMethod. Confirmed on real hardware: when the volume
    # already has other BitLocker metadata (e.g. a pre-staged TPM protector),
    # re-specifying an encryption method can conflict with what's already
    # configured on the volume and throws "Value does not fall within the
    # expected range." - a generic enum-validation message from the underlying
    # cmdletization layer. Omitting it lets Windows use whatever is already
    # configured (or its platform default, XtsAes256 on modern Windows).
    Enable-BitLocker -MountPoint $env:SystemDrive -RecoveryPasswordProtector -SkipHardwareTest -UsedSpaceOnly -ErrorAction Stop
}

function Add-OsDriveRecoveryPasswordProtector {
    [CmdletBinding()]
    param()
    Add-BitLockerKeyProtector -MountPoint $env:SystemDrive -RecoveryPasswordProtector -ErrorAction Stop
}

function Test-OsDriveHasRecoveryPasswordProtector {
    [CmdletBinding()]
    param()
    $types = @((Get-OsDriveBitLockerVolume).KeyProtector | Select-Object -ExpandProperty KeyProtectorType)
    return ($types -contains 'RecoveryPassword')
}

function Resume-OsDriveBitLocker {
    [CmdletBinding()]
    param()
    Resume-BitLocker -MountPoint $env:SystemDrive
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
    #
    # Confirmed separately on a volume where Windows had already started
    # "Device Encryption" automatically (encryption in progress, no protector
    # yet): Invoke-EnableBitLockerWithRecoveryPasswordProtector raised a
    # terminating error (EncryptionMethod conflicting with the in-progress
    # conversion) even though the underlying protector-add had already been
    # committed (confirmed via the BitLocker-API event log, which showed a
    # successful "key protector was created" event despite the cmdlet
    # throwing). Retrying blindly in that case added a second, redundant
    # recovery password protector whose password was never recorded anywhere.
    # Every fallback below now re-checks for an existing RecoveryPassword
    # protector before adding another one.
    $existingProtectorTypes = @((Get-OsDriveBitLockerVolume).KeyProtector | Select-Object -ExpandProperty KeyProtectorType)
    $tpmProtectorAdded = $true

    if ($existingProtectorTypes -contains 'Tpm') {
        try {
            Invoke-EnableBitLockerWithRecoveryPasswordProtector -EncryptionMethod $EncryptionMethod | Out-Null
        }
        catch {
            if (-not (Test-OsDriveHasRecoveryPasswordProtector)) {
                Invoke-EnableBitLockerWithRecoveryPasswordProtectorOnly | Out-Null
            }
        }
    }
    else {
        try {
            Invoke-EnableBitLockerWithTpmProtector -EncryptionMethod $EncryptionMethod | Out-Null
            if (-not (Test-OsDriveHasRecoveryPasswordProtector)) {
                Add-OsDriveRecoveryPasswordProtector | Out-Null
            }
        }
        catch {
            $tpmProtectorAdded = $false
            if (-not (Test-OsDriveHasRecoveryPasswordProtector)) {
                try {
                    Invoke-EnableBitLockerWithRecoveryPasswordProtector -EncryptionMethod $EncryptionMethod | Out-Null
                }
                catch {
                    Invoke-EnableBitLockerWithRecoveryPasswordProtectorOnly | Out-Null
                }
            }
        }
    }

    # Enable-BitLocker/Add-BitLockerKeyProtector can leave protection
    # suspended rather than actually turned on, particularly on a volume
    # where Windows' automatic "Device Encryption" already started
    # encrypting before this ever ran. Confirmed on real hardware: a volume
    # sitting at 100% encrypted with valid TPM + recovery password
    # protectors still showed ProtectionStatus "Off" - manage-bde's text
    # output doesn't distinguish "suspended" from "never activated" here
    # (it just says "Protection Off" either way), but Resume-BitLocker
    # immediately flipped it to "On". This is a best-effort nudge, not
    # something every code path above is guaranteed to leave in a
    # resumable state, so failures here are not fatal to the overall
    # Apply - Test-BitLockerBaseline's post-apply verification will still
    # catch it if this doesn't work.
    try {
        Resume-OsDriveBitLocker | Out-Null
    }
    catch {
    }

    return $tpmProtectorAdded
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
    $recoveryKey = $null

    if (-not $before.Pass) {
        try {
            $tpmProtectorAdded = Enable-OsDriveBitLocker -EncryptionMethod $method
        }
        catch {
            $limitationNote = Get-BitLockerKnownApiLimitationNote -ErrorRecord $_
            if ($limitationNote) {
                return @(
                    [PSCustomObject]@{
                        Module      = 'BitLocker'
                        Setting     = 'OSDriveEncrypted'
                        Before      = $before.Actual
                        After       = $before.Actual
                        Changed     = $false
                        Note        = $limitationNote
                        Secret      = $null
                        SecretLabel = $null
                    }
                )
            }
            throw
        }

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
            Module      = 'BitLocker'
            Setting     = 'OSDriveEncrypted'
            Before      = $before.Actual
            After       = $(if ($changed) { $true } else { $before.Actual })
            Changed     = $changed
            Note        = $note
            Secret      = $recoveryKey
            SecretLabel = 'BitLocker recovery key'
        }
    )
}

function Restore-BitLockerSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BackupPath,
        [hashtable]$Config,
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

    # Confirmed on real hardware: calling Disable-BitLocker on a volume
    # that's already decrypting (or already fully decrypted) throws
    # "BitLocker Drive Encryption is not enabled on this drive" - harmless
    # in effect (decryption was already under way from an earlier Restore
    # -DecryptOnRestore), but a needless scary-looking error on a repeat
    # run. Skip the call entirely if there's nothing left to disable.
    $alreadyDecrypting = "$((Get-OsDriveBitLockerVolume).VolumeStatus)" -in @('DecryptionInProgress', 'FullyDecrypted')
    if ($saved.ProtectionStatus -ne 'On' -and -not $alreadyDecrypting) {
        Disable-OsDriveBitLocker
    }

    # Reaching here means decryption genuinely succeeded (or was already
    # under way/complete, or was never needed) - Disable-OsDriveBitLocker
    # above would have thrown otherwise and this line would never run. The
    # recovery key Set-BitLockerBaseline saved to disk is now just a stale
    # plaintext secret, so clean it up rather than leaving it behind.
    if ($Config) {
        $keyFolder = Get-BaselineValue -Section $Config -Name 'RecoveryKeyPath'
        $safeName = $env:SystemDrive.Replace(':', '')
        $keyFile = Join-Path -Path $keyFolder -ChildPath "$safeName-recovery-key.txt"
        Remove-Item -Path $keyFile -Force -ErrorAction SilentlyContinue
    }

    return [PSCustomObject]@{ Module = 'BitLocker'; Setting = 'OSDriveEncrypted'; Restored = $true }
}

Export-ModuleMember -Function Test-BitLockerBaseline, Backup-BitLockerSettings, Set-BitLockerBaseline, Restore-BitLockerSettings
