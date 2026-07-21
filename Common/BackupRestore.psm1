function New-BaselineBackupFolder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][string]$Timestamp,
        [Parameter(Mandatory)][string]$Area
    )

    $path = Join-Path -Path $RootPath -ChildPath (Join-Path 'Backups' (Join-Path $Timestamp $Area))
    New-Item -Path $path -ItemType Directory -Force | Out-Null
    return $path
}

function Write-BaselineManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][string]$Timestamp,
        [Parameter(Mandatory)][ValidateSet('Audit', 'Apply', 'Restore')][string]$Mode,
        [Parameter(Mandatory)][string[]]$Modules,
        [Parameter(Mandatory)][string]$OSBuild
    )

    $snapshotRoot = Join-Path -Path $RootPath -ChildPath (Join-Path 'Backups' $Timestamp)
    New-Item -Path $snapshotRoot -ItemType Directory -Force | Out-Null

    $manifest = [PSCustomObject]@{
        Timestamp = $Timestamp
        Mode      = $Mode
        Modules   = $Modules
        OSBuild   = $OSBuild
    }

    $manifestPath = Join-Path -Path $snapshotRoot -ChildPath 'manifest.json'
    $manifest | ConvertTo-Json | Set-Content -Path $manifestPath
    return $manifestPath
}

function Get-BaselineSnapshots {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RootPath
    )

    $backupsRoot = Join-Path -Path $RootPath -ChildPath 'Backups'
    if (-not (Test-Path -Path $backupsRoot)) {
        return @()
    }

    $snapshots = foreach ($dir in Get-ChildItem -Path $backupsRoot -Directory) {
        $manifestPath = Join-Path -Path $dir.FullName -ChildPath 'manifest.json'
        if (Test-Path -Path $manifestPath) {
            [PSCustomObject]@{
                Timestamp    = $dir.Name
                ManifestPath = $manifestPath
                Manifest     = Get-Content -Path $manifestPath -Raw | ConvertFrom-Json
            }
        }
    }

    return @($snapshots | Sort-Object -Property Timestamp -Descending)
}

function Resolve-BaselineSnapshotPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [string]$Timestamp,
        [switch]$Latest
    )

    if (-not $Latest -and -not $Timestamp) {
        throw 'Either -Timestamp or -Latest must be specified.'
    }

    $snapshots = Get-BaselineSnapshots -RootPath $RootPath
    if ($snapshots.Count -eq 0) {
        throw "No backup snapshots found under '$RootPath'."
    }

    if ($Latest) {
        $selected = $snapshots[0]
    }
    else {
        $selected = $snapshots | Where-Object { $_.Timestamp -eq $Timestamp } | Select-Object -First 1
        if (-not $selected) {
            throw "No backup snapshot found with timestamp '$Timestamp'."
        }
    }

    return Join-Path -Path $RootPath -ChildPath (Join-Path 'Backups' $selected.Timestamp)
}

Export-ModuleMember -Function New-BaselineBackupFolder, Write-BaselineManifest, Get-BaselineSnapshots, Resolve-BaselineSnapshotPath
