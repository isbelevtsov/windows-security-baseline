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
    Invoke-SecEditConfigure -CfgPath $cfgPath
}

Export-ModuleMember -Function Test-PasswordPolicyBaseline, Backup-PasswordPolicySettings, Set-PasswordPolicyBaseline, Restore-PasswordPolicySettings
