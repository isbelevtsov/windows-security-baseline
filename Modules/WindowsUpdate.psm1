Import-Module (Join-Path $PSScriptRoot '..\Common\Config.psm1') -Force

# Registry-policy paths for standalone/workgroup devices with no WSUS/Intune
# to push these via real Group Policy - writing directly under
# HKLM:\SOFTWARE\Policies mirrors what a domain GPO would set, without
# requiring one.
$script:AuPolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
$script:WuPolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'

function Get-WindowsUpdateServiceStartType {
    [CmdletBinding()]
    param()
    "$((Get-Service -Name wuauserv).StartType)"
}

function Set-WindowsUpdateServiceStartType {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StartupType)
    Set-Service -Name wuauserv -StartupType $StartupType
}

function Get-RegistryDwordOrDefault {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Default
    )
    $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $Default }
    return [int]$item.$Name
}

function Test-RegistryValueExists {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    $null -ne (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue)
}

function Set-RegistryDword {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Value
    )
    if (-not (Test-Path -Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
}

function Remove-RegistryValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    Remove-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
}

function Test-WindowsUpdateBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $autoUpdateExpected = Get-BaselineValue -Section $Config -Name 'AutomaticUpdatesEnabled'
    $autoUpdateDescription = Get-BaselineDescription -Section $Config -Name 'AutomaticUpdatesEnabled'
    $deferExpected = Get-BaselineValue -Section $Config -Name 'DeferQualityUpdatesDays'
    $deferDescription = Get-BaselineDescription -Section $Config -Name 'DeferQualityUpdatesDays'

    $serviceActual = ((Get-WindowsUpdateServiceStartType) -ne 'Disabled')
    # NoAutoUpdate/AUOptions default to "enabled"/"auto download+install" when
    # absent - matching Windows' own out-of-box behavior on a standalone
    # device with no policy configured, so an unconfigured machine reads as
    # compliant rather than failing until this module has run once.
    $autoUpdateActual = ((Get-RegistryDwordOrDefault -Path $script:AuPolicyPath -Name 'NoAutoUpdate' -Default 0) -eq 0)
    $auOptionsActual = ((Get-RegistryDwordOrDefault -Path $script:AuPolicyPath -Name 'AUOptions' -Default 4) -eq 4)
    $deferDays = Get-RegistryDwordOrDefault -Path $script:WuPolicyPath -Name 'DeferQualityUpdatesPeriodInDays' -Default 0

    @(
        [PSCustomObject]@{
            Module = 'WindowsUpdate'; Setting = 'ServiceNotDisabled'
            Expected = $true; Actual = $serviceActual; Pass = $serviceActual
            Description = 'The Windows Update service (wuauserv) must not be disabled, or updates can never be checked for or installed at all.'
        }
        [PSCustomObject]@{
            Module = 'WindowsUpdate'; Setting = 'AutomaticUpdatesEnabled'
            Expected = $autoUpdateExpected; Actual = $autoUpdateActual; Pass = ($autoUpdateActual -eq $autoUpdateExpected)
            Description = $autoUpdateDescription
        }
        [PSCustomObject]@{
            Module = 'WindowsUpdate'; Setting = 'AutoDownloadAndInstall'
            Expected = $true; Actual = $auOptionsActual; Pass = $auOptionsActual
            Description = 'Configures Windows Update to automatically download and schedule installation of updates (AUOptions=4) instead of only notifying.'
        }
        [PSCustomObject]@{
            Module = 'WindowsUpdate'; Setting = 'DeferQualityUpdatesDays'
            Expected = $deferExpected; Actual = $deferDays; Pass = ($deferDays -le $deferExpected)
            Description = $deferDescription
        }
    )
}

