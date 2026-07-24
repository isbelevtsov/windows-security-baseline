# SecurityBaseline

A PowerShell toolkit that hardens standalone/workgroup Windows 11 devices (Home,
Pro, and Enterprise) toward HIPAA Security Rule technical safeguards, with
Audit / Apply / Restore modes and automatic backup before every change.

## Status

Originally built and tested only on non-Windows dev hardware, with every OS
interaction (registry, `secedit.exe`, `auditpol.exe`, `netsh.exe`, `reg.exe`,
Defender/NetSecurity/BitLocker/LocalAccounts cmdlets) mocked in the test
suite. Since then, `-Mode Audit`, `-Mode Apply`, and `-Mode Restore -Latest`
have each been run for real on both a Windows Pro test VM and a Windows Home
test VM (see [`docs/MANUAL-VALIDATION.md`](docs/MANUAL-VALIDATION.md)
Findings for the bugs that surfaced and were fixed as a result), including
BitLocker reaching `ProtectionStatus = On` and staying there across repeated
idempotent Apply runs on Pro, and BitLocker's absence on Home being reported
as a graceful non-compliant Note rather than a crash. Run through
`docs/MANUAL-VALIDATION.md` on any device meaningfully different from what's
already covered (e.g. Enterprise, a domain-joined machine, or real - not
virtual - hardware) before relying on this in production.

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
| Windows Update | `wuauserv` service start type + registry policy (automatic updates, deferral) |
| PowerShell logging | Script block / module / transcription logging registry policy |
| Removable storage | Registry policy denying write access to removable disks (read stays allowed) |
| UAC | Registry policy (UAC enabled, consent prompt behavior, secure desktop) |
| Network hardening | NTLM compatibility level (`LmCompatibilityLevel`), LLMNR disabled |
| Event log retention | `wevtutil.exe` maximum size for Application/Security/System logs |

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

