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
      **If the log still shows a Warn "Post-apply verification failed" for
      `OSDriveEncrypted`** after the TPM-protector fix (see Findings below),
      **restart the machine** and re-run `-Mode Audit -Modules BitLocker` — BitLocker
      on the OS drive is known to sometimes require a reboot to fully activate
      protection even with a proper protector configured, and this hasn't yet been
      confirmed one way or the other on real hardware.
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

## Findings

### 2026-07-23 — Windows 11 Pro, `-Mode Apply`

Two real bugs found, invisible to the mocked test suite, both fixed:

- **Firewall module crashed entirely.** `Set-NetFirewallProfile`'s
  `-Enabled`/`-LogAllowed`/`-LogBlocked` parameters are typed as
  `Microsoft.PowerShell.Cmdletization.GeneratedTypes.NetSecurity.GpoBoolean`, not a
  native `[bool]` — PowerShell can't auto-cast `$true`/`$false` to it, only the
  literal strings `'True'`/`'False'`. Fixed in `Modules/Firewall.psm1`; regression
  test added asserting the values passed to the cmdlet wrapper are strings, not
  booleans.
- **BitLocker apply reported `Changed=True` but post-apply verification found
  `ProtectionStatus` still `Off`.** `Enable-OsDriveBitLocker` was only adding a
  `-RecoveryPasswordProtector` — meant as a backup protector, not a primary one.
  Fixed to add a TPM protector as primary (falling back to recovery-password-only
  if no usable TPM is present), with the recovery password added as a secondary
  protector either way. **Not yet confirmed on real hardware whether this alone
  is sufficient, or whether a restart is additionally required** for
  `ProtectionStatus` to flip to `On` — re-run the BitLocker Apply/Audit check
  above and update this entry with the result.

### 2026-07-23 — same machine, follow-up: BitLocker fix above was insufficient

Restarting did not resolve it. Real error surfaced on retry:

```
Add-TpmProtectorInternal : This key protector cannot be added. Only one key
protector of this type is allowed for this drive. (Exception from HRESULT: 0x80310031)
```

Root cause: Windows had already pre-staged a TPM key protector on the OS drive
(common as part of "Device Encryption" readiness, even before BitLocker is
manually turned on) — so `-TpmProtector` failed. Critically, that error comes
from a **non-terminating `Write-Error`** inside Microsoft's own `BitLocker.psm1`,
not a normal exception, so the `try`/`catch` from the first fix never saw it —
it silently continued as if the call had succeeded, added a redundant recovery
password protector, and left the volume in **"BitLocker waiting for
activation"** (confirmed via the Control Panel BitLocker page) — protectors
staged, but encryption itself never started. This is also why a restart didn't
help: there was nothing "paused" to resume.

Fixed in `Modules/BitLocker.psm1`:
- Check for an existing TPM protector before ever requesting `-TpmProtector`;
  skip straight to activating with `-RecoveryPasswordProtector` if one is
  already present (the pre-existing TPM protector is retained alongside it).
- Every `Enable-BitLocker`/`Add-BitLockerKeyProtector` call now uses
  `-ErrorAction Stop`, so any future failure of this kind is actually
  catchable instead of silently passing through.
- Regression tests added directly against this branching logic (not just
  against `Set-BitLockerBaseline` with the whole function mocked away, which
  is exactly why this didn't get caught the first time).

**Still not independently confirmed on real hardware** whether this fully
resolves activation on a drive that already has a pre-staged TPM protector —
re-run `-Mode Apply` and update this entry with the result. If it's still
stuck in "waiting for activation," check `Get-BitLockerVolume | Select
-ExpandProperty KeyProtector` for the exact current protector state and
compare against what this fix expects, or try manually clicking "Turn on
BitLocker" in the Control Panel once to see whether the GUI wizard succeeds
where the PowerShell cmdlet path doesn't (which would point at a deeper
BitLocker.psm1/cmdletization quirk beyond what this fix addresses).

### 2026-07-23 — same machine, second follow-up: EncryptionMethod conflict

The fix above hit a second issue on the very next retry:

```
Write-BaselineLog : Apply of module 'BitLocker' failed, skipping:
Value does not fall within the expected range.
```

Two things wrong: (1) `Enable-BitLocker -EncryptionMethod ... -RecoveryPasswordProtector`
threw when called on a volume that already has a TPM protector staged —
"Value does not fall within the expected range" is a generic enum-validation
error from the cmdletization layer, most likely because re-specifying an
encryption method conflicts with whatever was already implicitly set when
the TPM protector was pre-staged. (2) That whole code branch (the
"TPM already present" path from the first fix) had **no try/catch around it
at all**, so the exception propagated all the way out of
`Enable-OsDriveBitLocker`, past `Set-BitLockerBaseline`, and was only ever
caught by the Orchestrator's generic per-module catch-all — which is why the
log said "Apply of module 'BitLocker' failed, skipping" rather than
something BitLocker-specific.

Fixed in `Modules/BitLocker.psm1`: both the "TPM already present" branch and
the "fresh TPM add failed, falling back to recovery password" branch now
retry without `-EncryptionMethod` if the with-method attempt throws (Windows
then uses whatever is already configured, or its platform default —
`XtsAes256` on modern Windows). Regression tests added reproducing this
exact throw and asserting it's caught, not propagated.

