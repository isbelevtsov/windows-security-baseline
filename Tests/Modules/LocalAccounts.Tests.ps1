# Tests/Modules/LocalAccounts.Tests.ps1
BeforeAll {
    Import-Module "$PSScriptRoot/../../Modules/LocalAccounts.psm1" -Force

    function New-TestConfig {
        @{
            DisableAutoLogon              = @{ Value = $true; Description = 'autologon' }
            RequirePasswordForAllAccounts = @{ Value = $true; Description = 'password required' }
            TemporaryPasswordPath         = @{ Value = (Join-Path $TestDrive 'TemporaryPasswords'); Description = 'temp password path' }
            DisablePasswordNeverExpires   = @{ Value = $true; Description = 'password never expires' }
        }
    }
}

Describe 'New-CompliantTemporaryPassword' {
    It 'generates a 24-character password covering all four character classes' {
        $password = InModuleScope -ModuleName LocalAccounts { New-CompliantTemporaryPassword }

        $password.Length | Should -Be 24
        $password | Should -Match '[A-Z]'
        $password | Should -Match '[a-z]'
        $password | Should -Match '[0-9]'
        $password | Should -Match '[^A-Za-z0-9]'
    }

    It 'generates a different password on each call' {
        $first = InModuleScope -ModuleName LocalAccounts { New-CompliantTemporaryPassword }
        $second = InModuleScope -ModuleName LocalAccounts { New-CompliantTemporaryPassword }

        $first | Should -Not -Be $second
    }
}

Describe 'Test-LocalAccountsBaseline' {
    It 'flags autologon as non-compliant when enabled' {
        Mock -ModuleName LocalAccounts -CommandName Get-AutoLogonEnabled { $true }
        Mock -ModuleName LocalAccounts -CommandName Get-ManagedLocalUsers { @() }

        $results = Test-LocalAccountsBaseline -Config (New-TestConfig)

        ($results | Where-Object Setting -eq 'AutoLogonDisabled').Pass | Should -BeFalse
    }

    It 'passes when autologon is disabled and there are no enabled local users' {
        Mock -ModuleName LocalAccounts -CommandName Get-AutoLogonEnabled { $false }
        Mock -ModuleName LocalAccounts -CommandName Get-ManagedLocalUsers { @() }

        $results = @(Test-LocalAccountsBaseline -Config (New-TestConfig))

        $results.Count | Should -Be 1
        $results[0].Pass | Should -BeTrue
    }

    It 'flags an enabled account that does not require a password' {
        Mock -ModuleName LocalAccounts -CommandName Get-AutoLogonEnabled { $false }
        Mock -ModuleName LocalAccounts -CommandName Get-ManagedLocalUsers {
            @([PSCustomObject]@{ Name = 'alice'; PasswordRequired = $false })
        }
        Mock -ModuleName LocalAccounts -CommandName Get-LocalUserPasswordNeverExpires { $false }

        $results = Test-LocalAccountsBaseline -Config (New-TestConfig)

        ($results | Where-Object Setting -eq 'alice.PasswordRequired').Pass | Should -BeFalse
    }

    It 'passes for an enabled account that already requires a password' {
        Mock -ModuleName LocalAccounts -CommandName Get-AutoLogonEnabled { $false }
        Mock -ModuleName LocalAccounts -CommandName Get-ManagedLocalUsers {
            @([PSCustomObject]@{ Name = 'alice'; PasswordRequired = $true })
        }
        Mock -ModuleName LocalAccounts -CommandName Get-LocalUserPasswordNeverExpires { $false }

        $results = Test-LocalAccountsBaseline -Config (New-TestConfig)

        ($results | Where-Object Setting -eq 'alice.PasswordRequired').Pass | Should -BeTrue
    }

    It 'flags an enabled account that has "password never expires" set' {
        # Regression test for a real failure on Windows hardware: an
        # account can already be PasswordRequired=True (e.g. from a prior
        # Apply run) while still having "Password never expires" set from
        # before this baseline ever touched it - and that combination
        # silently defeats any future forced password change on that
        # account, so it must be checked independently rather than only
        # as a side effect of remediating PasswordRequired.
        Mock -ModuleName LocalAccounts -CommandName Get-AutoLogonEnabled { $false }
        Mock -ModuleName LocalAccounts -CommandName Get-ManagedLocalUsers {
            @([PSCustomObject]@{ Name = 'alice'; PasswordRequired = $true })
        }
        Mock -ModuleName LocalAccounts -CommandName Get-LocalUserPasswordNeverExpires { $true }

        $results = Test-LocalAccountsBaseline -Config (New-TestConfig)

        ($results | Where-Object Setting -eq 'alice.PasswordNeverExpires').Pass | Should -BeFalse
    }

    It 'passes for an enabled account without "password never expires" set' {
        Mock -ModuleName LocalAccounts -CommandName Get-AutoLogonEnabled { $false }
        Mock -ModuleName LocalAccounts -CommandName Get-ManagedLocalUsers {
            @([PSCustomObject]@{ Name = 'alice'; PasswordRequired = $true })
        }
        Mock -ModuleName LocalAccounts -CommandName Get-LocalUserPasswordNeverExpires { $false }

        $results = Test-LocalAccountsBaseline -Config (New-TestConfig)

        ($results | Where-Object Setting -eq 'alice.PasswordNeverExpires').Pass | Should -BeTrue
    }
}