| Module | Key | Default | Description |
|---|---|---|---|
| PasswordPolicy | `MinimumPasswordLength` | `14` | Minimum characters required. HIPAA doesn't mandate a specific number; NIST SP 800-63B recommends 14+ over relying on complexity rules. |
| PasswordPolicy | `PasswordComplexity` | `$true` | Requires a mix of character classes (upper/lower/digit/symbol) when set. |
| PasswordPolicy | `PasswordHistorySize` | `24` | Number of previous passwords remembered to prevent reuse. |
| PasswordPolicy | `MaximumPasswordAgeDays` | `90` | Days before a password must be changed. Set to 0 to disable expiry (NIST 800-63B now discourages forced periodic rotation, but many HIPAA auditors still expect it). |
| PasswordPolicy | `MinimumPasswordAgeDays` | `1` | Minimum days before a password can be changed again, preventing rapid cycling back to an old password. |
| AccountLockout | `LockoutThreshold` | `5` | Failed logon attempts allowed before the account locks. |
| AccountLockout | `LockoutDurationMinutes` | `15` | How long a locked account stays locked before auto-unlocking. |
| AccountLockout | `ObservationWindowMinutes` | `15` | Time window during which failed attempts count toward the lockout threshold. |
| ScreenLock | `InactivityTimeoutSeconds` | `900` | Idle seconds before the machine locks (900 = 15 minutes). This is the 'machine inactivity limit,' independent of screensaver settings. |
| AuditPolicy | `Categories` | `Logon=SuccessAndFailure`, `Logoff=Success`, `Account Lockout=SuccessAndFailure`, `User Account Management=SuccessAndFailure`, `Security Group Management=SuccessAndFailure`, `Removable Storage=Failure`, `Audit Policy Change=SuccessAndFailure`, `Sensitive Privilege Use=Failure` | Advanced audit policy subcategories (exact `auditpol.exe /subcategory:` names) and what outcomes to log for each, supporting HIPAA's audit control requirement. |
| Defender | `RealTimeProtection` | `$true` | Keeps Defender's real-time scanning engine active. |
| Defender | `CloudProtection` | `$true` | Enables cloud-delivered protection (MAPS) for faster response to new threats. |
| Defender | `PUAProtection` | `'Enabled'` | Blocks potentially unwanted applications (adware, bundled software). |
| Firewall | `EnabledProfiles` | `@('Domain','Private','Public')` | Firewall profiles that must be turned on. |
| Firewall | `DefaultInboundAction` | `'Block'` | Default action for inbound connections with no matching allow rule. |
| Firewall | `LoggingEnabled` | `$true` | Enables firewall connection logging for audit/troubleshooting. |
| RemoteAccess | `DisableRDP` | `$true` | Disables inbound Remote Desktop entirely. Set to `$false` if this device needs RDP for support access, or exclude the RemoteAccess module via `-Modules`. |
| RemoteAccess | `DisableSMBv1` | `$true` | Disables the legacy SMBv1 protocol, which has no meaningful modern use case and a history of critical vulnerabilities (e.g. EternalBlue). |
| RemoteAccess | `DisableGuestAccount` | `$true` | Disables the built-in Guest account to prevent unauthenticated/low-friction local access. |
| BitLocker | `EncryptionMethod` | `'XtsAes256'` | Encryption algorithm used for the OS drive. |
| BitLocker | `RecoveryKeyPath` | `'C:\ProgramData\SecurityBaseline\RecoveryKeys'` | Local folder where the BitLocker recovery key is saved, since standalone/workgroup devices have no AD/Entra to escrow it to. Secure or relocate this folder's contents as a manual follow-up. |
| LocalAccounts | `DisableAutoLogon` | `$true` | Disables Windows automatic sign-in (AutoAdminLogon). Autologon stores the account's password in plaintext in the registry (`Winlogon\DefaultPassword`) and skips the logon prompt/screen lock entirely, both of which defeat the other controls in this baseline. |
| LocalAccounts | `RequirePasswordForAllAccounts` | `$true` | Ensures every enabled local account requires a password, rejecting the 'password not required' flag that allows a blank password. A random, policy-compliant temporary password is set immediately on any account that fails this, and the account is forced to change it at next logon. |
| LocalAccounts | `TemporaryPasswordPath` | `'C:\ProgramData\SecurityBaseline\TemporaryPasswords'` | Local folder where a generated temporary password is saved in plaintext when `RequirePasswordForAllAccounts` remediates a blank-password account, since the account holder needs it to log on once before setting their own. Secure, relocate, or delete each file after that happens. |
| LocalAccounts | `DisablePasswordNeverExpires` | `$true` | Clears the 'Password never expires' flag on every enabled local account, since it silently defeats any forced 'must change password at next logon' action on that same account. |
| WindowsUpdate | `AutomaticUpdatesEnabled` | `$true` | Ensures automatic updates aren't disabled via policy (`NoAutoUpdate=0`). An unpatched machine undermines every other control in this baseline. |
| WindowsUpdate | `DeferQualityUpdatesDays` | `0` | Maximum days security/quality updates may be deferred (`DeferQualityUpdatesPeriodInDays`). 0 means install as soon as available. |
| PowerShellLogging | `EnableScriptBlockLogging` | `$true` | Logs the full text of executed PowerShell script blocks (including deobfuscated content) to the PowerShell/Operational event log. |
| PowerShellLogging | `EnableModuleLogging` | `$true` | Logs pipeline execution details for PowerShell modules/snap-ins to the event log, scoped to all modules. |
| PowerShellLogging | `EnableTranscription` | `$true` | Writes a transcript of every PowerShell session (commands and output) to `TranscriptOutputPath`, independent of and complementary to script block logging. |
| PowerShellLogging | `TranscriptOutputPath` | `'C:\ProgramData\SecurityBaseline\PowerShellTranscripts'` | Local folder where PowerShell session transcripts are written when `EnableTranscription` is on. |
| RemovableStorage | `DenyWriteAccess` | `$true` | Blocks write access to removable disks (USB mass storage) system-wide, reducing the most common PHI exfiltration path on a standalone device with no DLP tooling, while leaving read access available. |
| UAC | `EnableLUA` | `$true` | Keeps User Account Control itself turned on. Disabling this entirely removes UAC's split-token/elevation model. |
| UAC | `ConsentPromptBehaviorAdmin` | `2` | Requires administrators to consent to elevation on the secure desktop (2 = 'Prompt for consent on the secure desktop') rather than silently elevating (0) or prompting on the regular, spoofable desktop. |
| UAC | `PromptOnSecureDesktop` | `$true` | Ensures the UAC consent/credential prompt itself renders on the secure desktop, where other processes can't inject input or overlay a fake prompt. |
| NetworkHardening | `LmCompatibilityLevel` | `5` | Minimum acceptable LmCompatibilityLevel (0-5 scale; 5 = 'Send NTLMv2 response only, refuse LM and NTLM'). Rejects the legacy LM and NTLMv1 authentication protocols while still allowing NTLMv2. |
| NetworkHardening | `DisableLLMNR` | `$true` | Disables Link-Local Multicast Name Resolution (LLMNR), which is spoofable by anyone else on the network (LLMNR/NBT-NS poisoning) to harvest NTLM hashes. |
| EventLogRetention | `MinimumMaxSizeBytes` | `104857600` | Minimum maximum-size (100 MB) for the Application, Security, and System event logs. Windows' small default sizes (as low as 20 MB for Security) can roll over and silently discard audit history within hours on an active machine. |

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
