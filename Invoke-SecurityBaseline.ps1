# Invoke-SecurityBaseline.ps1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Audit', 'Apply', 'Restore')][string]$Mode,

    [ValidateSet('PasswordPolicy', 'AccountLockout', 'Defender', 'Firewall', 'ScreenLock', 'AuditPolicy', 'RemoteAccess', 'BitLocker')]
    [string[]]$Modules = @('PasswordPolicy', 'AccountLockout', 'Defender', 'Firewall', 'ScreenLock', 'AuditPolicy', 'RemoteAccess', 'BitLocker'),

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
)

foreach ($file in $moduleFiles) {
    Import-Module (Join-Path $PSScriptRoot $file) -Force -Global
}

if ($Mode -eq 'Restore' -and -not $Latest -and -not $Timestamp) {
    throw 'Restore mode requires either -Timestamp <snapshot> or -Latest.'
}

$runTimestamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'

Invoke-BaselineRun -Mode $Mode -Modules $Modules -RootPath $RootPath -ConfigPath $ConfigPath `
    -RunTimestamp $runTimestamp -SnapshotTimestamp $Timestamp -Latest:$Latest -DecryptOnRestore:$DecryptOnRestore
