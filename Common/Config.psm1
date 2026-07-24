$script:RequiredSections = @(
    'PasswordPolicy', 'AccountLockout', 'Defender', 'Firewall',
    'ScreenLock', 'AuditPolicy', 'RemoteAccess', 'BitLocker', 'LocalAccounts',
    'WindowsUpdate', 'PowerShellLogging', 'RemovableStorage', 'UAC', 'NetworkHardening', 'EventLogRetention'
)

function Import-BaselineConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path -Path $Path)) {
        throw "Baseline config file not found at '$Path'."
    }

    $config = Import-PowerShellDataFile -Path $Path

    $missing = $script:RequiredSections | Where-Object { -not $config.ContainsKey($_) }
    if (@($missing).Count -gt 0) {
        throw "Baseline config is missing required section(s): $($missing -join ', ')"
    }

    return $config
}

function Get-BaselineValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Section,
        [Parameter(Mandatory)][string]$Name
    )

    if (-not $Section.ContainsKey($Name)) {
        throw "Config section is missing expected key '$Name'."
    }
    return $Section[$Name].Value
}

function Get-BaselineDescription {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Section,
        [Parameter(Mandatory)][string]$Name
    )

    if (-not $Section.ContainsKey($Name)) {
        throw "Config section is missing expected key '$Name'."
    }
    return $Section[$Name].Description
}

Export-ModuleMember -Function Import-BaselineConfig, Get-BaselineValue, Get-BaselineDescription