Describe 'Set-LocalAccountsBaseline' {
    It 'disables autologon when non-compliant and notes a removed plaintext password' {
        Mock -ModuleName LocalAccounts -CommandName Get-AutoLogonEnabled { $true }
        Mock -ModuleName LocalAccounts -CommandName Get-AutoLogonDefaultPasswordExists { $true }
        Mock -ModuleName LocalAccounts -CommandName Disable-AutoLogon { }
        Mock -ModuleName LocalAccounts -CommandName Get-ManagedLocalUsers { @() }

        $changes = Set-LocalAccountsBaseline -Config (New-TestConfig)

        $autoLogonChange = $changes | Where-Object Setting -eq 'AutoLogonDisabled'
        $autoLogonChange.Changed | Should -BeTrue
        $autoLogonChange.Note | Should -Match 'plaintext'
        Should -Invoke -ModuleName LocalAccounts -CommandName Disable-AutoLogon -Times 1
    }

    It 'disables autologon without a plaintext-password note when none was stored' {
        Mock -ModuleName LocalAccounts -CommandName Get-AutoLogonEnabled { $true }
        Mock -ModuleName LocalAccounts -CommandName Get-AutoLogonDefaultPasswordExists { $false }
        Mock -ModuleName LocalAccounts -CommandName Disable-AutoLogon { }
        Mock -ModuleName LocalAccounts -CommandName Get-ManagedLocalUsers { @() }

        $changes = Set-LocalAccountsBaseline -Config (New-TestConfig)

        ($changes | Where-Object Setting -eq 'AutoLogonDisabled').Note | Should -BeNullOrEmpty
    }

    It 'does nothing to autologon when already disabled' {
        Mock -ModuleName LocalAccounts -CommandName Get-AutoLogonEnabled { $false }
        Mock -ModuleName LocalAccounts -CommandName Disable-AutoLogon { }
        Mock -ModuleName LocalAccounts -CommandName Get-ManagedLocalUsers { @() }

        $changes = Set-LocalAccountsBaseline -Config (New-TestConfig)

        ($changes | Where-Object Setting -eq 'AutoLogonDisabled').Changed | Should -BeFalse
        Should -Invoke -ModuleName LocalAccounts -CommandName Disable-AutoLogon -Times 0
    }

    It 'sets a temporary password, forces a change at next logon, and writes the password to a file' {
        # Regression test for a real failure found on a rebooted VM: forcing
        # only "must change password at next logon" was not enough - a
        # genuinely blank-password account never showed a change prompt at
        # the logon screen, since Windows' blank-password logon path doesn't
        # always route through the credential-entry step that flag relies
        # on. Invalidating the blank password immediately with a real
        # temporary one is the only unconditional fix.
        Mock -ModuleName LocalAccounts -CommandName Get-AutoLogonEnabled { $false }
        Mock -ModuleName LocalAccounts -CommandName Get-ManagedLocalUsers {
            @([PSCustomObject]@{ Name = 'alice'; PasswordRequired = $false })
        }
        Mock -ModuleName LocalAccounts -CommandName Get-LocalUserPasswordNeverExpires { $false }
        Mock -ModuleName LocalAccounts -CommandName New-CompliantTemporaryPassword { 'Tmp-Passw0rd!12345678' }
        Mock -ModuleName LocalAccounts -CommandName Set-LocalUserTemporaryPassword { }
        Mock -ModuleName LocalAccounts -CommandName Set-LocalUserRequiresPassword { }
        Mock -ModuleName LocalAccounts -CommandName Set-LocalUserPasswordExpired { }

        $changes = Set-LocalAccountsBaseline -Config (New-TestConfig)

        $userChange = $changes | Where-Object Setting -eq 'alice.PasswordRequired'
        $userChange.Changed | Should -BeTrue
        $userChange.Note | Should -Match 'blank password'
        $userChange.Note | Should -Match 'temporary password'
        Should -Invoke -ModuleName LocalAccounts -CommandName Set-LocalUserTemporaryPassword -Times 1 -ParameterFilter { $Name -eq 'alice' }
        Should -Invoke -ModuleName LocalAccounts -CommandName Set-LocalUserRequiresPassword -Times 1 -ParameterFilter { $Name -eq 'alice' }
        Should -Invoke -ModuleName LocalAccounts -CommandName Set-LocalUserPasswordExpired -Times 1 -ParameterFilter { $Name -eq 'alice' }

        $tempPasswordFile = Join-Path (Join-Path $TestDrive 'TemporaryPasswords') 'alice-temp-password.txt'
        Test-Path -Path $tempPasswordFile | Should -BeTrue
        Get-Content -Path $tempPasswordFile -Raw | Should -Match 'Tmp-Passw0rd!12345678'
        $userChange.Note | Should -Match ([regex]::Escape($tempPasswordFile))
    }

    It 'still forces the password change and reports partial success when PasswordRequired cannot yet be set' {
        # Regression test for a real failure on Windows hardware: Set-LocalUser
        # has no -PasswordRequired parameter at all (confirmed via
        # Get-Command -Syntax), and the ADSI equivalent throws "The password
        # does not meet the password policy requirements" when the account's
        # CURRENT password doesn't satisfy the active policy. Even with the
        # temporary-password fix above, this is kept as defense in depth -
        # forcing the password change must still happen and must not be
        # skipped just because the PasswordRequired flip can't succeed yet.
        Mock -ModuleName LocalAccounts -CommandName Get-AutoLogonEnabled { $false }
        Mock -ModuleName LocalAccounts -CommandName Get-ManagedLocalUsers {
            @([PSCustomObject]@{ Name = 'alice'; PasswordRequired = $false })
        }
        Mock -ModuleName LocalAccounts -CommandName Get-LocalUserPasswordNeverExpires { $false }
        Mock -ModuleName LocalAccounts -CommandName New-CompliantTemporaryPassword { 'Tmp-Passw0rd!12345678' }
        Mock -ModuleName LocalAccounts -CommandName Set-LocalUserTemporaryPassword { }
        Mock -ModuleName LocalAccounts -CommandName Set-LocalUserRequiresPassword { throw 'The password does not meet the password policy requirements.' }
        Mock -ModuleName LocalAccounts -CommandName Set-LocalUserPasswordExpired { }

        $changes = Set-LocalAccountsBaseline -Config (New-TestConfig)

        $userChange = $changes | Where-Object Setting -eq 'alice.PasswordRequired'
        $userChange.Changed | Should -BeTrue
        $userChange.After | Should -BeFalse
        $userChange.Note | Should -Match 'blank password'
        $userChange.Note | Should -Match 'later Apply run'
        Should -Invoke -ModuleName LocalAccounts -CommandName Set-LocalUserTemporaryPassword -Times 1 -ParameterFilter { $Name -eq 'alice' }
        Should -Invoke -ModuleName LocalAccounts -CommandName Set-LocalUserPasswordExpired -Times 1 -ParameterFilter { $Name -eq 'alice' }
    }

    It 'does not touch an account that already requires a password' {
        Mock -ModuleName LocalAccounts -CommandName Get-AutoLogonEnabled { $false }
        Mock -ModuleName LocalAccounts -CommandName Get-ManagedLocalUsers {
            @([PSCustomObject]@{ Name = 'alice'; PasswordRequired = $true })
        }
        Mock -ModuleName LocalAccounts -CommandName Get-LocalUserPasswordNeverExpires { $false }
        Mock -ModuleName LocalAccounts -CommandName Set-LocalUserRequiresPassword { }
        Mock -ModuleName LocalAccounts -CommandName Set-LocalUserPasswordExpired { }

        $changes = Set-LocalAccountsBaseline -Config (New-TestConfig)

        ($changes | Where-Object Setting -eq 'alice.PasswordRequired').Changed | Should -BeFalse
        Should -Invoke -ModuleName LocalAccounts -CommandName Set-LocalUserRequiresPassword -Times 0
        Should -Invoke -ModuleName LocalAccounts -CommandName Set-LocalUserPasswordExpired -Times 0
    }

    It 'clears "password never expires" for an account that already requires a password but still has it set' {
        # Regression test for the real failure this session started from:
        # the 'user' account was already PasswordRequired=True from a prior
        # Apply run, so the PasswordRequired remediation branch never ran
        # again - but it still had "Password never expires" set, which
        # silently defeated the forced password change. This must be
        # remediated on its own, independent of PasswordRequired's state.
        Mock -ModuleName LocalAccounts -CommandName Get-AutoLogonEnabled { $false }
        Mock -ModuleName LocalAccounts -CommandName Get-ManagedLocalUsers {
            @([PSCustomObject]@{ Name = 'alice'; PasswordRequired = $true })
        }
        Mock -ModuleName LocalAccounts -CommandName Get-LocalUserPasswordNeverExpires { $true }
        Mock -ModuleName LocalAccounts -CommandName Clear-LocalUserPasswordNeverExpires { }
        Mock -ModuleName LocalAccounts -CommandName Set-LocalUserPasswordExpired { }

        $changes = Set-LocalAccountsBaseline -Config (New-TestConfig)

        $neverExpiresChange = $changes | Where-Object Setting -eq 'alice.PasswordNeverExpires'
        $neverExpiresChange.Changed | Should -BeTrue
        $neverExpiresChange.Note | Should -Match 'defeats'
        Should -Invoke -ModuleName LocalAccounts -CommandName Clear-LocalUserPasswordNeverExpires -Times 1 -ParameterFilter { $Name -eq 'alice' }
        # PasswordExpired must be re-forced here too - the earlier attempt
        # already consumed it (Windows cleared it back to 0 on the logon
        # that "Password never expires" silently let through), so clearing
        # PasswordNeverExpires alone would leave nothing to prompt at the
        # next logon.
        Should -Invoke -ModuleName LocalAccounts -CommandName Set-LocalUserPasswordExpired -Times 1 -ParameterFilter { $Name -eq 'alice' }
    }

    It 'does not touch an account that already has "password never expires" cleared' {
        Mock -ModuleName LocalAccounts -CommandName Get-AutoLogonEnabled { $false }
        Mock -ModuleName LocalAccounts -CommandName Get-ManagedLocalUsers {
            @([PSCustomObject]@{ Name = 'alice'; PasswordRequired = $true })
        }
        Mock -ModuleName LocalAccounts -CommandName Get-LocalUserPasswordNeverExpires { $false }
        Mock -ModuleName LocalAccounts -CommandName Clear-LocalUserPasswordNeverExpires { }

        $changes = Set-LocalAccountsBaseline -Config (New-TestConfig)

        ($changes | Where-Object Setting -eq 'alice.PasswordNeverExpires').Changed | Should -BeFalse
        Should -Invoke -ModuleName LocalAccounts -CommandName Clear-LocalUserPasswordNeverExpires -Times 0
    }
}

