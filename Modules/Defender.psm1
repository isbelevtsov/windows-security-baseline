Import-Module (Join-Path $PSScriptRoot '..\Common\Config.psm1') -Force

function Get-DefenderPreference {
    [CmdletBinding()]
    param()
    Get-MpPreference
}

function Set-DefenderPreference {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Settings)
    Set-MpPreference @Settings
}

function Test-DefenderBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $pref = Get-DefenderPreference

    $realTimeExpected = Get-BaselineValue -Section $Config -Name 'RealTimeProtection'
    $realTimeActual = -not $pref.DisableRealtimeMonitoring

    $cloudExpected = Get-BaselineValue -Section $Config -Name 'CloudProtection'
    $cloudActual = ($pref.MAPSReporting -eq 2)

    $puaExpectedRaw = Get-BaselineValue -Section $Config -Name 'PUAProtection'
    $puaExpected = $(if ($puaExpectedRaw -eq 'Enabled') { 1 } else { 0 })
    $puaActual = [int]$pref.PUAProtection

    @(
        [PSCustomObject]@{
            Module = 'Defender'; Setting = 'RealTimeProtection'
            Expected = $realTimeExpected; Actual = $realTimeActual; Pass = ($realTimeActual -eq $realTimeExpected)
            Description = Get-BaselineDescription -Section $Config -Name 'RealTimeProtection'
        }
        [PSCustomObject]@{
            Module = 'Defender'; Setting = 'CloudProtection'
            Expected = $cloudExpected; Actual = $cloudActual; Pass = ($cloudActual -eq $cloudExpected)
            Description = Get-BaselineDescription -Section $Config -Name 'CloudProtection'
        }
        [PSCustomObject]@{
            Module = 'Defender'; Setting = 'PUAProtection'
            Expected = $puaExpected; Actual = $puaActual; Pass = ($puaActual -eq $puaExpected)
            Description = Get-BaselineDescription -Section $Config -Name 'PUAProtection'
        }
    )
}

function Backup-DefenderSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    New-Item -Path $BackupPath -ItemType Directory -Force | Out-Null
    $jsonPath = Join-Path -Path $BackupPath -ChildPath 'defender-preference.json'
    $pref = Get-DefenderPreference
    [PSCustomObject]@{
        DisableRealtimeMonitoring = $pref.DisableRealtimeMonitoring
        MAPSReporting             = $pref.MAPSReporting
        PUAProtection             = $pref.PUAProtection
    } | ConvertTo-Json | Set-Content -Path $jsonPath
    return $jsonPath
}

function Set-DefenderBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $before = Test-DefenderBaseline -Config $Config

    $changes = foreach ($result in $before) {
        if (-not $result.Pass) {
            switch ($result.Setting) {
                'RealTimeProtection' { Set-DefenderPreference -Settings @{ DisableRealtimeMonitoring = (-not $result.Expected) } }
                'CloudProtection'    { Set-DefenderPreference -Settings @{ MAPSReporting = $(if ($result.Expected) { 2 } else { 0 }) } }
                'PUAProtection'      { Set-DefenderPreference -Settings @{ PUAProtection = $result.Expected } }
            }
        }

        [PSCustomObject]@{
            Module  = 'Defender'
            Setting = $result.Setting
            Before  = $result.Actual
            After   = $result.Expected
            Changed = (-not $result.Pass)
        }
    }

    return $changes
}

function Restore-DefenderSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    $jsonPath = Join-Path -Path $BackupPath -ChildPath 'defender-preference.json'
    if (-not (Test-Path -Path $jsonPath)) {
        throw "No Defender backup found at '$jsonPath'."
    }
    $saved = Get-Content -Path $jsonPath -Raw | ConvertFrom-Json

    Set-DefenderPreference -Settings @{
        DisableRealtimeMonitoring = $saved.DisableRealtimeMonitoring
        MAPSReporting             = $saved.MAPSReporting
        PUAProtection             = $saved.PUAProtection
    }
}

Export-ModuleMember -Function Test-DefenderBaseline, Backup-DefenderSettings, Set-DefenderBaseline, Restore-DefenderSettings
