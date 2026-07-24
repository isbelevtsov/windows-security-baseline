# Common/Orchestrator.psm1
Import-Module (Join-Path $PSScriptRoot 'SystemInfo.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Config.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'BackupRestore.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Reporting.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Logging.psm1') -Force

$script:AllModules = @(
    'PasswordPolicy', 'AccountLockout', 'Defender', 'Firewall', 'ScreenLock', 'AuditPolicy', 'RemoteAccess', 'BitLocker', 'LocalAccounts',
    'WindowsUpdate', 'PowerShellLogging', 'RemovableStorage', 'UAC', 'NetworkHardening', 'EventLogRetention'
)

$script:ModuleFunctionMap = @{
    PasswordPolicy    = @{ Test = 'Test-PasswordPolicyBaseline';    Backup = 'Backup-PasswordPolicySettings';    Set = 'Set-PasswordPolicyBaseline';    Restore = 'Restore-PasswordPolicySettings' }
    AccountLockout    = @{ Test = 'Test-AccountLockoutBaseline';    Backup = 'Backup-AccountLockoutSettings';    Set = 'Set-AccountLockoutBaseline';    Restore = 'Restore-AccountLockoutSettings' }
    Defender          = @{ Test = 'Test-DefenderBaseline';          Backup = 'Backup-DefenderSettings';          Set = 'Set-DefenderBaseline';          Restore = 'Restore-DefenderSettings' }
    Firewall          = @{ Test = 'Test-FirewallBaseline';          Backup = 'Backup-FirewallSettings';          Set = 'Set-FirewallBaseline';          Restore = 'Restore-FirewallSettings' }
    ScreenLock        = @{ Test = 'Test-ScreenLockBaseline';        Backup = 'Backup-ScreenLockSettings';        Set = 'Set-ScreenLockBaseline';        Restore = 'Restore-ScreenLockSettings' }
    AuditPolicy       = @{ Test = 'Test-AuditPolicyBaseline';       Backup = 'Backup-AuditPolicySettings';       Set = 'Set-AuditPolicyBaseline';       Restore = 'Restore-AuditPolicySettings' }
    RemoteAccess      = @{ Test = 'Test-RemoteAccessBaseline';      Backup = 'Backup-RemoteAccessSettings';      Set = 'Set-RemoteAccessBaseline';      Restore = 'Restore-RemoteAccessSettings' }
    BitLocker         = @{ Test = 'Test-BitLockerBaseline';         Backup = 'Backup-BitLockerSettings';         Set = 'Set-BitLockerBaseline';         Restore = 'Restore-BitLockerSettings' }
    LocalAccounts     = @{ Test = 'Test-LocalAccountsBaseline';     Backup = 'Backup-LocalAccountsSettings';     Set = 'Set-LocalAccountsBaseline';     Restore = 'Restore-LocalAccountsSettings' }
    WindowsUpdate     = @{ Test = 'Test-WindowsUpdateBaseline';     Backup = 'Backup-WindowsUpdateSettings';     Set = 'Set-WindowsUpdateBaseline';     Restore = 'Restore-WindowsUpdateSettings' }
    PowerShellLogging = @{ Test = 'Test-PowerShellLoggingBaseline'; Backup = 'Backup-PowerShellLoggingSettings'; Set = 'Set-PowerShellLoggingBaseline'; Restore = 'Restore-PowerShellLoggingSettings' }
    RemovableStorage  = @{ Test = 'Test-RemovableStorageBaseline';  Backup = 'Backup-RemovableStorageSettings';  Set = 'Set-RemovableStorageBaseline';  Restore = 'Restore-RemovableStorageSettings' }
    UAC               = @{ Test = 'Test-UACBaseline';               Backup = 'Backup-UACSettings';               Set = 'Set-UACBaseline';               Restore = 'Restore-UACSettings' }
    NetworkHardening  = @{ Test = 'Test-NetworkHardeningBaseline';  Backup = 'Backup-NetworkHardeningSettings';  Set = 'Set-NetworkHardeningBaseline';  Restore = 'Restore-NetworkHardeningSettings' }
    EventLogRetention = @{ Test = 'Test-EventLogRetentionBaseline'; Backup = 'Backup-EventLogRetentionSettings'; Set = 'Set-EventLogRetentionBaseline'; Restore = 'Restore-EventLogRetentionSettings' }
}

$script:SeceditModules = @('PasswordPolicy', 'AccountLockout')

function Invoke-AuditRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Modules,
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$RunTimestamp,
        [Parameter(Mandatory)][string]$LogPath
    )

    $config = Import-BaselineConfig -Path $ConfigPath

    $allResults = foreach ($moduleName in $Modules) {
        try {
            $testFunction = $script:ModuleFunctionMap[$moduleName].Test
            if ($moduleName -in $script:SeceditModules) {
                $workingCfg = Join-Path -Path $RootPath -ChildPath (Join-Path 'Logs' "$RunTimestamp-$moduleName-working.cfg")
                & $testFunction -Config $config[$moduleName] -WorkingCfgPath $workingCfg
            }
            else {
                & $testFunction -Config $config[$moduleName]
            }
        }
        catch {
            Write-BaselineLog -Message "Audit of module '$moduleName' failed: $($_.Exception.Message)" -Level 'Error' -LogPath $LogPath
            [PSCustomObject]@{ Module = $moduleName; Setting = 'ModuleError'; Expected = $null; Actual = $_.Exception.Message; Pass = $false; Description = 'This module raised an error during audit.' }
        }
    }

    $reportPath = Join-Path -Path $RootPath -ChildPath (Join-Path 'Reports' "$RunTimestamp-audit.json")
    $summary = New-BaselineAuditReport -Results $allResults -ReportPath $reportPath
    Write-BaselineAuditSummary -Results $allResults
    Write-BaselineLog -Message "Audit complete: $($summary.Passed)/$($summary.Total) settings passed. Report: $reportPath" -LogPath $LogPath

    return $allResults
}

