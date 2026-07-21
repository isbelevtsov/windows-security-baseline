# Tests/Common/Orchestrator.Tests.ps1
BeforeAll {
    Import-Module "$PSScriptRoot/../../Common/Orchestrator.psm1" -Force

    # Stand-in stubs for every area-module function the orchestrator calls by name.
    # Mock (below) replaces these bodies per-test; they only need to exist and be resolvable.
    function global:Test-PasswordPolicyBaseline { @() }
    function global:Backup-PasswordPolicySettings { }
    function global:Set-PasswordPolicyBaseline { @() }
    function global:Restore-PasswordPolicySettings { }

    function global:Test-AccountLockoutBaseline { @() }
    function global:Backup-AccountLockoutSettings { }
    function global:Set-AccountLockoutBaseline { @() }
    function global:Restore-AccountLockoutSettings { }

    function global:Test-DefenderBaseline { @() }
    function global:Backup-DefenderSettings { }
    function global:Set-DefenderBaseline { @() }
    function global:Restore-DefenderSettings { }

    function global:Test-FirewallBaseline { @() }
    function global:Backup-FirewallSettings { }
    function global:Set-FirewallBaseline { @() }
    function global:Restore-FirewallSettings { }

    function global:Test-ScreenLockBaseline { @() }
    function global:Backup-ScreenLockSettings { }
    function global:Set-ScreenLockBaseline { @() }
    function global:Restore-ScreenLockSettings { }

    function global:Test-AuditPolicyBaseline { @() }
    function global:Backup-AuditPolicySettings { }
    function global:Set-AuditPolicyBaseline { @() }
    function global:Restore-AuditPolicySettings { }

    function global:Test-RemoteAccessBaseline { @() }
    function global:Backup-RemoteAccessSettings { }
    function global:Set-RemoteAccessBaseline { @() }
    function global:Restore-RemoteAccessSettings { }

    function global:Test-BitLockerBaseline { @() }
    function global:Backup-BitLockerSettings { }
    function global:Set-BitLockerBaseline { @() }
    function global:Restore-BitLockerSettings { param([string]$BackupPath, [switch]$DecryptOnRestore) }
}

Describe 'Invoke-BaselineRun elevation check' {
    It 'throws immediately when not elevated' {
        Mock -ModuleName Orchestrator -CommandName Test-BaselineElevation { $false }

        { Invoke-BaselineRun -Mode 'Audit' -RootPath $TestDrive -ConfigPath 'unused.psd1' -RunTimestamp '2026-07-21_120000' } |
            Should -Throw '*elevated*'
    }
}

Describe 'Invoke-BaselineRun -Mode Audit' {
    BeforeEach {
        Mock -ModuleName Orchestrator -CommandName Test-BaselineElevation { $true }
        Mock -ModuleName Orchestrator -CommandName Get-WindowsEditionInfo { [PSCustomObject]@{ Edition = 'Pro'; Build = '22631' } }
        Mock -ModuleName Orchestrator -CommandName Import-BaselineConfig {
            @{
                PasswordPolicy = @{}; AccountLockout = @{}; Defender = @{}; Firewall = @{}
                ScreenLock = @{}; AuditPolicy = @{}; RemoteAccess = @{}; BitLocker = @{}
            }
        }
    }

    It 'calls Test-<Area>Baseline for every requested module and aggregates results' {
        Mock -ModuleName Orchestrator -CommandName Test-DefenderBaseline { @([PSCustomObject]@{ Module = 'Defender'; Setting = 'X'; Expected = $true; Actual = $true; Pass = $true }) }
        Mock -ModuleName Orchestrator -CommandName Test-FirewallBaseline { @([PSCustomObject]@{ Module = 'Firewall'; Setting = 'Y'; Expected = $true; Actual = $false; Pass = $false }) }

        $results = Invoke-BaselineRun -Mode 'Audit' -Modules @('Defender', 'Firewall') -RootPath $TestDrive -ConfigPath 'unused.psd1' -RunTimestamp '2026-07-21_120000'

        $results.Count | Should -Be 2
        Should -Invoke -ModuleName Orchestrator -CommandName Test-DefenderBaseline -Times 1
        Should -Invoke -ModuleName Orchestrator -CommandName Test-FirewallBaseline -Times 1
    }

    It 'rejects an unknown module name' {
        { Invoke-BaselineRun -Mode 'Audit' -Modules @('NotARealModule') -RootPath $TestDrive -ConfigPath 'unused.psd1' -RunTimestamp '2026-07-21_120000' } |
            Should -Throw '*Unknown module*'
    }

    It 'continues auditing other modules when one module throws' {
        Mock -ModuleName Orchestrator -CommandName Test-DefenderBaseline { throw 'boom' }
        Mock -ModuleName Orchestrator -CommandName Test-FirewallBaseline { @([PSCustomObject]@{ Module = 'Firewall'; Setting = 'Y'; Expected = $true; Actual = $true; Pass = $true }) }

        $results = Invoke-BaselineRun -Mode 'Audit' -Modules @('Defender', 'Firewall') -RootPath $TestDrive -ConfigPath 'unused.psd1' -RunTimestamp '2026-07-21_120000'

        ($results | Where-Object Module -eq 'Defender').Pass | Should -BeFalse
        ($results | Where-Object Module -eq 'Firewall').Pass | Should -BeTrue
    }
}

