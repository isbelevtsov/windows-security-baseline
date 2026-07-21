# Windows 11 Security Baseline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `SecurityBaseline` PowerShell toolkit described in `docs/superpowers/specs/2026-07-21-windows-security-baseline-design.md` — an Audit/Apply/Restore toolkit that hardens standalone Windows 11 Home/Pro/Enterprise devices toward HIPAA technical safeguards, with backup-before-change and revert support.

**Architecture:** A thin `Invoke-SecurityBaseline.ps1` entry point imports every `.psm1` and delegates to `Invoke-BaselineRun` in `Common/Orchestrator.psm1`. Each of the 8 policy areas is its own module in `Modules/` exposing `Test-/Backup-/Set-/Restore-<Area>Baseline|Settings`. Every module wraps each external dependency (a cmdlet, `secedit.exe`, `auditpol.exe`, `netsh.exe`, `reg.exe`, a registry path) in its own small private PowerShell function — this is the only way to unit-test the logic, since none of these OS features exist on the non-Windows machine this code is authored and tested on, and Pester can only mock a command that is itself resolvable as a real PowerShell function.

**Tech Stack:** PowerShell (must run under Windows PowerShell 5.1 — the version that ships with Windows 11 — with no PowerShell 7/pwsh dependency at runtime), Pester 6 for tests (installed via `Install-Module -Name Pester -Force -Scope CurrentUser -SkipPublisherCheck`, already done in this environment), `secedit.exe` / `auditpol.exe` / `netsh.exe` / `reg.exe` for local policy, `NetSecurity`, `Defender`, `Microsoft.PowerShell.LocalAccounts`, and `BitLocker` PowerShell modules (all ship in-box on Windows 11).

## Global Constraints

- **PowerShell 5.1 compatible.** No ternary operator (`?:`), no null-coalescing (`??`), no pipeline chain operators (`&&`/`||`) — these are PowerShell 7+ only and the target runtime is Windows PowerShell 5.1. Use `$(if (...) { } else { })` instead of ternary.
- **Wrap every external dependency.** Any call to a cmdlet that doesn't exist in this dev environment (`Get-MpPreference`, `Set-NetFirewallProfile`, `Get-BitLockerVolume`, `Get-LocalUser`, registry `Get-ItemProperty` against `HKLM:`, etc.) or any external binary (`secedit.exe`, `auditpol.exe`, `netsh.exe`, `reg.exe`) must live inside its own single-purpose private PowerShell function (verified working pattern — see Task 1). Tests mock that wrapper via `Mock -ModuleName <ModuleName> -CommandName <WrapperFunctionName>`; wrapper functions do **not** need `Export-ModuleMember` to be mockable (verified — Pester can mock non-exported module-internal functions).
- **Consistent result shapes.** Every module's `Test-<Area>Baseline` returns an array of `[PSCustomObject]` with properties `Module, Setting, Expected, Actual, Pass, Description`. Every module's `Set-<Area>Baseline` (or `-BaselineSettings`) returns an array of `[PSCustomObject]` with properties `Module, Setting, Before, After, Changed`.
- **Config access.** Modules never read `$Config.Foo.Value` directly — always through `Get-BaselineValue -Section $Config -Name 'Foo'` / `Get-BaselineDescription -Section $Config -Name 'Foo'` from `Common/Config.psm1`.
- **No `gpedit.msc` dependency anywhere** — only tools present on every Windows 11 SKU (Home included): `secedit.exe`, `auditpol.exe`, registry, and PowerShell cmdlets that ship in-box.
- **Default root path** for backups/logs/reports is `C:\ProgramData\SecurityBaseline`, always passed in as a parameter (`-RootPath`) rather than hardcoded, so tests can point it at `$TestDrive`.
- **Idempotent applies.** Every `Set-<Area>Baseline` function must skip writing a setting whose current value already matches the config (check-before-write), so a second `Apply` run reports `Changed = $false` for everything.
- Test files live under `Tests/`, mirroring the source layout (`Tests/Common/*.Tests.ps1`, `Tests/Modules/*.Tests.ps1`), and use Pester 6 `Describe`/`It`/`Mock` syntax.

---

## Task 1: Common/Logging.psm1 — shared file logging

**Files:**
- Create: `Common/Logging.psm1`
- Test: `Tests/Common/Logging.Tests.ps1`

**Interfaces:**
- Produces: `Write-BaselineLog(-Message <string>, -Level <'Info'|'Warn'|'Error'> = 'Info', -LogPath <string>)` — appends a timestamped line to `-LogPath`, creating the parent directory if needed. Used by every later task that logs.

- [ ] **Step 1: Write the failing test**

```powershell
# Tests/Common/Logging.Tests.ps1
BeforeAll {
    Import-Module "$PSScriptRoot/../../Common/Logging.psm1" -Force
}

Describe 'Write-BaselineLog' {
    It 'creates the log directory if it does not exist' {
        $logPath = Join-Path $TestDrive 'nested/dir/test.log'
        Write-BaselineLog -Message 'hello' -LogPath $logPath
        Test-Path $logPath | Should -BeTrue
    }

    It 'writes a line containing the level and message' {
        $logPath = Join-Path $TestDrive 'test.log'
        Write-BaselineLog -Message 'something happened' -Level 'Warn' -LogPath $logPath
        $content = Get-Content -Path $logPath -Raw
        $content | Should -Match '\[Warn\] something happened'
    }

    It 'appends multiple messages rather than overwriting' {
        $logPath = Join-Path $TestDrive 'append.log'
        Write-BaselineLog -Message 'first' -LogPath $logPath
        Write-BaselineLog -Message 'second' -LogPath $logPath
        (Get-Content -Path $logPath).Count | Should -Be 2
    }

    It 'defaults to Info level' {
        $logPath = Join-Path $TestDrive 'default.log'
        Write-BaselineLog -Message 'plain message' -LogPath $logPath
        Get-Content -Path $logPath -Raw | Should -Match '\[Info\] plain message'
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path Tests/Common/Logging.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Common/Logging.psm1` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

```powershell
# Common/Logging.psm1
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path Tests/Common/Logging.Tests.ps1 -Output Detailed"`
Expected: PASS — 4 tests, 0 failed.

- [ ] **Step 5: Commit**

```bash
git add Common/Logging.psm1 Tests/Common/Logging.Tests.ps1
git commit -m "Add Write-BaselineLog shared logging function"
```

---

## Task 2: Common/SystemInfo.psm1 — elevation check and edition detection

**Files:**
- Create: `Common/SystemInfo.psm1`
- Test: `Tests/Common/SystemInfo.Tests.ps1`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `Test-BaselineElevation()` → `[bool]`, `Get-WindowsEditionInfo()` → `[PSCustomObject]@{ Caption; Edition; Build }` where `Edition` is one of `Home|Pro|Enterprise|Education|Other`. Both consumed by `Common/Orchestrator.psm1` (Task 15).

- [ ] **Step 1: Write the failing test**

```powershell
# Tests/Common/SystemInfo.Tests.ps1
BeforeAll {
    Import-Module "$PSScriptRoot/../../Common/SystemInfo.psm1" -Force
}

Describe 'Test-BaselineElevation' {
    It 'returns a boolean without throwing' {
        { Test-BaselineElevation } | Should -Not -Throw
    }
}

Describe 'Get-WindowsEditionInfo' {
    It 'classifies a Home caption correctly' {
        Mock -ModuleName SystemInfo -CommandName Get-OperatingSystemCimInstance {
            [PSCustomObject]@{ Caption = 'Microsoft Windows 11 Home'; BuildNumber = '22631' }
        }
        $result = Get-WindowsEditionInfo
        $result.Edition | Should -Be 'Home'
        $result.Build | Should -Be '22631'
    }

    It 'classifies a Pro caption correctly' {
        Mock -ModuleName SystemInfo -CommandName Get-OperatingSystemCimInstance {
            [PSCustomObject]@{ Caption = 'Microsoft Windows 11 Pro'; BuildNumber = '22631' }
        }
        (Get-WindowsEditionInfo).Edition | Should -Be 'Pro'
    }

    It 'classifies an Enterprise caption correctly' {
        Mock -ModuleName SystemInfo -CommandName Get-OperatingSystemCimInstance {
            [PSCustomObject]@{ Caption = 'Microsoft Windows 11 Enterprise'; BuildNumber = '22631' }
        }
        (Get-WindowsEditionInfo).Edition | Should -Be 'Enterprise'
    }

    It 'falls back to Other for an unrecognized caption' {
        Mock -ModuleName SystemInfo -CommandName Get-OperatingSystemCimInstance {
            [PSCustomObject]@{ Caption = 'Some Future Windows SKU'; BuildNumber = '99999' }
        }
        (Get-WindowsEditionInfo).Edition | Should -Be 'Other'
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path Tests/Common/SystemInfo.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Common/SystemInfo.psm1` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

```powershell
# Common/SystemInfo.psm1
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path Tests/Common/SystemInfo.Tests.ps1 -Output Detailed"`
Expected: PASS — 5 tests, 0 failed. (On this non-Windows dev machine, `Test-BaselineElevation` exercises its `$false` short-circuit path; the true elevation-check path is exercised only during manual validation on real Windows in Task 16.)

- [ ] **Step 5: Commit**

```bash
git add Common/SystemInfo.psm1 Tests/Common/SystemInfo.Tests.ps1
git commit -m "Add elevation check and Windows edition detection"
```

---

## Task 3: Common/Config.psm1 + Config/Baseline.config.psd1 — baseline config loader

**Files:**
- Create: `Common/Config.psm1`
- Create: `Config/Baseline.config.psd1`
- Test: `Tests/Common/Config.Tests.ps1`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `Import-BaselineConfig(-Path <string>)` → `[hashtable]` (validated, all 8 top-level sections present); `Get-BaselineValue(-Section <hashtable>, -Name <string>)` → the setting's `.Value`; `Get-BaselineDescription(-Section <hashtable>, -Name <string>)` → the setting's `.Description`. All three are consumed by every module task (4–13) and by the orchestrator (Task 15).

- [ ] **Step 1: Write the failing test**

```powershell
# Tests/Common/Config.Tests.ps1
BeforeAll {
    Import-Module "$PSScriptRoot/../../Common/Config.psm1" -Force
}

Describe 'Import-BaselineConfig' {
    It 'throws if the file does not exist' {
        { Import-BaselineConfig -Path (Join-Path $TestDrive 'missing.psd1') } | Should -Throw
    }

    It 'throws if a required section is missing' {
        $path = Join-Path $TestDrive 'incomplete.psd1'
        Set-Content -Path $path -Value '@{ PasswordPolicy = @{} }'
        { Import-BaselineConfig -Path $path } | Should -Throw '*missing required section*'
    }

    It 'loads a config with all required sections' {
        $path = Join-Path $TestDrive 'full.psd1'
        Set-Content -Path $path -Value @'
@{
    PasswordPolicy = @{ MinimumPasswordLength = @{ Value = 14; Description = "min length" } }
    AccountLockout = @{}
    Defender       = @{}
    Firewall       = @{}
    ScreenLock     = @{}
    AuditPolicy    = @{}
    RemoteAccess   = @{}
    BitLocker      = @{}
}
'@
        $config = Import-BaselineConfig -Path $path
        $config.PasswordPolicy.MinimumPasswordLength.Value | Should -Be 14
    }

    It 'loads the real shipped Baseline.config.psd1' {
        $config = Import-BaselineConfig -Path "$PSScriptRoot/../../Config/Baseline.config.psd1"
        $config.PasswordPolicy.MinimumPasswordLength.Value | Should -Be 14
        $config.RemoteAccess.DisableRDP.Value | Should -Be $true
    }
}

Describe 'Get-BaselineValue' {
    It 'returns the Value property for a known key' {
        $section = @{ Foo = @{ Value = 42; Description = 'the answer' } }
        Get-BaselineValue -Section $section -Name 'Foo' | Should -Be 42
    }

    It 'throws for an unknown key' {
        $section = @{ Foo = @{ Value = 42 } }
        { Get-BaselineValue -Section $section -Name 'Bar' } | Should -Throw
    }
}

Describe 'Get-BaselineDescription' {
    It 'returns the Description property for a known key' {
        $section = @{ Foo = @{ Value = 42; Description = 'the answer' } }
        Get-BaselineDescription -Section $section -Name 'Foo' | Should -Be 'the answer'
    }

    It 'throws for an unknown key' {
        $section = @{ Foo = @{ Value = 42; Description = 'the answer' } }
        { Get-BaselineDescription -Section $section -Name 'Bar' } | Should -Throw
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path Tests/Common/Config.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Common/Config.psm1` and `Config/Baseline.config.psd1` do not exist yet.

- [ ] **Step 3: Write minimal implementation**

```powershell
# Common/Config.psm1
$script:RequiredSections = @(
    'PasswordPolicy', 'AccountLockout', 'Defender', 'Firewall',
    'ScreenLock', 'AuditPolicy', 'RemoteAccess', 'BitLocker'
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
```