Describe 'Backup-LocalAccountsSettings / Restore-LocalAccountsSettings' {
    It 'round-trips autologon registry values and per-user PasswordRequired state without ever touching DefaultPassword' {
        InModuleScope -ModuleName LocalAccounts {
            Mock -CommandName Get-ItemProperty -ParameterFilter { $Name -eq 'AutoAdminLogon' } { [PSCustomObject]@{ AutoAdminLogon = '0' } }
            Mock -CommandName Get-ItemProperty -ParameterFilter { $Name -eq 'DefaultUserName' } { [PSCustomObject]@{ DefaultUserName = 'alice' } }
            Mock -CommandName Get-ItemProperty -ParameterFilter { $Name -eq 'DefaultDomainName' } { $null }
        }
        Mock -ModuleName LocalAccounts -CommandName Get-ManagedLocalUsers {
            @([PSCustomObject]@{ Name = 'alice'; PasswordRequired = $true }, [PSCustomObject]@{ Name = 'bob'; PasswordRequired = $false })
        }

        $backupPath = Join-Path $TestDrive 'LocalAccounts'
        Backup-LocalAccountsSettings -BackupPath $backupPath

        $raw = Get-Content -Path (Join-Path $backupPath 'local-accounts-state.json') -Raw
        $raw | Should -Not -Match 'DefaultPassword'

        InModuleScope -ModuleName LocalAccounts {
            Mock -CommandName Set-ItemProperty { }
            Mock -CommandName Remove-ItemProperty { }
        }
        Mock -ModuleName LocalAccounts -CommandName Set-LocalUserRequiresPassword { }

        Restore-LocalAccountsSettings -BackupPath $backupPath

        InModuleScope -ModuleName LocalAccounts {
            Should -Invoke -CommandName Set-ItemProperty -Times 1 -ParameterFilter { $Name -eq 'AutoAdminLogon' -and $Value -eq '0' }
            Should -Invoke -CommandName Set-ItemProperty -Times 1 -ParameterFilter { $Name -eq 'DefaultUserName' -and $Value -eq 'alice' }
            Should -Invoke -CommandName Set-ItemProperty -Times 0 -ParameterFilter { $Name -eq 'DefaultPassword' }
        }
        Should -Invoke -ModuleName LocalAccounts -CommandName Set-LocalUserRequiresPassword -Times 1 -ParameterFilter { $Name -eq 'alice' }
        Should -Invoke -ModuleName LocalAccounts -CommandName Set-LocalUserRequiresPassword -Times 0 -ParameterFilter { $Name -eq 'bob' }
    }

    It 'removes the AutoAdminLogon value on restore when it did not exist at backup time' {
        InModuleScope -ModuleName LocalAccounts {
            Mock -CommandName Get-ItemProperty { $null }
        }
        Mock -ModuleName LocalAccounts -CommandName Get-ManagedLocalUsers { @() }

        $backupPath = Join-Path $TestDrive 'LocalAccountsNoAutoLogon'
        Backup-LocalAccountsSettings -BackupPath $backupPath

        InModuleScope -ModuleName LocalAccounts {
            Mock -CommandName Set-ItemProperty { }
            Mock -CommandName Remove-ItemProperty { }
        }

        Restore-LocalAccountsSettings -BackupPath $backupPath

        InModuleScope -ModuleName LocalAccounts {
            Should -Invoke -CommandName Remove-ItemProperty -Times 1 -ParameterFilter { $Name -eq 'AutoAdminLogon' }
        }
    }

    It 'throws when restoring without a prior backup' {
        { Restore-LocalAccountsSettings -BackupPath (Join-Path $TestDrive 'missing') } | Should -Throw
    }
}
