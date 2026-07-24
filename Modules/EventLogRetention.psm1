Import-Module (Join-Path $PSScriptRoot '..\Common\Config.psm1') -Force

$script:LogNames = @('Application', 'Security', 'System')

function Get-EventLogMaxSizeBytes {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LogName)
    (Get-WinEvent -ListLog $LogName).MaximumSizeInBytes
}

function Set-EventLogMaxSizeBytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LogName,
        [Parameter(Mandatory)][long]$Bytes
    )
    # wevtutil, not Limit-EventLog: the classic cmdlet doesn't reliably manage
    # the modern channel-based Security log on every Windows version, while
    # wevtutil operates on the same channel API regardless of log name.
    & wevtutil.exe sl $LogName "/ms:$Bytes"
    if ($LASTEXITCODE -ne 0) {
        throw "wevtutil.exe failed with exit code $LASTEXITCODE (log: $LogName, maxSize: $Bytes)"
    }
}

function Test-EventLogRetentionBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $expected = Get-BaselineValue -Section $Config -Name 'MinimumMaxSizeBytes'
    $description = Get-BaselineDescription -Section $Config -Name 'MinimumMaxSizeBytes'

    foreach ($logName in $script:LogNames) {
        $actual = Get-EventLogMaxSizeBytes -LogName $logName
        [PSCustomObject]@{
            Module = 'EventLogRetention'; Setting = "$logName.MaxSizeBytes"
            Expected = $expected; Actual = $actual; Pass = ($actual -ge $expected)
            Description = $description
        }
    }
}

function Backup-EventLogRetentionSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    New-Item -Path $BackupPath -ItemType Directory -Force | Out-Null
    $statePath = Join-Path -Path $BackupPath -ChildPath 'event-log-retention-state.json'

    $state = @{}
    foreach ($logName in $script:LogNames) {
        $state[$logName] = Get-EventLogMaxSizeBytes -LogName $logName
    }

    [PSCustomObject]$state | ConvertTo-Json | Set-Content -Path $statePath
    return $statePath
}

function Set-EventLogRetentionBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $before = @(Test-EventLogRetentionBaseline -Config $Config)

    foreach ($result in $before) {
        if (-not $result.Pass) {
            $logName = $result.Setting -replace '\.MaxSizeBytes$', ''
            Set-EventLogMaxSizeBytes -LogName $logName -Bytes $result.Expected
        }
    }

    foreach ($result in $before) {
        [PSCustomObject]@{
            Module  = 'EventLogRetention'
            Setting = $result.Setting
            Before  = $result.Actual
            After   = $result.Expected
            Changed = (-not $result.Pass)
        }
    }
}

function Restore-EventLogRetentionSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    $statePath = Join-Path -Path $BackupPath -ChildPath 'event-log-retention-state.json'
    if (-not (Test-Path -Path $statePath)) {
        throw "No event log retention backup found at '$statePath'."
    }
    $saved = Get-Content -Path $statePath -Raw | ConvertFrom-Json

    foreach ($logName in $script:LogNames) {
        $savedSize = $saved.$logName
        if ($null -ne $savedSize) {
            Set-EventLogMaxSizeBytes -LogName $logName -Bytes $savedSize
        }
    }
}

Export-ModuleMember -Function Test-EventLogRetentionBaseline, Backup-EventLogRetentionSettings, Set-EventLogRetentionBaseline, Restore-EventLogRetentionSettings
