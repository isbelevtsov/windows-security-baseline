function Write-BaselineLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info', 'Warn', 'Error')][string]$Level = 'Info',
        [Parameter(Mandatory)][string]$LogPath
    )

    $timestamp = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$timestamp] [$Level] $Message"

    $logDir = Split-Path -Path $LogPath -Parent
    if ($logDir -and -not (Test-Path -Path $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }

    Add-Content -Path $LogPath -Value $line

    switch ($Level) {
        'Warn'  { Write-Warning $Message }
        'Error' { Write-Error $Message -ErrorAction Continue }
        default { Write-Verbose $Message }
    }
}

Export-ModuleMember -Function Write-BaselineLog
