Import-Module (Join-Path $PSScriptRoot '..\Common\Config.psm1') -Force

$script:RdpRegistryPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'

function Get-RdpDenyRawValue {
    [CmdletBinding()]
    param()
    $item = Get-ItemProperty -Path $script:RdpRegistryPath -Name 'fDenyTSConnections' -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    return [int]$item.fDenyTSConnections
}

function Get-RdpDenyValue {
    [CmdletBinding()]
    param()
    $raw = Get-RdpDenyRawValue
    if ($null -eq $raw) { return $null }
    return [bool]$raw
}

function Set-RdpDenyValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][bool]$Deny)
    Set-ItemProperty -Path $script:RdpRegistryPath -Name 'fDenyTSConnections' -Value ([int]$Deny) -Type DWord
}

function Remove-RdpDenyValue {
    [CmdletBinding()]
    param()
    Remove-ItemProperty -Path $script:RdpRegistryPath -Name 'fDenyTSConnections' -ErrorAction SilentlyContinue
}

function Get-Smb1Enabled {
    [CmdletBinding()]
    param()
    (Get-SmbServerConfiguration).EnableSMB1Protocol
}

function Set-Smb1Enabled {
    [CmdletBinding()]
    param([Parameter(Mandatory)][bool]$Enabled)
    Set-SmbServerConfiguration -EnableSMB1Protocol $Enabled -Force
}

function Get-GuestAccountEnabled {
    [CmdletBinding()]
    param()
    (Get-LocalUser -Name 'Guest').Enabled
}

function Set-GuestAccountEnabled {
    [CmdletBinding()]
    param([Parameter(Mandatory)][bool]$Enabled)
    if ($Enabled) {
        Enable-LocalUser -Name 'Guest'
    }
    else {
        Disable-LocalUser -Name 'Guest'
    }
}

function Test-RemoteAccessBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $rdpExpected   = Get-BaselineValue -Section $Config -Name 'DisableRDP'
    $smbExpected   = Get-BaselineValue -Section $Config -Name 'DisableSMBv1'
    $guestExpected = Get-BaselineValue -Section $Config -Name 'DisableGuestAccount'

    $rdpActual   = [bool](Get-RdpDenyValue)
    $smbActual   = -not [bool](Get-Smb1Enabled)
    $guestActual = -not [bool](Get-GuestAccountEnabled)

    @(
        [PSCustomObject]@{ Module = 'RemoteAccess'; Setting = 'DisableRDP'; Expected = $rdpExpected; Actual = $rdpActual; Pass = ($rdpActual -eq $rdpExpected); Description = Get-BaselineDescription -Section $Config -Name 'DisableRDP' }
        [PSCustomObject]@{ Module = 'RemoteAccess'; Setting = 'DisableSMBv1'; Expected = $smbExpected; Actual = $smbActual; Pass = ($smbActual -eq $smbExpected); Description = Get-BaselineDescription -Section $Config -Name 'DisableSMBv1' }
        [PSCustomObject]@{ Module = 'RemoteAccess'; Setting = 'DisableGuestAccount'; Expected = $guestExpected; Actual = $guestActual; Pass = ($guestActual -eq $guestExpected); Description = Get-BaselineDescription -Section $Config -Name 'DisableGuestAccount' }
    )
}

function Backup-RemoteAccessSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    New-Item -Path $BackupPath -ItemType Directory -Force | Out-Null

    # RDP state is captured as a single named value rather than a full
    # `reg export`/`reg import` of the whole Terminal Server key. Confirmed on
    # real Windows hardware: that key tree includes subkeys owned by the
    # actively-running Terminal Services listener (e.g. WinStations\RDP-Tcp,
    # RCM) that `reg import` cannot overwrite while the service holds them
    # open, so Restore failed with "Error accessing the registry" every time
    # even though the export itself succeeded. Only fDenyTSConnections is
    # ever written by this module, so only that value needs to round-trip.
    $rdpRawValue = Get-RdpDenyRawValue

    $statePath = Join-Path -Path $BackupPath -ChildPath 'remote-access-state.json'
    [PSCustomObject]@{
        Smb1Enabled         = Get-Smb1Enabled
        GuestEnabled        = Get-GuestAccountEnabled
        RdpDenyValueExisted = ($null -ne $rdpRawValue)
        RdpDenyValue        = $rdpRawValue
    } | ConvertTo-Json | Set-Content -Path $statePath

    return @($statePath)
}

function Set-RemoteAccessBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $before = Test-RemoteAccessBaseline -Config $Config

    foreach ($result in $before) {
        if ($result.Pass) { continue }

        switch ($result.Setting) {
            'DisableRDP'          { Set-RdpDenyValue -Deny $result.Expected }
            'DisableSMBv1'        { Set-Smb1Enabled -Enabled (-not $result.Expected) }
            'DisableGuestAccount' { Set-GuestAccountEnabled -Enabled (-not $result.Expected) }
        }
    }

    foreach ($result in $before) {
        [PSCustomObject]@{
            Module  = 'RemoteAccess'
            Setting = $result.Setting
            Before  = $result.Actual
            After   = $result.Expected
            Changed = (-not $result.Pass)
        }
    }
}

function Restore-RemoteAccessSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    $statePath = Join-Path -Path $BackupPath -ChildPath 'remote-access-state.json'

    if (-not (Test-Path -Path $statePath)) {
        throw "No remote access backup found at '$BackupPath'."
    }

    $saved = Get-Content -Path $statePath -Raw | ConvertFrom-Json

    if ($saved.RdpDenyValueExisted) {
        Set-ItemProperty -Path $script:RdpRegistryPath -Name 'fDenyTSConnections' -Value ([int]$saved.RdpDenyValue) -Type DWord
    }
    else {
        Remove-RdpDenyValue
    }

    Set-Smb1Enabled -Enabled $saved.Smb1Enabled
    Set-GuestAccountEnabled -Enabled $saved.GuestEnabled
}

Export-ModuleMember -Function Test-RemoteAccessBaseline, Backup-RemoteAccessSettings, Set-RemoteAccessBaseline, Restore-RemoteAccessSettings