**Still not independently confirmed on real hardware.** After this fix,
please check `Get-BitLockerVolume -MountPoint C: | Format-List *` (or
`manage-bde -status C:`) and share the full output if it's still not
reaching `ProtectionStatus = On` — two guesses in a row needed correction
from real-hardware feedback, so a full diagnostic dump this time (rather
than another log excerpt) would let the next fix be verified against the
actual state instead of inferred from an error message alone.

### 2026-07-22 — QEMU Windows test VM, full Audit/Apply/Restore cycle

Ran `-Mode Audit`, `-Mode Apply`, and `-Mode Restore -Latest` for real
against a fresh VM. The `EncryptionMethod` fix above held up under this
run — no propagated exception, no "Value does not fall within the
expected range." Two new real bugs found and fixed, plus one same-session
over-fix reverted after it broke real usage:

- **`Restore-RemoteAccessSettings` always failed** with
  `ERROR: Error accessing the registry.` /
  `reg.exe failed with exit code 1`. `Backup-RemoteAccessSettings` did a
  full `reg export` of the entire `HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server`
  key. That tree includes subkeys (`WinStations\RDP-Tcp`, `RCM`, etc.)
  owned by the actively-running Terminal Services listener service,
  which `reg import` cannot overwrite while the service holds them open
  — confirmed by hand: a full-tree `reg import` of the exact backup file
  failed, while a minimal one-value `.reg` file for just
  `fDenyTSConnections` imported cleanly. Fixed in
  `Modules/RemoteAccess.psm1`: backup/restore now round-trips only the
  single `fDenyTSConnections` value (recording whether it existed at
  backup time, the same pattern `ScreenLock` already used), instead of
  exporting/importing the whole key. `Export-RemoteAccessRegistry` /
  `Import-RemoteAccessRegistry` removed.

- **`Enable-OsDriveBitLocker` could add two redundant recovery password
  protectors in a single `Apply` run**, on a volume where Windows had
  already started "Device Encryption" automatically before the toolkit
  ever ran (`Get-WinEvent -LogName 'Microsoft-Windows-BitLocker/BitLocker Management'`
  showed `Device Encryption initialized automatically for volume C:`
  well before the toolkit's own run). `manage-bde -status C:` afterward
  showed **two** `Numerical Password` protectors, but only the first was
  ever written to the recovery-key file — the second was silently lost.
  The BitLocker-API event log showed both protector-creation events
  succeeded (`A BitLocker key protector was created` /
  `BitLocker successfully committed metadata changes`), meaning the
  *first* protector-adding call actually succeeded at the OS level even
  though the wrapping cmdlet still raised a terminating error (the same
  class of PowerShell-cmdletization-vs-underlying-WMI-call mismatch as
  the earlier TPM-protector bug, just on a different code path) — so the
  existing catch/retry logic blindly added a second one. Fixed in
  `Modules/BitLocker.psm1`: every fallback branch in
  `Enable-OsDriveBitLocker` now re-checks the volume's actual key
  protectors (`Test-OsDriveHasRecoveryPasswordProtector`) before adding
  another, and skips the add if one is already present. Verified by
  running `-Mode Apply` twice in a row and confirming via the event log
  and `KeyProtector` count that no new protector was added on the
  second run.

  Separately (not yet resolved, not a code bug): on this VM,
  `ProtectionStatus` stayed `Off` and `Conversion Status` stayed stuck
  around 93.5-93.6% across multiple `Apply` runs roughly an hour apart,
  even with a valid recovery password protector in place. This appears
  to be expected BitLocker behavior (protection only turns on once
  conversion reaches 100%) combined with a very slow virtual disk, not
  a defect in this toolkit — the post-apply verification `Warn` is the
  correct response to it. Re-check `manage-bde -status C:` after giving
  the VM significantly more time (or on faster storage) to confirm it
  eventually reaches `ProtectionStatus = On` on its own.

- **Self-inflicted regression, caught and reverted before merging**:
  partway through this session, the single-item-array-collapsing bug
  described below was fixed by wrapping every `Common/Orchestrator.psm1`
  return path in `Write-Output -NoEnumerate`. That fixed the failing
  Pester assertion (`$results.Count` on a 1-module Restore) but broke
  real usage — piping `Invoke-SecurityBaseline.ps1`'s output to anything
  (`| Select-Object ...`, `| Where-Object ...`) started receiving the
  *entire* result array as one object instead of individual records,
  confirmed by comparing `$_.GetType().Name` before/after (`PSCustomObject`
  vs `System.Object[]`). Reverted to plain `return`; the one test that
  needs guaranteed array semantics on direct assignment now wraps at its
  own call site with `@(...)` — the standard PowerShell idiom for this —
  instead of forcing it into the producer. Worth remembering for future
  changes here: array-count bugs in PowerShell should almost always be
  fixed at the consuming call site, not by changing how the producer
  writes to the pipeline.

  Also fixed, found via the mocked Pester suite rather than real
  hardware: `New-BaselineAuditReport` wrote `"[\r\n\r\n]"` instead of
  `"[]"` for an empty result set (`ConvertTo-Json`'s default formatting
  of an empty array), and every `Invoke-*Run` function in
  `Common/Orchestrator.psm1` silently returned `$null` instead of an
  empty/single-element array when crossing a function-call boundary —
  standard PowerShell pipeline-enumeration behavior, not specific to
  this codebase, but worth knowing about before writing more code here
  that assumes `.Count` works uniformly regardless of result size.
