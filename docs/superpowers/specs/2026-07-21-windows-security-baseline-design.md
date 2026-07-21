# Windows 11 Security Baseline — Design Spec

**Date:** 2026-07-21
**Status:** Approved (pending implementation)

## 1. Overview & Goals

A PowerShell toolkit (`SecurityBaseline`) that hardens standalone/workgroup Windows 11
devices (both Home and Pro/Enterprise editions) against HIPAA Security Rule technical
safeguards. Three operating modes:

- **Audit** — checks current state vs. the configured baseline, produces a pass/fail
  report, changes nothing.
- **Apply** — snapshots current settings (backup), then enforces the baseline.
- **Restore** — reverts a prior `Apply` from a chosen snapshot.

### In scope

- Password policy
- Account lockout policy
- Windows Defender (built-in antivirus) policy
- Windows Firewall policy
- Screen lock / idle timeout policy
- BitLocker / Device Encryption
- Audit logging policy
- Remote access hardening (RDP, SMBv1, Guest account)

### Constraints

- Target machines are **standalone/workgroup** — not domain-joined, no Intune/GPO
  management. These scripts are the sole policy enforcement mechanism.
- Must work on **both Windows 11 Home and Pro/Enterprise**. `gpedit.msc`-dependent
  configuration is avoided; all modules use tools that ship on every SKU
  (`secedit.exe`, `auditpol.exe`, PowerShell cmdlets, registry).
- Requires Administrator elevation.

## 2. Architecture & File Layout

```
SecurityBaseline\
  Invoke-SecurityBaseline.ps1        # orchestrator (entry point)
  Config\
    Baseline.config.psd1             # all tunable baseline values (see §8)
  Modules\
    PasswordPolicy.psm1
    AccountLockout.psm1
    Defender.psm1
    Firewall.psm1
    ScreenLock.psm1
    BitLocker.psm1
    AuditPolicy.psm1
    RemoteAccess.psm1
  Common\
    BackupRestore.psm1                # shared snapshot/restore engine
    Reporting.psm1                    # shared audit report + logging

C:\ProgramData\SecurityBaseline\
  Backups\<timestamp>\...             # per-run snapshots
  Logs\<timestamp>.log
  Reports\<timestamp>-audit.json
```

Each module exports a consistent function contract:

- `Test-<Area>Baseline` — audit: compares live system state to config, returns
  pass/fail per setting.
- `Backup-<Area>Settings` — captures current state before changes.
- `Set-<Area>Baseline` — apply: enforces config values (idempotent — a second run
  produces no changes).
- `Restore-<Area>Settings` — reverts from a given backup snapshot.

Modules never call each other. The orchestrator is the only thing that sequences them,
which keeps each module independently testable and independently selectable via
`-Modules`.

## 3. Module Implementation Approach

| Module | Mechanism | Notes |
|---|---|---|
| **PasswordPolicy** | `secedit /export` + INF template + `secedit /configure` | `secedit.exe` ships on all editions (only the GPO Editor GUI is Pro+); lets min length, complexity, history, max/min age work on Home too |
| **AccountLockout** | Same secedit INF (shares the local security policy store with PasswordPolicy) | Threshold, duration, observation window |
| **Defender** | `Set-MpPreference` / `Get-MpComputerStatus` | Real-time protection, cloud-delivered protection, PUA protection, scheduled scan |
| **Firewall** | `Set-NetFirewallProfile` / `Get-NetFirewallProfile` | All 3 profiles (Domain/Private/Public): enabled, default-block inbound, logging on |
| **ScreenLock** | `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\InactivityTimeoutSecs` | "Machine inactivity limit" — locks the session after idle regardless of screensaver choice; edition-agnostic and machine-wide (unlike per-user screensaver registry keys) |
| **BitLocker** | `Enable-BitLocker` attempted uniformly on both editions | The cmdlet only fails at runtime if truly unlicensed on the SKU, so no special-casing by edition; falls back to reporting whichever of BitLocker/Device Encryption is actually active if enabling fails |
| **AuditPolicy** | `auditpol.exe` | Ships on all editions; sets advanced audit subcategories (logon, account mgmt, object access, policy change, privilege use, etc.) |
| **RemoteAccess** | Registry (`fDenyTSConnections`) + `Set-SmbServerConfiguration` + `net user guest` | Disables RDP entirely by default, disables SMBv1, disables Guest account |

### BitLocker specifics

- `Enable-BitLocker` is attempted on the OS drive regardless of edition (Home vs
  Pro/Enterprise), since the cmdlet only errors at runtime if the SKU truly lacks
  licensing — there's no reliable way to predict this from edition alone.