Describe 'Invoke-BaselineRun -Mode Apply' {
    BeforeEach {
        Mock -ModuleName Orchestrator -CommandName Test-BaselineElevation { $true }
        Mock -ModuleName Orchestrator -CommandName Get-WindowsEditionInfo { [PSCustomObject]@{ Edition = 'Pro'; Build = '22631' } }
        Mock -ModuleName Orchestrator -CommandName Import-BaselineConfig {
            @{
                PasswordPolicy = @{}; AccountLockout = @{}; Defender = @{}; Firewall = @{}
                ScreenLock = @{}; AuditPolicy = @{}; RemoteAccess = @{}; BitLocker = @{}
            }
        }
    }

    It 'backs up before applying, and skips Set entirely when Backup throws' {
        Mock -ModuleName Orchestrator -CommandName Backup-DefenderSettings { throw 'disk full' }
        Mock -ModuleName Orchestrator -CommandName Set-DefenderBaseline { @([PSCustomObject]@{ Module = 'Defender'; Setting = 'X'; Before = $false; After = $true; Changed = $true }) }

        Invoke-BaselineRun -Mode 'Apply' -Modules @('Defender') -RootPath $TestDrive -ConfigPath 'unused.psd1' -RunTimestamp '2026-07-21_130000' | Out-Null

        Should -Invoke -ModuleName Orchestrator -CommandName Set-DefenderBaseline -Times 0
    }

    It 'applies a module whose backup succeeds' {
        Mock -ModuleName Orchestrator -CommandName Backup-DefenderSettings { }
        Mock -ModuleName Orchestrator -CommandName Set-DefenderBaseline { @([PSCustomObject]@{ Module = 'Defender'; Setting = 'X'; Before = $false; After = $true; Changed = $true }) }

        $changes = Invoke-BaselineRun -Mode 'Apply' -Modules @('Defender') -RootPath $TestDrive -ConfigPath 'unused.psd1' -RunTimestamp '2026-07-21_130000'

        Should -Invoke -ModuleName Orchestrator -CommandName Set-DefenderBaseline -Times 1
        $changes[0].Changed | Should -BeTrue
    }

    It 'writes a manifest listing only the modules that actually applied' {
        Mock -ModuleName Orchestrator -CommandName Backup-DefenderSettings { throw 'boom' }
        Mock -ModuleName Orchestrator -CommandName Set-DefenderBaseline { @() }
        Mock -ModuleName Orchestrator -CommandName Backup-FirewallSettings { }
        Mock -ModuleName Orchestrator -CommandName Set-FirewallBaseline { @([PSCustomObject]@{ Module = 'Firewall'; Setting = 'Y'; Before = $false; After = $true; Changed = $true }) }

        Invoke-BaselineRun -Mode 'Apply' -Modules @('Defender', 'Firewall') -RootPath $TestDrive -ConfigPath 'unused.psd1' -RunTimestamp '2026-07-21_140000' | Out-Null

        $manifest = Get-Content -Path (Join-Path $TestDrive 'Backups/2026-07-21_140000/manifest.json') -Raw | ConvertFrom-Json
        $manifest.Modules | Should -Contain 'Firewall'
        $manifest.Modules | Should -Not -Contain 'Defender'
    }

    It 'logs a Warn when post-apply verification finds a setting still non-compliant' {
        Mock -ModuleName Orchestrator -CommandName Backup-DefenderSettings { }
        Mock -ModuleName Orchestrator -CommandName Set-DefenderBaseline { @([PSCustomObject]@{ Module = 'Defender'; Setting = 'X'; Before = $false; After = $true; Changed = $true }) }
        Mock -ModuleName Orchestrator -CommandName Test-DefenderBaseline { @([PSCustomObject]@{ Module = 'Defender'; Setting = 'X'; Expected = $true; Actual = $false; Pass = $false }) }
        Mock -ModuleName Orchestrator -CommandName Write-BaselineLog { }

        Invoke-BaselineRun -Mode 'Apply' -Modules @('Defender') -RootPath $TestDrive -ConfigPath 'unused.psd1' -RunTimestamp '2026-07-21_170000' | Out-Null

        Should -Invoke -ModuleName Orchestrator -CommandName Write-BaselineLog -ParameterFilter {
            $Level -eq 'Warn' -and $Message -match 'verification failed' -and $Message -match 'still'
        }
    }

    It 'does not log a verification Warn when the re-check passes' {
        Mock -ModuleName Orchestrator -CommandName Backup-DefenderSettings { }
        Mock -ModuleName Orchestrator -CommandName Set-DefenderBaseline { @([PSCustomObject]@{ Module = 'Defender'; Setting = 'X'; Before = $false; After = $true; Changed = $true }) }
        Mock -ModuleName Orchestrator -CommandName Test-DefenderBaseline { @([PSCustomObject]@{ Module = 'Defender'; Setting = 'X'; Expected = $true; Actual = $true; Pass = $true }) }
        Mock -ModuleName Orchestrator -CommandName Write-BaselineLog { }

        Invoke-BaselineRun -Mode 'Apply' -Modules @('Defender') -RootPath $TestDrive -ConfigPath 'unused.psd1' -RunTimestamp '2026-07-21_170500' | Out-Null

        Should -Invoke -ModuleName Orchestrator -CommandName Write-BaselineLog -Times 0 -ParameterFilter {
            $Level -eq 'Warn' -and $Message -match 'verification failed'
        }
    }

    It 'logs a Warn for a change record Note (e.g. a plaintext recovery key warning)' {
        Mock -ModuleName Orchestrator -CommandName Backup-BitLockerSettings { }
        Mock -ModuleName Orchestrator -CommandName Set-BitLockerBaseline {
            @([PSCustomObject]@{
                Module  = 'BitLocker'
                Setting = 'OSDriveEncrypted'
                Before  = $false
                After   = $true
                Changed = $true
                Note    = "Recovery key written in plaintext to 'C:\ProgramData\SecurityBaseline\RecoveryKeys\C-recovery-key.txt' - secure or relocate it."
            })
        }
        Mock -ModuleName Orchestrator -CommandName Write-BaselineLog { }

        Invoke-BaselineRun -Mode 'Apply' -Modules @('BitLocker') -RootPath $TestDrive -ConfigPath 'unused.psd1' -RunTimestamp '2026-07-21_180000' | Out-Null

        Should -Invoke -ModuleName Orchestrator -CommandName Write-BaselineLog -ParameterFilter {
            $Level -eq 'Warn' -and $Message -match 'plaintext'
        }
    }
}

