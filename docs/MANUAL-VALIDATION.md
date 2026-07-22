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
