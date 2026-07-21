BeforeAll {
    Import-Module "$PSScriptRoot/../../Common/BackupRestore.psm1" -Force
}

Describe 'New-BaselineBackupFolder' {
    It 'creates and returns the area-specific backup path' {
        $path = New-BaselineBackupFolder -RootPath $TestDrive -Timestamp '2026-07-21_120000' -Area 'Firewall'
        Test-Path -Path $path -PathType Container | Should -BeTrue
        $path | Should -BeLike '*Backups*2026-07-21_120000*Firewall'
    }
}

Describe 'Write-BaselineManifest' {
    It 'writes a manifest.json with the expected fields' {
        $manifestPath = Write-BaselineManifest -RootPath $TestDrive -Timestamp '2026-07-21_120000' -Mode 'Apply' -Modules @('Firewall', 'Defender') -OSBuild '22631'
        Test-Path -Path $manifestPath | Should -BeTrue
        $manifest = Get-Content -Path $manifestPath -Raw | ConvertFrom-Json
        $manifest.Mode | Should -Be 'Apply'
        $manifest.Modules | Should -Contain 'Firewall'
        $manifest.OSBuild | Should -Be '22631'
    }
}

Describe 'Get-BaselineSnapshots' {
    It 'returns an empty array when no backups exist' {
        $root = Join-Path $TestDrive 'empty-root'
        New-Item -Path $root -ItemType Directory -Force | Out-Null
        Get-BaselineSnapshots -RootPath $root | Should -BeNullOrEmpty
    }

    It 'returns snapshots sorted newest first' {
        $root = Join-Path $TestDrive 'multi-root'
        Write-BaselineManifest -RootPath $root -Timestamp '2026-07-21_090000' -Mode 'Apply' -Modules @('Firewall') -OSBuild '22631' | Out-Null
        Write-BaselineManifest -RootPath $root -Timestamp '2026-07-21_150000' -Mode 'Apply' -Modules @('Firewall') -OSBuild '22631' | Out-Null

        $snapshots = Get-BaselineSnapshots -RootPath $root
        $snapshots.Count | Should -Be 2
        $snapshots[0].Timestamp | Should -Be '2026-07-21_150000'
    }
}

Describe 'Resolve-BaselineSnapshotPath' {
    It 'throws when neither -Timestamp nor -Latest is given' {
        { Resolve-BaselineSnapshotPath -RootPath $TestDrive } | Should -Throw
    }

    It 'throws when no snapshots exist' {
        $root = Join-Path $TestDrive 'no-snapshots'
        New-Item -Path $root -ItemType Directory -Force | Out-Null
        { Resolve-BaselineSnapshotPath -RootPath $root -Latest } | Should -Throw
    }

    It 'resolves -Latest to the most recent snapshot' {
        $root = Join-Path $TestDrive 'latest-root'
        Write-BaselineManifest -RootPath $root -Timestamp '2026-07-21_090000' -Mode 'Apply' -Modules @('Firewall') -OSBuild '22631' | Out-Null
        Write-BaselineManifest -RootPath $root -Timestamp '2026-07-21_150000' -Mode 'Apply' -Modules @('Firewall') -OSBuild '22631' | Out-Null

        Resolve-BaselineSnapshotPath -RootPath $root -Latest | Should -BeLike '*150000*'
    }

    It 'resolves an explicit -Timestamp' {
        $root = Join-Path $TestDrive 'explicit-root'
        Write-BaselineManifest -RootPath $root -Timestamp '2026-07-21_090000' -Mode 'Apply' -Modules @('Firewall') -OSBuild '22631' | Out-Null

        Resolve-BaselineSnapshotPath -RootPath $root -Timestamp '2026-07-21_090000' | Should -BeLike '*090000*'
    }

    It 'throws for an unknown explicit timestamp' {
        $root = Join-Path $TestDrive 'unknown-root'
        Write-BaselineManifest -RootPath $root -Timestamp '2026-07-21_090000' -Mode 'Apply' -Modules @('Firewall') -OSBuild '22631' | Out-Null

        { Resolve-BaselineSnapshotPath -RootPath $root -Timestamp '1999-01-01_000000' } | Should -Throw
    }
}
