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
      `OSDriveEncrypted`**, check `manage-bde -status C:` for
      `Percentage Encrypted: 100.0%` with `Protection Status: Protection Off` -
      this combination means protection is suspended, not never-activated (see
      Findings below); `Enable-OsDriveBitLocker` now calls `Resume-BitLocker`
      automatically to handle exactly this, but if it's still stuck after an
      `Apply` run, try `Resume-BitLocker -MountPoint C:` by hand and share the
      result.
- [ ] Re-run `.\Invoke-SecurityBaseline.ps1 -Mode Apply` immediately again — the log
      for the second run shows `Changed=False` for every setting (idempotency).
- [ ] `Get-Service wuauserv` shows `StartType` not `Disabled`, and
      `HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU` shows
      `NoAutoUpdate = 0`, `AUOptions = 4`.
- [ ] `HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging`
      shows `EnableScriptBlockLogging = 1`, and
      `C:\ProgramData\SecurityBaseline\PowerShellTranscripts` exists.
- [ ] `HKLM:\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices\{53f5630d-b6bf-11d0-94f2-00a0c91efb8b}`
      shows `Deny_Write = 1` and no `Deny_All` value (not a real Windows
      setting — see Findings below); plugging in a USB drive shows files can
      still be opened/read but copying a new file to it, or deleting/editing
      one already on it, fails with an access-denied error.
- [ ] `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System` shows
      `ConsentPromptBehaviorAdmin = 2`.
- [ ] `HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\LmCompatibilityLevel` is `5`,
      and `HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient\EnableMulticast`
      is `0`.
- [ ] `(Get-WinEvent -ListLog Application/Security/System).MaximumSizeInBytes`
      is at least `104857600` for all three logs.

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

**Confirmed by an actual interactive logon**: logged the `user` account out
and back in with the temporary password - Windows prompted to change it,
as intended. `PasswordLastSet` moved to the time of that logon,
`PasswordExpired` read back `0` afterward (cleared because the change was
actually completed this time, not silently bypassed), and `UserFlags`
settled at a clean `0x201` (no `PASSWD_NOTREQD`, no `DONT_EXPIRE_PASSWD`,
no `PASSWORD_EXPIRED`). The temporary password file was deleted afterward
per its own instructions, once confirmed no longer needed.

### 2026-07-23 — same VM, third follow-up: BitLocker "100% encrypted, Protection Off" resolved

The open question from every earlier BitLocker entry above - why
`ProtectionStatus` stayed `Off` even once the volume finished converting -
is now resolved. On this VM, `Get-BitLockerVolume` showed
`VolumeStatus = FullyEncrypted`, `EncryptionPercentage = 100`, valid `Tpm`
+ multiple `RecoveryPassword` protectors, and yet `ProtectionStatus = Off`.
`manage-bde -status` doesn't distinguish a **suspended** protection state
from one that was **never activated** - both print as plain
"Protection Off" - which is exactly why this went unnoticed for so long.
Running `Resume-BitLocker -MountPoint C:` directly flipped
`ProtectionStatus` to `On` immediately, with no other change needed.

Root cause (most likely): this volume's OS-drive encryption was originally
started by Windows' automatic "Device Encryption" (see the very first
BitLocker findings entry above), and every subsequent `Enable-BitLocker`/
`Add-BitLockerKeyProtector` call this module made on top of that
pre-existing state - across several Apply runs while diagnosing the
earlier TPM-protector and duplicate-protector bugs - left protection in a
suspended rather than active state, without ever surfacing an error to
say so.

Fixed in `Modules/BitLocker.psm1`: `Enable-OsDriveBitLocker` now always
calls a new `Resume-OsDriveBitLocker` (`Resume-BitLocker -MountPoint
$env:SystemDrive`) as its final step, after configuring protectors,
regardless of which code path was taken. This is deliberately best-effort
- failures are swallowed, since `Test-BitLockerBaseline`'s post-apply
verification already catches and reports it if protection still isn't
`On` afterward.

