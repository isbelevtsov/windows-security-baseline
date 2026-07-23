Import-Module (Join-Path $PSScriptRoot '..\Common\SecEdit.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\Common\Config.psm1') -Force

$script:SeceditKeyMap = [ordered]@{
    MinimumPasswordLength  = 'MinimumPasswordLength'
    PasswordComplexity     = 'PasswordComplexity'
    PasswordHistorySize    = 'PasswordHistorySize'
    MaximumPasswordAgeDays = 'MaximumPasswordAge'
    MinimumPasswordAgeDays = 'MinimumPasswordAge'
}

function ConvertTo-SeceditValue {
    param($Value)
    if ($Value -is [bool]) {
        return $(if ($Value) { '1' } else { '0' })
    }
    return "$Value"
}

function ConvertFrom-SeceditValue {
    param([string]$RawValue, [string]$ConfigName)
    if ($ConfigName -eq 'PasswordComplexity') {
        return ($RawValue -eq '1')
    }
    return [int]$RawValue
}

function Test-PasswordPolicyBaseline {
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
        $actual = if ($null -ne $rawActual) { ConvertFrom-SeceditValue -RawValue $rawActual -ConfigName $configName } else { $null }

        [PSCustomObject]@{
            Module      = 'PasswordPolicy'
            Setting     = $configName
            Expected    = $expected
            Actual      = $actual
            Pass        = ($actual -eq $expected)
            Description = Get-BaselineDescription -Section $Config -Name $configName
        }
    }

    return $results
}

function Backup-PasswordPolicySettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    New-Item -Path $BackupPath -ItemType Directory -Force | Out-Null
    $cfgPath = Join-Path -Path $BackupPath -ChildPath 'password-policy.cfg'
    Invoke-SecEditExport -CfgPath $cfgPath
    return $cfgPath
}

function Set-PasswordPolicyBaseline {
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
        $before = if ($null -ne $rawActual) { ConvertFrom-SeceditValue -RawValue $rawActual -ConfigName $configName } else { $null }
        $changed = ($before -ne $expected)

        if ($changed) {
            Set-SecurityPolicyValue -CfgPath $WorkingCfgPath -Key $seceditKey -Value (ConvertTo-SeceditValue -Value $expected)
        }

        [PSCustomObject]@{
            Module  = 'PasswordPolicy'
            Setting = $configName
            Before  = $before
            After   = $expected
            Changed = $changed
        }
    }

    Invoke-SecEditConfigure -CfgPath $WorkingCfgPath
    return $changes
}

function Restore-PasswordPolicySettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    $cfgPath = Join-Path -Path $BackupPath -ChildPath 'password-policy.cfg'
    if (-not (Test-Path -Path $cfgPath)) {
        throw "No password policy backup found at '$cfgPath'."
    }

    # Restoring by /configuring the raw backup file directly would also
    # reassert whatever else was in its [System Access] section at backup
    # time - and since secedit exports that whole shared section,
    # AccountLockout's own backup (taken later in the same Apply run,
    # after this module's Set already committed) silently captures
    # PasswordPolicy's already-applied values instead of the true
    # pre-Apply ones. Restoring PasswordPolicy from its own snapshot would
    # then be immediately clobbered back to those stale values when
    # AccountLockout's restore ran its own full /configure right
    # afterward - confirmed on real hardware. Instead, only this module's
    # own keys are copied out of the backup into a freshly-exported
    # CURRENT working cfg, leaving every other setting - including
    # AccountLockout's - exactly as it currently stands.
    $workingCfgPath = Join-Path -Path $BackupPath -ChildPath 'password-policy-restore-working.cfg'
    Invoke-SecEditExport -CfgPath $workingCfgPath

    foreach ($seceditKey in $script:SeceditKeyMap.Values) {
        $backedUpValue = Get-SecurityPolicyValue -CfgPath $cfgPath -Key $seceditKey
        if ($null -ne $backedUpValue) {
            Set-SecurityPolicyValue -CfgPath $workingCfgPath -Key $seceditKey -Value $backedUpValue
        }
    }

    Invoke-SecEditConfigure -CfgPath $workingCfgPath
}

Export-ModuleMember -Function Test-PasswordPolicyBaseline, Backup-PasswordPolicySettings, Set-PasswordPolicyBaseline, Restore-PasswordPolicySettings
