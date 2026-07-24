Import-Module (Join-Path $PSScriptRoot '..\Common\Config.psm1') -Force

# Registry-policy paths - mirrors what a domain GPO would push under
# "Administrative Templates > Windows Components > Windows PowerShell",
# without requiring AD/GPO on a standalone device.
$script:ScriptBlockLoggingPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging'
$script:ModuleLoggingPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging'
$script:ModuleNamesPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging\ModuleNames'
$script:TranscriptionPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\Transcription'

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

function Get-RegistryStringOrDefault {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [string]$Default = $null
    )
    $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $Default }
    return "$($item.$Name)"
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

function Set-RegistryString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )
    if (-not (Test-Path -Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType String -Force | Out-Null
}

function Remove-RegistryValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    Remove-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
}

function Test-PowerShellLoggingBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $scriptBlockExpected = Get-BaselineValue -Section $Config -Name 'EnableScriptBlockLogging'
    $moduleExpected = Get-BaselineValue -Section $Config -Name 'EnableModuleLogging'
    $transcriptExpected = Get-BaselineValue -Section $Config -Name 'EnableTranscription'
    $outputPathExpected = Get-BaselineValue -Section $Config -Name 'TranscriptOutputPath'

    $scriptBlockActual = ((Get-RegistryDwordOrDefault -Path $script:ScriptBlockLoggingPath -Name 'EnableScriptBlockLogging' -Default 0) -eq 1)
    $moduleActual = ((Get-RegistryDwordOrDefault -Path $script:ModuleLoggingPath -Name 'EnableModuleLogging' -Default 0) -eq 1)
    $moduleNamesActual = ((Get-RegistryStringOrDefault -Path $script:ModuleNamesPath -Name '*') -eq '*')
    $transcriptActual = ((Get-RegistryDwordOrDefault -Path $script:TranscriptionPath -Name 'EnableTranscripting' -Default 0) -eq 1)
    $outputPathActual = Get-RegistryStringOrDefault -Path $script:TranscriptionPath -Name 'OutputDirectory'

    @(
        [PSCustomObject]@{
            Module = 'PowerShellLogging'; Setting = 'ScriptBlockLogging'
            Expected = $scriptBlockExpected; Actual = $scriptBlockActual; Pass = ($scriptBlockActual -eq $scriptBlockExpected)
            Description = Get-BaselineDescription -Section $Config -Name 'EnableScriptBlockLogging'
        }
        [PSCustomObject]@{
            Module = 'PowerShellLogging'; Setting = 'ModuleLogging'
            Expected = $moduleExpected; Actual = $moduleActual; Pass = ($moduleActual -eq $moduleExpected)
            Description = Get-BaselineDescription -Section $Config -Name 'EnableModuleLogging'
        }
        [PSCustomObject]@{
            Module = 'PowerShellLogging'; Setting = 'ModuleLoggingCoversAllModules'
            Expected = $moduleExpected; Actual = $moduleNamesActual; Pass = ($moduleNamesActual -eq $moduleExpected)
            Description = 'Module logging is scoped to all modules (ModuleNames\* = "*") rather than an incomplete allow-list.'
        }
        [PSCustomObject]@{
            Module = 'PowerShellLogging'; Setting = 'Transcription'
            Expected = $transcriptExpected; Actual = $transcriptActual; Pass = ($transcriptActual -eq $transcriptExpected)
            Description = Get-BaselineDescription -Section $Config -Name 'EnableTranscription'
        }
        [PSCustomObject]@{
            Module = 'PowerShellLogging'; Setting = 'TranscriptOutputPath'
            Expected = $outputPathExpected; Actual = $outputPathActual; Pass = ($outputPathActual -eq $outputPathExpected)
            Description = Get-BaselineDescription -Section $Config -Name 'TranscriptOutputPath'
        }
    )
}

