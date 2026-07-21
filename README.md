# SecurityBaseline

A PowerShell toolkit that hardens standalone/workgroup Windows 11 devices (Home,
Pro, and Enterprise) toward HIPAA Security Rule technical safeguards, with
Audit / Apply / Restore modes and automatic backup before every change.

## Status

Built and tested on non-Windows dev hardware — every OS interaction (registry,
`secedit.exe`, `auditpol.exe`, `netsh.exe`, `reg.exe`, Defender/NetSecurity/
BitLocker/LocalAccounts cmdlets) is mocked in the test suite, since none of
those APIs exist outside Windows. **This has not yet been run against a real
Windows machine.** Before using it on anything real, run through
[`docs/MANUAL-VALIDATION.md`](docs/MANUAL-VALIDATION.md) on both a Windows 11
Home and a Windows 11 Pro/Enterprise device.

## What it covers

| Area | Mechanism |
|---|---|
| Password policy | `secedit.exe` (works on Home, not just Pro/Enterprise) |
| Account lockout | `secedit.exe` |
| Windows Defender | `Set-MpPreference` / `Get-MpPreference` |
| Firewall | `NetSecurity` cmdlets + `netsh advfirewall` for backup/restore |
| Screen lock / idle timeout | Machine inactivity limit registry key |
| Audit logging | `auditpol.exe` (advanced audit policy subcategories) |
| Remote access | Disables RDP, SMBv1, and the built-in Guest account |
| BitLocker | `Enable-/Disable-BitLocker`, local recovery key file |

Every module exposes the same four-function contract: `Test-`, `Backup-`,
`Set-`, `Restore-<Area>Baseline`. See the [design spec](docs/superpowers/specs)
and [implementation plan](docs/superpowers/plans) for the full architecture.

## Requirements

- Windows 11 (Home, Pro, or Enterprise), standalone or workgroup — not
  designed for domain-joined machines with competing Group Policy.
- Windows PowerShell 5.1 (ships in-box) or PowerShell 7 — no extra modules to
  install.
- An elevated (Administrator) PowerShell session.

## Quick start

```powershell
# Report current compliance without changing anything
.\Invoke-SecurityBaseline.ps1 -Mode Audit

# Audit just a subset of modules
.\Invoke-SecurityBaseline.ps1 -Mode Audit -Modules Firewall,Defender

# Back up current settings, then enforce the baseline
.\Invoke-SecurityBaseline.ps1 -Mode Apply

# Revert the most recent Apply
.\Invoke-SecurityBaseline.ps1 -Mode Restore -Latest

# Revert a specific snapshot, including decrypting BitLocker if it was enabled
.\Invoke-SecurityBaseline.ps1 -Mode Restore -Timestamp "2026-07-21_143000" -DecryptOnRestore
```

Backups, logs, and audit reports are written under
`C:\ProgramData\SecurityBaseline` by default (override with `-RootPath`).

## Configuration

All baseline values — password length, lockout threshold, idle timeout, audit
subcategories, and so on — live in [`Config/Baseline.config.psd1`](Config/Baseline.config.psd1),
separate from the module code. Every setting carries a `Description`
explaining what it does and why the shipped default was chosen. **Review this
file for your own environment and risk tolerance before running `Apply`** —
the defaults are NIST-aligned starting points, not requirements handed down
by HIPAA itself.

One setting needs particular attention: `BitLocker.RecoveryKeyPath`. Since a
standalone device has no Active Directory or Entra ID to escrow the recovery
key to, it's written in plaintext to a local folder — move or secure that
file after `Apply` runs.

## Backup and restore

Every `Apply` run snapshots the current state of each module it touches
*before* changing anything, under `Backups\<timestamp>\<Module>\`. If backing
up a module fails, that module is skipped entirely for that run rather than
applied without a safety net. `Restore` reverts from a chosen snapshot;
BitLocker is excluded from restore by default (decryption is slow and
destructive) unless `-DecryptOnRestore` is passed explicitly.

## Running the tests

```powershell
Install-Module -Name Pester -Force -Scope CurrentUser -SkipPublisherCheck
Invoke-Pester -Path Tests -Output Detailed
```

## Repository layout

```
Invoke-SecurityBaseline.ps1   Entry point (parses CLI args, delegates to the orchestrator)
Common/                       Shared engine: logging, config, backup/restore, reporting, secedit helpers, orchestrator
Modules/                      One file per policy area, each with the Test-/Backup-/Set-/Restore- contract
Config/Baseline.config.psd1   Tunable baseline values, separate from code
Tests/                        Pester tests, mirroring the Common/ and Modules/ layout
docs/MANUAL-VALIDATION.md     Checklist to run on real Windows hardware before trusting this in production
docs/superpowers/             Design spec and implementation plan this toolkit was built from
```
