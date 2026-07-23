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
- [ ] Local accounts: `Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'` shows
      `AutoAdminLogon = 0` and no `DefaultPassword` value. Any enabled local account that
      previously showed `PasswordRequired = False` in `Get-LocalUser` now shows
      `PasswordRequired = True` (`net user <name>` shows `Password required   Yes`)
      immediately after a single Apply run, and a temporary password file exists at
      `C:\ProgramData\SecurityBaseline\TemporaryPasswords\<name>-temp-password.txt`.
      Also check `([ADSI]"WinNT://$env:COMPUTERNAME/<name>,user").UserFlags.Value` (as a
      hex value) does **not** include `0x10000` (`UF_DONT_EXPIRE_PASSWD` / "Password
      never expires") - neither `Get-LocalUser` nor `net user` surfaces this flag, but it
      silently defeats the forced password change if set. Confirm the forced change
      actually works by logging that account out and back in (or switching user) using
      the password from that file, and observing the "you must change your password"
      prompt — this is the step most worth re-checking after any change here, since two
      earlier versions of this fix each looked correct from the registry/cmdlet state
      alone but didn't actually prompt at the logon screen for this exact account.
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

### 2026-07-22 — same VM, adding the LocalAccounts module (autologon + blank passwords)

Added a ninth module, `Modules/LocalAccounts.psm1`, covering two gaps not
previously in scope: Windows autologon (`AutoAdminLogon`, which stores a
plaintext password in the registry and skips the logon prompt/screen lock
entirely) and local accounts that allow a blank password
(`Get-LocalUser`'s `PasswordRequired = $false`). Tested against this VM's
real `user` account, which had exactly that: enabled, `PasswordRequired =
False`. Three real bugs found and fixed while doing so, none visible from
the mocked Pester suite alone:

- **`Set-LocalUser` has no `-PasswordRequired` parameter at all.**
  `Get-Command Set-LocalUser -Syntax` on this build confirms it only
  supports `-AccountExpires`, `-AccountNeverExpires`, `-Description`,
  `-FullName`, `-Password`, `-PasswordNeverExpires`, and
  `-UserMayChangePassword` — a long-standing gap in the built-in
  `Microsoft.PowerShell.LocalAccounts` module (`PasswordRequired` is
  exposed as a read-only property on `Get-LocalUser`'s output, with no
  corresponding setter anywhere in the module). Fixed by using the WinNT
  ADSI provider instead (`([ADSI]"WinNT://$env:COMPUTERNAME/$Name,user").PasswordRequired
  = $true`), the same mechanism already used for forcing a password
  change at next logon.

- **That ADSI call throws "The password does not meet the password
  policy requirements"** when the account's *current* password doesn't
  satisfy the active complexity/length policy — confirmed directly
  against the real `user` account, which is exactly the situation this
  feature exists to fix (a blank or otherwise non-compliant existing
  password). So `Set-LocalUserRequiresPassword` can legitimately fail on
  the very account it's meant to remediate, on the very first Apply run.
  Fixed by reordering: `Set-LocalUserPasswordExpired` (forces a change at
  next logon) runs first and has no such precondition, so it always
  succeeds; `Set-LocalUserRequiresPassword` is now best-effort, wrapped
  in its own try/catch, with `Set-LocalAccountsBaseline` reporting
  `Changed=True`/`After=False` and a Note explaining it'll succeed
  automatically on a later Apply run once the account's password has
  actually been changed to something compliant.

- **`[ADSI]::SetInfo()` leaked a stray `$null` onto the pipeline**,
  silently prepending it to `Set-LocalAccountsBaseline`'s returned array.
  `SetInfo()` is a COM method call through the ADSI interop layer, and an
  unsuppressed call to it (or to any function whose last statement calls
  it) writes `$null` to the output stream as an interop artifact — this
  isn't specific to this codebase, but it's an easy thing to miss since
  the function *looks* like it returns nothing. Confirmed directly:
  calling `Set-LocalAccountsBaseline` and inspecting each array element
  individually showed index 0 was `$null`, indices 1-2 were the real
  `PSCustomObject` results. This in turn caused a *second*, harder-to-
  diagnose failure further up the call chain: `Invoke-ApplyRun`'s
  `Write-BaselineApplySummary -ChangeRecords @($allChanges) ...` threw
  `ParameterBindingValidationException` even though `@($allChanges).Count
  -gt 0` had just evaluated true moments earlier in the preceding `if` —
  the count check passed because the array had 3 elements (including the
  null), but something about that specific mix apparently still tripped
  the mandatory-parameter null check on the actual call. Fixed by piping
  every ADSI `SetInfo()` call to `Out-Null` at its source, inside
  `Set-LocalUserRequiresPassword` and `Set-LocalUserPasswordExpired`
  themselves (not just at each call site), so every caller — including
  `Restore-LocalAccountsSettings` — is protected.

Verified end-to-end after all three fixes: real `Apply` forced the `user`
account's password-expired flag (confirmed via `net user user` and the
`Microsoft-Windows-Security` mechanics, though not by an actual interactive
logon in this session — see the Apply-mode checklist above for that step),
correctly reported `PasswordRequired` as still-pending with a clear Note,
re-running `Apply` immediately after was idempotent (no crash, consistent
Note, no duplicate side effects), and `Restore` correctly reverted the
autologon registry values while leaving `PasswordRequired` alone (per the
module's intentionally one-way security posture) and never touching
`DefaultPassword`.

### 2026-07-23 — same VM, follow-up: forcing PasswordExpired alone was not enough

Real-world feedback after rebooting the VM: the `user` account still had a
blank password, autologon still wasn't requested to change it, and no
"you must change your password" prompt appeared at the logon screen despite
the fix above.

Root cause: forcing `PasswordExpired = 1` only has an effect if the
account's logon actually goes through an interactive credential-entry
step. For an account with `PasswordRequired = $false` and a genuinely
blank password, Windows' blank-password logon path (type nothing, press
Enter/click the tile) evidently doesn't always route through that step on
this build, so the "must change" flag never gets a chance to trigger. This
also explains why nothing looked like "autologon" was ever actually
enabled in the registry (`AutoAdminLogon` was `0` the whole time, confirmed
directly) — the blank password alone was functionally equivalent to
autologon from the user's point of view, since no real credential was ever
required at the console.

Fixed in `Modules/LocalAccounts.psm1`: stopped relying on `PasswordExpired`
alone. `Set-LocalAccountsBaseline` now generates a random, policy-compliant
24-character temporary password (`New-CompliantTemporaryPassword`, using
all four character classes so it satisfies any reasonable complexity
policy) and sets it immediately via `Set-LocalUser -Password` (found via
`Get-Command -Syntax` that unlike `-PasswordRequired`, `-Password` **is**
supported), invalidating the blank password right away rather than waiting
for a logon-time prompt that might never come. `PasswordExpired` is still
set on top of that so the account holder is forced to replace the
temporary value with their own at next logon. Setting the password first
also fixed the earlier "could not yet mark it as requiring a password"
problem: `Set-LocalUserRequiresPassword` now succeeds immediately on the
same `Apply` run, since the account's current password is compliant by
the time it's called.

The generated password is written in plaintext to
`C:\ProgramData\SecurityBaseline\TemporaryPasswords\<username>-temp-password.txt`,
the same plaintext-secret-with-a-clear-warning pattern already used for
the BitLocker recovery key, since the account holder needs it to log on
once. `Set-LocalUserRequiresPassword`'s try/catch fallback (for when
`PasswordRequired` still can't be set) is kept as defense in depth even
though this fix makes it far less likely to trigger.

One more real bug hit while building this:
`[System.Security.Cryptography.RandomNumberGenerator]::Fill(byte[])` —
the modern static one-liner for filling a byte array with random data —
does not exist in .NET Framework, which is what Windows PowerShell 5.1
targets (it's a .NET Core/5+-only API). Fixed by using the classic
`[RandomNumberGenerator]::Create()` / `.GetBytes(byte[])` instance API
instead, which works on both.

Verified end-to-end for real: `Get-LocalUser -Name user` and `net user
user` both now show `PasswordRequired`/`Password required` as
`True`/`Yes` immediately after a single `Apply` run (no more "pending"
Note), the temporary password file was created with a real
24-character/all-classes password, re-running `Apply` immediately after
was fully idempotent (`0 setting(s) changed`), and a follow-up `Audit`
shows the module fully compliant. **Still not confirmed by an actual
interactive logon in this session** — re-run the Apply-mode checklist
item above (log the account out and back in using the temporary password)
and update this entry if the change-password prompt still doesn't appear.

### 2026-07-23 — same VM, second follow-up: "Password never expires" silently defeated the forced change

Real-world feedback again: logged out, logged back in with the temporary
password from the file above, and Windows still did not prompt to change
it.

Root cause, confirmed by reading the account's raw `UserFlags` bitmask
directly via ADSI (`([ADSI]"WinNT://$env:COMPUTERNAME/user,user").UserFlags`):
it was `0x10201`, which includes `UF_DONT_EXPIRE_PASSWD` (`0x10000`) -
i.e. "Password never expires" was set on this account (not something this
baseline had set; it was already there). After the logon that used the
temporary password, `PasswordExpired` read back as `0` and a matching
Security event 4624 (`LogonType 2`, account `user`) was sitting right at
that timestamp - Windows accepted the logon and silently cleared the
must-change flag without ever prompting, because "Password never expires"
and "must change at next logon" conflict, and the former wins. This is a
known Windows quirk, not specific to this codebase, but easy to miss
since neither `Get-LocalUser` nor `net user` surfaces "Password never
expires" as a queryable property or line - only the raw `UserFlags` (or
`lusrmgr.msc`) shows it.

Fixed in `Modules/LocalAccounts.psm1`: `PasswordNeverExpires` is now a
first-class, independently-audited per-account setting (`<user>.PasswordNeverExpires`,
new `DisablePasswordNeverExpires` config value), checked and remediated
on its own rather than only as a side effect of fixing `PasswordRequired`
- this matters because an account can already be `PasswordRequired=True`
from a prior `Apply` run (as this one was) while still having "Password
never expires" set, in which case the old code's `PasswordRequired`
remediation branch would never run again and the flag would never get
cleared. `Get-LocalUserPasswordNeverExpires` reads the raw `UserFlags`
bit directly since there's no cmdlet property for it;
`Clear-LocalUserPasswordNeverExpires` uses `Set-LocalUser -PasswordNeverExpires $false`
(which does exist as a parameter, confirmed via `Get-Command -Syntax`).
Clearing it alone isn't enough either - `Set-LocalUserPasswordExpired` is
re-called in the same remediation, since the earlier logon already
consumed the flag once.

Verified for real: raw `UserFlags` went from `0x10201` to `0x800201`
(`UF_DONT_EXPIRE_PASSWD` gone, `UF_PASSWORD_EXPIRED` now present),
`PasswordExpired` reads `1`, a follow-up `Apply` is idempotent
(`0 setting(s) changed`), and `Audit` shows all three settings
(`AutoLogonDisabled`, `PasswordRequired`, `PasswordNeverExpires`)
compliant. **Still not confirmed by an actual interactive logon** - this
is now the second time a fix that looked complete from cmdlet/registry
state didn't hold up against a real logon attempt, so treat this one the
same way: log the account out and back in with the same temporary
password and confirm the change prompt actually appears before trusting
this is done. If it still doesn't prompt, capture the account's raw
`UserFlags` value and the nearest Security event 4624 right after that
attempt, the same way this entry did.