function Backup-WindowsUpdateSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    New-Item -Path $BackupPath -ItemType Directory -Force | Out-Null
    $statePath = Join-Path -Path $BackupPath -ChildPath 'windows-update-state.json'

    [PSCustomObject]@{
        ServiceStartType         = Get-WindowsUpdateServiceStartType
        NoAutoUpdateExisted      = Test-RegistryValueExists -Path $script:AuPolicyPath -Name 'NoAutoUpdate'
        NoAutoUpdateValue        = Get-RegistryDwordOrDefault -Path $script:AuPolicyPath -Name 'NoAutoUpdate' -Default 0
        AUOptionsExisted         = Test-RegistryValueExists -Path $script:AuPolicyPath -Name 'AUOptions'
        AUOptionsValue           = Get-RegistryDwordOrDefault -Path $script:AuPolicyPath -Name 'AUOptions' -Default 4
        DeferQualityExisted      = Test-RegistryValueExists -Path $script:WuPolicyPath -Name 'DeferQualityUpdatesPeriodInDays'
        DeferQualityValue        = Get-RegistryDwordOrDefault -Path $script:WuPolicyPath -Name 'DeferQualityUpdatesPeriodInDays' -Default 0
    } | ConvertTo-Json | Set-Content -Path $statePath

    return $statePath
}

function Set-WindowsUpdateBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $before = Test-WindowsUpdateBaseline -Config $Config
    $deferDaysExpected = Get-BaselineValue -Section $Config -Name 'DeferQualityUpdatesDays'

    foreach ($result in $before) {
        if (-not $result.Pass) {
            switch ($result.Setting) {
                'ServiceNotDisabled'       { Set-WindowsUpdateServiceStartType -StartupType 'Manual' }
                'AutomaticUpdatesEnabled'  { Set-RegistryDword -Path $script:AuPolicyPath -Name 'NoAutoUpdate' -Value 0 }
                'AutoDownloadAndInstall'   { Set-RegistryDword -Path $script:AuPolicyPath -Name 'AUOptions' -Value 4 }
                'DeferQualityUpdatesDays'  { Set-RegistryDword -Path $script:WuPolicyPath -Name 'DeferQualityUpdatesPeriodInDays' -Value $deferDaysExpected }
            }
        }
    }

    foreach ($result in $before) {
        [PSCustomObject]@{
            Module  = 'WindowsUpdate'
            Setting = $result.Setting
            Before  = $result.Actual
            After   = $result.Expected
            Changed = (-not $result.Pass)
        }
    }
}

function Restore-WindowsUpdateSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    $statePath = Join-Path -Path $BackupPath -ChildPath 'windows-update-state.json'
    if (-not (Test-Path -Path $statePath)) {
        throw "No Windows Update backup found at '$statePath'."
    }
    $saved = Get-Content -Path $statePath -Raw | ConvertFrom-Json

    if ($saved.ServiceStartType) {
        Set-WindowsUpdateServiceStartType -StartupType $saved.ServiceStartType
    }

    if ($saved.NoAutoUpdateExisted) {
        Set-RegistryDword -Path $script:AuPolicyPath -Name 'NoAutoUpdate' -Value $saved.NoAutoUpdateValue
    }
    else {
        Remove-RegistryValue -Path $script:AuPolicyPath -Name 'NoAutoUpdate'
    }

    if ($saved.AUOptionsExisted) {
        Set-RegistryDword -Path $script:AuPolicyPath -Name 'AUOptions' -Value $saved.AUOptionsValue
    }
    else {
        Remove-RegistryValue -Path $script:AuPolicyPath -Name 'AUOptions'
    }

    if ($saved.DeferQualityExisted) {
        Set-RegistryDword -Path $script:WuPolicyPath -Name 'DeferQualityUpdatesPeriodInDays' -Value $saved.DeferQualityValue
    }
    else {
        Remove-RegistryValue -Path $script:WuPolicyPath -Name 'DeferQualityUpdatesPeriodInDays'
    }
}

Export-ModuleMember -Function Test-WindowsUpdateBaseline, Backup-WindowsUpdateSettings, Set-WindowsUpdateBaseline, Restore-WindowsUpdateSettings
