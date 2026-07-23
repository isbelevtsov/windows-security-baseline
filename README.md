# SecurityBaseline

A PowerShell toolkit that hardens standalone/workgroup Windows 11 devices (Home,
Pro, and Enterprise) toward HIPAA Security Rule technical safeguards, with
Audit / Apply / Restore modes and automatic backup before every change.

## Status

Originally built and tested only on non-Windows dev hardware, with every OS
interaction (registry, `secedit.exe`, `auditpol.exe`, `netsh.exe`, `reg.exe`,
Defender/NetSecurity/BitLocker/LocalAccounts cmdlets) mocked in the test
suite. Since then, `-Mode Audit`, `-Mode Apply`, and `-Mode Restore -Latest`
have each been run for real on a Windows Pro test VM (see
[`docs/MANUAL-VALIDATION.md`](docs/MANUAL-VALIDATION.md) Findings for the
bugs that surfaced and were fixed as a result). **Windows 11 Home has not yet
been validated**, and BitLocker activation timing on slow/virtual storage is
still an open question (see the Findings entries). Run through
`docs/MANUAL-VALIDATION.md` on a Home device, and on any device meaningfully
different from what's already covered, before relying on this in production.

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
| Local accounts | Disables autologon; forces accounts with blank passwords to require one and change it at next logon |

Every module exposes the same four-function contract: `Test-`, `Backup-`,
`Set-`, `Restore-<Area>Baseline`. See the [design spec](docs/superpowers/specs)
and [implementation plan](docs/superpowers/plans) for the full architecture.

## Requirements

- Windows 11 (Home, Pro, or Enterprise), standalone or workgroup — not
  designed for domain-joined machines with competing Group Policy.
- Windows PowerShell 5.1 (ships in-box) or PowerShell 7 — no extra modules to
  install.
- An elevated (Administrator) PowerShell session.

### Execution policy

**Recommended: run [`Setup.cmd`](Setup.cmd) once per machine/account.** It's
a single prerequisites entry point — double-click it, or run it from a
terminal — that unblocks every script (in case the repo was copied or
downloaded rather than `git clone`d, which makes Windows block files as
coming from another machine regardless of execution policy), sets a durable
`RemoteSigned` execution policy for your account, and code-signs the whole
repo with a self-signed certificate so it keeps running with no bypass after
this one-time step:

```cmd
Setup.cmd
```

Any arguments are passed straight through to
[`Tools\Setup-Prerequisites.ps1`](Tools/Setup-Prerequisites.ps1) /
[`Tools\Sign-Scripts.ps1`](Tools/Sign-Scripts.ps1), e.g.:

```cmd
Setup.cmd -Scope LocalMachine -Force
Setup.cmd -CertificateThumbprint A1B2C3D4E5F6...
```

**Read the warning it prints before confirming.** Adding a certificate to a
Trusted Root store isn't scoped to "PowerShell script signing" — that store
is consulted for all certificate validation in its scope (TLS, S/MIME, other
code signing). By default it scopes both the private key and the trust
grant to your account only (`-Scope CurrentUser`), so it only affects
certificate validation for the account that's actually going to run the
toolkit. Pass `-Scope LocalMachine` only if multiple accounts need to run
signed scripts — that extends the trust grant to every account on the
machine and requires an elevated session. If your organization already has
a code-signing certificate, pass its thumbprint with
`-CertificateThumbprint` instead of creating a self-signed one — this
avoids the self-signed root-trust tradeoff entirely, since a properly
issued certificate chains to a CA your machine already trusts.

Re-run `Setup.cmd` whenever a script file changes — editing a signed file
invalidates its signature.

<details>
<summary>Doing it manually, or just want a one-off session-scoped bypass instead</summary>

Unblock the files:

```powershell
Get-ChildItem -Path . -Recurse -Filter *.ps1  | Unblock-File
Get-ChildItem -Path . -Recurse -Filter *.psm1 | Unblock-File
```

If PowerShell still refuses to run the script (`... is not digitally signed
...`), scope the bypass to the current session only — don't change execution
policy machine-wide:

```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process
.\Invoke-SecurityBaseline.ps1 -Mode Audit
```

`-Scope Process` reverts automatically when that PowerShell window closes.
This is the quick, no-persistence path; `Setup.cmd` (or running
`Tools\Sign-Scripts.ps1` directly) is preferred for anything beyond a
one-off session, since it doesn't need repeating.

</details>

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
file after `Apply` runs. The same applies to `LocalAccounts.TemporaryPasswordPath`,
used when an account with a blank password gets a temporary one set. Whenever
`Apply` generates either of these, the value is also printed to the console
in a highlighted `SAVE THESE NOW` block, in addition to being written to its
file — easy to miss otherwise among everything else `Apply` prints.

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