function Backup-PowerShellLoggingSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    New-Item -Path $BackupPath -ItemType Directory -Force | Out-Null
    $statePath = Join-Path -Path $BackupPath -ChildPath 'powershell-logging-state.json'

    [PSCustomObject]@{
        ScriptBlockLoggingExisted = Test-RegistryValueExists -Path $script:ScriptBlockLoggingPath -Name 'EnableScriptBlockLogging'
        ScriptBlockLoggingValue   = Get-RegistryDwordOrDefault -Path $script:ScriptBlockLoggingPath -Name 'EnableScriptBlockLogging' -Default 0
        ModuleLoggingExisted      = Test-RegistryValueExists -Path $script:ModuleLoggingPath -Name 'EnableModuleLogging'
        ModuleLoggingValue        = Get-RegistryDwordOrDefault -Path $script:ModuleLoggingPath -Name 'EnableModuleLogging' -Default 0
        ModuleNamesExisted        = Test-RegistryValueExists -Path $script:ModuleNamesPath -Name '*'
        ModuleNamesValue          = Get-RegistryStringOrDefault -Path $script:ModuleNamesPath -Name '*'
        TranscriptionExisted      = Test-RegistryValueExists -Path $script:TranscriptionPath -Name 'EnableTranscripting'
        TranscriptionValue        = Get-RegistryDwordOrDefault -Path $script:TranscriptionPath -Name 'EnableTranscripting' -Default 0
        OutputDirectoryExisted    = Test-RegistryValueExists -Path $script:TranscriptionPath -Name 'OutputDirectory'
        OutputDirectoryValue      = Get-RegistryStringOrDefault -Path $script:TranscriptionPath -Name 'OutputDirectory'
    } | ConvertTo-Json | Set-Content -Path $statePath

    return $statePath
}

function Set-PowerShellLoggingBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $before = Test-PowerShellLoggingBaseline -Config $Config
    $outputPathExpected = Get-BaselineValue -Section $Config -Name 'TranscriptOutputPath'

    foreach ($result in $before) {
        if (-not $result.Pass) {
            switch ($result.Setting) {
                'ScriptBlockLogging'            { Set-RegistryDword -Path $script:ScriptBlockLoggingPath -Name 'EnableScriptBlockLogging' -Value ([int][bool]$result.Expected) }
                'ModuleLogging'                 { Set-RegistryDword -Path $script:ModuleLoggingPath -Name 'EnableModuleLogging' -Value ([int][bool]$result.Expected) }
                'ModuleLoggingCoversAllModules' { if ($result.Expected) { Set-RegistryString -Path $script:ModuleNamesPath -Name '*' -Value '*' } }
                'Transcription'                 { Set-RegistryDword -Path $script:TranscriptionPath -Name 'EnableTranscripting' -Value ([int][bool]$result.Expected) }
                'TranscriptOutputPath'          {
                    if (-not (Test-Path -Path $outputPathExpected)) {
                        New-Item -Path $outputPathExpected -ItemType Directory -Force | Out-Null
                    }
                    Set-RegistryString -Path $script:TranscriptionPath -Name 'OutputDirectory' -Value $outputPathExpected
                }
            }
        }
    }

    foreach ($result in $before) {
        [PSCustomObject]@{
            Module  = 'PowerShellLogging'
            Setting = $result.Setting
            Before  = $result.Actual
            After   = $result.Expected
            Changed = (-not $result.Pass)
        }
    }
}

function Restore-PowerShellLoggingSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    $statePath = Join-Path -Path $BackupPath -ChildPath 'powershell-logging-state.json'
    if (-not (Test-Path -Path $statePath)) {
        throw "No PowerShell logging backup found at '$statePath'."
    }
    $saved = Get-Content -Path $statePath -Raw | ConvertFrom-Json

    if ($saved.ScriptBlockLoggingExisted) { Set-RegistryDword -Path $script:ScriptBlockLoggingPath -Name 'EnableScriptBlockLogging' -Value $saved.ScriptBlockLoggingValue }
    else { Remove-RegistryValue -Path $script:ScriptBlockLoggingPath -Name 'EnableScriptBlockLogging' }

    if ($saved.ModuleLoggingExisted) { Set-RegistryDword -Path $script:ModuleLoggingPath -Name 'EnableModuleLogging' -Value $saved.ModuleLoggingValue }
    else { Remove-RegistryValue -Path $script:ModuleLoggingPath -Name 'EnableModuleLogging' }

    if ($saved.ModuleNamesExisted) { Set-RegistryString -Path $script:ModuleNamesPath -Name '*' -Value $saved.ModuleNamesValue }
    else { Remove-RegistryValue -Path $script:ModuleNamesPath -Name '*' }

    if ($saved.TranscriptionExisted) { Set-RegistryDword -Path $script:TranscriptionPath -Name 'EnableTranscripting' -Value $saved.TranscriptionValue }
    else { Remove-RegistryValue -Path $script:TranscriptionPath -Name 'EnableTranscripting' }

    if ($saved.OutputDirectoryExisted) { Set-RegistryString -Path $script:TranscriptionPath -Name 'OutputDirectory' -Value $saved.OutputDirectoryValue }
    else { Remove-RegistryValue -Path $script:TranscriptionPath -Name 'OutputDirectory' }
}

Export-ModuleMember -Function Test-PowerShellLoggingBaseline, Backup-PowerShellLoggingSettings, Set-PowerShellLoggingBaseline, Restore-PowerShellLoggingSettings
