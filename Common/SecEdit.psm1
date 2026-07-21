function Invoke-SecEditBinary {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments)
    & secedit.exe @Arguments
}

function Invoke-SecEditExport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CfgPath)
    Invoke-SecEditBinary -Arguments @('/export', '/cfg', $CfgPath, '/quiet')
}

function Invoke-SecEditConfigure {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CfgPath)
    $dbPath = [System.IO.Path]::ChangeExtension($CfgPath, '.sdb')
    Invoke-SecEditBinary -Arguments @('/configure', '/db', $dbPath, '/cfg', $CfgPath, '/areas', 'SECURITYPOLICY', '/quiet')
}

function Get-SecurityPolicyValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CfgPath,
        [Parameter(Mandatory)][string]$Key
    )

    $line = Get-Content -Path $CfgPath -Encoding Unicode | Where-Object { $_ -match "^\s*$Key\s*=" } | Select-Object -First 1
    if (-not $line) {
        return $null
    }
    return ($line -split '=', 2)[1].Trim()
}

function Set-SecurityPolicyValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CfgPath,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value
    )

    $lines = @(Get-Content -Path $CfgPath -Encoding Unicode)
    $pattern = "^\s*$Key\s*="
    $found = $false

    $updated = foreach ($line in $lines) {
        if ($line -match $pattern) {
            $found = $true
            "$Key = $Value"
        }
        else {
            $line
        }
    }

    if (-not $found) {
        $sectionLine = $updated | Select-String -Pattern '^\[System Access\]$' | Select-Object -First 1
        if (-not $sectionLine) {
            throw "Could not find [System Access] section in '$CfgPath'."
        }
        $sectionIndex = $sectionLine.LineNumber
        $updated = @($updated[0..($sectionIndex - 1)]) + "$Key = $Value" + @($updated[$sectionIndex..($updated.Count - 1)])
    }

    Set-Content -Path $CfgPath -Value $updated -Encoding Unicode
}

Export-ModuleMember -Function Invoke-SecEditExport, Invoke-SecEditConfigure, Get-SecurityPolicyValue, Set-SecurityPolicyValue
