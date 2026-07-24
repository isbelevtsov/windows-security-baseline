# Invoke-SecurityBaseline.ps1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Audit', 'Apply', 'Restore')][string]$Mode,

    [ValidateSet('PasswordPolicy', 'AccountLockout', 'Defender', 'Firewall', 'ScreenLock', 'AuditPolicy', 'RemoteAccess', 'BitLocker', 'LocalAccounts', 'WindowsUpdate', 'PowerShellLogging', 'RemovableStorage', 'UAC', 'NetworkHardening', 'EventLogRetention')]
    [string[]]$Modules = @('PasswordPolicy', 'AccountLockout', 'Defender', 'Firewall', 'ScreenLock', 'AuditPolicy', 'RemoteAccess', 'BitLocker', 'LocalAccounts', 'WindowsUpdate', 'PowerShellLogging', 'RemovableStorage', 'UAC', 'NetworkHardening', 'EventLogRetention'),

    [string]$RootPath = 'C:\ProgramData\SecurityBaseline',
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'Config\Baseline.config.psd1'),

    [string]$Timestamp,
    [switch]$Latest,
    [switch]$DecryptOnRestore
)

$moduleFiles = @(
    'Common\Logging.psm1'
    'Common\SystemInfo.psm1'
    'Common\Config.psm1'
    'Common\BackupRestore.psm1'
    'Common\Reporting.psm1'
    'Common\SecEdit.psm1'
    'Common\Orchestrator.psm1'
    'Modules\PasswordPolicy.psm1'
    'Modules\AccountLockout.psm1'
    'Modules\Defender.psm1'
    'Modules\Firewall.psm1'
    'Modules\ScreenLock.psm1'
    'Modules\AuditPolicy.psm1'
    'Modules\RemoteAccess.psm1'
    'Modules\BitLocker.psm1'
    'Modules\LocalAccounts.psm1'
    'Modules\WindowsUpdate.psm1'
    'Modules\PowerShellLogging.psm1'
    'Modules\RemovableStorage.psm1'
    'Modules\UAC.psm1'
    'Modules\NetworkHardening.psm1'
    'Modules\EventLogRetention.psm1'
)

foreach ($file in $moduleFiles) {
    Import-Module (Join-Path $PSScriptRoot $file) -Force -Global
}

if ($Mode -eq 'Restore' -and -not $Latest -and -not $Timestamp) {
    throw 'Restore mode requires either -Timestamp <snapshot> or -Latest.'
}

$runTimestamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'

# Invoke-BaselineRun's result objects are for programmatic/Pester callers
# (see Tests\Common\Orchestrator.Tests.ps1) - this entry point is normally run
# interactively, where an uncaptured return value gets auto-dumped to the
# console by PowerShell after everything else, burying the audit summary
# table / "SAVE THESE NOW" secrets banner that Write-BaselineAuditSummary and
# Write-BaselineApplySummary already print. Suppress it here so those stay
# the last thing the operator sees.
Invoke-BaselineRun -Mode $Mode -Modules $Modules -RootPath $RootPath -ConfigPath $ConfigPath `
    -RunTimestamp $runTimestamp -SnapshotTimestamp $Timestamp -Latest:$Latest -DecryptOnRestore:$DecryptOnRestore | Out-Null
