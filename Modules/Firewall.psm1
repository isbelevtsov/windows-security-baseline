Import-Module (Join-Path $PSScriptRoot '..\Common\Config.psm1') -Force

function Get-FirewallProfileState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProfileName)
    Get-NetFirewallProfile -Name $ProfileName
}

function Set-FirewallProfileState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProfileName,
        [Parameter(Mandatory)][hashtable]$Settings
    )
    Set-NetFirewallProfile -Name $ProfileName @Settings
}

function Invoke-NetshBinary {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments)
    & netsh.exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "netsh.exe failed with exit code $LASTEXITCODE (arguments: $($Arguments -join ' '))"
    }
}

function Test-FirewallBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $expectedProfiles = Get-BaselineValue -Section $Config -Name 'EnabledProfiles'
    $expectedInbound  = Get-BaselineValue -Section $Config -Name 'DefaultInboundAction'
    $expectedLogging  = Get-BaselineValue -Section $Config -Name 'LoggingEnabled'

    $results = foreach ($profileName in $expectedProfiles) {
        $state = Get-FirewallProfileState -ProfileName $profileName
        $enabledActual = [bool]$state.Enabled
        $inboundActual = "$($state.DefaultInboundAction)"
        $loggingActual = ([bool]$state.LogAllowed -and [bool]$state.LogBlocked)

        [PSCustomObject]@{
            Module = 'Firewall'; Setting = "$profileName.Enabled"
            Expected = $true; Actual = $enabledActual; Pass = $enabledActual
            Description = Get-BaselineDescription -Section $Config -Name 'EnabledProfiles'
        }
        [PSCustomObject]@{
            Module = 'Firewall'; Setting = "$profileName.DefaultInboundAction"
            Expected = $expectedInbound; Actual = $inboundActual; Pass = ($inboundActual -eq $expectedInbound)
            Description = Get-BaselineDescription -Section $Config -Name 'DefaultInboundAction'
        }
        [PSCustomObject]@{
            Module = 'Firewall'; Setting = "$profileName.LoggingEnabled"
            Expected = $expectedLogging; Actual = $loggingActual; Pass = ($loggingActual -eq $expectedLogging)
            Description = Get-BaselineDescription -Section $Config -Name 'LoggingEnabled'
        }
    }

    return $results
}

function Backup-FirewallSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    New-Item -Path $BackupPath -ItemType Directory -Force | Out-Null
    $wfwPath = Join-Path -Path $BackupPath -ChildPath 'firewall.wfw'
    Invoke-NetshBinary -Arguments @('advfirewall', 'export', $wfwPath) | Out-Null
    return $wfwPath
}

function Set-FirewallBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $before = Test-FirewallBaseline -Config $Config
    $expectedProfiles = Get-BaselineValue -Section $Config -Name 'EnabledProfiles'
    $expectedInbound  = Get-BaselineValue -Section $Config -Name 'DefaultInboundAction'
    $expectedLogging  = Get-BaselineValue -Section $Config -Name 'LoggingEnabled'

    $changes = foreach ($profileName in $expectedProfiles) {
        $profileResults = @($before | Where-Object { $_.Setting -like "$profileName.*" })
        $needsChange = @($profileResults | Where-Object { -not $_.Pass }).Count -gt 0

        if ($needsChange) {
            Set-FirewallProfileState -ProfileName $profileName -Settings @{
                Enabled              = $true
                DefaultInboundAction = $expectedInbound
                LogAllowed           = $expectedLogging
                LogBlocked           = $expectedLogging
            }
        }

        foreach ($result in $profileResults) {
            [PSCustomObject]@{
                Module  = 'Firewall'
                Setting = $result.Setting
                Before  = $result.Actual
                After   = $result.Expected
                Changed = (-not $result.Pass)
            }
        }
    }

    return $changes
}

function Restore-FirewallSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    $wfwPath = Join-Path -Path $BackupPath -ChildPath 'firewall.wfw'
    if (-not (Test-Path -Path $wfwPath)) {
        throw "No firewall backup found at '$wfwPath'."
    }
    Invoke-NetshBinary -Arguments @('advfirewall', 'import', $wfwPath) | Out-Null
}

Export-ModuleMember -Function Test-FirewallBaseline, Backup-FirewallSettings, Set-FirewallBaseline, Restore-FirewallSettings