function Invoke-ApplyRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Modules,
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$RunTimestamp,
        [Parameter(Mandatory)][string]$LogPath
    )

    $config = Import-BaselineConfig -Path $ConfigPath
    $osInfo = Get-WindowsEditionInfo
    $appliedModules = @()

    $allChanges = foreach ($moduleName in $Modules) {
        try {
            $backupPath = New-BaselineBackupFolder -RootPath $RootPath -Timestamp $RunTimestamp -Area $moduleName
            & $script:ModuleFunctionMap[$moduleName].Backup -BackupPath $backupPath | Out-Null

            $setFunction = $script:ModuleFunctionMap[$moduleName].Set
            $testFunction = $script:ModuleFunctionMap[$moduleName].Test
            $workingCfg = $null
            $changes = if ($moduleName -in $script:SeceditModules) {
                $workingCfg = Join-Path -Path $RootPath -ChildPath (Join-Path 'Logs' "$RunTimestamp-$moduleName-working.cfg")
                & $setFunction -Config $config[$moduleName] -WorkingCfgPath $workingCfg
            }
            else {
                & $setFunction -Config $config[$moduleName]
            }

            $appliedModules += $moduleName
            foreach ($change in $changes) {
                Write-BaselineLog -Message "[$moduleName] $($change.Setting): $($change.Before) -> $($change.After) (Changed=$($change.Changed))" -LogPath $LogPath
                if ($change.Note) {
                    Write-BaselineLog -Message "[$moduleName] $($change.Note)" -Level 'Warn' -LogPath $LogPath
                }
            }

            # Post-apply verification: re-run Test-<Area>Baseline as the primary correctness
            # signal for Apply, and surface any setting that is still non-compliant. A failure
            # here must not undo the fact that Backup+Set already succeeded for this module.
            try {
                $verifyResults = if ($moduleName -in $script:SeceditModules) {
                    & $testFunction -Config $config[$moduleName] -WorkingCfgPath $workingCfg
                }
                else {
                    & $testFunction -Config $config[$moduleName]
                }

                foreach ($verifyResult in $verifyResults) {
                    if (-not $verifyResult.Pass) {
                        Write-BaselineLog -Message "[$moduleName] Post-apply verification failed: setting '$($verifyResult.Setting)' is still non-compliant (Expected=$($verifyResult.Expected), Actual=$($verifyResult.Actual))." -Level 'Warn' -LogPath $LogPath
                    }
                }
            }
            catch {
                Write-BaselineLog -Message "[$moduleName] Post-apply verification could not run: $($_.Exception.Message)" -Level 'Warn' -LogPath $LogPath
            }

            $changes
        }
        catch {
            Write-BaselineLog -Message "Apply of module '$moduleName' failed, skipping: $($_.Exception.Message)" -Level 'Error' -LogPath $LogPath
        }
    }

    if (@($appliedModules).Count -gt 0) {
        Write-BaselineManifest -RootPath $RootPath -Timestamp $RunTimestamp -Mode 'Apply' -Modules @($appliedModules) -OSBuild $osInfo.Build | Out-Null
    }

    $backupRoot = Join-Path -Path $RootPath -ChildPath (Join-Path 'Backups' $RunTimestamp)
    if (@($allChanges).Count -gt 0) {
        Write-BaselineApplySummary -ChangeRecords @($allChanges) -BackupPath $backupRoot -LogPath $LogPath
    }

    return @($allChanges)
}

