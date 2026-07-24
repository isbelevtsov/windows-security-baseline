Import-Module (Join-Path $PSScriptRoot '..\Common\Config.psm1') -Force

# Same registry key secpol.msc's "Security Options > User Account Control"
# entries edit directly - a real local policy path, not exclusively a
# domain-GPO one, so it works identically on a standalone/workgroup device.
$script:UacPolicyPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'

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

function Test-UACBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $lueExpected = Get-BaselineValue -Section $Config -Name 'EnableLUA'
    $consentExpected = Get-BaselineValue -Section $Config -Name 'ConsentPromptBehaviorAdmin'
    $secureDesktopExpected = Get-BaselineValue -Section $Config -Name 'PromptOnSecureDesktop'

    $lueActual = ((Get-RegistryDwordOrDefault -Path $script:UacPolicyPath -Name 'EnableLUA' -Default 1) -eq 1)
    $consentActual = Get-RegistryDwordOrDefault -Path $script:UacPolicyPath -Name 'ConsentPromptBehaviorAdmin' -Default 5
    $secureDesktopActual = ((Get-RegistryDwordOrDefault -Path $script:UacPolicyPath -Name 'PromptOnSecureDesktop' -Default 1) -eq 1)

    @(
        [PSCustomObject]@{
            Module = 'UAC'; Setting = 'EnableLUA'
            Expected = $lueExpected; Actual = $lueActual; Pass = ($lueActual -eq $lueExpected)
            Description = Get-BaselineDescription -Section $Config -Name 'EnableLUA'
        }
        [PSCustomObject]@{
            Module = 'UAC'; Setting = 'ConsentPromptBehaviorAdmin'
            Expected = $consentExpected; Actual = $consentActual; Pass = ($consentActual -eq $consentExpected)
            Description = Get-BaselineDescription -Section $Config -Name 'ConsentPromptBehaviorAdmin'
        }
        [PSCustomObject]@{
            Module = 'UAC'; Setting = 'PromptOnSecureDesktop'
            Expected = $secureDesktopExpected; Actual = $secureDesktopActual; Pass = ($secureDesktopActual -eq $secureDesktopExpected)
            Description = Get-BaselineDescription -Section $Config -Name 'PromptOnSecureDesktop'
        }
    )
}

function Backup-UACSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    New-Item -Path $BackupPath -ItemType Directory -Force | Out-Null
    $statePath = Join-Path -Path $BackupPath -ChildPath 'uac-state.json'

    [PSCustomObject]@{
        EnableLUAExisted                  = Test-RegistryValueExists -Path $script:UacPolicyPath -Name 'EnableLUA'
        EnableLUAValue                    = Get-RegistryDwordOrDefault -Path $script:UacPolicyPath -Name 'EnableLUA' -Default 1
        ConsentPromptBehaviorAdminExisted = Test-RegistryValueExists -Path $script:UacPolicyPath -Name 'ConsentPromptBehaviorAdmin'
        ConsentPromptBehaviorAdminValue   = Get-RegistryDwordOrDefault -Path $script:UacPolicyPath -Name 'ConsentPromptBehaviorAdmin' -Default 5
        PromptOnSecureDesktopExisted      = Test-RegistryValueExists -Path $script:UacPolicyPath -Name 'PromptOnSecureDesktop'
        PromptOnSecureDesktopValue        = Get-RegistryDwordOrDefault -Path $script:UacPolicyPath -Name 'PromptOnSecureDesktop' -Default 1
    } | ConvertTo-Json | Set-Content -Path $statePath

    return $statePath
}

function Set-UACBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $before = Test-UACBaseline -Config $Config

    foreach ($result in $before) {
        if (-not $result.Pass) {
            switch ($result.Setting) {
                'EnableLUA'                  { Set-RegistryDword -Path $script:UacPolicyPath -Name 'EnableLUA' -Value ([int][bool]$result.Expected) }
                'ConsentPromptBehaviorAdmin' { Set-RegistryDword -Path $script:UacPolicyPath -Name 'ConsentPromptBehaviorAdmin' -Value $result.Expected }
                'PromptOnSecureDesktop'      { Set-RegistryDword -Path $script:UacPolicyPath -Name 'PromptOnSecureDesktop' -Value ([int][bool]$result.Expected) }
            }
        }
    }

    foreach ($result in $before) {
        [PSCustomObject]@{
            Module  = 'UAC'
            Setting = $result.Setting
            Before  = $result.Actual
            After   = $result.Expected
            Changed = (-not $result.Pass)
        }
    }
}

function Restore-UACSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    $statePath = Join-Path -Path $BackupPath -ChildPath 'uac-state.json'
    if (-not (Test-Path -Path $statePath)) {
        throw "No UAC backup found at '$statePath'."
    }
    $saved = Get-Content -Path $statePath -Raw | ConvertFrom-Json

    if ($saved.EnableLUAExisted) { Set-RegistryDword -Path $script:UacPolicyPath -Name 'EnableLUA' -Value $saved.EnableLUAValue }
    else { Remove-RegistryValue -Path $script:UacPolicyPath -Name 'EnableLUA' }

    if ($saved.ConsentPromptBehaviorAdminExisted) { Set-RegistryDword -Path $script:UacPolicyPath -Name 'ConsentPromptBehaviorAdmin' -Value $saved.ConsentPromptBehaviorAdminValue }
    else { Remove-RegistryValue -Path $script:UacPolicyPath -Name 'ConsentPromptBehaviorAdmin' }

    if ($saved.PromptOnSecureDesktopExisted) { Set-RegistryDword -Path $script:UacPolicyPath -Name 'PromptOnSecureDesktop' -Value $saved.PromptOnSecureDesktopValue }
    else { Remove-RegistryValue -Path $script:UacPolicyPath -Name 'PromptOnSecureDesktop' }
}

Export-ModuleMember -Function Test-UACBaseline, Backup-UACSettings, Set-UACBaseline, Restore-UACSettings
