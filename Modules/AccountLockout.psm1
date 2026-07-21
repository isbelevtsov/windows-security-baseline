Import-Module (Join-Path $PSScriptRoot '..\Common\SecEdit.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\Common\Config.psm1') -Force

$script:SeceditKeyMap = [ordered]@{
    LockoutThreshold         = 'LockoutBadCount'
    LockoutDurationMinutes   = 'LockoutDuration'
    ObservationWindowMinutes = 'ResetLockoutCount'
}

function Test-AccountLockoutBaseline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$WorkingCfgPath
    )

    Invoke-SecEditExport -CfgPath $WorkingCfgPath

    $results = foreach ($configName in $script:SeceditKeyMap.Keys) {
        $seceditKey = $script:SeceditKeyMap[$configName]
        $expected = Get-BaselineValue -Section $Config -Name $configName
        $rawActual = Get-SecurityPolicyValue -CfgPath $WorkingCfgPath -Key $seceditKey
        $actual = if ($null -ne $rawActual) { [int]$rawActual } else { $null }

        [PSCustomObject]@{
            Module      = 'AccountLockout'
            Setting     = $configName
            Expected    = $expected
            Actual      = $actual
            Pass        = ($actual -eq $expected)
            Description = Get-BaselineDescription -Section $Config -Name $configName
        }
    }

    return $results
}

function Backup-AccountLockoutSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    New-Item -Path $BackupPath -ItemType Directory -Force | Out-Null
    $cfgPath = Join-Path -Path $BackupPath -ChildPath 'account-lockout.cfg'
    Invoke-SecEditExport -CfgPath $cfgPath
    return $cfgPath
}

function Set-AccountLockoutBaseline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$WorkingCfgPath
    )

    Invoke-SecEditExport -CfgPath $WorkingCfgPath

    $changes = foreach ($configName in $script:SeceditKeyMap.Keys) {
        $seceditKey = $script:SeceditKeyMap[$configName]
        $expected = Get-BaselineValue -Section $Config -Name $configName
        $rawActual = Get-SecurityPolicyValue -CfgPath $WorkingCfgPath -Key $seceditKey
        $before = if ($null -ne $rawActual) { [int]$rawActual } else { $null }
        $changed = ($before -ne $expected)

        if ($changed) {
            Set-SecurityPolicyValue -CfgPath $WorkingCfgPath -Key $seceditKey -Value "$expected"
        }

        [PSCustomObject]@{
            Module  = 'AccountLockout'
            Setting = $configName
            Before  = $before
            After   = $expected
            Changed = $changed
        }
    }

    Invoke-SecEditConfigure -CfgPath $WorkingCfgPath
    return $changes
}

function Restore-AccountLockoutSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    $cfgPath = Join-Path -Path $BackupPath -ChildPath 'account-lockout.cfg'
    if (-not (Test-Path -Path $cfgPath)) {
        throw "No account lockout backup found at '$cfgPath'."
    }
    Invoke-SecEditConfigure -CfgPath $cfgPath
}

Export-ModuleMember -Function Test-AccountLockoutBaseline, Backup-AccountLockoutSettings, Set-AccountLockoutBaseline, Restore-AccountLockoutSettings