```powershell
# Config/Baseline.config.psd1
@{
    PasswordPolicy = @{
        MinimumPasswordLength = @{
            Value       = 14
            Description = "Minimum characters required. HIPAA doesn't mandate a specific number; NIST SP 800-63B recommends 14+ over relying on complexity rules."
        }
        PasswordComplexity = @{
            Value       = $true
            Description = "Requires a mix of character classes (upper/lower/digit/symbol) when set."
        }
        PasswordHistorySize = @{
            Value       = 24
            Description = "Number of previous passwords remembered to prevent reuse."
        }
        MaximumPasswordAgeDays = @{
            Value       = 90
            Description = "Days before a password must be changed. Set to 0 to disable expiry (NIST 800-63B now discourages forced periodic rotation, but many HIPAA auditors still expect it)."
        }
        MinimumPasswordAgeDays = @{
            Value       = 1
            Description = "Minimum days before a password can be changed again, preventing rapid cycling back to an old password."
        }
    }
    AccountLockout = @{
        LockoutThreshold = @{
            Value       = 5
            Description = "Failed logon attempts allowed before the account locks."
        }
        LockoutDurationMinutes = @{
            Value       = 15
            Description = "How long a locked account stays locked before auto-unlocking."
        }
        ObservationWindowMinutes = @{
            Value       = 15
            Description = "Time window during which failed attempts count toward the lockout threshold."
        }
    }
    ScreenLock = @{
        InactivityTimeoutSeconds = @{
            Value       = 900
            Description = "Idle seconds before the machine locks (900 = 15 minutes). This is the 'machine inactivity limit,' independent of screensaver settings."
        }
    }
    AuditPolicy = @{
        Categories = @{
            Value = @{
                'Logon'                      = 'SuccessAndFailure'
                'Logoff'                     = 'Success'
                'Account Lockout'            = 'SuccessAndFailure'
                'User Account Management'    = 'SuccessAndFailure'
                'Security Group Management'  = 'SuccessAndFailure'
                'Removable Storage'          = 'Failure'
                'Audit Policy Change'        = 'SuccessAndFailure'
                'Sensitive Privilege Use'    = 'Failure'
            }
            Description = "Advanced audit policy subcategories (exact auditpol.exe /subcategory: names) and what outcomes to log for each, supporting HIPAA's audit control requirement."
        }
    }
    Defender = @{
        RealTimeProtection = @{
            Value       = $true
            Description = "Keeps Defender's real-time scanning engine active."
        }
        CloudProtection = @{
            Value       = $true
            Description = "Enables cloud-delivered protection (MAPS) for faster response to new threats."
        }
        PUAProtection = @{
            Value       = 'Enabled'
            Description = "Blocks potentially unwanted applications (adware, bundled software)."
        }
    }
    Firewall = @{
        EnabledProfiles = @{
            Value       = @('Domain', 'Private', 'Public')
            Description = "Firewall profiles that must be turned on."
        }
        DefaultInboundAction = @{
            Value       = 'Block'
            Description = "Default action for inbound connections with no matching allow rule."
        }
        LoggingEnabled = @{
            Value       = $true
            Description = "Enables firewall connection logging for audit/troubleshooting."
        }
    }
    RemoteAccess = @{
        DisableRDP = @{
            Value       = $true
            Description = "Disables inbound Remote Desktop entirely. Set to `$false if this device needs RDP for support access, or exclude the RemoteAccess module via -Modules."
        }
        DisableSMBv1 = @{
            Value       = $true
            Description = "Disables the legacy SMBv1 protocol, which has no meaningful modern use case and a history of critical vulnerabilities (e.g. EternalBlue)."
        }
        DisableGuestAccount = @{
            Value       = $true
            Description = "Disables the built-in Guest account to prevent unauthenticated/low-friction local access."
        }
    }
    BitLocker = @{
        EncryptionMethod = @{
            Value       = 'XtsAes256'
            Description = "Encryption algorithm used for the OS drive."
        }
        RecoveryKeyPath = @{
            Value       = 'C:\ProgramData\SecurityBaseline\RecoveryKeys'
            Description = "Local folder where the BitLocker recovery key is saved, since standalone/workgroup devices have no AD/Entra to escrow it to. Secure or relocate this folder's contents as a manual follow-up."
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path Tests/Common/Config.Tests.ps1 -Output Detailed"`
Expected: PASS — 8 tests, 0 failed. (Get-BaselineDescription throws on an unknown key, matching Get-BaselineValue, per a task-review fix.)

- [ ] **Step 5: Commit**

```bash
git add Common/Config.psm1 Config/Baseline.config.psd1 Tests/Common/Config.Tests.ps1
git commit -m "Add baseline config loader and default HIPAA-aligned config values"
```

---

## Task 4: Common/BackupRestore.psm1 — snapshot folder and manifest engine

**Files:**
- Create: `Common/BackupRestore.psm1`
- Test: `Tests/Common/BackupRestore.Tests.ps1`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `New-BaselineBackupFolder(-RootPath, -Timestamp, -Area)` → `[string]` path (created); `Write-BaselineManifest(-RootPath, -Timestamp, -Mode <'Audit'|'Apply'|'Restore'>, -Modules <string[]>, -OSBuild <string>)` → `[string]` manifest path; `Get-BaselineSnapshots(-RootPath)` → `[PSCustomObject[]]` with `Timestamp, ManifestPath, Manifest`, newest first; `Resolve-BaselineSnapshotPath(-RootPath, [-Timestamp <string>], [-Latest])` → `[string]` snapshot root path. Consumed by module Backup-/Restore- functions (via the orchestrator) and by `Common/Orchestrator.psm1` (Task 15).

- [ ] **Step 1: Write the failing test**

```powershell
# Tests/Common/BackupRestore.Tests.ps1
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path Tests/Common/BackupRestore.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Common/BackupRestore.psm1` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

```powershell
# Common/BackupRestore.psm1
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path Tests/Common/BackupRestore.Tests.ps1 -Output Detailed"`
Expected: PASS — 9 tests, 0 failed.

- [ ] **Step 5: Commit**

```bash
git add Common/BackupRestore.psm1 Tests/Common/BackupRestore.Tests.ps1
git commit -m "Add backup snapshot folder, manifest, and restore-target resolution"
```

---

## Task 5: Common/Reporting.psm1 — audit report and console summaries

**Files:**
- Create: `Common/Reporting.psm1`
- Test: `Tests/Common/Reporting.Tests.ps1`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `New-BaselineAuditReport(-Results <object[]>, -ReportPath <string>)` → `[PSCustomObject]@{ Total; Passed; Failed }` (also writes JSON to `-ReportPath`); `Write-BaselineAuditSummary(-Results <object[]>)` → console output; `Write-BaselineApplySummary(-ChangeRecords <object[]>, -BackupPath <string>, -LogPath <string>)` → console output. All three consumed by `Common/Orchestrator.psm1` (Task 15).

- [ ] **Step 1: Write the failing test**

```powershell
# Tests/Common/Reporting.Tests.ps1
BeforeAll {
    Import-Module "$PSScriptRoot/../../Common/Reporting.psm1" -Force
}

Describe 'New-BaselineAuditReport' {
    It 'writes a JSON report and returns pass/fail counts' {
        $results = @(
            [PSCustomObject]@{ Module = 'Firewall'; Setting = 'DefaultInboundAction'; Expected = 'Block'; Actual = 'Block'; Pass = $true }
            [PSCustomObject]@{ Module = 'Defender'; Setting = 'RealTimeProtection'; Expected = $true; Actual = $false; Pass = $false }
        )
        $reportPath = Join-Path $TestDrive 'audit.json'

        $summary = New-BaselineAuditReport -Results $results -ReportPath $reportPath

        Test-Path -Path $reportPath | Should -BeTrue
        $summary.Total | Should -Be 2
        $summary.Passed | Should -Be 1
        $summary.Failed | Should -Be 1

        (Get-Content -Path $reportPath -Raw | ConvertFrom-Json).Count | Should -Be 2
    }

    It 'correctly round-trips a single-element array (not unwrapped to a bare object)' {
        $results = @([PSCustomObject]@{ Module = 'Firewall'; Setting = 'DefaultInboundAction'; Expected = 'Block'; Actual = 'Block'; Pass = $true })
        $reportPath = Join-Path $TestDrive 'audit-one.json'

        New-BaselineAuditReport -Results $results -ReportPath $reportPath | Out-Null

        $content = (Get-Content -Path $reportPath -Raw).Trim()
        $content.StartsWith('[') | Should -BeTrue
        $content.EndsWith(']') | Should -BeTrue

        $parsed = $content | ConvertFrom-Json
        @($parsed).Count | Should -Be 1
    }

    It 'correctly round-trips an empty array' {
        $reportPath = Join-Path $TestDrive 'audit-empty.json'

        New-BaselineAuditReport -Results @() -ReportPath $reportPath | Out-Null

        $parsed = Get-Content -Path $reportPath -Raw | ConvertFrom-Json
        @($parsed).Count | Should -Be 0
    }
}

Describe 'Write-BaselineAuditSummary' {
    It 'reports when all settings pass' {
        $results = @([PSCustomObject]@{ Module = 'Firewall'; Setting = 'DefaultInboundAction'; Expected = 'Block'; Actual = 'Block'; Pass = $true })
        $output = Write-BaselineAuditSummary -Results $results 6>&1 | Out-String
        $output | Should -Match 'All settings pass'
    }

    It 'reports the failure count when settings fail' {
        $results = @([PSCustomObject]@{ Module = 'Defender'; Setting = 'RealTimeProtection'; Expected = $true; Actual = $false; Pass = $false })
        $output = Write-BaselineAuditSummary -Results $results 6>&1 | Out-String
        $output | Should -Match '1 setting\(s\) failed'
    }
}

Describe 'Write-BaselineApplySummary' {
    It 'includes the changed count, backup path, and restore command' {
        $records = @(
            [PSCustomObject]@{ Setting = 'MinimumPasswordLength'; Before = 7; After = 14; Changed = $true }
            [PSCustomObject]@{ Setting = 'PasswordComplexity'; Before = $true; After = $true; Changed = $false }
        )
        $output = Write-BaselineApplySummary -ChangeRecords $records -BackupPath 'C:\ProgramData\SecurityBaseline\Backups\2026-07-21_120000' -LogPath 'C:\ProgramData\SecurityBaseline\Logs\2026-07-21_120000.log' 6>&1 | Out-String
        $output | Should -Match '1 setting\(s\) changed'
        $output | Should -Match '2026-07-21_120000'
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path Tests/Common/Reporting.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Common/Reporting.psm1` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

```powershell
# Common/Reporting.psm1
function New-BaselineAuditReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Results,
        [Parameter(Mandatory)][string]$ReportPath
    )

    $reportDir = Split-Path -Path $ReportPath -Parent
    if ($reportDir -and -not (Test-Path -Path $reportDir)) {
        New-Item -Path $reportDir -ItemType Directory -Force | Out-Null
    }

    ConvertTo-Json -InputObject $Results -Depth 5 | Set-Content -Path $ReportPath

    $passed = @($Results | Where-Object { $_.Pass }).Count
    $failed = @($Results | Where-Object { -not $_.Pass }).Count

    return [PSCustomObject]@{
        Total  = $Results.Count
        Passed = $passed
        Failed = $failed
    }
}

function Write-BaselineAuditSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Results
    )

    $Results |
        Sort-Object Module, Setting |
        Format-Table -Property Module, Setting, Expected, Actual, Pass -AutoSize |
        Out-String |
        Write-Host

    $failed = @($Results | Where-Object { -not $_.Pass })
    if ($failed.Count -gt 0) {
        Write-Host "$($failed.Count) setting(s) failed the baseline check."
    }
    else {
        Write-Host 'All settings pass the baseline check.'
    }
}

function Write-BaselineApplySummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$ChangeRecords,
        [Parameter(Mandatory)][string]$BackupPath,
        [Parameter(Mandatory)][string]$LogPath
    )

    $changed = @($ChangeRecords | Where-Object { $_.Changed })
    Write-Host "Applied baseline: $($changed.Count) setting(s) changed."
    Write-Host "Backup saved to: $BackupPath"
    Write-Host "Full log: $LogPath"
    Write-Host "To revert: .\Invoke-SecurityBaseline.ps1 -Mode Restore -Timestamp `"$(Split-Path -Path $BackupPath -Leaf)`""
}

Export-ModuleMember -Function New-BaselineAuditReport, Write-BaselineAuditSummary, Write-BaselineApplySummary
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path Tests/Common/Reporting.Tests.ps1 -Output Detailed"`
Expected: PASS — 6 tests, 0 failed. (Includes two regression tests added per a task-review fix for `ConvertTo-Json` array-unwrapping on 0/1-element results.)

- [ ] **Step 5: Commit**

```bash
git add Common/Reporting.psm1 Tests/Common/Reporting.Tests.ps1
git commit -m "Add audit report generation and console summaries"
```

---

## Task 6: Common/SecEdit.psm1 — secedit INF helpers shared by two modules

**Files:**
- Create: `Common/SecEdit.psm1`
- Test: `Tests/Common/SecEdit.Tests.ps1`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `Invoke-SecEditExport(-CfgPath <string>)`, `Invoke-SecEditConfigure(-CfgPath <string>)`, `Get-SecurityPolicyValue(-CfgPath <string>, -Key <string>)` → `[string]` or `$null`, `Set-SecurityPolicyValue(-CfgPath <string>, -Key <string>, -Value <string>)`. Consumed by `Modules/PasswordPolicy.psm1` (Task 7) and `Modules/AccountLockout.psm1` (Task 8).

- [ ] **Step 1: Write the failing test**

```powershell
# Tests/Common/SecEdit.Tests.ps1
BeforeAll {
    Import-Module "$PSScriptRoot/../../Common/SecEdit.psm1" -Force
}

Describe 'Get-SecurityPolicyValue' {
    It 'extracts an existing key value' {
        $cfgPath = Join-Path $TestDrive 'policy.cfg'
        Set-Content -Path $cfgPath -Encoding Unicode -Value @(
            '[Unicode]'
            'Unicode=yes'
            '[System Access]'
            'MinimumPasswordLength = 0'
            'PasswordComplexity = 0'
        )
        Get-SecurityPolicyValue -CfgPath $cfgPath -Key 'MinimumPasswordLength' | Should -Be '0'
    }

    It 'returns $null for a key that is not present' {
        $cfgPath = Join-Path $TestDrive 'policy2.cfg'
        Set-Content -Path $cfgPath -Encoding Unicode -Value @('[System Access]', 'PasswordComplexity = 0')
        Get-SecurityPolicyValue -CfgPath $cfgPath -Key 'MinimumPasswordLength' | Should -BeNullOrEmpty
    }
}

Describe 'Set-SecurityPolicyValue' {
    It 'updates an existing key in place' {
        $cfgPath = Join-Path $TestDrive 'policy3.cfg'
        Set-Content -Path $cfgPath -Encoding Unicode -Value @('[System Access]', 'MinimumPasswordLength = 0')

        Set-SecurityPolicyValue -CfgPath $cfgPath -Key 'MinimumPasswordLength' -Value '14'

        Get-SecurityPolicyValue -CfgPath $cfgPath -Key 'MinimumPasswordLength' | Should -Be '14'
    }

    It 'inserts a missing key under [System Access]' {
        $cfgPath = Join-Path $TestDrive 'policy4.cfg'
        Set-Content -Path $cfgPath -Encoding Unicode -Value @('[System Access]', 'PasswordComplexity = 0', '[Event Audit]', 'AuditSystemEvents = 0')

        Set-SecurityPolicyValue -CfgPath $cfgPath -Key 'MinimumPasswordLength' -Value '14'

        Get-SecurityPolicyValue -CfgPath $cfgPath -Key 'MinimumPasswordLength' | Should -Be '14'
        (Get-Content -Path $cfgPath -Encoding Unicode) | Should -Contain 'AuditSystemEvents = 0'
    }

    It 'throws if the cfg has no [System Access] section and the key is missing' {
        $cfgPath = Join-Path $TestDrive 'policy5.cfg'
        Set-Content -Path $cfgPath -Encoding Unicode -Value @('[Event Audit]', 'AuditSystemEvents = 0')

        { Set-SecurityPolicyValue -CfgPath $cfgPath -Key 'MinimumPasswordLength' -Value '14' } | Should -Throw
    }

    It 'inserts a missing key correctly when [System Access] is the last line of the file' {
        $cfgPath = Join-Path $TestDrive 'policy6.cfg'
        Set-Content -Path $cfgPath -Encoding Unicode -Value @('[Version]', 'signature=test', '[System Access]')

        Set-SecurityPolicyValue -CfgPath $cfgPath -Key 'MinimumPasswordLength' -Value '14'

        Get-SecurityPolicyValue -CfgPath $cfgPath -Key 'MinimumPasswordLength' | Should -Be '14'
        $lines = @(Get-Content -Path $cfgPath -Encoding Unicode)
        ($lines | Where-Object { $_ -eq '[System Access]' }).Count | Should -Be 1
    }
}

Describe 'Invoke-SecEditExport / Invoke-SecEditConfigure' {
    BeforeAll {
        Import-Module "$PSScriptRoot/../../Common/SecEdit.psm1" -Force
    }

    It 'Invoke-SecEditExport calls the secedit binary wrapper with /export and the cfg path' {
        Mock -ModuleName SecEdit -CommandName Invoke-SecEditBinary { }
        Invoke-SecEditExport -CfgPath 'C:\temp\policy.cfg'
        Should -Invoke -ModuleName SecEdit -CommandName Invoke-SecEditBinary -ParameterFilter {
            $Arguments -contains '/export' -and $Arguments -contains 'C:\temp\policy.cfg'
        } -Times 1
    }

    It 'Invoke-SecEditConfigure calls the secedit binary wrapper with /configure and /areas SECURITYPOLICY' {
        Mock -ModuleName SecEdit -CommandName Invoke-SecEditBinary { }
        Invoke-SecEditConfigure -CfgPath 'C:\temp\policy.cfg'
        Should -Invoke -ModuleName SecEdit -CommandName Invoke-SecEditBinary -ParameterFilter {
            $Arguments -contains '/configure' -and $Arguments -contains 'SECURITYPOLICY'
        } -Times 1
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path Tests/Common/SecEdit.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Common/SecEdit.psm1` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

```powershell
# Common/SecEdit.psm1
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
        if ($sectionIndex -ge $updated.Count) {
            $tail = @()
        }
        else {
            $tail = @($updated[$sectionIndex..($updated.Count - 1)])
        }
        $updated = @($updated[0..($sectionIndex - 1)]) + "$Key = $Value" + $tail
    }

    Set-Content -Path $CfgPath -Value $updated -Encoding Unicode
}

Export-ModuleMember -Function Invoke-SecEditExport, Invoke-SecEditConfigure, Get-SecurityPolicyValue, Set-SecurityPolicyValue
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path Tests/Common/SecEdit.Tests.ps1 -Output Detailed"`
Expected: PASS — 8 tests, 0 failed. (Includes a regression test for a task-review fix: `Set-SecurityPolicyValue` previously duplicated the `[System Access]` line when it was the last line of the file.)

- [ ] **Step 5: Commit**

```bash
git add Common/SecEdit.psm1 Tests/Common/SecEdit.Tests.ps1
git commit -m "Add secedit INF read/write helpers shared by password and lockout policy"
```

---

## Task 7: Modules/PasswordPolicy.psm1

**Files:**
- Create: `Modules/PasswordPolicy.psm1`
- Test: `Tests/Modules/PasswordPolicy.Tests.ps1`

**Interfaces:**
- Consumes: `Common/SecEdit.psm1` (Task 6): `Invoke-SecEditExport`, `Invoke-SecEditConfigure`, `Get-SecurityPolicyValue`, `Set-SecurityPolicyValue`. `Common/Config.psm1` (Task 3): `Get-BaselineValue`, `Get-BaselineDescription`.
- Produces: `Test-PasswordPolicyBaseline(-Config <hashtable>, -WorkingCfgPath <string>)` → result array; `Backup-PasswordPolicySettings(-BackupPath <string>)` → `[string]` cfg path; `Set-PasswordPolicyBaseline(-Config <hashtable>, -WorkingCfgPath <string>)` → change array; `Restore-PasswordPolicySettings(-BackupPath <string>)`. Consumed by `Common/Orchestrator.psm1` (Task 15).

- [ ] **Step 1: Write the failing test**

```powershell
# Tests/Modules/PasswordPolicy.Tests.ps1
BeforeAll {
    Import-Module "$PSScriptRoot/../../Modules/PasswordPolicy.psm1" -Force

    function New-TestConfig {
        @{
            MinimumPasswordLength  = @{ Value = 14; Description = 'min length' }
            PasswordComplexity     = @{ Value = $true; Description = 'complexity' }
            PasswordHistorySize    = @{ Value = 24; Description = 'history' }
            MaximumPasswordAgeDays = @{ Value = 90; Description = 'max age' }
            MinimumPasswordAgeDays = @{ Value = 1; Description = 'min age' }
        }
    }
}

Describe 'Test-PasswordPolicyBaseline' {
    It 'flags settings that do not match the config' {
        Mock -ModuleName PasswordPolicy -CommandName Invoke-SecEditExport { }
        Mock -ModuleName PasswordPolicy -CommandName Get-SecurityPolicyValue {
            param($CfgPath, $Key)
            switch ($Key) {
                'MinimumPasswordLength' { '7' }
                'PasswordComplexity'    { '0' }
                'PasswordHistorySize'   { '24' }
                'MaximumPasswordAge'    { '90' }
                'MinimumPasswordAge'    { '1' }
            }
        }

        $results = Test-PasswordPolicyBaseline -Config (New-TestConfig) -WorkingCfgPath 'C:\temp\working.cfg'

        ($results | Where-Object Setting -eq 'MinimumPasswordLength').Pass | Should -BeFalse
        ($results | Where-Object Setting -eq 'PasswordComplexity').Pass | Should -BeFalse
        ($results | Where-Object Setting -eq 'PasswordHistorySize').Pass | Should -BeTrue
    }
}

Describe 'Backup-PasswordPolicySettings' {
    It 'exports the current policy to password-policy.cfg under the backup path' {
        Mock -ModuleName PasswordPolicy -CommandName Invoke-SecEditExport { }
        $backupPath = Join-Path $TestDrive 'PasswordPolicy'

        $cfgPath = Backup-PasswordPolicySettings -BackupPath $backupPath

        $cfgPath | Should -Be (Join-Path $backupPath 'password-policy.cfg')
        Should -Invoke -ModuleName PasswordPolicy -CommandName Invoke-SecEditExport -ParameterFilter { $CfgPath -eq $cfgPath } -Times 1
    }
}

Describe 'Set-PasswordPolicyBaseline' {
    It 'only writes settings that differ from config, and always configures once at the end' {
        Mock -ModuleName PasswordPolicy -CommandName Invoke-SecEditExport { }
        Mock -ModuleName PasswordPolicy -CommandName Invoke-SecEditConfigure { }
        Mock -ModuleName PasswordPolicy -CommandName Set-SecurityPolicyValue { }
        Mock -ModuleName PasswordPolicy -CommandName Get-SecurityPolicyValue {
            param($CfgPath, $Key)
            switch ($Key) {
                'MinimumPasswordLength' { '7' }
                'PasswordComplexity'    { '1' }
                'PasswordHistorySize'   { '24' }
                'MaximumPasswordAge'    { '90' }
                'MinimumPasswordAge'    { '1' }
            }
        }

        $changes = Set-PasswordPolicyBaseline -Config (New-TestConfig) -WorkingCfgPath 'C:\temp\working.cfg'

        ($changes | Where-Object Setting -eq 'MinimumPasswordLength').Changed | Should -BeTrue
        ($changes | Where-Object Setting -eq 'PasswordHistorySize').Changed | Should -BeFalse
        Should -Invoke -ModuleName PasswordPolicy -CommandName Set-SecurityPolicyValue -Times 1
        Should -Invoke -ModuleName PasswordPolicy -CommandName Invoke-SecEditConfigure -Times 1
    }
}

Describe 'Restore-PasswordPolicySettings' {
    It 'configures from the backed-up cfg file' {
        Mock -ModuleName PasswordPolicy -CommandName Invoke-SecEditConfigure { }
        $backupPath = Join-Path $TestDrive 'RestorePasswordPolicy'
        New-Item -Path $backupPath -ItemType Directory -Force | Out-Null
        $cfgPath = Join-Path $backupPath 'password-policy.cfg'
        Set-Content -Path $cfgPath -Value 'placeholder'

        Restore-PasswordPolicySettings -BackupPath $backupPath

        Should -Invoke -ModuleName PasswordPolicy -CommandName Invoke-SecEditConfigure -ParameterFilter { $CfgPath -eq $cfgPath } -Times 1
    }

    It 'throws when no backup cfg exists' {
        { Restore-PasswordPolicySettings -BackupPath (Join-Path $TestDrive 'missing') } | Should -Throw
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path Tests/Modules/PasswordPolicy.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Modules/PasswordPolicy.psm1` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

```powershell
# Modules/PasswordPolicy.psm1
Import-Module (Join-Path $PSScriptRoot '..\Common\SecEdit.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\Common\Config.psm1') -Force

$script:SeceditKeyMap = [ordered]@{
    MinimumPasswordLength  = 'MinimumPasswordLength'
    PasswordComplexity     = 'PasswordComplexity'
    PasswordHistorySize    = 'PasswordHistorySize'
    MaximumPasswordAgeDays = 'MaximumPasswordAge'
    MinimumPasswordAgeDays = 'MinimumPasswordAge'
}

function ConvertTo-SeceditValue {
    param($Value)
    if ($Value -is [bool]) {
        return $(if ($Value) { '1' } else { '0' })
    }
    return "$Value"
}

function ConvertFrom-SeceditValue {
    param([string]$RawValue, [string]$ConfigName)
    if ($ConfigName -eq 'PasswordComplexity') {
        return ($RawValue -eq '1')
    }
    return [int]$RawValue
}

function Test-PasswordPolicyBaseline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$WorkingCfgPath
    )

    Invoke-SecEditExport -CfgPath $WorkingCfgPath

    $results = foreach ($configName in $script:SeceditKeyMap.Keys) {
        $seceditKey = $script:SeceditKeyMap[$configName]
        $expected = Get-BaselineValue -Section $Config -Name $configName
        $rawActual = Get-SecurityPolicyValue -CfgPath $WorkingCfgPath -Key $seceditKey
        $actual = if ($null -ne $rawActual) { ConvertFrom-SeceditValue -RawValue $rawActual -ConfigName $configName } else { $null }

        [PSCustomObject]@{
            Module      = 'PasswordPolicy'
            Setting     = $configName
            Expected    = $expected
            Actual      = $actual
            Pass        = ($actual -eq $expected)
            Description = Get-BaselineDescription -Section $Config -Name $configName
        }
    }

    return $results
}

function Backup-PasswordPolicySettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    New-Item -Path $BackupPath -ItemType Directory -Force | Out-Null
    $cfgPath = Join-Path -Path $BackupPath -ChildPath 'password-policy.cfg'
    Invoke-SecEditExport -CfgPath $cfgPath
    return $cfgPath
}

function Set-PasswordPolicyBaseline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$WorkingCfgPath
    )

    Invoke-SecEditExport -CfgPath $WorkingCfgPath

    $changes = foreach ($configName in $script:SeceditKeyMap.Keys) {
        $seceditKey = $script:SeceditKeyMap[$configName]
        $expected = Get-BaselineValue -Section $Config -Name $configName
        $rawActual = Get-SecurityPolicyValue -CfgPath $WorkingCfgPath -Key $seceditKey
        $before = if ($null -ne $rawActual) { ConvertFrom-SeceditValue -RawValue $rawActual -ConfigName $configName } else { $null }
        $changed = ($before -ne $expected)

        if ($changed) {
            Set-SecurityPolicyValue -CfgPath $WorkingCfgPath -Key $seceditKey -Value (ConvertTo-SeceditValue -Value $expected)
        }

        [PSCustomObject]@{
            Module  = 'PasswordPolicy'
            Setting = $configName
            Before  = $before
            After   = $expected
            Changed = $changed
        }
    }

    Invoke-SecEditConfigure -CfgPath $WorkingCfgPath
    return $changes
}

function Restore-PasswordPolicySettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    $cfgPath = Join-Path -Path $BackupPath -ChildPath 'password-policy.cfg'
    if (-not (Test-Path -Path $cfgPath)) {
        throw "No password policy backup found at '$cfgPath'."
    }
    Invoke-SecEditConfigure -CfgPath $cfgPath
}

Export-ModuleMember -Function Test-PasswordPolicyBaseline, Backup-PasswordPolicySettings, Set-PasswordPolicyBaseline, Restore-PasswordPolicySettings
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path Tests/Modules/PasswordPolicy.Tests.ps1 -Output Detailed"`
Expected: PASS — 5 tests, 0 failed.

- [ ] **Step 5: Commit**

```bash
git add Modules/PasswordPolicy.psm1 Tests/Modules/PasswordPolicy.Tests.ps1
git commit -m "Add PasswordPolicy module (secedit-based, Home and Pro/Enterprise safe)"
```

---

## Task 8: Modules/AccountLockout.psm1

**Files:**
- Create: `Modules/AccountLockout.psm1`
- Test: `Tests/Modules/AccountLockout.Tests.ps1`

**Interfaces:**
- Consumes: `Common/SecEdit.psm1` (Task 6), `Common/Config.psm1` (Task 3) — same functions as Task 7.
- Produces: `Test-AccountLockoutBaseline(-Config, -WorkingCfgPath)`, `Backup-AccountLockoutSettings(-BackupPath)`, `Set-AccountLockoutBaseline(-Config, -WorkingCfgPath)`, `Restore-AccountLockoutSettings(-BackupPath)` — same shapes as Task 7's password-policy equivalents. Consumed by `Common/Orchestrator.psm1` (Task 15).

- [ ] **Step 1: Write the failing test**

```powershell
# Tests/Modules/AccountLockout.Tests.ps1
BeforeAll {
    Import-Module "$PSScriptRoot/../../Modules/AccountLockout.psm1" -Force

    function New-TestConfig {
        @{
            LockoutThreshold         = @{ Value = 5; Description = 'threshold' }
            LockoutDurationMinutes   = @{ Value = 15; Description = 'duration' }
            ObservationWindowMinutes = @{ Value = 15; Description = 'window' }
        }
    }
}

Describe 'Test-AccountLockoutBaseline' {
    It 'flags settings that do not match the config' {
        Mock -ModuleName AccountLockout -CommandName Invoke-SecEditExport { }
        Mock -ModuleName AccountLockout -CommandName Get-SecurityPolicyValue {
            param($CfgPath, $Key)
            switch ($Key) {
                'LockoutBadCount'   { '0' }
                'LockoutDuration'   { '15' }
                'ResetLockoutCount' { '15' }
            }
        }

        $results = Test-AccountLockoutBaseline -Config (New-TestConfig) -WorkingCfgPath 'C:\temp\working.cfg'

        ($results | Where-Object Setting -eq 'LockoutThreshold').Pass | Should -BeFalse
        ($results | Where-Object Setting -eq 'LockoutDurationMinutes').Pass | Should -BeTrue
    }
}

Describe 'Backup-AccountLockoutSettings' {
    It 'exports the current policy to account-lockout.cfg under the backup path' {
        Mock -ModuleName AccountLockout -CommandName Invoke-SecEditExport { }
        $backupPath = Join-Path $TestDrive 'AccountLockout'

        $cfgPath = Backup-AccountLockoutSettings -BackupPath $backupPath

        $cfgPath | Should -Be (Join-Path $backupPath 'account-lockout.cfg')
    }
}

Describe 'Set-AccountLockoutBaseline' {
    It 'only writes settings that differ from config' {
        Mock -ModuleName AccountLockout -CommandName Invoke-SecEditExport { }
        Mock -ModuleName AccountLockout -CommandName Invoke-SecEditConfigure { }
        Mock -ModuleName AccountLockout -CommandName Set-SecurityPolicyValue { }
        Mock -ModuleName AccountLockout -CommandName Get-SecurityPolicyValue {
            param($CfgPath, $Key)
            switch ($Key) {
                'LockoutBadCount'   { '0' }
                'LockoutDuration'   { '15' }
                'ResetLockoutCount' { '15' }
            }
        }

        $changes = Set-AccountLockoutBaseline -Config (New-TestConfig) -WorkingCfgPath 'C:\temp\working.cfg'

        ($changes | Where-Object Setting -eq 'LockoutThreshold').Changed | Should -BeTrue
        ($changes | Where-Object Setting -eq 'LockoutDurationMinutes').Changed | Should -BeFalse
        Should -Invoke -ModuleName AccountLockout -CommandName Set-SecurityPolicyValue -Times 1
    }
}

Describe 'Restore-AccountLockoutSettings' {
    It 'configures from the backed-up cfg file' {
        Mock -ModuleName AccountLockout -CommandName Invoke-SecEditConfigure { }
        $backupPath = Join-Path $TestDrive 'RestoreAccountLockout'
        New-Item -Path $backupPath -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $backupPath 'account-lockout.cfg') -Value 'placeholder'

        Restore-AccountLockoutSettings -BackupPath $backupPath

        Should -Invoke -ModuleName AccountLockout -CommandName Invoke-SecEditConfigure -Times 1
    }

    It 'throws when no backup cfg exists' {
        { Restore-AccountLockoutSettings -BackupPath (Join-Path $TestDrive 'missing') } | Should -Throw
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path Tests/Modules/AccountLockout.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Modules/AccountLockout.psm1` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

```powershell
# Modules/AccountLockout.psm1
Import-Module (Join-Path $PSScriptRoot '..\Common\SecEdit.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..\Common\Config.psm1') -Force

$script:SeceditKeyMap = [ordered]@{
    LockoutThreshold         = 'LockoutBadCount'
    LockoutDurationMinutes   = 'LockoutDuration'
    ObservationWindowMinutes = 'ResetLockoutCount'
}

function Test-AccountLockoutBaseline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$WorkingCfgPath
    )

    Invoke-SecEditExport -CfgPath $WorkingCfgPath

    $results = foreach ($configName in $script:SeceditKeyMap.Keys) {
        $seceditKey = $script:SeceditKeyMap[$configName]
        $expected = Get-BaselineValue -Section $Config -Name $configName
        $rawActual = Get-SecurityPolicyValue -CfgPath $WorkingCfgPath -Key $seceditKey
        $actual = if ($null -ne $rawActual) { [int]$rawActual } else { $null }

        [PSCustomObject]@{
            Module      = 'AccountLockout'
            Setting     = $configName
            Expected    = $expected
            Actual      = $actual
            Pass        = ($actual -eq $expected)
            Description = Get-BaselineDescription -Section $Config -Name $configName
        }
    }

    return $results
}

function Backup-AccountLockoutSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    New-Item -Path $BackupPath -ItemType Directory -Force | Out-Null
    $cfgPath = Join-Path -Path $BackupPath -ChildPath 'account-lockout.cfg'
    Invoke-SecEditExport -CfgPath $cfgPath
    return $cfgPath
}

function Set-AccountLockoutBaseline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$WorkingCfgPath
    )

    Invoke-SecEditExport -CfgPath $WorkingCfgPath

    $changes = foreach ($configName in $script:SeceditKeyMap.Keys) {
        $seceditKey = $script:SeceditKeyMap[$configName]
        $expected = Get-BaselineValue -Section $Config -Name $configName
        $rawActual = Get-SecurityPolicyValue -CfgPath $WorkingCfgPath -Key $seceditKey
        $before = if ($null -ne $rawActual) { [int]$rawActual } else { $null }
        $changed = ($before -ne $expected)

        if ($changed) {
            Set-SecurityPolicyValue -CfgPath $WorkingCfgPath -Key $seceditKey -Value "$expected"
        }

        [PSCustomObject]@{
            Module  = 'AccountLockout'
            Setting = $configName
            Before  = $before
            After   = $expected
            Changed = $changed
        }
    }

    Invoke-SecEditConfigure -CfgPath $WorkingCfgPath
    return $changes
}

function Restore-AccountLockoutSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    $cfgPath = Join-Path -Path $BackupPath -ChildPath 'account-lockout.cfg'
    if (-not (Test-Path -Path $cfgPath)) {
        throw "No account lockout backup found at '$cfgPath'."
    }
    Invoke-SecEditConfigure -CfgPath $cfgPath
}

Export-ModuleMember -Function Test-AccountLockoutBaseline, Backup-AccountLockoutSettings, Set-AccountLockoutBaseline, Restore-AccountLockoutSettings
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path Tests/Modules/AccountLockout.Tests.ps1 -Output Detailed"`
Expected: PASS — 5 tests, 0 failed.

- [ ] **Step 5: Commit**

```bash
git add Modules/AccountLockout.psm1 Tests/Modules/AccountLockout.Tests.ps1
git commit -m "Add AccountLockout module (secedit-based)"
```

---

## Task 9: Modules/AuditPolicy.psm1

**Files:**
- Create: `Modules/AuditPolicy.psm1`
- Test: `Tests/Modules/AuditPolicy.Tests.ps1`

**Interfaces:**
- Consumes: `Common/Config.psm1` (Task 3): `Get-BaselineValue`, `Get-BaselineDescription`.
- Produces: `Test-AuditPolicyBaseline(-Config <hashtable>)`, `Backup-AuditPolicySettings(-BackupPath <string>)`, `Set-AuditPolicyBaseline(-Config <hashtable>)`, `Restore-AuditPolicySettings(-BackupPath <string>)`. Consumed by `Common/Orchestrator.psm1` (Task 15). Note: unlike Password/AccountLockout, this module takes no `-WorkingCfgPath` — `auditpol.exe` reads/writes live state directly and has native `/backup /file:` and `/restore /file:` flags.

- [ ] **Step 1: Write the failing test**

```powershell
# Tests/Modules/AuditPolicy.Tests.ps1
BeforeAll {
    Import-Module "$PSScriptRoot/../../Modules/AuditPolicy.psm1" -Force

    function New-TestConfig {
        @{
            Categories = @{
                Value       = @{ 'Logon' = 'SuccessAndFailure'; 'Logoff' = 'Success' }
                Description = 'subcategories'
            }
        }
    }
}

Describe 'Test-AuditPolicyBaseline' {
    It 'flags subcategories that do not match the config' {
        Mock -ModuleName AuditPolicy -CommandName Get-AuditSubcategorySetting {
            param($Subcategory)
            switch ($Subcategory) {
                'Logon'  { 'NoAuditing' }
                'Logoff' { 'Success' }
            }
        }

        $results = Test-AuditPolicyBaseline -Config (New-TestConfig)

        ($results | Where-Object Setting -eq 'Logon').Pass | Should -BeFalse
        ($results | Where-Object Setting -eq 'Logoff').Pass | Should -BeTrue
    }
}

Describe 'Set-AuditPolicyBaseline' {
    It 'only sets subcategories that differ from config' {
        Mock -ModuleName AuditPolicy -CommandName Get-AuditSubcategorySetting {
            param($Subcategory)
            switch ($Subcategory) {
                'Logon'  { 'NoAuditing' }
                'Logoff' { 'Success' }
            }
        }
        Mock -ModuleName AuditPolicy -CommandName Set-AuditSubcategorySetting { }

        $changes = Set-AuditPolicyBaseline -Config (New-TestConfig)

        ($changes | Where-Object Setting -eq 'Logon').Changed | Should -BeTrue
        ($changes | Where-Object Setting -eq 'Logoff').Changed | Should -BeFalse
        Should -Invoke -ModuleName AuditPolicy -CommandName Set-AuditSubcategorySetting -Times 1 -ParameterFilter { $Subcategory -eq 'Logon' }
    }
}

Describe 'ConvertTo-AuditPolFlags' {
    It 'converts Success to enable/disable' {
        InModuleScope -ModuleName AuditPolicy {
            $result = ConvertTo-AuditPolFlags -Outcome 'Success'
            $result.Success | Should -Be 'enable'
            $result.Failure | Should -Be 'disable'
        }
    }

    It 'converts Failure to disable/enable' {
        InModuleScope -ModuleName AuditPolicy {
            $result = ConvertTo-AuditPolFlags -Outcome 'Failure'
            $result.Success | Should -Be 'disable'
            $result.Failure | Should -Be 'enable'
        }
    }

    It 'converts SuccessAndFailure to enable/enable' {
        InModuleScope -ModuleName AuditPolicy {
            $result = ConvertTo-AuditPolFlags -Outcome 'SuccessAndFailure'
            $result.Success | Should -Be 'enable'
            $result.Failure | Should -Be 'enable'
        }
    }

    It 'converts NoAuditing to disable/disable' {
        InModuleScope -ModuleName AuditPolicy {
            $result = ConvertTo-AuditPolFlags -Outcome 'NoAuditing'
            $result.Success | Should -Be 'disable'
            $result.Failure | Should -Be 'disable'
        }
    }
}

Describe 'Get-AuditSubcategorySetting' {
    It 'parses "Success and Failure" to SuccessAndFailure' {
        InModuleScope -ModuleName AuditPolicy {
            Mock -CommandName Invoke-AuditPolBinary {
                @(
                    'Machine Name,Policy Target,Subcategory,Subcategory GUID,Inclusion Setting,Exclusion Setting'
                    'HOST,System,Logon,{guid},Success and Failure,'
                )
            }

            $result = Get-AuditSubcategorySetting -Subcategory 'Logon'
            $result | Should -Be 'SuccessAndFailure'
        }
    }

    It 'parses "Success" to Success' {
        InModuleScope -ModuleName AuditPolicy {
            Mock -CommandName Invoke-AuditPolBinary {
                @(
                    'Machine Name,Policy Target,Subcategory,Subcategory GUID,Inclusion Setting,Exclusion Setting'
                    'HOST,System,Logon,{guid},Success,'
                )
            }

            $result = Get-AuditSubcategorySetting -Subcategory 'Logon'
            $result | Should -Be 'Success'
        }
    }

    It 'parses "Failure" to Failure' {
        InModuleScope -ModuleName AuditPolicy {
            Mock -CommandName Invoke-AuditPolBinary {
                @(
                    'Machine Name,Policy Target,Subcategory,Subcategory GUID,Inclusion Setting,Exclusion Setting'
                    'HOST,System,Logon,{guid},Failure,'
                )
            }

            $result = Get-AuditSubcategorySetting -Subcategory 'Logon'
            $result | Should -Be 'Failure'
        }
    }

    It 'defaults an unrecognized setting to NoAuditing' {
        InModuleScope -ModuleName AuditPolicy {
            Mock -CommandName Invoke-AuditPolBinary {
                @(
                    'Machine Name,Policy Target,Subcategory,Subcategory GUID,Inclusion Setting,Exclusion Setting'
                    'HOST,System,Logon,{guid},UnknownSetting,'
                )
            }

            $result = Get-AuditSubcategorySetting -Subcategory 'Logon'
            $result | Should -Be 'NoAuditing'
        }
    }
}

Describe 'Backup-AuditPolicySettings / Restore-AuditPolicySettings' {
    It 'backs up via the native auditpol /backup flag' {
        Mock -ModuleName AuditPolicy -CommandName Invoke-AuditPolBinary { }
        $backupPath = Join-Path $TestDrive 'AuditPolicy'

        $csvPath = Backup-AuditPolicySettings -BackupPath $backupPath

        $csvPath | Should -Be (Join-Path $backupPath 'audit-policy.csv')
        Should -Invoke -ModuleName AuditPolicy -CommandName Invoke-AuditPolBinary -ParameterFilter {
            $Arguments -contains '/backup'
        } -Times 1
    }

    It 'restores via the native auditpol /restore flag' {
        Mock -ModuleName AuditPolicy -CommandName Invoke-AuditPolBinary { }
        $backupPath = Join-Path $TestDrive 'RestoreAuditPolicy'
        New-Item -Path $backupPath -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $backupPath 'audit-policy.csv') -Value 'placeholder'

        Restore-AuditPolicySettings -BackupPath $backupPath

        Should -Invoke -ModuleName AuditPolicy -CommandName Invoke-AuditPolBinary -ParameterFilter {
            $Arguments -contains '/restore'
        } -Times 1
    }

    It 'throws when restoring without a prior backup' {
        { Restore-AuditPolicySettings -BackupPath (Join-Path $TestDrive 'missing') } | Should -Throw
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path Tests/Modules/AuditPolicy.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Modules/AuditPolicy.psm1` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

```powershell
# Modules/AuditPolicy.psm1
Import-Module (Join-Path $PSScriptRoot '..\Common\Config.psm1') -Force

function Invoke-AuditPolBinary {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments)
    & auditpol.exe @Arguments
}

function ConvertTo-AuditPolFlags {
    param(
        [Parameter(Mandatory)][ValidateSet('Success', 'Failure', 'SuccessAndFailure', 'NoAuditing')][string]$Outcome
    )

    switch ($Outcome) {
        'Success'           { @{ Success = 'enable'; Failure = 'disable' } }
        'Failure'           { @{ Success = 'disable'; Failure = 'enable' } }
        'SuccessAndFailure' { @{ Success = 'enable'; Failure = 'enable' } }
        'NoAuditing'        { @{ Success = 'disable'; Failure = 'disable' } }
    }
}

function Get-AuditSubcategorySetting {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Subcategory)

    $csv = Invoke-AuditPolBinary -Arguments @('/get', "/subcategory:$Subcategory", '/r')
    $row = $csv | ConvertFrom-Csv | Select-Object -First 1
    if (-not $row) {
        return $null
    }

    switch ($row.'Inclusion Setting') {
        'Success and Failure' { return 'SuccessAndFailure' }
        'Success'             { return 'Success' }
        'Failure'             { return 'Failure' }
        default               { return 'NoAuditing' }
    }
}

function Set-AuditSubcategorySetting {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Subcategory,
        [Parameter(Mandatory)][string]$Outcome
    )

    $flags = ConvertTo-AuditPolFlags -Outcome $Outcome
    Invoke-AuditPolBinary -Arguments @('/set', "/subcategory:$Subcategory", "/success:$($flags.Success)", "/failure:$($flags.Failure)") | Out-Null
}

function Test-AuditPolicyBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $categories = Get-BaselineValue -Section $Config -Name 'Categories'
    $description = Get-BaselineDescription -Section $Config -Name 'Categories'

    $results = foreach ($subcategory in $categories.Keys) {
        $expected = $categories[$subcategory]
        $actual = Get-AuditSubcategorySetting -Subcategory $subcategory

        [PSCustomObject]@{
            Module      = 'AuditPolicy'
            Setting     = $subcategory
            Expected    = $expected
            Actual      = $actual
            Pass        = ($actual -eq $expected)
            Description = $description
        }
    }

    return $results
}

function Backup-AuditPolicySettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    New-Item -Path $BackupPath -ItemType Directory -Force | Out-Null
    $csvPath = Join-Path -Path $BackupPath -ChildPath 'audit-policy.csv'
    Invoke-AuditPolBinary -Arguments @('/backup', "/file:$csvPath") | Out-Null
    return $csvPath
}

function Set-AuditPolicyBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $categories = Get-BaselineValue -Section $Config -Name 'Categories'

    $changes = foreach ($subcategory in $categories.Keys) {
        $expected = $categories[$subcategory]
        $before = Get-AuditSubcategorySetting -Subcategory $subcategory
        $changed = ($before -ne $expected)

        if ($changed) {
            Set-AuditSubcategorySetting -Subcategory $subcategory -Outcome $expected
        }

        [PSCustomObject]@{
            Module  = 'AuditPolicy'
            Setting = $subcategory
            Before  = $before
            After   = $expected
            Changed = $changed
        }
    }

    return $changes
}

function Restore-AuditPolicySettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    $csvPath = Join-Path -Path $BackupPath -ChildPath 'audit-policy.csv'
    if (-not (Test-Path -Path $csvPath)) {
        throw "No audit policy backup found at '$csvPath'."
    }
    Invoke-AuditPolBinary -Arguments @('/restore', "/file:$csvPath") | Out-Null
}

Export-ModuleMember -Function Test-AuditPolicyBaseline, Backup-AuditPolicySettings, Set-AuditPolicyBaseline, Restore-AuditPolicySettings
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path Tests/Modules/AuditPolicy.Tests.ps1 -Output Detailed"`
Expected: PASS — 13 tests, 0 failed. (Includes 8 tests added per a task-review fix, giving direct coverage to `ConvertTo-AuditPolFlags` and `Get-AuditSubcategorySetting`'s CSV parsing, which the original 5 tests only exercised indirectly through mocks.)

- [ ] **Step 5: Commit**

```bash
git add Modules/AuditPolicy.psm1 Tests/Modules/AuditPolicy.Tests.ps1
git commit -m "Add AuditPolicy module (auditpol-based advanced audit subcategories)"
```

---

## Task 10: Modules/Defender.psm1

**Files:**
- Create: `Modules/Defender.psm1`
- Test: `Tests/Modules/Defender.Tests.ps1`

**Interfaces:**
- Consumes: `Common/Config.psm1` (Task 3).
- Produces: `Test-DefenderBaseline(-Config <hashtable>)`, `Backup-DefenderSettings(-BackupPath <string>)`, `Set-DefenderBaseline(-Config <hashtable>)`, `Restore-DefenderSettings(-BackupPath <string>)`. Consumed by `Common/Orchestrator.psm1` (Task 15).

- [ ] **Step 1: Write the failing test**

```powershell
# Tests/Modules/Defender.Tests.ps1
BeforeAll {
    Import-Module "$PSScriptRoot/../../Modules/Defender.psm1" -Force

    function New-TestConfig {
        @{
            RealTimeProtection = @{ Value = $true; Description = 'rtp' }
            CloudProtection    = @{ Value = $true; Description = 'cloud' }
            PUAProtection      = @{ Value = 'Enabled'; Description = 'pua' }
        }
    }
}

Describe 'Test-DefenderBaseline' {
    It 'reports Pass=$true for every setting when live state already matches config' {
        Mock -ModuleName Defender -CommandName Get-DefenderPreference {
            [PSCustomObject]@{ DisableRealtimeMonitoring = $false; MAPSReporting = 2; PUAProtection = 1 }
        }
        $results = Test-DefenderBaseline -Config (New-TestConfig)
        @($results | Where-Object { -not $_.Pass }).Count | Should -Be 0
    }

    It 'reports Pass=$false when real-time protection is disabled' {
        Mock -ModuleName Defender -CommandName Get-DefenderPreference {
            [PSCustomObject]@{ DisableRealtimeMonitoring = $true; MAPSReporting = 2; PUAProtection = 1 }
        }
        $results = Test-DefenderBaseline -Config (New-TestConfig)
        ($results | Where-Object Setting -eq 'RealTimeProtection').Pass | Should -BeFalse
    }
}

Describe 'Set-DefenderBaseline' {
    It 'only calls Set-DefenderPreference for settings that are out of compliance' {
        Mock -ModuleName Defender -CommandName Get-DefenderPreference {
            [PSCustomObject]@{ DisableRealtimeMonitoring = $true; MAPSReporting = 2; PUAProtection = 1 }
        }
        Mock -ModuleName Defender -CommandName Set-DefenderPreference { }

        $changes = Set-DefenderBaseline -Config (New-TestConfig)

        Should -Invoke -ModuleName Defender -CommandName Set-DefenderPreference -Times 1
        ($changes | Where-Object Setting -eq 'RealTimeProtection').Changed | Should -BeTrue
        ($changes | Where-Object Setting -eq 'CloudProtection').Changed | Should -BeFalse
    }
}

Describe 'Backup-DefenderSettings / Restore-DefenderSettings' {
    It 'round-trips preference values through backup and restore' {
        Mock -ModuleName Defender -CommandName Get-DefenderPreference {
            [PSCustomObject]@{ DisableRealtimeMonitoring = $false; MAPSReporting = 2; PUAProtection = 1 }
        }
        Mock -ModuleName Defender -CommandName Set-DefenderPreference { }

        $backupPath = Join-Path $TestDrive 'Defender'
        Backup-DefenderSettings -BackupPath $backupPath
        Restore-DefenderSettings -BackupPath $backupPath

        Should -Invoke -ModuleName Defender -CommandName Set-DefenderPreference -Times 1 -ParameterFilter {
            $Settings.DisableRealtimeMonitoring -eq $false -and $Settings.MAPSReporting -eq 2 -and $Settings.PUAProtection -eq 1
        }
    }

    It 'throws when restoring without a prior backup' {
        { Restore-DefenderSettings -BackupPath (Join-Path $TestDrive 'missing') } | Should -Throw
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path Tests/Modules/Defender.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Modules/Defender.psm1` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

```powershell
# Modules/Defender.psm1
Import-Module (Join-Path $PSScriptRoot '..\Common\Config.psm1') -Force

function Get-DefenderPreference {
    [CmdletBinding()]
    param()
    Get-MpPreference
}

function Set-DefenderPreference {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Settings)
    Set-MpPreference @Settings
}

function Test-DefenderBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $pref = Get-DefenderPreference

    $realTimeExpected = Get-BaselineValue -Section $Config -Name 'RealTimeProtection'
    $realTimeActual = -not $pref.DisableRealtimeMonitoring

    $cloudExpected = Get-BaselineValue -Section $Config -Name 'CloudProtection'
    $cloudActual = ($pref.MAPSReporting -eq 2)

    $puaExpectedRaw = Get-BaselineValue -Section $Config -Name 'PUAProtection'
    $puaExpected = $(if ($puaExpectedRaw -eq 'Enabled') { 1 } else { 0 })
    $puaActual = [int]$pref.PUAProtection

    @(
        [PSCustomObject]@{
            Module = 'Defender'; Setting = 'RealTimeProtection'
            Expected = $realTimeExpected; Actual = $realTimeActual; Pass = ($realTimeActual -eq $realTimeExpected)
            Description = Get-BaselineDescription -Section $Config -Name 'RealTimeProtection'
        }
        [PSCustomObject]@{
            Module = 'Defender'; Setting = 'CloudProtection'
            Expected = $cloudExpected; Actual = $cloudActual; Pass = ($cloudActual -eq $cloudExpected)
            Description = Get-BaselineDescription -Section $Config -Name 'CloudProtection'
        }
        [PSCustomObject]@{
            Module = 'Defender'; Setting = 'PUAProtection'
            Expected = $puaExpected; Actual = $puaActual; Pass = ($puaActual -eq $puaExpected)
            Description = Get-BaselineDescription -Section $Config -Name 'PUAProtection'
        }
    )
}

function Backup-DefenderSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    New-Item -Path $BackupPath -ItemType Directory -Force | Out-Null
    $jsonPath = Join-Path -Path $BackupPath -ChildPath 'defender-preference.json'
    $pref = Get-DefenderPreference
    [PSCustomObject]@{
        DisableRealtimeMonitoring = $pref.DisableRealtimeMonitoring
        MAPSReporting             = $pref.MAPSReporting
        PUAProtection             = $pref.PUAProtection
    } | ConvertTo-Json | Set-Content -Path $jsonPath
    return $jsonPath
}

function Set-DefenderBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $before = Test-DefenderBaseline -Config $Config

    $changes = foreach ($result in $before) {
        if (-not $result.Pass) {
            switch ($result.Setting) {
                'RealTimeProtection' { Set-DefenderPreference -Settings @{ DisableRealtimeMonitoring = (-not $result.Expected) } }
                'CloudProtection'    { Set-DefenderPreference -Settings @{ MAPSReporting = $(if ($result.Expected) { 2 } else { 0 }) } }
                'PUAProtection'      { Set-DefenderPreference -Settings @{ PUAProtection = $result.Expected } }
            }
        }

        [PSCustomObject]@{
            Module  = 'Defender'
            Setting = $result.Setting
            Before  = $result.Actual
            After   = $result.Expected
            Changed = (-not $result.Pass)
        }
    }

    return $changes
}

function Restore-DefenderSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    $jsonPath = Join-Path -Path $BackupPath -ChildPath 'defender-preference.json'
    if (-not (Test-Path -Path $jsonPath)) {
        throw "No Defender backup found at '$jsonPath'."
    }
    $saved = Get-Content -Path $jsonPath -Raw | ConvertFrom-Json

    Set-DefenderPreference -Settings @{
        DisableRealtimeMonitoring = $saved.DisableRealtimeMonitoring
        MAPSReporting             = $saved.MAPSReporting
        PUAProtection             = $saved.PUAProtection
    }
}

Export-ModuleMember -Function Test-DefenderBaseline, Backup-DefenderSettings, Set-DefenderBaseline, Restore-DefenderSettings
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path Tests/Modules/Defender.Tests.ps1 -Output Detailed"`
Expected: PASS — 5 tests, 0 failed.

- [ ] **Step 5: Commit**

```bash
git add Modules/Defender.psm1 Tests/Modules/Defender.Tests.ps1
git commit -m "Add Defender module (Set-MpPreference-based)"
```

---

## Task 11: Modules/Firewall.psm1

**Files:**
- Create: `Modules/Firewall.psm1`
- Test: `Tests/Modules/Firewall.Tests.ps1`

**Interfaces:**
- Consumes: `Common/Config.psm1` (Task 3).
- Produces: `Test-FirewallBaseline(-Config <hashtable>)`, `Backup-FirewallSettings(-BackupPath <string>)`, `Set-FirewallBaseline(-Config <hashtable>)`, `Restore-FirewallSettings(-BackupPath <string>)`. Consumed by `Common/Orchestrator.psm1` (Task 15).

- [ ] **Step 1: Write the failing test**

```powershell
# Tests/Modules/Firewall.Tests.ps1
BeforeAll {
    Import-Module "$PSScriptRoot/../../Modules/Firewall.psm1" -Force

    function New-TestConfig {
        @{
            EnabledProfiles      = @{ Value = @('Domain', 'Private', 'Public'); Description = 'profiles' }
            DefaultInboundAction = @{ Value = 'Block'; Description = 'inbound' }
            LoggingEnabled       = @{ Value = $true; Description = 'logging' }
        }
    }
}

Describe 'Test-FirewallBaseline' {
    It 'flags a profile with logging disabled' {
        Mock -ModuleName Firewall -CommandName Get-FirewallProfileState {
            param($ProfileName)
            [PSCustomObject]@{ Enabled = $true; DefaultInboundAction = 'Block'; LogAllowed = $false; LogBlocked = $false }
        }

        $results = Test-FirewallBaseline -Config (New-TestConfig)

        @($results | Where-Object { $_.Setting -eq 'Domain.LoggingEnabled' }).Pass | Should -BeFalse
        @($results | Where-Object { $_.Setting -eq 'Domain.DefaultInboundAction' }).Pass | Should -BeTrue
    }
}

Describe 'Set-FirewallBaseline' {
    It 'only reconfigures a profile that is out of compliance' {
        Mock -ModuleName Firewall -CommandName Get-FirewallProfileState {
            param($ProfileName)
            if ($ProfileName -eq 'Public') {
                [PSCustomObject]@{ Enabled = $false; DefaultInboundAction = 'Allow'; LogAllowed = $false; LogBlocked = $false }
            }
            else {
                [PSCustomObject]@{ Enabled = $true; DefaultInboundAction = 'Block'; LogAllowed = $true; LogBlocked = $true }
            }
        }
        Mock -ModuleName Firewall -CommandName Set-FirewallProfileState { }

        Set-FirewallBaseline -Config (New-TestConfig) | Out-Null

        Should -Invoke -ModuleName Firewall -CommandName Set-FirewallProfileState -Times 1 -ParameterFilter { $ProfileName -eq 'Public' }
    }
}

Describe 'Backup-FirewallSettings / Restore-FirewallSettings' {
    It 'exports via netsh advfirewall export' {
        Mock -ModuleName Firewall -CommandName Invoke-NetshBinary { }
        $backupPath = Join-Path $TestDrive 'Firewall'

        $wfwPath = Backup-FirewallSettings -BackupPath $backupPath

        $wfwPath | Should -Be (Join-Path $backupPath 'firewall.wfw')
        Should -Invoke -ModuleName Firewall -CommandName Invoke-NetshBinary -ParameterFilter {
            $Arguments -contains 'export'
        } -Times 1
    }

    It 'imports via netsh advfirewall import' {
        Mock -ModuleName Firewall -CommandName Invoke-NetshBinary { }
        $backupPath = Join-Path $TestDrive 'RestoreFirewall'
        New-Item -Path $backupPath -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $backupPath 'firewall.wfw') -Value 'placeholder'

        Restore-FirewallSettings -BackupPath $backupPath

        Should -Invoke -ModuleName Firewall -CommandName Invoke-NetshBinary -ParameterFilter {
            $Arguments -contains 'import'
        } -Times 1
    }

    It 'throws when restoring without a prior backup' {
        { Restore-FirewallSettings -BackupPath (Join-Path $TestDrive 'missing') } | Should -Throw
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path Tests/Modules/Firewall.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Modules/Firewall.psm1` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

```powershell
# Modules/Firewall.psm1
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path Tests/Modules/Firewall.Tests.ps1 -Output Detailed"`
Expected: PASS — 5 tests, 0 failed.

- [ ] **Step 5: Commit**

```bash
git add Modules/Firewall.psm1 Tests/Modules/Firewall.Tests.ps1
git commit -m "Add Firewall module (NetSecurity + netsh advfirewall backup/restore)"
```

---

## Task 12: Modules/ScreenLock.psm1

**Files:**
- Create: `Modules/ScreenLock.psm1`
- Test: `Tests/Modules/ScreenLock.Tests.ps1`

**Interfaces:**
- Consumes: `Common/Config.psm1` (Task 3).
- Produces: `Test-ScreenLockBaseline(-Config <hashtable>)`, `Backup-ScreenLockSettings(-BackupPath <string>)`, `Set-ScreenLockBaseline(-Config <hashtable>)`, `Restore-ScreenLockSettings(-BackupPath <string>)`. Consumed by `Common/Orchestrator.psm1` (Task 15).

- [ ] **Step 1: Write the failing test**

```powershell
# Tests/Modules/ScreenLock.Tests.ps1
BeforeAll {
    Import-Module "$PSScriptRoot/../../Modules/ScreenLock.psm1" -Force

    function New-TestConfig {
        @{ InactivityTimeoutSeconds = @{ Value = 900; Description = '15 min' } }
    }
}

Describe 'Test-ScreenLockBaseline' {
    It 'fails when the live value differs from config' {
        Mock -ModuleName ScreenLock -CommandName Get-InactivityTimeoutValue { 0 }
        (Test-ScreenLockBaseline -Config (New-TestConfig))[0].Pass | Should -BeFalse
    }

    It 'passes when the live value matches config' {
        Mock -ModuleName ScreenLock -CommandName Get-InactivityTimeoutValue { 900 }
        (Test-ScreenLockBaseline -Config (New-TestConfig))[0].Pass | Should -BeTrue
    }
}

Describe 'Set-ScreenLockBaseline' {
    It 'writes the new value only when it differs from the current one' {
        Mock -ModuleName ScreenLock -CommandName Get-InactivityTimeoutValue { 0 }
        Mock -ModuleName ScreenLock -CommandName Set-InactivityTimeoutValue { }

        $changes = Set-ScreenLockBaseline -Config (New-TestConfig)

        $changes[0].Changed | Should -BeTrue
        Should -Invoke -ModuleName ScreenLock -CommandName Set-InactivityTimeoutValue -Times 1 -ParameterFilter { $Seconds -eq 900 }
    }

    It 'skips writing when already compliant' {
        Mock -ModuleName ScreenLock -CommandName Get-InactivityTimeoutValue { 900 }
        Mock -ModuleName ScreenLock -CommandName Set-InactivityTimeoutValue { }

        $changes = Set-ScreenLockBaseline -Config (New-TestConfig)

        $changes[0].Changed | Should -BeFalse
        Should -Invoke -ModuleName ScreenLock -CommandName Set-InactivityTimeoutValue -Times 0
    }
}

Describe 'Backup-ScreenLockSettings / Restore-ScreenLockSettings' {
    It 'exports the registry key via the reg export wrapper' {
        Mock -ModuleName ScreenLock -CommandName Export-InactivityTimeoutRegistry { }
        $backupPath = Join-Path $TestDrive 'ScreenLock'

        $regPath = Backup-ScreenLockSettings -BackupPath $backupPath

        $regPath | Should -Be (Join-Path $backupPath 'screenlock.reg')
    }

    It 'imports the registry key via the reg import wrapper' {
        Mock -ModuleName ScreenLock -CommandName Import-InactivityTimeoutRegistry { }
        $backupPath = Join-Path $TestDrive 'RestoreScreenLock'
        New-Item -Path $backupPath -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $backupPath 'screenlock.reg') -Value 'placeholder'

        Restore-ScreenLockSettings -BackupPath $backupPath

        Should -Invoke -ModuleName ScreenLock -CommandName Import-InactivityTimeoutRegistry -Times 1
    }

    It 'throws when restoring without a prior backup' {
        { Restore-ScreenLockSettings -BackupPath (Join-Path $TestDrive 'missing') } | Should -Throw
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path Tests/Modules/ScreenLock.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Modules/ScreenLock.psm1` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

```powershell
# Modules/ScreenLock.psm1
Import-Module (Join-Path $PSScriptRoot '..\Common\Config.psm1') -Force

$script:RegistryPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$script:ValueName = 'InactivityTimeoutSecs'

function Get-InactivityTimeoutValue {
    [CmdletBinding()]
    param()
    $item = Get-ItemProperty -Path $script:RegistryPath -Name $script:ValueName -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return $null
    }
    return $item.$($script:ValueName)
}

function Set-InactivityTimeoutValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Seconds)

    if (-not (Test-Path -Path $script:RegistryPath)) {
        New-Item -Path $script:RegistryPath -Force | Out-Null
    }
    New-ItemProperty -Path $script:RegistryPath -Name $script:ValueName -Value $Seconds -PropertyType DWord -Force | Out-Null
}

function Export-InactivityTimeoutRegistry {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RegPath)
    & reg.exe export 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' $RegPath /y
}

function Import-InactivityTimeoutRegistry {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RegPath)
    & reg.exe import $RegPath
}

function Test-ScreenLockBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $expected = Get-BaselineValue -Section $Config -Name 'InactivityTimeoutSeconds'
    $actual = Get-InactivityTimeoutValue

    @(
        [PSCustomObject]@{
            Module = 'ScreenLock'; Setting = 'InactivityTimeoutSeconds'
            Expected = $expected; Actual = $actual; Pass = ($actual -eq $expected)
            Description = Get-BaselineDescription -Section $Config -Name 'InactivityTimeoutSeconds'
        }
    )
}

function Backup-ScreenLockSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    New-Item -Path $BackupPath -ItemType Directory -Force | Out-Null
    $regPath = Join-Path -Path $BackupPath -ChildPath 'screenlock.reg'
    Export-InactivityTimeoutRegistry -RegPath $regPath
    return $regPath
}

function Set-ScreenLockBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $result = (Test-ScreenLockBaseline -Config $Config)[0]

    if (-not $result.Pass) {
        Set-InactivityTimeoutValue -Seconds $result.Expected
    }

    @(
        [PSCustomObject]@{
            Module = 'ScreenLock'; Setting = 'InactivityTimeoutSeconds'
            Before = $result.Actual; After = $result.Expected; Changed = (-not $result.Pass)
        }
    )
}

function Restore-ScreenLockSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    $regPath = Join-Path -Path $BackupPath -ChildPath 'screenlock.reg'
    if (-not (Test-Path -Path $regPath)) {
        throw "No screen lock backup found at '$regPath'."
    }
    Import-InactivityTimeoutRegistry -RegPath $regPath
}

Export-ModuleMember -Function Test-ScreenLockBaseline, Backup-ScreenLockSettings, Set-ScreenLockBaseline, Restore-ScreenLockSettings
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path Tests/Modules/ScreenLock.Tests.ps1 -Output Detailed"`
Expected: PASS — 7 tests, 0 failed.

- [ ] **Step 5: Commit**

```bash
git add Modules/ScreenLock.psm1 Tests/Modules/ScreenLock.Tests.ps1
git commit -m "Add ScreenLock module (machine inactivity limit registry key)"
```

---

## Task 13: Modules/RemoteAccess.psm1

**Files:**
- Create: `Modules/RemoteAccess.psm1`
- Test: `Tests/Modules/RemoteAccess.Tests.ps1`

**Interfaces:**
- Consumes: `Common/Config.psm1` (Task 3).
- Produces: `Test-RemoteAccessBaseline(-Config <hashtable>)`, `Backup-RemoteAccessSettings(-BackupPath <string>)`, `Set-RemoteAccessBaseline(-Config <hashtable>)`, `Restore-RemoteAccessSettings(-BackupPath <string>)`. Consumed by `Common/Orchestrator.psm1` (Task 15).

- [ ] **Step 1: Write the failing test**

```powershell
# Tests/Modules/RemoteAccess.Tests.ps1
BeforeAll {
    Import-Module "$PSScriptRoot/../../Modules/RemoteAccess.psm1" -Force

    function New-TestConfig {
        @{
            DisableRDP          = @{ Value = $true; Description = 'rdp' }
            DisableSMBv1        = @{ Value = $true; Description = 'smb1' }
            DisableGuestAccount = @{ Value = $true; Description = 'guest' }
        }
    }
}

Describe 'Test-RemoteAccessBaseline' {
    It 'flags RDP as non-compliant when it is not denied' {
        Mock -ModuleName RemoteAccess -CommandName Get-RdpDenyValue { $false }
        Mock -ModuleName RemoteAccess -CommandName Get-Smb1Enabled { $false }
        Mock -ModuleName RemoteAccess -CommandName Get-GuestAccountEnabled { $false }

        $results = Test-RemoteAccessBaseline -Config (New-TestConfig)

        ($results | Where-Object Setting -eq 'DisableRDP').Pass | Should -BeFalse
        ($results | Where-Object Setting -eq 'DisableSMBv1').Pass | Should -BeTrue
        ($results | Where-Object Setting -eq 'DisableGuestAccount').Pass | Should -BeTrue
    }
}

Describe 'Set-RemoteAccessBaseline' {
    It 'only touches settings that are out of compliance' {
        Mock -ModuleName RemoteAccess -CommandName Get-RdpDenyValue { $false }
        Mock -ModuleName RemoteAccess -CommandName Get-Smb1Enabled { $false }
        Mock -ModuleName RemoteAccess -CommandName Get-GuestAccountEnabled { $false }
        Mock -ModuleName RemoteAccess -CommandName Set-RdpDenyValue { }
        Mock -ModuleName RemoteAccess -CommandName Set-Smb1Enabled { }
        Mock -ModuleName RemoteAccess -CommandName Set-GuestAccountEnabled { }

        $changes = Set-RemoteAccessBaseline -Config (New-TestConfig)

        ($changes | Where-Object Setting -eq 'DisableRDP').Changed | Should -BeTrue
        Should -Invoke -ModuleName RemoteAccess -CommandName Set-RdpDenyValue -Times 1
        Should -Invoke -ModuleName RemoteAccess -CommandName Set-Smb1Enabled -Times 0
        Should -Invoke -ModuleName RemoteAccess -CommandName Set-GuestAccountEnabled -Times 0
    }

    It 'correctly inverts polarity when writing SMBv1 and Guest account state' {
        Mock -ModuleName RemoteAccess -CommandName Get-RdpDenyValue { $true }
        Mock -ModuleName RemoteAccess -CommandName Get-Smb1Enabled { $true }
        Mock -ModuleName RemoteAccess -CommandName Get-GuestAccountEnabled { $true }
        Mock -ModuleName RemoteAccess -CommandName Set-RdpDenyValue { }
        Mock -ModuleName RemoteAccess -CommandName Set-Smb1Enabled { }
        Mock -ModuleName RemoteAccess -CommandName Set-GuestAccountEnabled { }

        Set-RemoteAccessBaseline -Config (New-TestConfig) | Out-Null

        Should -Invoke -ModuleName RemoteAccess -CommandName Set-Smb1Enabled -Times 1 -ParameterFilter { $Enabled -eq $false }
        Should -Invoke -ModuleName RemoteAccess -CommandName Set-GuestAccountEnabled -Times 1 -ParameterFilter { $Enabled -eq $false }
        Should -Invoke -ModuleName RemoteAccess -CommandName Set-RdpDenyValue -Times 0
    }
}

Describe 'Backup-RemoteAccessSettings / Restore-RemoteAccessSettings' {
    It 'round-trips SMB1/Guest state and re-imports the registry' {
        Mock -ModuleName RemoteAccess -CommandName Export-RemoteAccessRegistry { }
        Mock -ModuleName RemoteAccess -CommandName Import-RemoteAccessRegistry { }
        Mock -ModuleName RemoteAccess -CommandName Get-Smb1Enabled { $false }
        Mock -ModuleName RemoteAccess -CommandName Get-GuestAccountEnabled { $false }
        Mock -ModuleName RemoteAccess -CommandName Set-Smb1Enabled { }
        Mock -ModuleName RemoteAccess -CommandName Set-GuestAccountEnabled { }

        $backupPath = Join-Path $TestDrive 'RemoteAccess'
        Backup-RemoteAccessSettings -BackupPath $backupPath
        Restore-RemoteAccessSettings -BackupPath $backupPath

        Should -Invoke -ModuleName RemoteAccess -CommandName Import-RemoteAccessRegistry -Times 1
        Should -Invoke -ModuleName RemoteAccess -CommandName Set-Smb1Enabled -Times 1 -ParameterFilter { $Enabled -eq $false }
        Should -Invoke -ModuleName RemoteAccess -CommandName Set-GuestAccountEnabled -Times 1 -ParameterFilter { $Enabled -eq $false }
    }

    It 'throws when restoring without a prior backup' {
        { Restore-RemoteAccessSettings -BackupPath (Join-Path $TestDrive 'missing') } | Should -Throw
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path Tests/Modules/RemoteAccess.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Modules/RemoteAccess.psm1` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

```powershell
# Modules/RemoteAccess.psm1
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
}

function Import-RemoteAccessRegistry {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RegPath)
    & reg.exe import $RegPath
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path Tests/Modules/RemoteAccess.Tests.ps1 -Output Detailed"`
Expected: PASS — 5 tests, 0 failed. (Includes a regression test added per a task-review fix: `Set-RemoteAccessBaseline` previously had no test exercising the write-side polarity inversion for SMBv1/Guest when they are actually non-compliant.)

- [ ] **Step 5: Commit**

```bash
git add Modules/RemoteAccess.psm1 Tests/Modules/RemoteAccess.Tests.ps1
git commit -m "Add RemoteAccess module (RDP, SMBv1, Guest account)"
```

---

## Task 14: Modules/BitLocker.psm1

**Files:**
- Create: `Modules/BitLocker.psm1`
- Test: `Tests/Modules/BitLocker.Tests.ps1`

**Interfaces:**
- Consumes: `Common/Config.psm1` (Task 3).
- Produces: `Test-BitLockerBaseline(-Config <hashtable>)`, `Backup-BitLockerSettings(-BackupPath <string>)`, `Set-BitLockerBaseline(-Config <hashtable>)`, `Restore-BitLockerSettings(-BackupPath <string>, [-DecryptOnRestore])`. Consumed by `Common/Orchestrator.psm1` (Task 15). Note the extra `-DecryptOnRestore` switch, unique to this module per the design spec's restore-safety rule.

- [ ] **Step 1: Write the failing test**

```powershell
# Tests/Modules/BitLocker.Tests.ps1
BeforeAll {
    Import-Module "$PSScriptRoot/../../Modules/BitLocker.psm1" -Force

    # $env:SystemDrive is a Windows-only environment variable; Set-BitLockerBaseline
    # references it directly (not inside a mockable wrapper), so it must be set here
    # for the test to run on non-Windows dev hardware.
    $env:SystemDrive = 'C:'

    function New-TestConfig {
        @{
            EncryptionMethod = @{ Value = 'XtsAes256'; Description = 'method' }
            RecoveryKeyPath  = @{ Value = (Join-Path $TestDrive 'RecoveryKeys'); Description = 'key path' }
        }
    }
}

Describe 'Test-BitLockerBaseline' {
    It 'passes when protection status is On' {
        Mock -ModuleName BitLocker -CommandName Get-OsDriveBitLockerVolume { [PSCustomObject]@{ ProtectionStatus = 'On' } }
        (Test-BitLockerBaseline -Config (New-TestConfig))[0].Pass | Should -BeTrue
    }

    It 'fails when protection status is Off' {
        Mock -ModuleName BitLocker -CommandName Get-OsDriveBitLockerVolume { [PSCustomObject]@{ ProtectionStatus = 'Off' } }
        (Test-BitLockerBaseline -Config (New-TestConfig))[0].Pass | Should -BeFalse
    }

    It 'fails without throwing when BitLocker is unavailable on this SKU' {
        Mock -ModuleName BitLocker -CommandName Get-OsDriveBitLockerVolume { throw 'BitLocker is not available on this device.' }
        { Test-BitLockerBaseline -Config (New-TestConfig) } | Should -Not -Throw
        (Test-BitLockerBaseline -Config (New-TestConfig))[0].Pass | Should -BeFalse
    }
}

Describe 'Set-BitLockerBaseline' {
    It 'attempts to enable encryption and saves the recovery key when not yet protected' {
        Mock -ModuleName BitLocker -CommandName Get-OsDriveBitLockerVolume { [PSCustomObject]@{ ProtectionStatus = 'Off' } }
        Mock -ModuleName BitLocker -CommandName Enable-OsDriveBitLocker { }
        Mock -ModuleName BitLocker -CommandName Get-OsDriveRecoveryKey { 'AAAA-1111-BBBB-2222' }

        $changes = Set-BitLockerBaseline -Config (New-TestConfig)

        $changes[0].Changed | Should -BeTrue
        Should -Invoke -ModuleName BitLocker -CommandName Enable-OsDriveBitLocker -Times 1
        $keyFiles = Get-ChildItem -Path (Join-Path $TestDrive 'RecoveryKeys') -Filter '*.txt'
        $keyFiles.Count | Should -Be 1
        Get-Content -Path $keyFiles[0].FullName | Should -Be 'AAAA-1111-BBBB-2222'
    }

    It 'does nothing when already protected' {
        Mock -ModuleName BitLocker -CommandName Get-OsDriveBitLockerVolume { [PSCustomObject]@{ ProtectionStatus = 'On' } }
        Mock -ModuleName BitLocker -CommandName Enable-OsDriveBitLocker { }

        $changes = Set-BitLockerBaseline -Config (New-TestConfig)

        $changes[0].Changed | Should -BeFalse
        Should -Invoke -ModuleName BitLocker -CommandName Enable-OsDriveBitLocker -Times 0
    }
}

Describe 'Restore-BitLockerSettings' {
    It 'skips restoring by default' {
        Mock -ModuleName BitLocker -CommandName Disable-OsDriveBitLocker { }
        $backupPath = Join-Path $TestDrive 'BitLockerBackupSkip'
        New-Item -Path $backupPath -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $backupPath 'bitlocker-state.json') -Value (@{ ProtectionStatus = 'Off' } | ConvertTo-Json)

        $result = Restore-BitLockerSettings -BackupPath $backupPath

        $result.Restored | Should -BeFalse
        Should -Invoke -ModuleName BitLocker -CommandName Disable-OsDriveBitLocker -Times 0
    }

    It 'decrypts when -DecryptOnRestore is passed and the backup shows protection was Off' {
        Mock -ModuleName BitLocker -CommandName Disable-OsDriveBitLocker { }
        $backupPath = Join-Path $TestDrive 'BitLockerBackupDecrypt'
        New-Item -Path $backupPath -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $backupPath 'bitlocker-state.json') -Value (@{ ProtectionStatus = 'Off' } | ConvertTo-Json)

        $result = Restore-BitLockerSettings -BackupPath $backupPath -DecryptOnRestore

        $result.Restored | Should -BeTrue
        Should -Invoke -ModuleName BitLocker -CommandName Disable-OsDriveBitLocker -Times 1
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path Tests/Modules/BitLocker.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Modules/BitLocker.psm1` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

```powershell
# Modules/BitLocker.psm1
Import-Module (Join-Path $PSScriptRoot '..\Common\Config.psm1') -Force

function Get-OsDriveBitLockerVolume {
    [CmdletBinding()]
    param()
    Get-BitLockerVolume -MountPoint $env:SystemDrive
}

function Enable-OsDriveBitLocker {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$EncryptionMethod)
    Enable-BitLocker -MountPoint $env:SystemDrive -EncryptionMethod $EncryptionMethod -RecoveryPasswordProtector -SkipHardwareTest
}

function Disable-OsDriveBitLocker {
    [CmdletBinding()]
    param()
    Disable-BitLocker -MountPoint $env:SystemDrive
}

function Get-OsDriveRecoveryKey {
    [CmdletBinding()]
    param()
    $volume = Get-OsDriveBitLockerVolume
    $protector = $volume.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' } | Select-Object -First 1
    if ($protector) { return $protector.RecoveryPassword }
    return $null
}

function Test-BitLockerBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    try {
        $volume = Get-OsDriveBitLockerVolume
        $actual = ("$($volume.ProtectionStatus)" -eq 'On')
        $description = 'OS drive encryption status (BitLocker or Device Encryption).'
    }
    catch {
        $actual = $false
        $description = "BitLocker/Device Encryption is not available or not queryable on this device: $($_.Exception.Message)"
    }

    @(
        [PSCustomObject]@{
            Module = 'BitLocker'; Setting = 'OSDriveEncrypted'
            Expected = $true; Actual = $actual; Pass = $actual
            Description = $description
        }
    )
}

function Backup-BitLockerSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    New-Item -Path $BackupPath -ItemType Directory -Force | Out-Null
    $statePath = Join-Path -Path $BackupPath -ChildPath 'bitlocker-state.json'

    try {
        $volume = Get-OsDriveBitLockerVolume
        $state = [PSCustomObject]@{ ProtectionStatus = "$($volume.ProtectionStatus)" }
    }
    catch {
        $state = [PSCustomObject]@{ ProtectionStatus = 'Unavailable' }
    }

    $state | ConvertTo-Json | Set-Content -Path $statePath
    return $statePath
}

function Set-BitLockerBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $before = (Test-BitLockerBaseline -Config $Config)[0]
    $method = Get-BaselineValue -Section $Config -Name 'EncryptionMethod'
    $keyFolder = Get-BaselineValue -Section $Config -Name 'RecoveryKeyPath'

    $changed = $false

    if (-not $before.Pass) {
        Enable-OsDriveBitLocker -EncryptionMethod $method

        if (-not (Test-Path -Path $keyFolder)) {
            New-Item -Path $keyFolder -ItemType Directory -Force | Out-Null
        }
        $recoveryKey = Get-OsDriveRecoveryKey
        if ($recoveryKey) {
            $safeName = $env:SystemDrive.Replace(':', '')
            $keyFile = Join-Path -Path $keyFolder -ChildPath "$safeName-recovery-key.txt"
            Set-Content -Path $keyFile -Value $recoveryKey
        }
        $changed = $true
    }

    @(
        [PSCustomObject]@{
            Module  = 'BitLocker'
            Setting = 'OSDriveEncrypted'
            Before  = $before.Actual
            After   = $(if ($changed) { $true } else { $before.Actual })
            Changed = $changed
        }
    )
}

function Restore-BitLockerSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BackupPath,
        [switch]$DecryptOnRestore
    )

    if (-not $DecryptOnRestore) {
        return [PSCustomObject]@{
            Module   = 'BitLocker'
            Setting  = 'OSDriveEncrypted'
            Restored = $false
            Reason   = 'BitLocker restore skipped (pass -DecryptOnRestore to include it).'
        }
    }

    $statePath = Join-Path -Path $BackupPath -ChildPath 'bitlocker-state.json'
    if (-not (Test-Path -Path $statePath)) {
        throw "No BitLocker backup found at '$statePath'."
    }
    $saved = Get-Content -Path $statePath -Raw | ConvertFrom-Json

    if ($saved.ProtectionStatus -ne 'On') {
        Disable-OsDriveBitLocker
    }

    return [PSCustomObject]@{ Module = 'BitLocker'; Setting = 'OSDriveEncrypted'; Restored = $true }
}

Export-ModuleMember -Function Test-BitLockerBaseline, Backup-BitLockerSettings, Set-BitLockerBaseline, Restore-BitLockerSettings
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path Tests/Modules/BitLocker.Tests.ps1 -Output Detailed"`
Expected: PASS — 7 tests, 0 failed.

- [ ] **Step 5: Commit**

```bash
git add Modules/BitLocker.psm1 Tests/Modules/BitLocker.Tests.ps1
git commit -m "Add BitLocker module (edition-agnostic attempt, local recovery key, opt-in decrypt-on-restore)"
```

---

## Task 15: Common/Orchestrator.psm1 — ties all modules together

**Files:**
- Create: `Common/Orchestrator.psm1`
- Test: `Tests/Common/Orchestrator.Tests.ps1`

**Interfaces:**
- Consumes: `Test-BaselineElevation`, `Get-WindowsEditionInfo` (Task 2); `Import-BaselineConfig` (Task 3); `New-BaselineBackupFolder`, `Write-BaselineManifest`, `Resolve-BaselineSnapshotPath` (Task 4); `New-BaselineAuditReport`, `Write-BaselineAuditSummary`, `Write-BaselineApplySummary` (Task 5); `Write-BaselineLog` (Task 1); and, by exact name only (not statically imported — see below), every `Test-/Backup-/Set-/Restore-` function from Tasks 7–14.
- Produces: `Invoke-BaselineRun(-Mode <'Audit'|'Apply'|'Restore'>, -RootPath <string>, -ConfigPath <string>, -RunTimestamp <string>, [-Modules <string[]>], [-SnapshotTimestamp <string>], [-Latest], [-DecryptOnRestore])` → mode-dependent result array. Consumed by `Invoke-SecurityBaseline.ps1` (Task 16).

This module calls the 8 area modules' functions by name via the call operator (`& $functionName`) rather than importing them directly, because the orchestrator must stay decoupled from which modules are loaded — the entry point script (Task 16) is responsible for importing all `Modules/*.psm1` into the global session before calling `Invoke-BaselineRun`. For this task's own tests, define lightweight global stub functions for the 32 area-module function names before mocking them (a real target function must exist for Pester's `Mock` to attach to — verified in Task 6's spike).

- [ ] **Step 1: Write the failing test**

```powershell
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path Tests/Common/Orchestrator.Tests.ps1 -Output Detailed"`
Expected: FAIL — `Common/Orchestrator.psm1` does not exist yet.

- [ ] **Step 3: Write minimal implementation**

```powershell
# Common/Orchestrator.psm1
Import-Module (Join-Path $PSScriptRoot 'SystemInfo.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Config.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'BackupRestore.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Reporting.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Logging.psm1') -Force

$script:AllModules = @('PasswordPolicy', 'AccountLockout', 'Defender', 'Firewall', 'ScreenLock', 'AuditPolicy', 'RemoteAccess', 'BitLocker')

$script:ModuleFunctionMap = @{
    PasswordPolicy = @{ Test = 'Test-PasswordPolicyBaseline'; Backup = 'Backup-PasswordPolicySettings'; Set = 'Set-PasswordPolicyBaseline'; Restore = 'Restore-PasswordPolicySettings' }
    AccountLockout = @{ Test = 'Test-AccountLockoutBaseline'; Backup = 'Backup-AccountLockoutSettings'; Set = 'Set-AccountLockoutBaseline'; Restore = 'Restore-AccountLockoutSettings' }
    Defender       = @{ Test = 'Test-DefenderBaseline';       Backup = 'Backup-DefenderSettings';       Set = 'Set-DefenderBaseline';       Restore = 'Restore-DefenderSettings' }
    Firewall       = @{ Test = 'Test-FirewallBaseline';       Backup = 'Backup-FirewallSettings';       Set = 'Set-FirewallBaseline';       Restore = 'Restore-FirewallSettings' }
    ScreenLock     = @{ Test = 'Test-ScreenLockBaseline';     Backup = 'Backup-ScreenLockSettings';     Set = 'Set-ScreenLockBaseline';     Restore = 'Restore-ScreenLockSettings' }
    AuditPolicy    = @{ Test = 'Test-AuditPolicyBaseline';    Backup = 'Backup-AuditPolicySettings';    Set = 'Set-AuditPolicyBaseline';    Restore = 'Restore-AuditPolicySettings' }
    RemoteAccess   = @{ Test = 'Test-RemoteAccessBaseline';   Backup = 'Backup-RemoteAccessSettings';   Set = 'Set-RemoteAccessBaseline';   Restore = 'Restore-RemoteAccessSettings' }
    BitLocker      = @{ Test = 'Test-BitLockerBaseline';      Backup = 'Backup-BitLockerSettings';      Set = 'Set-BitLockerBaseline';      Restore = 'Restore-BitLockerSettings' }
}

$script:SeceditModules = @('PasswordPolicy', 'AccountLockout')

function Invoke-AuditRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Modules,
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$RunTimestamp,
        [Parameter(Mandatory)][string]$LogPath
    )

    $config = Import-BaselineConfig -Path $ConfigPath

    $allResults = foreach ($moduleName in $Modules) {
        try {
            $testFunction = $script:ModuleFunctionMap[$moduleName].Test
            if ($moduleName -in $script:SeceditModules) {
                $workingCfg = Join-Path -Path $RootPath -ChildPath (Join-Path 'Logs' "$RunTimestamp-$moduleName-working.cfg")
                & $testFunction -Config $config[$moduleName] -WorkingCfgPath $workingCfg
            }
            else {
                & $testFunction -Config $config[$moduleName]
            }
        }
        catch {
            Write-BaselineLog -Message "Audit of module '$moduleName' failed: $($_.Exception.Message)" -Level 'Error' -LogPath $LogPath
            [PSCustomObject]@{ Module = $moduleName; Setting = 'ModuleError'; Expected = $null; Actual = $_.Exception.Message; Pass = $false; Description = 'This module raised an error during audit.' }
        }
    }

    $reportPath = Join-Path -Path $RootPath -ChildPath (Join-Path 'Reports' "$RunTimestamp-audit.json")
    $summary = New-BaselineAuditReport -Results $allResults -ReportPath $reportPath
    Write-BaselineAuditSummary -Results $allResults
    Write-BaselineLog -Message "Audit complete: $($summary.Passed)/$($summary.Total) settings passed. Report: $reportPath" -LogPath $LogPath

    return $allResults
}

function Invoke-ApplyRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Modules,
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$RunTimestamp,
        [Parameter(Mandatory)][string]$LogPath
    )

    $config = Import-BaselineConfig -Path $ConfigPath
    $osInfo = Get-WindowsEditionInfo
    $appliedModules = @()

    $allChanges = foreach ($moduleName in $Modules) {
        try {
            $backupPath = New-BaselineBackupFolder -RootPath $RootPath -Timestamp $RunTimestamp -Area $moduleName
            & $script:ModuleFunctionMap[$moduleName].Backup -BackupPath $backupPath | Out-Null

            $setFunction = $script:ModuleFunctionMap[$moduleName].Set
            $changes = if ($moduleName -in $script:SeceditModules) {
                $workingCfg = Join-Path -Path $RootPath -ChildPath (Join-Path 'Logs' "$RunTimestamp-$moduleName-working.cfg")
                & $setFunction -Config $config[$moduleName] -WorkingCfgPath $workingCfg
            }
            else {
                & $setFunction -Config $config[$moduleName]
            }

            $appliedModules += $moduleName
            foreach ($change in $changes) {
                Write-BaselineLog -Message "[$moduleName] $($change.Setting): $($change.Before) -> $($change.After) (Changed=$($change.Changed))" -LogPath $LogPath
            }
            $changes
        }
        catch {
            Write-BaselineLog -Message "Apply of module '$moduleName' failed, skipping: $($_.Exception.Message)" -Level 'Error' -LogPath $LogPath
        }
    }

    if (@($appliedModules).Count -gt 0) {
        Write-BaselineManifest -RootPath $RootPath -Timestamp $RunTimestamp -Mode 'Apply' -Modules @($appliedModules) -OSBuild $osInfo.Build | Out-Null
    }

    $backupRoot = Join-Path -Path $RootPath -ChildPath (Join-Path 'Backups' $RunTimestamp)
    if (@($allChanges).Count -gt 0) {
        Write-BaselineApplySummary -ChangeRecords @($allChanges) -BackupPath $backupRoot -LogPath $LogPath
    }

    return @($allChanges)
}

function Invoke-RestoreRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Modules,
        [Parameter(Mandatory)][string]$RootPath,
        [string]$SnapshotTimestamp,
        [switch]$Latest,
        [Parameter(Mandatory)][string]$LogPath,
        [switch]$DecryptOnRestore
    )

    $snapshotRoot = Resolve-BaselineSnapshotPath -RootPath $RootPath -Timestamp $SnapshotTimestamp -Latest:$Latest

    $results = foreach ($moduleName in $Modules) {
        $backupPath = Join-Path -Path $snapshotRoot -ChildPath $moduleName

        if (-not (Test-Path -Path $backupPath)) {
            Write-BaselineLog -Message "No backup for module '$moduleName' in snapshot '$snapshotRoot', skipping." -Level 'Warn' -LogPath $LogPath
            continue
        }

        try {
            $restoreFunction = $script:ModuleFunctionMap[$moduleName].Restore

            if ($moduleName -eq 'BitLocker') {
                & $restoreFunction -BackupPath $backupPath -DecryptOnRestore:$DecryptOnRestore
            }
            else {
                & $restoreFunction -BackupPath $backupPath | Out-Null
                Write-BaselineLog -Message "Restored module '$moduleName' from '$backupPath'." -LogPath $LogPath
                [PSCustomObject]@{ Module = $moduleName; Restored = $true }
            }
        }
        catch {
            Write-BaselineLog -Message "Restore of module '$moduleName' failed: $($_.Exception.Message)" -Level 'Error' -LogPath $LogPath
            [PSCustomObject]@{ Module = $moduleName; Restored = $false; Error = $_.Exception.Message }
        }
    }

    return @($results)
}

function Invoke-BaselineRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Audit', 'Apply', 'Restore')][string]$Mode,
        [string[]]$Modules = $script:AllModules,
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$RunTimestamp,
        [string]$SnapshotTimestamp,
        [switch]$Latest,
        [switch]$DecryptOnRestore
    )

    if (-not (Test-BaselineElevation)) {
        throw 'This script must be run from an elevated (Administrator) PowerShell session.'
    }

    $unknown = @($Modules | Where-Object { $_ -notin $script:AllModules })
    if ($unknown.Count -gt 0) {
        throw "Unknown module(s): $($unknown -join ', '). Valid modules are: $($script:AllModules -join ', ')"
    }

    $logPath = Join-Path -Path $RootPath -ChildPath (Join-Path 'Logs' "$RunTimestamp.log")
    Write-BaselineLog -Message "Starting $Mode run for modules: $($Modules -join ', ')" -LogPath $logPath

    switch ($Mode) {
        'Audit'   { return Invoke-AuditRun -Modules $Modules -RootPath $RootPath -ConfigPath $ConfigPath -RunTimestamp $RunTimestamp -LogPath $logPath }
        'Apply'   { return Invoke-ApplyRun -Modules $Modules -RootPath $RootPath -ConfigPath $ConfigPath -RunTimestamp $RunTimestamp -LogPath $logPath }
        'Restore' { return Invoke-RestoreRun -Modules $Modules -RootPath $RootPath -SnapshotTimestamp $SnapshotTimestamp -Latest:$Latest -LogPath $logPath -DecryptOnRestore:$DecryptOnRestore }
    }
}

Export-ModuleMember -Function Invoke-BaselineRun
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path Tests/Common/Orchestrator.Tests.ps1 -Output Detailed"`
Expected: PASS — 9 tests, 0 failed.

- [ ] **Step 5: Commit**

```bash
git add Common/Orchestrator.psm1 Tests/Common/Orchestrator.Tests.ps1
git commit -m "Add orchestrator tying elevation, config, backup, modules, and reporting together"
```

---

## Task 16: Invoke-SecurityBaseline.ps1 — CLI entry point, plus full test suite run and manual validation checklist

**Files:**
- Create: `Invoke-SecurityBaseline.ps1`
- Create: `docs/MANUAL-VALIDATION.md`

**Interfaces:**
- Consumes: `Invoke-BaselineRun` (Task 15) and every `Common/*.psm1` / `Modules/*.psm1` file (Tasks 1–15), imported by path.
- Produces: the CLI documented in the design spec §5. Nothing later consumes this — it is the toolkit's entry point.

This is the one task in the plan without a red/green Pester cycle: the script's only job is parameter parsing and module imports, and its actual behavior (registry writes, secedit calls, BitLocker encryption, etc.) can only be verified end-to-end on a real Windows 11 machine, which this dev environment does not have. Steps below are therefore: write the script, run the full existing test suite to confirm nothing already built is broken, then write a concrete manual validation checklist to run once on real Windows 11 Home and Pro/Enterprise machines before considering the toolkit done.

- [ ] **Step 1: Write the entry point script**

```powershell
# Invoke-SecurityBaseline.ps1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Audit', 'Apply', 'Restore')][string]$Mode,

    [ValidateSet('PasswordPolicy', 'AccountLockout', 'Defender', 'Firewall', 'ScreenLock', 'AuditPolicy', 'RemoteAccess', 'BitLocker')]
    [string[]]$Modules = @('PasswordPolicy', 'AccountLockout', 'Defender', 'Firewall', 'ScreenLock', 'AuditPolicy', 'RemoteAccess', 'BitLocker'),

    [string]$RootPath = 'C:\ProgramData\SecurityBaseline',
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'Config\Baseline.config.psd1'),

    [string]$Timestamp,
    [switch]$Latest,
    [switch]$DecryptOnRestore
)

$moduleFiles = @(
    'Common\Logging.psm1'
    'Common\SystemInfo.psm1'
    'Common\Config.psm1'
    'Common\BackupRestore.psm1'
    'Common\Reporting.psm1'
    'Common\SecEdit.psm1'
    'Common\Orchestrator.psm1'
    'Modules\PasswordPolicy.psm1'
    'Modules\AccountLockout.psm1'
    'Modules\Defender.psm1'
    'Modules\Firewall.psm1'
    'Modules\ScreenLock.psm1'
    'Modules\AuditPolicy.psm1'
    'Modules\RemoteAccess.psm1'
    'Modules\BitLocker.psm1'
)

foreach ($file in $moduleFiles) {
    Import-Module (Join-Path $PSScriptRoot $file) -Force -Global
}

if ($Mode -eq 'Restore' -and -not $Latest -and -not $Timestamp) {
    throw 'Restore mode requires either -Timestamp <snapshot> or -Latest.'
}

$runTimestamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'

Invoke-BaselineRun -Mode $Mode -Modules $Modules -RootPath $RootPath -ConfigPath $ConfigPath `
    -RunTimestamp $runTimestamp -SnapshotTimestamp $Timestamp -Latest:$Latest -DecryptOnRestore:$DecryptOnRestore
```

- [ ] **Step 2: Run the full test suite to confirm nothing regressed**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path Tests -Output Detailed"`
Expected: PASS — every test from Tasks 1–15 (70+ tests total), 0 failed. This does not exercise `Invoke-SecurityBaseline.ps1` itself (no Pester tests target it directly, per the rationale above), only confirms the modules it wires together still work.

- [ ] **Step 3: Write the manual validation checklist**

```markdown
# Manual Validation — Windows 11 Security Baseline

Run once on a real Windows 11 **Home** VM/device and once on **Pro or Enterprise**
before considering this toolkit production-ready. The automated Pester suite (`Tests/`)
mocks every OS interaction because it runs on non-Windows dev hardware — this checklist
is what actually exercises secedit, auditpol, the registry, Defender, the firewall, and
BitLocker for real.

## Setup

1. Copy the repository to the test machine.
2. Open an elevated (Run as Administrator) Windows PowerShell 5.1 window — not pwsh —
   to match the real deployment target.
3. `cd` into the repository root.

## Audit mode (no changes expected)

- [ ] `.\Invoke-SecurityBaseline.ps1 -Mode Audit` completes without throwing.
- [ ] Console prints a `Module/Setting/Expected/Actual/Pass` table and a pass/fail count.
- [ ] `C:\ProgramData\SecurityBaseline\Reports\<timestamp>-audit.json` exists and is valid JSON.
- [ ] `C:\ProgramData\SecurityBaseline\Logs\<timestamp>.log` exists and has one line per check.
- [ ] Re-running elevation check: run the same command from a **non-elevated** prompt —
      it must throw immediately with a clear "must be run from an elevated" message.
- [ ] Run `Set-StrictMode -Version Latest` in the elevated Windows PowerShell 5.1
      session, then `Import-Module .\Common\SystemInfo.psm1 -Force; Test-BaselineElevation`
      — it must return `$true`/`$false` without throwing a
      "variable '$IsWindows' cannot be retrieved" error (this is the scenario the
      `$PSVersionTable.PSVersion.Major -ge 6 -and $IsWindows -eq $false` guard in
      Task 2 exists to prevent, and it cannot be exercised on non-Windows dev hardware).

## Apply mode

- [ ] `.\Invoke-SecurityBaseline.ps1 -Mode Apply` completes; note the printed backup path.
- [ ] `secpol.msc` (Pro/Enterprise) or `net accounts` (Home) shows the new minimum
      password length (14) and lockout threshold (5).
- [ ] `Get-MpPreference` shows `DisableRealtimeMonitoring = $false` and
      `MAPSReporting = 2`.
- [ ] `Get-NetFirewallProfile` shows all three profiles `Enabled = True`,
      `DefaultInboundAction = Block`.
- [ ] Locking the screen manually and waiting confirms the machine auto-locks at the
      configured idle timeout (15 minutes by default — safe to temporarily lower
      `InactivityTimeoutSeconds` in `Config\Baseline.config.psd1` to 60 for this check).
- [ ] `auditpol /get /category:*` shows the configured subcategories set to the
      expected success/failure outcomes.
- [ ] RDP: attempting to enable Remote Desktop via Settings shows it blocked/greyed or
      reverts — `fDenyTSConnections` is `1`.
- [ ] `Get-SmbServerConfiguration | Select EnableSMB1Protocol` is `False`.
- [ ] `Get-LocalUser -Name Guest` shows `Enabled = False`.
- [ ] BitLocker: `Get-BitLockerVolume` shows `ProtectionStatus = On` for the OS drive
      (Pro/Enterprise) **or** the audit report notes it as unavailable rather than
      crashing (Home, if Device Encryption prerequisites like a TPM aren't present in
      the test VM). A recovery key `.txt` file exists under
      `C:\ProgramData\SecurityBaseline\RecoveryKeys\`.
- [ ] Re-run `.\Invoke-SecurityBaseline.ps1 -Mode Apply` immediately again — the log
      for the second run shows `Changed=False` for every setting (idempotency).

## Restore mode

- [ ] `.\Invoke-SecurityBaseline.ps1 -Mode Restore -Latest` completes without throwing.
- [ ] Password policy, lockout policy, Defender preferences, firewall profiles, screen
      lock timeout, audit policy, RDP/SMBv1/Guest settings all revert to their
      pre-`Apply` values (spot-check at least 3 of these against the values noted
      before running Apply).
- [ ] BitLocker is **not** touched (still `On` if Apply turned it on) — confirms the
      default-skip behavior.
- [ ] `.\Invoke-SecurityBaseline.ps1 -Mode Restore -Latest -DecryptOnRestore` on a
      fresh Apply run does trigger `Disable-BitLocker` (only run this one on a
      disposable test VM — decryption takes time and you don't want it on a real
      device by accident).

## Sign-off

- [ ] Both Home and Pro/Enterprise runs completed with no unexpected exceptions.
- [ ] Any deviations from the checklist are written up in this file (append a "Findings"
      section) before merging.
```

- [ ] **Step 4: Confirm the full suite still passes after adding the entry point**

Run: `pwsh -NoProfile -Command "Invoke-Pester -Path Tests -Output Detailed"`
Expected: PASS — same count as Step 2 (the entry point script has no Pester tests of its own, so the count is unchanged).

- [ ] **Step 5: Commit**

```bash
git add Invoke-SecurityBaseline.ps1 docs/MANUAL-VALIDATION.md
git commit -m "Add CLI entry point and manual validation checklist for real Windows hardware"
```

---

## Post-plan reminder

Task 16's manual validation checklist is not optional polish — every module in this
plan was written and tested entirely on non-Windows dev hardware with every OS
interaction mocked. Nothing in Tasks 1–15 proves `secedit.exe`'s actual INF syntax
round-trips correctly, that `auditpol`'s CSV output columns are named exactly
`Inclusion Setting`, or that `Enable-BitLocker` behaves as expected on a Home SKU.
Do not consider this toolkit safe to run against a real environment until Task 16's
checklist has been completed at least once on both a Windows 11 Home and a
Windows 11 Pro/Enterprise machine.