function Invoke-RestoreRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Modules,
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][string]$ConfigPath,
        [string]$SnapshotTimestamp,
        [switch]$Latest,
        [Parameter(Mandatory)][string]$LogPath,
        [switch]$DecryptOnRestore
    )

    $config = Import-BaselineConfig -Path $ConfigPath
    $snapshotRoot = Resolve-BaselineSnapshotPath -RootPath $RootPath -Timestamp $SnapshotTimestamp -Latest:$Latest

    $results = foreach ($moduleName in $Modules) {
        $backupPath = Join-Path -Path $snapshotRoot -ChildPath $moduleName

        if (-not (Test-Path -Path $backupPath)) {
            Write-BaselineLog -Message "No backup for module '$moduleName' in snapshot '$snapshotRoot', skipping." -Level 'Warn' -LogPath $LogPath
            continue
        }

        try {
            $restoreFunction = $script:ModuleFunctionMap[$moduleName].Restore

            # BitLocker and LocalAccounts are the only two modules whose
            # restore can clean up a saved plaintext secret (recovery key /
            # temporary password) that Apply generated - each needs its own
            # config section (RecoveryKeyPath / TemporaryPasswordPath) to
            # know where that secret lives. Every other module's restore is
            # a pure settings rollback with no config dependency.
            if ($moduleName -eq 'BitLocker') {
                & $restoreFunction -BackupPath $backupPath -Config $config[$moduleName] -DecryptOnRestore:$DecryptOnRestore
            }
            elseif ($moduleName -eq 'LocalAccounts') {
                & $restoreFunction -BackupPath $backupPath -Config $config[$moduleName] | Out-Null
                Write-BaselineLog -Message "Restored module '$moduleName' from '$backupPath'." -LogPath $LogPath
                [PSCustomObject]@{ Module = $moduleName; Restored = $true }
            }
            else {
                & $restoreFunction -BackupPath $backupPath | Out-Null
                Write-BaselineLog -Message "Restored module '$moduleName' from '$backupPath'." -LogPath $LogPath
                [PSCustomObject]@{ Module = $moduleName; Restored = $true }
            }
        }
        catch {
            Write-BaselineLog -Message "Restore of module '$moduleName' failed: $($_.Exception.Message)" -Level 'Error' -LogPath $LogPath
            [PSCustomObject]@{ Module = $moduleName; Restored = $false; Error = $_.Exception.Message }
        }
    }

    return @($results)
}

function Invoke-BaselineRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Audit', 'Apply', 'Restore')][string]$Mode,
        [string[]]$Modules = $script:AllModules,
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$RunTimestamp,
        [string]$SnapshotTimestamp,
        [switch]$Latest,
        [switch]$DecryptOnRestore
    )

    if (-not (Test-BaselineElevation)) {
        throw 'This script must be run from an elevated (Administrator) PowerShell session.'
    }

    $unknown = @($Modules | Where-Object { $_ -notin $script:AllModules })
    if ($unknown.Count -gt 0) {
        throw "Unknown module(s): $($unknown -join ', '). Valid modules are: $($script:AllModules -join ', ')"
    }

    $logPath = Join-Path -Path $RootPath -ChildPath (Join-Path 'Logs' "$RunTimestamp.log")
    Write-BaselineLog -Message "Starting $Mode run for modules: $($Modules -join ', ')" -LogPath $logPath

    switch ($Mode) {
        'Audit'   { return Invoke-AuditRun -Modules $Modules -RootPath $RootPath -ConfigPath $ConfigPath -RunTimestamp $RunTimestamp -LogPath $logPath }
        'Apply'   { return Invoke-ApplyRun -Modules $Modules -RootPath $RootPath -ConfigPath $ConfigPath -RunTimestamp $RunTimestamp -LogPath $logPath }
        'Restore' { return Invoke-RestoreRun -Modules $Modules -RootPath $RootPath -ConfigPath $ConfigPath -SnapshotTimestamp $SnapshotTimestamp -Latest:$Latest -LogPath $logPath -DecryptOnRestore:$DecryptOnRestore }
    }
}

Export-ModuleMember -Function Invoke-BaselineRun