- No AD/Entra join means no cloud/domain escrow target for the recovery key. The
  recovery key is saved to a local file under
  `C:\ProgramData\SecurityBaseline\RecoveryKeys\` — securing that path (e.g. moving
  the key off-box) is a manual follow-up outside this toolkit's scope.
- Audit mode reports whichever protection is actually active (full BitLocker or
  Device Encryption) rather than requiring one specific mechanism.

### RemoteAccess specifics

- Default posture is **disable RDP entirely** (`fDenyTSConnections = 1`) — smallest
  attack surface for workstations that don't need inbound remote administration.
  Devices that need RDP can exclude the module via `-Modules` (excluding
  `RemoteAccess`, or a future finer-grained sub-toggle if needed later).

## 4. Backup/Restore Engine

Each module's `Backup-<Area>Settings` writes to `Backups\<timestamp>\<Area>\`:

- **Registry-based settings** (ScreenLock, RemoteAccess) → `.reg` exports of the exact
  keys touched.
- **secedit-based settings** (PasswordPolicy, AccountLockout, AuditPolicy) →
  `secedit /export` of the full local security policy `.cfg` — one file covers all
  three since they share the same store.
- **Firewall** → `netsh advfirewall export` (native full-profile backup/restore).
- **Defender** → `Get-MpPreference | ConvertTo-Json` (no native export/import, so JSON
  capture + `Set-MpPreference` replay on restore).
- **BitLocker** → status snapshot only (JSON: was it on/off, method).

A `manifest.json` in each timestamp folder records which modules ran, mode,
timestamp, and OS build. `Invoke-SecurityBaseline.ps1 -Mode Restore` lists available
snapshots and lets you pick one (`-Timestamp "..."` or `-Latest`).

### BitLocker restore behavior

Decrypting a drive is slow and destructive, so it is **not** part of the default
restore path. Passing `-DecryptOnRestore` explicitly opts BitLocker into the restore
(reverting encryption state along with everything else); omitting it leaves BitLocker
untouched during `Restore` regardless of what other modules revert.

## 5. CLI Interface

```powershell
.\Invoke-SecurityBaseline.ps1 -Mode Audit
.\Invoke-SecurityBaseline.ps1 -Mode Audit -Modules Firewall,Defender
.\Invoke-SecurityBaseline.ps1 -Mode Apply
.\Invoke-SecurityBaseline.ps1 -Mode Apply -Modules PasswordPolicy,AccountLockout
.\Invoke-SecurityBaseline.ps1 -Mode Restore -Latest
.\Invoke-SecurityBaseline.ps1 -Mode Restore -Timestamp "2026-07-21_143000" -DecryptOnRestore
```

- `-Mode` (required): `Audit` | `Apply` | `Restore`
- `-Modules` (optional): defaults to all 8 modules
- `-Latest` / `-Timestamp`: select a snapshot for `Restore`
- `-DecryptOnRestore`: opt BitLocker into `Restore` (see §4)

Startup checks (before anything else runs):

1. Administrator elevation — exit with a clear error if not elevated.
2. Windows edition detection (Home vs Pro/Enterprise) — logged, and used by modules
   that branch on edition (currently: none strictly require it, since BitLocker's
   tiered attempt is edition-agnostic by design; retained as diagnostic context in
   logs).

## 6. Logging & Reporting

- Every run writes a timestamped transcript to `Logs\<timestamp>.log`: start/end time,
  mode, modules run, each setting changed with before→after values, and any errors.
- `Audit` mode additionally writes `Reports\<timestamp>-audit.json` — machine-readable
  (setting name, expected value, actual value, pass/fail per module) — intended to
  double as retainable HIPAA audit evidence — plus a human-readable console summary
  table.
- `Apply` mode's console output is a summary: modules applied, count of settings
  changed, backup location, and a reminder of the restore command.

## 7. Safety & Error Handling

- Each module wraps its own changes in try/catch. A failure in one module logs the
  error and the orchestrator continues to the next module rather than aborting the
  whole run (e.g. a BitLocker failure doesn't block firewall hardening).
- Before `Apply` touches a module's settings, that module's backup must succeed, or
  the module is skipped entirely — changes are never applied without a corresponding
  backup existing.
- Idempotent by design: running `Apply` twice in a row should produce no additional
  changes on the second run (each module's `Set-` function checks current state
  before writing).

## 8. Config File

All tunable baseline values live in `Config\Baseline.config.psd1`, separate from the
module logic, so the actual policy thresholds can be reviewed/tuned without touching
code. Since these numbers are policy judgment calls rather than fixed HIPAA
requirements, each value carries an inline `Description` explaining what it does and
why the shipped default was chosen, so the file is reviewable without needing to read
the module code:

```powershell
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
                'Logon/Logoff'       = 'SuccessAndFailure'
                'Account Management' = 'SuccessAndFailure'
                'Object Access'      = 'Failure'
                'Policy Change'      = 'SuccessAndFailure'
                'Privilege Use'      = 'Failure'
            }
            Description = "Advanced audit policy subcategories and what outcomes to log for each, supporting HIPAA's audit control requirement."
        }
    }
    Defender = @{
        RealTimeProtection = @{
            Value       = $true
            Description = "Keeps Defender's real-time scanning engine active."
        }
        CloudProtection = @{
            Value       = $true
            Description = "Enables cloud-delivered protection for faster response to new threats."
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
            Description = "Disables inbound Remote Desktop entirely. Set to $false if this device needs RDP for support access, or exclude the RemoteAccess module via -Modules."
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

The orchestrator loads this via `Import-PowerShellDataFile`, validates required keys
are present, and passes each module its relevant sub-hashtable (unwrapping `.Value`
for use, while `.Description` is also surfaced in audit reports next to each setting
so reports are self-explanatory).

**Before running `Apply` for real**, review and adjust these defaults for your actual
environment and risk tolerance — they are NIST-aligned starting points, not
requirements handed down by HIPAA itself.

## 9. Testing Approach

- Each module's `Test-<Area>Baseline` function doubles as its own verification: after
  `Set-<Area>Baseline` runs, immediately re-run `Test-<Area>Baseline` and confirm all
  checks pass — this is the primary correctness signal for Apply, run automatically
  at the end of each module's Apply path.
- Manual validation on a real (or VM) Windows 11 Home and a Windows 11 Pro machine
  before considering the toolkit done, since edition differences (particularly
  BitLocker) can't be fully verified by static review.
- Idempotency check: run `Apply` twice back-to-back and confirm the second run's log
  shows zero changes.
- Restore check: `Apply`, verify settings changed, `Restore -Latest`, verify settings
  return to their original values.
