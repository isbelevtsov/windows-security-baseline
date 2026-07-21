Import-Module (Join-Path $PSScriptRoot '..\Common\Config.psm1') -Force

$script:RegistryPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$script:ValueName = 'InactivityTimeoutSecs'

function Get-InactivityTimeoutValue {
    [CmdletBinding()]
    param()
    $item = Get-ItemProperty -Path $script:RegistryPath -Name $script:ValueName -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return $null
    }
    return $item.$($script:ValueName)
}

function Set-InactivityTimeoutValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Seconds)

    if (-not (Test-Path -Path $script:RegistryPath)) {
        New-Item -Path $script:RegistryPath -Force | Out-Null
    }
    New-ItemProperty -Path $script:RegistryPath -Name $script:ValueName -Value $Seconds -PropertyType DWord -Force | Out-Null
}

function Export-InactivityTimeoutRegistry {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RegPath)
    & reg.exe export 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' $RegPath /y
    if ($LASTEXITCODE -ne 0) {
        throw "reg.exe failed with exit code $LASTEXITCODE (arguments: export 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' $RegPath /y)"
    }
}

function Import-InactivityTimeoutRegistry {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RegPath)
    & reg.exe import $RegPath
    if ($LASTEXITCODE -ne 0) {
        throw "reg.exe failed with exit code $LASTEXITCODE (arguments: import $RegPath)"
    }
}

function Remove-InactivityTimeoutValue {
    [CmdletBinding()]
    param()
    Remove-ItemProperty -Path $script:RegistryPath -Name $script:ValueName -ErrorAction SilentlyContinue
}

function Test-ScreenLockBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $expected = Get-BaselineValue -Section $Config -Name 'InactivityTimeoutSeconds'
    $actual = Get-InactivityTimeoutValue

    @(
        [PSCustomObject]@{
            Module = 'ScreenLock'; Setting = 'InactivityTimeoutSeconds'
            Expected = $expected; Actual = $actual; Pass = ($actual -eq $expected)
            Description = Get-BaselineDescription -Section $Config -Name 'InactivityTimeoutSeconds'
        }
    )
}

function Backup-ScreenLockSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    New-Item -Path $BackupPath -ItemType Directory -Force | Out-Null
    $regPath = Join-Path -Path $BackupPath -ChildPath 'screenlock.reg'
    Export-InactivityTimeoutRegistry -RegPath $regPath

    # InactivityTimeoutSecs is not configured by default on Windows. If Apply creates it,
    # a plain `reg import` of this backup will never delete it again (reg import only
    # adds/overwrites values it lists). Record whether the value existed at backup time so
    # Restore can explicitly remove it if it didn't.
    $statePath = Join-Path -Path $BackupPath -ChildPath 'screenlock-state.json'
    $valueExisted = ($null -ne (Get-InactivityTimeoutValue))
    [PSCustomObject]@{ ValueExisted = $valueExisted } | ConvertTo-Json | Set-Content -Path $statePath

    return $regPath
}

function Set-ScreenLockBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $result = (Test-ScreenLockBaseline -Config $Config)[0]

    if (-not $result.Pass) {
        Set-InactivityTimeoutValue -Seconds $result.Expected
    }

    @(
        [PSCustomObject]@{
            Module = 'ScreenLock'; Setting = 'InactivityTimeoutSeconds'
            Before = $result.Actual; After = $result.Expected; Changed = (-not $result.Pass)
        }
    )
}

function Restore-ScreenLockSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    $regPath = Join-Path -Path $BackupPath -ChildPath 'screenlock.reg'
    if (-not (Test-Path -Path $regPath)) {
        throw "No screen lock backup found at '$regPath'."
    }
    Import-InactivityTimeoutRegistry -RegPath $regPath

    # If the value didn't exist at backup time, the .reg import above can't remove it
    # (reg import never deletes values it doesn't mention) — strip it explicitly.
    # Backups made before this fix won't have a state file; skip gracefully in that case.
    $statePath = Join-Path -Path $BackupPath -ChildPath 'screenlock-state.json'
    if (Test-Path -Path $statePath) {
        $state = Get-Content -Path $statePath -Raw | ConvertFrom-Json
        if ($state.ValueExisted -eq $false) {
            Remove-InactivityTimeoutValue
        }
    }
}

Export-ModuleMember -Function Test-ScreenLockBaseline, Backup-ScreenLockSettings, Set-ScreenLockBaseline, Restore-ScreenLockSettings