Verified for real via the actual toolkit (not just the direct cmdlet
call above): `.\Invoke-SecurityBaseline.ps1 -Mode Audit -Modules
BitLocker` now shows `Pass = True` for `OSDriveEncrypted` - the first
time in this project's real-hardware validation history that BitLocker
has reported fully compliant - and a follow-up `-Mode Apply` shows
`0 setting(s) changed`, confirming it stays compliant and idempotent
rather than needlessly re-attempting protector setup on every run.

### 2026-07-23 — same VM, restoring to a fresh-like state for a clean re-test: two more real bugs

Asked to restore every setting back toward the VM's original state (from
the earliest snapshot, before any Apply this project ever ran) to set up
for another clean full-suite test pass. This surfaced two more real bugs.

**Restoring PasswordPolicy and AccountLockout together silently clobbered
PasswordPolicy back to its already-applied (compliant) values.**
`PasswordPolicy` and `AccountLockout` share the same secedit
`[System Access]` section. `Backup-<Area>Settings` for both simply calls
`secedit /export`, which dumps the *entire* section - not just the keys
that module manages. Because `Invoke-ApplyRun` processes modules
sequentially (`PasswordPolicy` before `AccountLockout`), `AccountLockout`'s
own backup - taken *after* `PasswordPolicy`'s `Set` already committed in
that same `Apply` run - silently captured `PasswordPolicy`'s post-`Set`
values instead of the true pre-`Apply` ones. Confirmed directly:
`PasswordPolicy\password-policy.cfg` showed `MinimumPasswordLength = 0`
(the true original), while `AccountLockout\account-lockout.cfg` from the
exact same snapshot showed `MinimumPasswordLength = 14`
(`PasswordPolicy`'s already-applied value, baked in by accident). Restoring
both from that snapshot together then reverted `AccountLockout` correctly
but immediately re-asserted `PasswordPolicy`'s stale compliant values the
moment `AccountLockout`'s own `/configure` ran afterward - reproduced and
confirmed via `Get-Content ... | Select-String` on both cfg files, and via
`Invoke-SecurityBaseline.ps1 -Mode Audit` before/after each restore step.

Fixed in `Modules/PasswordPolicy.psm1` and `Modules/AccountLockout.psm1`:
`Restore-<Area>Settings` no longer `/configure`s the raw historical backup
file directly. It now exports the **current** live policy fresh, copies
only that module's own keys out of the backup into that fresh export
(the same `Get-`/`Set-SecurityPolicyValue` pattern `Test-`/`Set-<Area>Baseline`
already use), and configures from that patched-current export instead -
leaving every other setting, including whatever the other secedit-based
module currently has, untouched. Verified for real: reproduced the exact
failing scenario (restore `PasswordPolicy`+`AccountLockout` together) both
before and after the fix - before, `PasswordPolicy` stayed compliant after
restore; after, both correctly revert to their true original values.

**Restoring BitLocker a second time with `-DecryptOnRestore` threw
"BitLocker Drive Encryption is not enabled on this drive."** Harmless in
effect (decryption was already under way from an earlier restore), but a
needless scary error on a repeat run. Fixed in `Modules/BitLocker.psm1`:
`Restore-BitLockerSettings` now checks `VolumeStatus` first and skips the
`Disable-BitLocker` call entirely if the volume is already
`DecryptionInProgress` or `FullyDecrypted`.

Verified for real, full-suite: restored every module from the earliest
snapshot (`Get-ItemProperty`/`Get-LocalUser`/`manage-bde` checked
directly, not just re-running `Audit`) - `PasswordPolicy`, `AccountLockout`,
`AuditPolicy`, `Firewall`, `ScreenLock`, and `RemoteAccess` (including
`DisableRDP` correctly reverting to `False`, confirming RDP really was
enabled before this project's very first `Apply`) all reverted to their
true pre-`Apply` values, and `manage-bde -status C:` reached
`Conversion Status: Fully Decrypted`, `Percentage Encrypted: 0.0%`.
`LocalAccounts` intentionally stayed hardened (`PasswordRequired`,
`PasswordNeverExpires` both still compliant) - by design, restoring a
blank password is a security regression this toolkit refuses to perform,
documented in that module's own Restore function.

### 2026-07-23 — same VM, fourth BitLocker follow-up: thin-provisioned storage rejects full-volume encryption

Immediately after the fresh-state restore above (BitLocker now genuinely
`Fully Decrypted`, `0%`), running `-Mode Apply` again threw a brand new
real error that had never surfaced before:

```
Write-BaselineLog : Apply of module 'BitLocker' failed, skipping:
BitLocker Drive Encryption only supports Used Space Only encryption on
thin provisioned storage. (Exception from HRESULT: 0x803100A5)
```

Root cause: none of this module's `Enable-BitLocker` calls ever passed
`-UsedSpaceOnly`, so without it, `Enable-BitLocker` defaults to
full-volume encryption. This had never been hit before because every
prior real-hardware test session found Windows' own automatic
"Device Encryption" had *already* started the volume as Used Space Only
before this toolkit ever ran (see the very first BitLocker findings entry
in this log) - so this module's own `Enable-BitLocker` calls only ever
needed to add protectors to conversion already locked into that method,
never to decide the method itself. Fully decrypting the volume (the
restore above) reset that entirely, and the very next `Enable-BitLocker`
call had to choose a method fresh - defaulting to full-volume, which this
VM's thin-provisioned virtual disk (`Get-PhysicalDisk` shows
`QEMU QEMU HARDDISK`) rejects outright.

Fixed in `Modules/BitLocker.psm1`: all three `Invoke-EnableBitLockerWith*`
functions now pass `-UsedSpaceOnly` (matching what Device Encryption
already defaults to, and required on any thin-provisioned storage -
common for VMs generally, not just this one).

While fixing this, adding a regression test surfaced an unrelated,
pre-existing test-infrastructure issue worth knowing about for future
BitLocker test changes: this project's own module is named `BitLocker`,
identical to the real Windows `BitLocker` PowerShell module. Mocking a
real cmdlet name this module doesn't itself define (`Enable-BitLocker`)
forces PowerShell's command auto-load to import the *actual* Windows
module to resolve it, and Pester then finds two distinct modules both
named `BitLocker` and refuses to pick one for `InModuleScope`. Fixed by
pre-defining a stub `Enable-BitLocker` function before the module import
- with the relevant parameters declared in its own `param()` block, since
without them `-ParameterFilter` in a `Should -Invoke` assertion has no
bound variables to match against and silently never matches anything -
the same stand-in-stub pattern `Tests/Common/Orchestrator.Tests.ps1`
already uses for the
per-area functions it mocks.

Verified for real: re-ran `-Mode Apply -Modules BitLocker` after the fix
- no error this time, `manage-bde -status C:` showed
`Conversion Status: Encryption in Progress`, `53.8%`, a real `Tpm`
protector successfully added (no TPM-fallback note this time), using
`XTS-AES 256` as configured.

### 2026-07-23 — same VM, six new modules added: WindowsUpdate, PowerShellLogging, RemovableStorage, UAC, NetworkHardening, EventLogRetention

Added six new modules covering gaps identified when asked "did I miss any
settings?" — Windows Update policy, PowerShell script block/module/
transcription logging, removable storage lockdown, UAC prompt behavior,
NTLM/LLMNR network hardening, and event log retention size. All follow the
existing `Test-`/`Backup-`/`Set-`/`Restore-<Area>Baseline` contract, are
config-driven via `Config/Baseline.config.psd1`, and ship with Pester
coverage (47 new tests, mocked at the registry-wrapper level).

Verified for real against this VM, full cycle, no bugs found this round:

- **Fresh Audit**: all 18 settings read correctly, including genuine
  Windows-default values on an unconfigured machine (`LmCompatibilityLevel
  = 3`, `ConsentPromptBehaviorAdmin = 5`, event logs at the default 20 MiB)
  — confirming the "absent registry value = Windows' own compliant
  default" design for `WindowsUpdate`/`NetworkHardening` doesn't
  misreport a stock machine as non-compliant.
- **Apply**: `12 setting(s) changed`, `LASTEXITCODE 0`, no errors. The 6
  settings already compliant out of the box (`WindowsUpdate` x4,
  `UAC.EnableLUA`, `UAC.PromptOnSecureDesktop`) correctly reported
  `Changed=False`.
- **Idempotency**: immediate re-`Apply` reported `0 setting(s) changed`
  across all 18 settings.
- **Direct spot-checks** (not just re-running the toolkit's own `Audit`):
  `Get-ItemProperty ... ScriptBlockLogging` key present, `wevtutil`-backed
  `(Get-WinEvent -ListLog Security).MaximumSizeInBytes` read `104857600`,
  `(Get-Service wuauserv).StartType` read `Manual` (not `Disabled`) — all
  matched what the toolkit reported.
- **Restore**: reverted all 12 changed settings back to their pre-`Apply`
  values (confirmed via a post-Restore `Audit` showing `12 setting(s)
  failed` plus the same direct spot-checks — `LmCompatibilityLevel` back
  to `3`, Security log back to `20971520` bytes, `wuauserv` back to
  `Manual`), then re-`Apply`d to leave the machine in its hardened state.

No new bugs surfaced this round — first module addition in this project's
real-hardware validation history to go from Audit through Apply,
idempotency, and Restore with nothing to fix.

### 2026-07-24 — same VM, RemovableStorage follow-up: `Deny_All` was never a real Windows setting

Asked to clarify the removable-storage setting so it blocks write access
only, leaving read allowed (the toolkit had been configured to deny all
access outright). While making that change, found that `Modules/RemovableStorage.psm1`
was writing a registry value named `Deny_All` under the "Removable Disks"
device-class key
(`HKLM:\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices\{53f5630d-b6bf-11d0-94f2-00a0c91efb8b}`)
— confirmed via web search against Microsoft's actual Removable Storage
Access Group Policy documentation that this key only recognizes `Deny_Read`
and `Deny_Write` per device class; there is no `Deny_All` at this path (a
value of that name exists only directly under the parent
`RemovableStorageDevices` key, for the separate "All Removable Storage
classes" policy, which this module was never targeting). Confirmed directly
on this VM: `Get-ItemProperty` on the key showed `Deny_All = 1` with no
`Deny_Write`/`Deny_Read` present at all — meaning every prior `Apply` run
that reported this setting as compliant had, in reality, changed nothing;
removable storage access was never actually restricted despite the toolkit
saying otherwise.

Fixed in `Modules/RemovableStorage.psm1`: now reads/writes `Deny_Write`
instead of `Deny_All` (setting name renamed
`RemovableDisksAccessDenied` → `RemovableDisksWriteDenied`; config key
renamed `DenyAllAccess` → `DenyWriteAccess` in `Config/Baseline.config.psd1`),
which also directly satisfies the write-only-block request — `Deny_Read` is
a distinct, real value under the same key that this module deliberately
never touches, so read access is never denied. Verified for real: a fresh
`Audit` after the fix correctly reported non-compliant (the stale `Deny_All`
value has no effect Windows recognizes, so nothing was actually enforced),
`Apply` set `Deny_Write = 1`, and the stale `Deny_All` value was left in
place harmlessly (Windows ignores unrecognized value names at this path) —
worth manually removing on any machine this ran against before this fix.
**Not yet confirmed by an actual USB read/write attempt on this VM** (no
removable media attached to it) — re-check the Apply-mode checklist item
above on real hardware with a USB drive attached before relying on this.

### 2026-07-24 — first Windows 11 Home run, full Audit/Apply/Restore cycle

Ran the mocked Pester suite (`Invoke-Pester -Path Tests`, 206 tests, after
installing Pester 5+ via `Install-PackageProvider NuGet` +
`Install-Module Pester -Scope CurrentUser` — the box only shipped the
ancient built-in Pester 3.4.0, which can't run this suite's `Should -Invoke`/
`InModuleScope` syntax), then a full real `-Mode Audit` → `-Mode Apply` →
`-Mode Restore` cycle against a genuine Windows 11 **Home** VM (`Get-CimInstance
Win32_OperatingSystem` confirms `Microsoft Windows 11 Home`, `Get-WindowsEdition
-Online` confirms SKU `Core`) — the edition this toolkit had never been
run against before. One real bug found and fixed:

- **BitLocker `Apply` crashed the module instead of degrading gracefully.**
  `Enable-BitLocker` throws `COMException` HRESULT `0x8031005A` ("This
  version of Windows does not support this feature of BitLocker Drive
  Encryption. To use this feature, upgrade the operating system.") on Home,
  for every protector combination tried (`-TpmProtector`,
  `-RecoveryPasswordProtector`, with or without `-EncryptionMethod`) —
  confirmed by calling each directly. This wasn't about missing hardware
  prerequisites (this VM's TPM was present, ready, owned, and activated,
  and Secure Boot was on) - Windows 11 Home simply never exposes full
  BitLocker Drive Encryption via this cmdlet path at all, regardless of
  hardware; only the OS's own automatic "Device Encryption" applies on
  Home, and it isn't controllable through `Enable-BitLocker`. Every
  existing fallback branch in `Enable-OsDriveBitLocker` still ends up
  calling `Enable-BitLocker` one way or another, so all of them threw the
  same error, which propagated all the way past `Set-BitLockerBaseline`
  to the Orchestrator's generic per-module catch-all — logging
  `Apply of module 'BitLocker' failed, skipping` instead of the graceful
  "unavailable, not a crash" outcome this checklist has always expected
  for Home. Fixed in `Modules/BitLocker.psm1`: `Set-BitLockerBaseline` now
  catches this exact HRESULT (`Test-BitLockerUnsupportedByEditionError`,
  matched on `$_.Exception.HResult -eq -2144272294` rather than the message
  string, which could vary by locale) and reports `Changed=False` with a
  clear Note instead of letting it propagate; any other exception still
  throws through unchanged, preserving the existing failure-surfacing
  behavior for genuinely unexpected errors. Regression tests added
  reproducing the exact HRESULT and asserting both the graceful path and
  that unrelated failures still throw.

Verified for real, full cycle, no other bugs found:

- **Audit** (fresh, never-configured machine): all 54 settings across 15
  modules read correctly, including genuine Windows-default values
  (`LmCompatibilityLevel = 3`, `ConsentPromptBehaviorAdmin = 5`, event logs
  at their 20 MiB default, all 4 `WindowsUpdate` settings and both
  `UAC.EnableLUA`/`PromptOnSecureDesktop` already compliant out of the box) -
  37 settings failed, matching what `Apply` then changed.
- **Apply**: `36 setting(s) changed`, `LASTEXITCODE 0`, no crash (after the
  BitLocker fix above). Direct spot-checks against the live system (not
  just the toolkit's own re-`Audit`) confirmed `net accounts`,
  `Get-NetFirewallProfile`, `auditpol /get /category:*`,
  `Get-ItemProperty ... Terminal Server\fDenyTSConnections`,
  `Get-SmbServerConfiguration`, `Get-LocalUser -Name Guest`,
  `Get-ItemProperty ... PowerShell\ScriptBlockLogging`/`ModuleLogging`/
  `Transcription`, the `RemovableStorageDevices` `Deny_Write` key,
  `ConsentPromptBehaviorAdmin`, `LmCompatibilityLevel`, `EnableMulticast`,
  `(Get-WinEvent -ListLog ...).MaximumSizeInBytes`, and
  `InactivityTimeoutSecs` all matched exactly what the toolkit reported.
  `LocalAccounts` correctly detected this VM's own interactively-logged-on
  `user` account had `PasswordRequired = False`, set a compliant 24-char
  temporary password (written to
  `C:\ProgramData\SecurityBaseline\TemporaryPasswords\user-temp-password.txt`),
  and forced a password change at next logon - consistent with the LocalAccounts
  behavior already validated on the Pro VM. **Not independently re-confirmed
  by an actual interactive logon in this session** (this exact mechanism was
  already confirmed working end-to-end on the Pro VM run above); if it's
  reused on this VM going forward, check the temp password file is still
  there and consider clearing it once a real password has been set.
- **Idempotency**: immediate re-`Apply` reported `0 setting(s) changed`
  (BitLocker's graceful edition-unsupported Note repeats every run, as
  expected, since Home can never satisfy `OSDriveEncrypted` through this
  toolkit).
- **Restore**: `Restore -Latest` completed without throwing (its backup
  happened to be the idempotent no-op run's snapshot, so nothing changed -
  expected, not a bug). A second `Restore -Timestamp` targeting the
  **first** `Apply`'s backup then genuinely reverted 35 of the original 37
  failing settings back to their true pre-`Apply` values (confirmed via a
  fresh `Audit` immediately after, and direct spot-checks of `net accounts`,
  firewall, and audit policy) - the other 2 (`LocalAccounts`
  `PasswordRequired`/`PasswordNeverExpires`) correctly stayed hardened by
  design, matching the intentional one-way security posture already
  documented above. Re-applied afterward to leave the VM in its hardened
  state.

Home-edition checklist items still not exercised on this VM (no physical
access / no removable media attached): the 15-minute auto-lock wait, an
actual USB drive write-denial test, and a non-elevated-prompt run to
confirm the "must be run from an elevated" error message (the underlying
`Test-BaselineElevation` guard logic was inspected directly and is
unchanged from what the Pro VM run already exercises via
`Set-StrictMode -Version Latest` + a direct call, which passed here too).

### 2026-07-24 — same Home VM, correction: BitLocker was never actually edition-blocked - a mounted ISO was

The entry above concluded Windows 11 Home can never support full BitLocker
Drive Encryption via any API this toolkit can reach, "confirmed" via
`Enable-BitLocker`, `Add-BitLockerKeyProtector`, and a raw
`Invoke-CimMethod` call directly against the `Win32_EncryptableVolume` WMI
provider - all three returned HRESULT `0x8031005A` ("This version of
Windows does not support this feature"). **That conclusion was wrong.**

While investigating whether Device Encryption could be triggered as a
fallback, `Enable-BitLocker` was retried on this exact same VM and threw a
*different* error: `0x80310030`, "BitLocker Drive Encryption detected
bootable media (CD or DVD) in the computer." This VM had two ISOs mounted
in virtual optical drives the entire time (a virtio driver disc and a
Windows install disc - standard leftovers from provisioning a QEMU VM) -
present during every earlier test in the entry above, unnoticed because
none of that testing checked for mounted media. After fixing the toolkit to
handle `0x80310030` gracefully too (see below), the media was ejected to
verify the new code path for real - and `Enable-BitLocker` **succeeded
immediately** on the next attempt, with no other change: a TPM and a
recovery-password protector were added, and the volume reached
`VolumeStatus = FullyEncrypted`, `ProtectionStatus = On` within minutes
(a ~49 GB used-space-only volume). A follow-up `-Mode Apply` was fully
idempotent (`0 setting(s) changed`, exactly the same two protectors, no
duplicates), and `-Mode Audit` reported `OSDriveEncrypted` compliant.

So Windows 11 Home **does** support full BitLocker Drive Encryption via
`Enable-BitLocker` on this hardware after all. The real blocker the whole
time was the mounted ISOs, and `0x8031005A` is not a reliable signal of a
genuine edition restriction - it can also surface for other blocking
preconditions (confirmed: bootable media present) that Windows reports
under the same code as the documented edition/SKU error. Why Windows
returns that specific code for a media-related block rather than
`0x80310030` in some call paths is not something this project can confirm
without access to Windows' internals; only the empirical, reproducible
before/after (identical call, only the media changed, on the same
edition/hardware) is claimed here.

Fixed in `Modules/BitLocker.psm1`:
- Added graceful handling for `0x80310030` (bootable media present)
  alongside the existing `0x8031005A` handling, via a small
  HRESULT-to-Note lookup (`Get-BitLockerKnownApiLimitationNote`) rather
  than a single-purpose edition check - reports `Changed=False` with a
  clear "eject the media and retry" Note instead of crashing the module,
  the same graceful treatment `0x8031005A` already got.
- Rewrote the `0x8031005A` Note to lead with the actionable, disprovable
  step (check for and eject any mounted CD/DVD/ISO) before suggesting a
  genuine edition/hardware limitation as a fallback explanation, instead
  of asserting Home can never support BitLocker regardless of hardware -
  a claim this session's own follow-up testing directly disproved.
- Regression tests added for both HRESULTs, including one asserting the
  `0x8031005A` case no longer claims certainty about an edition block.

Also corrects the README's Home-validation summary, which previously
described BitLocker's "absence on Home" as the expected outcome - it now
notes BitLocker reaching `ProtectionStatus = On` on **both** editions
tested, Home included, once the mounted media was cleared.

**Practical takeaway for future validation runs**: if `Enable-BitLocker`
throws `0x8031005A` on any edition, check for mounted CD/DVD/ISO media in
every optical drive (`Get-Volume | Where-Object DriveType -eq 'CD-ROM'`)
and eject it before concluding the edition can't support BitLocker - this
is now a known false signal, not confirmed proof.

### 2026-07-24 — same Home VM, second correction: a fully-reset volume genuinely cannot re-enable BitLocker here

As a final validation pass, asked to restore every module to the VM's
true pre-`Apply` snapshot (including `-DecryptOnRestore` for BitLocker,
fully decrypting the OS drive back to 0%) and then re-`Apply` from
scratch, to confirm this session's fixes hold up end-to-end. 34 of 35
non-compliant settings re-applied correctly and matched the original
hardened state exactly (password policy, lockout, firewall, audit policy,
etc. all spot-checked directly). BitLocker did not.

`Enable-BitLocker` threw `0x8031005A` again - but this time with **no**
optical media mounted at all (confirmed via `Get-Volume`), which the entry
above would have called proof of a genuine edition/hardware limitation.
Investigating further: `Get-BitLockerVolume` showed the freshly-decrypted
volume at `MetadataVersion = 0`, whereas it had been `MetadataVersion = 2`
(no protectors, but *some* prior BitLocker metadata already present) the
very first time it was ever inspected this session, before any testing
began. Calling the lowest-level `Win32_EncryptableVolume.PrepareVolume`
WMI method directly - the step that initializes BitLocker metadata from
an absolutely blank volume, bypassing every cmdlet layer - failed with the
identical `0x8031005A` on this now-`MetadataVersion = 0` volume. A full VM
restart (to test whether Windows' background Device Encryption readiness
process would re-stage the metadata skeleton the way it apparently had
before, unprompted) did not change the outcome: `PrepareVolume` still
fails identically post-reboot, and `msinfo32`'s "Automatic Device
Encryption Support" diagnostic still reports "TPM is not usable" for this
QEMU virtual TPM, unchanged from the very first time it was checked.

So the fuller, now best-understood picture: this VM's OS drive already
had non-zero BitLocker metadata staged before this project ever touched
it (origin unconfirmed - most likely Windows' own automatic Device
Encryption readiness process running once during the VM's initial
provisioning/first boot, independent of the "TPM is not usable" block on
*triggering* automatic encryption itself). Home can successfully add
protectors and encrypt a volume that already has that metadata staged
(confirmed twice, real encryption both times, `ProtectionStatus` reaching
`On`). But initializing BitLocker metadata on a **genuinely blank**
volume - which is exactly what a full decrypt produces - appears to be a
real, per-volume/hardware limitation on this machine that this toolkit
cannot route around via any API it can reach, confirmed at the lowest
possible layer and unaffected by a reboot.

**Net result: this VM's OS drive is currently unencrypted and this
toolkit cannot currently re-enable BitLocker on it.** This is a direct,
known consequence of the `-DecryptOnRestore` validation step above, not a
regression introduced by any code change, and not something any fix in
this codebase can address - the block is inside Windows' own encryption
engine reacting to this volume/hardware's current state, not in a cmdlet
wrapper. Every other module was re-verified fully hardened and correct.

Fixed in `Modules/BitLocker.psm1`: the `0x8031005A` Note now describes
both confirmed root causes (retriable bootable-media block, and this
non-retriable blank-volume limitation) instead of the previous entry's
still-too-confident "eject media, it's not really edition-related"
framing - which was accurate for the case it was tested against, but
incomplete, as this entry's own testing shows. Regression test comments
updated to match; the module's behavior (graceful `Changed=False`, never
crash) was already correct and needed no logic change, only a more honest
Note.

**Open question for a future session**: whether this is recoverable at
all on this specific VM (e.g. via a clean Windows reinstall, a different
virtual TPM implementation, or simply time/other Windows-triggered
staging this session didn't discover) is unknown - noted here rather than
guessed at further.

### 2026-07-24 — same Home VM, resolution: found the real bootstrap mechanism, and its limit

The open question above is now answered. Asked whether the manual
Settings toggle (which is known to work) could be automated, three
programmatic paths were tried and ruled out on this exact blank-metadata
volume:

- `manage-bde.exe -on` (a completely different binary from the cmdlet/WMI
  paths already tried) - identical `0x8031005A`.
- The officially-documented `BitLocker` CSP (`MDM_BitLocker`,
  `RequireDeviceEncryption` property, in `root\cimv2\mdm\dmmap`) - the same
  mechanism Intune/MDM enrollment uses to trigger Device Encryption with no
  human interaction. Writing it from a regular elevated-admin session
  failed ("the requested object could not be found"). Retried from a
  SYSTEM-context one-shot scheduled task (the privilege level Windows'
  own Settings toggle and MDM operate at) - got further, but failed with a
  different, generic error ("a general error occurred that is not covered
  by a more specific error code"). This CSP bridge appears to require
  genuine MDM enrollment plumbing (an enrollment ID, the
  `EnterpriseMgmt` scheduled-task infrastructure) that a standalone,
  non-enrolled device doesn't have - writing the desired value isn't
  enough without something to actually enact it.

Then the manual Settings > Privacy & security > Device encryption toggle
was flipped again, on this exact still-blank (`MetadataVersion = 0`)
volume, to observe it directly instead of guessing further. Two things
were learned:

1. **A screenshot of the Settings page showed the real reason the toggle
   alone doesn't finish**: "Sign in with your Microsoft account to finish
   encrypting this device." Windows 11 Home's Device Encryption needs
   somewhere to escrow the recovery key, and for a local account (this
   VM's `user` account, confirmed via the screenshot's account panel) that
   means a Microsoft account sign-in - which this toolkit correctly should
   never attempt to automate (it's a credential/identity action, out of
   scope for a hardening script, and deliberately gated by Windows itself).
2. **Flipping the toggle alone, without ever completing that sign-in,
   still moved `MetadataVersion` from `0` to `2` immediately** - this is
   the one step no scriptable API could do. Once that happened, this
   toolkit's own `Enable-BitLocker` call (which uses a local
   recovery-password protector, not a Microsoft-account-escrowed one)
   **succeeded immediately** with no further manual involvement - added a
   TPM + recovery-password protector and began encrypting normally. (The
   two ISOs also came back after the earlier reboot - a persistent VM/
   hypervisor configuration, not a Windows behavior - and had to be
   ejected again first; this is exactly the retriable `0x80310030` case
   already handled.)

So the complete, now fully-evidenced picture: **this toolkit can
automate everything except the very first metadata-initialization step
on a truly blank Home volume**, which requires a one-time human action
(flipping the Device encryption toggle - not completing the Microsoft
account sign-in, just the toggle) that has no scriptable equivalent this
session could find, including the officially-documented MDM CSP path.
Once that one-time step happens, by any means, this toolkit reliably
takes over forever after (confirmed idempotent across multiple Apply
runs, multiple reboots, and a full restore-to-fresh-and-reapply cycle).

Fixed in `Modules/BitLocker.psm1`: added `Test-OsDriveHasBitLockerMetadata`
(checks `MetadataVersion -gt 0`), called proactively in
`Set-BitLockerBaseline` before ever attempting `Enable-BitLocker` - a
blank volume now short-circuits straight to a specific, accurate Note
naming the exact one-time bootstrap step (flip the Settings toggle, don't
bother with the Microsoft-account prompt) instead of wastefully attempting
and failing first. The `0x8031005A` HRESULT-lookup entry is now a
narrower fallback for the rarer case where metadata already exists and
media isn't the issue either - an honestly-unexplained case, still
handled gracefully. Regression tests added for the new proactive check;
existing tests updated to set `MetadataVersion` on their mocked volumes so
they continue to exercise the paths they're meant to.

Verified for real: after flipping the toggle and ejecting the
re-mounted ISOs, `.\Invoke-SecurityBaseline.ps1 -Mode Apply -Modules
BitLocker` added a local recovery-password protector and started
encrypting on its own (`EncryptionInProgress`, climbing steadily),
confirming the fix's proactive check correctly gets bypassed once
metadata exists, and the existing Enable-BitLocker path still works
exactly as validated earlier in this document.
