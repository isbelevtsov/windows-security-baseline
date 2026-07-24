Import-Module (Join-Path $PSScriptRoot '..\Common\Config.psm1') -Force

# {53f5630d-b6bf-11d0-94f2-00a0c91efb8b} is the well-known "Removable Disks"
# device-class GUID under the standard Removable Storage Access Group Policy
# path - writing it directly lets a standalone/workgroup device get the same
# effect without a domain GPO. Only Deny_Write is managed here (blocks writes,
# leaves read access alone) - Deny_Read is a separate, real value under this
# same key that this module deliberately never touches.
$script:RemovableDisksPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices\{53f5630d-b6bf-11d0-94f2-00a0c91efb8b}'

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

function Test-RemovableStorageBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $expected = Get-BaselineValue -Section $Config -Name 'DenyWriteAccess'
    $actual = ((Get-RegistryDwordOrDefault -Path $script:RemovableDisksPath -Name 'Deny_Write' -Default 0) -eq 1)

    @(
        [PSCustomObject]@{
            Module = 'RemovableStorage'; Setting = 'RemovableDisksWriteDenied'
            Expected = $expected; Actual = $actual; Pass = ($actual -eq $expected)
            Description = Get-BaselineDescription -Section $Config -Name 'DenyWriteAccess'
        }
    )
}

function Backup-RemovableStorageSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    New-Item -Path $BackupPath -ItemType Directory -Force | Out-Null
    $statePath = Join-Path -Path $BackupPath -ChildPath 'removable-storage-state.json'

    [PSCustomObject]@{
        DenyWriteExisted = Test-RegistryValueExists -Path $script:RemovableDisksPath -Name 'Deny_Write'
        DenyWriteValue   = Get-RegistryDwordOrDefault -Path $script:RemovableDisksPath -Name 'Deny_Write' -Default 0
    } | ConvertTo-Json | Set-Content -Path $statePath

    return $statePath
}

function Set-RemovableStorageBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $result = (Test-RemovableStorageBaseline -Config $Config)[0]

    if (-not $result.Pass) {
        Set-RegistryDword -Path $script:RemovableDisksPath -Name 'Deny_Write' -Value ([int][bool]$result.Expected)
    }

    @(
        [PSCustomObject]@{
            Module = 'RemovableStorage'; Setting = 'RemovableDisksWriteDenied'
            Before = $result.Actual; After = $result.Expected; Changed = (-not $result.Pass)
        }
    )
}

function Restore-RemovableStorageSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    $statePath = Join-Path -Path $BackupPath -ChildPath 'removable-storage-state.json'
    if (-not (Test-Path -Path $statePath)) {
        throw "No removable storage backup found at '$statePath'."
    }
    $saved = Get-Content -Path $statePath -Raw | ConvertFrom-Json

    if ($saved.DenyWriteExisted) {
        Set-RegistryDword -Path $script:RemovableDisksPath -Name 'Deny_Write' -Value $saved.DenyWriteValue
    }
    else {
        Remove-RegistryValue -Path $script:RemovableDisksPath -Name 'Deny_Write'
    }
}

Export-ModuleMember -Function Test-RemovableStorageBaseline, Backup-RemovableStorageSettings, Set-RemovableStorageBaseline, Restore-RemovableStorageSettings
