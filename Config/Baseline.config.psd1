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
    LocalAccounts = @{
        DisableAutoLogon = @{
            Value       = $true
            Description = "Disables Windows automatic sign-in (AutoAdminLogon). Autologon stores the account's password in plaintext in the registry (Winlogon\DefaultPassword) and skips the logon prompt/screen lock entirely, both of which defeat the other controls in this baseline."
        }
        RequirePasswordForAllAccounts = @{
            Value       = $true
            Description = "Ensures every enabled local account requires a password, rejecting the 'password not required' flag that allows a blank password. Forcing a password change at next logon alone isn't sufficient - confirmed on real hardware, a blank-password account's logon can bypass the credential-entry step that flag relies on - so a random, policy-compliant temporary password is also set immediately, invalidating the blank password right away. The account is still forced to change it at next logon so the temporary value doesn't linger."
        }
        TemporaryPasswordPath = @{
            Value       = 'C:\ProgramData\SecurityBaseline\TemporaryPasswords'
            Description = "Local folder where a generated temporary password is saved in plaintext when RequirePasswordForAllAccounts remediates a blank-password account, since the account holder needs it to log on once before setting their own. Secure, relocate, or delete each file after that happens."
        }
        DisablePasswordNeverExpires = @{
            Value       = $true
            Description = "Clears the 'Password never expires' flag on every enabled local account. Confirmed on real hardware: an account with this flag set silently defeats any forced 'must change password at next logon' action on that same account - Windows lets the logon through and clears the must-change flag without ever prompting - so it has to be checked and cleared independently of whatever else is being remediated on the account."
        }
    }
    WindowsUpdate = @{
        AutomaticUpdatesEnabled = @{
            Value       = $true
            Description = "Ensures automatic updates aren't disabled via policy (NoAutoUpdate=0). An unpatched machine undermines every other control in this baseline, so this is enforced explicitly rather than relying on whatever a user last set in Settings."
        }
        DeferQualityUpdatesDays = @{
            Value       = 0
            Description = "Maximum days security/quality updates may be deferred (DeferQualityUpdatesPeriodInDays). 0 means install as soon as available - feature updates aren't covered by this setting since they're a stability/operational tradeoff rather than a security one, but quality updates carry security fixes and shouldn't sit unpatched."
        }
    }
    PowerShellLogging = @{
        EnableScriptBlockLogging = @{
            Value       = $true
            Description = "Logs the full text of executed PowerShell script blocks (including deobfuscated content) to the PowerShell/Operational event log - the single highest-value PowerShell audit setting, since it's what actually shows what a script or attacker ran, not just that PowerShell was launched."
        }
        EnableModuleLogging = @{
            Value       = $true
            Description = "Logs pipeline execution details for PowerShell modules/snap-ins to the event log, scoped to all modules (see ModuleLoggingCoversAllModules)."
        }
        EnableTranscription = @{
            Value       = $true
            Description = "Writes a transcript of every PowerShell session (commands and output) to TranscriptOutputPath, independent of and complementary to script block logging."
        }
        TranscriptOutputPath = @{
            Value       = 'C:\ProgramData\SecurityBaseline\PowerShellTranscripts'
            Description = "Local folder where PowerShell session transcripts are written when EnableTranscription is on."
        }
    }
    RemovableStorage = @{
        DenyAllAccess = @{
            Value       = $true
            Description = "Blocks read/write/execute access to removable disks (USB mass storage) system-wide, not just auditing attempts at it (see AuditPolicy's 'Removable Storage' subcategory) - reduces the most common PHI exfiltration and malware-introduction path on a standalone device with no DLP tooling."
        }
    }
    UAC = @{
        EnableLUA = @{
            Value       = $true
            Description = "Keeps User Account Control itself turned on. Disabling this entirely removes UAC's split-token/elevation model, so every other Windows security boundary that assumes a non-elevated default session no longer applies."
        }
        ConsentPromptBehaviorAdmin = @{
            Value       = 2
            Description = "Requires administrators to consent to elevation on the secure desktop (2 = 'Prompt for consent on the secure desktop') rather than silently elevating (0) or prompting on the regular, spoofable desktop."
        }
        PromptOnSecureDesktop = @{
            Value       = $true
            Description = "Ensures the UAC consent/credential prompt itself renders on the secure desktop, where other processes can't inject input or overlay a fake prompt."
        }
    }
    NetworkHardening = @{
        LmCompatibilityLevel = @{
            Value       = 5
            Description = "Minimum acceptable LmCompatibilityLevel (0-5 scale; 5 = 'Send NTLMv2 response only, refuse LM and NTLM'). Rejects the legacy LM and NTLMv1 authentication protocols, both trivially crackable/relayable, while still allowing NTLMv2 for compatibility with non-Kerberos scenarios on a workgroup device."
        }
        DisableLLMNR = @{
            Value       = $true
            Description = "Disables Link-Local Multicast Name Resolution (LLMNR). LLMNR falls back to multicast DNS-style name resolution on the local subnet, which is spoofable by anyone else on the network (LLMNR/NBT-NS poisoning) to harvest NTLM hashes."
        }
    }
    EventLogRetention = @{
        MinimumMaxSizeBytes = @{
            Value       = 104857600
            Description = "Minimum maximum-size (100 MB) for the Application, Security, and System event logs. Windows' small default sizes (as low as 20 MB for Security) can roll over and silently discard audit history within hours on an active machine, defeating the audit trail AuditPolicy is configured to produce."
        }
    }
}
