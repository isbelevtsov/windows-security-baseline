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