Describe 'Invoke-BaselineRun -Mode Restore' {
    BeforeEach {
        Mock -ModuleName Orchestrator -CommandName Test-BaselineElevation { $true }
    }

    It 'restores every module present in the resolved snapshot' {
        New-Item -Path (Join-Path $TestDrive 'Backups/2026-07-21_150000/Defender') -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $TestDrive 'Backups/2026-07-21_150000/manifest.json') -Value (@{ Timestamp = '2026-07-21_150000'; Mode = 'Apply'; Modules = @('Defender'); OSBuild = '22631' } | ConvertTo-Json)

        Mock -ModuleName Orchestrator -CommandName Restore-DefenderSettings { "some stray CLI output that should be suppressed" }

        $results = Invoke-BaselineRun -Mode 'Restore' -Modules @('Defender') -RootPath $TestDrive -ConfigPath 'unused.psd1' -RunTimestamp '2026-07-21_160000' -SnapshotTimestamp '2026-07-21_150000'

        $results.Count | Should -Be 1
        $results[0].Restored | Should -BeTrue
        Should -Invoke -ModuleName Orchestrator -CommandName Restore-DefenderSettings -Times 1
    }

    It 'passes -DecryptOnRestore through to the BitLocker module only' {
        New-Item -Path (Join-Path $TestDrive 'Backups/2026-07-21_150000/BitLocker') -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $TestDrive 'Backups/2026-07-21_150000/manifest.json') -Value (@{ Timestamp = '2026-07-21_150000'; Mode = 'Apply'; Modules = @('BitLocker'); OSBuild = '22631' } | ConvertTo-Json)

        Mock -ModuleName Orchestrator -CommandName Restore-BitLockerSettings { [PSCustomObject]@{ Module = 'BitLocker'; Restored = $true } }

        Invoke-BaselineRun -Mode 'Restore' -Modules @('BitLocker') -RootPath $TestDrive -ConfigPath 'unused.psd1' -RunTimestamp '2026-07-21_160000' -SnapshotTimestamp '2026-07-21_150000' -DecryptOnRestore | Out-Null

        Should -Invoke -ModuleName Orchestrator -CommandName Restore-BitLockerSettings -Times 1 -ParameterFilter { $DecryptOnRestore -eq $true }
    }
}
