Import-Module (Join-Path $PSScriptRoot '..\Common\Config.psm1') -Force

$script:RdpRegistryPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'

function Get-RdpDenyValue {
    [CmdletBinding()]
    param()
    $item = Get-ItemProperty -Path $script:RdpRegistryPath -Name 'fDenyTSConnections' -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    return [bool]$item.fDenyTSConnections
}

function Set-RdpDenyValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][bool]$Deny)
    Set-ItemProperty -Path $script:RdpRegistryPath -Name 'fDenyTSConnections' -Value ([int]$Deny) -Type DWord
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

function Export-RemoteAccessRegistry {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RegPath)
    & reg.exe export 'HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server' $RegPath /y
    if ($LASTEXITCODE -ne 0) {
        throw "reg.exe failed with exit code $LASTEXITCODE (arguments: export 'HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server' $RegPath /y)"
    }
}

function Import-RemoteAccessRegistry {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RegPath)
    & reg.exe import $RegPath
    if ($LASTEXITCODE -ne 0) {
        throw "reg.exe failed with exit code $LASTEXITCODE (arguments: import $RegPath)"
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
    $regPath = Join-Path -Path $BackupPath -ChildPath 'remote-access.reg'
    Export-RemoteAccessRegistry -RegPath $regPath

    $statePath = Join-Path -Path $BackupPath -ChildPath 'remote-access-state.json'
    [PSCustomObject]@{
        Smb1Enabled  = Get-Smb1Enabled
        GuestEnabled = Get-GuestAccountEnabled
    } | ConvertTo-Json | Set-Content -Path $statePath

    return @($regPath, $statePath)
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

    $regPath = Join-Path -Path $BackupPath -ChildPath 'remote-access.reg'
    $statePath = Join-Path -Path $BackupPath -ChildPath 'remote-access-state.json'

    if (-not (Test-Path -Path $regPath) -or -not (Test-Path -Path $statePath)) {
        throw "No remote access backup found at '$BackupPath'."
    }

    Import-RemoteAccessRegistry -RegPath $regPath

    $saved = Get-Content -Path $statePath -Raw | ConvertFrom-Json
    Set-Smb1Enabled -Enabled $saved.Smb1Enabled
    Set-GuestAccountEnabled -Enabled $saved.GuestEnabled
}

Export-ModuleMember -Function Test-RemoteAccessBaseline, Backup-RemoteAccessSettings, Set-RemoteAccessBaseline, Restore-RemoteAccessSettings
