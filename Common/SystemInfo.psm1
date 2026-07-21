function Get-OperatingSystemCimInstance {
    [CmdletBinding()]
    param()
    Get-CimInstance -ClassName Win32_OperatingSystem
}

function Test-BaselineElevation {
    [CmdletBinding()]
    param()

    if ($PSVersionTable.PSVersion.Major -ge 6 -and $IsWindows -eq $false) {
        return $false
    }

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-WindowsEditionInfo {
    [CmdletBinding()]
    param()

    $os = Get-OperatingSystemCimInstance
    $caption = $os.Caption

    $edition = switch -Regex ($caption) {
        'Home'       { 'Home'; break }
        'Enterprise' { 'Enterprise'; break }
        'Education'  { 'Education'; break }
        'Pro'        { 'Pro'; break }
        default      { 'Other' }
    }

    [PSCustomObject]@{
        Caption = $caption
        Edition = $edition
        Build   = $os.BuildNumber
    }
}

Export-ModuleMember -Function Test-BaselineElevation, Get-WindowsEditionInfo
