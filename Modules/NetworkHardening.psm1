Import-Module (Join-Path $PSScriptRoot '..\Common\Config.psm1') -Force

$script:LsaPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
$script:DnsClientPolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient'

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

function Test-NetworkHardeningBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $ntlmExpected = Get-BaselineValue -Section $Config -Name 'LmCompatibilityLevel'
    $llmnrExpected = Get-BaselineValue -Section $Config -Name 'DisableLLMNR'

    # Default of 3 ("Send NTLMv2 response only") matches modern Windows'
    # own out-of-box value when the policy is unconfigured.
    $ntlmActual = Get-RegistryDwordOrDefault -Path $script:LsaPath -Name 'LmCompatibilityLevel' -Default 3
    $llmnrActual = ((Get-RegistryDwordOrDefault -Path $script:DnsClientPolicyPath -Name 'EnableMulticast' -Default 1) -eq 0)

    @(
        [PSCustomObject]@{
            Module = 'NetworkHardening'; Setting = 'LmCompatibilityLevel'
            Expected = $ntlmExpected; Actual = $ntlmActual; Pass = ($ntlmActual -ge $ntlmExpected)
            Description = Get-BaselineDescription -Section $Config -Name 'LmCompatibilityLevel'
        }
        [PSCustomObject]@{
            Module = 'NetworkHardening'; Setting = 'LLMNRDisabled'
            Expected = $llmnrExpected; Actual = $llmnrActual; Pass = ($llmnrActual -eq $llmnrExpected)
            Description = Get-BaselineDescription -Section $Config -Name 'DisableLLMNR'
        }
    )
}

function Backup-NetworkHardeningSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    New-Item -Path $BackupPath -ItemType Directory -Force | Out-Null
    $statePath = Join-Path -Path $BackupPath -ChildPath 'network-hardening-state.json'

    [PSCustomObject]@{
        LmCompatibilityLevelExisted = Test-RegistryValueExists -Path $script:LsaPath -Name 'LmCompatibilityLevel'
        LmCompatibilityLevelValue   = Get-RegistryDwordOrDefault -Path $script:LsaPath -Name 'LmCompatibilityLevel' -Default 3
        EnableMulticastExisted      = Test-RegistryValueExists -Path $script:DnsClientPolicyPath -Name 'EnableMulticast'
        EnableMulticastValue        = Get-RegistryDwordOrDefault -Path $script:DnsClientPolicyPath -Name 'EnableMulticast' -Default 1
    } | ConvertTo-Json | Set-Content -Path $statePath

    return $statePath
}

function Set-NetworkHardeningBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $before = Test-NetworkHardeningBaseline -Config $Config

    foreach ($result in $before) {
        if (-not $result.Pass) {
            switch ($result.Setting) {
                'LmCompatibilityLevel' { Set-RegistryDword -Path $script:LsaPath -Name 'LmCompatibilityLevel' -Value $result.Expected }
                'LLMNRDisabled'        { Set-RegistryDword -Path $script:DnsClientPolicyPath -Name 'EnableMulticast' -Value $(if ($result.Expected) { 0 } else { 1 }) }
            }
        }
    }

    foreach ($result in $before) {
        [PSCustomObject]@{
            Module  = 'NetworkHardening'
            Setting = $result.Setting
            Before  = $result.Actual
            After   = $result.Expected
            Changed = (-not $result.Pass)
        }
    }
}

function Restore-NetworkHardeningSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    $statePath = Join-Path -Path $BackupPath -ChildPath 'network-hardening-state.json'
    if (-not (Test-Path -Path $statePath)) {
        throw "No network hardening backup found at '$statePath'."
    }
    $saved = Get-Content -Path $statePath -Raw | ConvertFrom-Json

    if ($saved.LmCompatibilityLevelExisted) { Set-RegistryDword -Path $script:LsaPath -Name 'LmCompatibilityLevel' -Value $saved.LmCompatibilityLevelValue }
    else { Remove-RegistryValue -Path $script:LsaPath -Name 'LmCompatibilityLevel' }

    if ($saved.EnableMulticastExisted) { Set-RegistryDword -Path $script:DnsClientPolicyPath -Name 'EnableMulticast' -Value $saved.EnableMulticastValue }
    else { Remove-RegistryValue -Path $script:DnsClientPolicyPath -Name 'EnableMulticast' }
}

Export-ModuleMember -Function Test-NetworkHardeningBaseline, Backup-NetworkHardeningSettings, Set-NetworkHardeningBaseline, Restore-NetworkHardeningSettings
