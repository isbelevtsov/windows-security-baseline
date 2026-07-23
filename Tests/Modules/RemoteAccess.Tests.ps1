BeforeAll {
    Import-Module "$PSScriptRoot/../../Modules/RemoteAccess.psm1" -Force

    function New-TestConfig {
        @{
            DisableRDP          = @{ Value = $true; Description = 'rdp' }
            DisableSMBv1        = @{ Value = $true; Description = 'smb1' }
            DisableGuestAccount = @{ Value = $true; Description = 'guest' }
        }
    }
}

Describe 'Test-RemoteAccessBaseline' {
    It 'flags RDP as non-compliant when it is not denied' {
        Mock -ModuleName RemoteAccess -CommandName Get-RdpDenyValue { $false }
        Mock -ModuleName RemoteAccess -CommandName Get-Smb1Enabled { $false }
        Mock -ModuleName RemoteAccess -CommandName Get-GuestAccountEnabled { $false }

        $results = Test-RemoteAccessBaseline -Config (New-TestConfig)

        ($results | Where-Object Setting -eq 'DisableRDP').Pass | Should -BeFalse
        ($results | Where-Object Setting -eq 'DisableSMBv1').Pass | Should -BeTrue
        ($results | Where-Object Setting -eq 'DisableGuestAccount').Pass | Should -BeTrue
    }
}

Describe 'Set-RemoteAccessBaseline' {
    It 'only touches settings that are out of compliance' {
        Mock -ModuleName RemoteAccess -CommandName Get-RdpDenyValue { $false }
        Mock -ModuleName RemoteAccess -CommandName Get-Smb1Enabled { $false }
        Mock -ModuleName RemoteAccess -CommandName Get-GuestAccountEnabled { $false }
        Mock -ModuleName RemoteAccess -CommandName Set-RdpDenyValue { }
        Mock -ModuleName RemoteAccess -CommandName Set-Smb1Enabled { }
        Mock -ModuleName RemoteAccess -CommandName Set-GuestAccountEnabled { }

        $changes = Set-RemoteAccessBaseline -Config (New-TestConfig)

        ($changes | Where-Object Setting -eq 'DisableRDP').Changed | Should -BeTrue
        Should -Invoke -ModuleName RemoteAccess -CommandName Set-RdpDenyValue -Times 1
        Should -Invoke -ModuleName RemoteAccess -CommandName Set-Smb1Enabled -Times 0
        Should -Invoke -ModuleName RemoteAccess -CommandName Set-GuestAccountEnabled -Times 0
    }

    It 'correctly inverts polarity when writing SMBv1 and Guest account state' {
        Mock -ModuleName RemoteAccess -CommandName Get-RdpDenyValue { $true }
        Mock -ModuleName RemoteAccess -CommandName Get-Smb1Enabled { $true }
        Mock -ModuleName RemoteAccess -CommandName Get-GuestAccountEnabled { $true }
        Mock -ModuleName RemoteAccess -CommandName Set-RdpDenyValue { }
        Mock -ModuleName RemoteAccess -CommandName Set-Smb1Enabled { }
        Mock -ModuleName RemoteAccess -CommandName Set-GuestAccountEnabled { }

        Set-RemoteAccessBaseline -Config (New-TestConfig) | Out-Null

        Should -Invoke -ModuleName RemoteAccess -CommandName Set-Smb1Enabled -Times 1 -ParameterFilter { $Enabled -eq $false }
        Should -Invoke -ModuleName RemoteAccess -CommandName Set-GuestAccountEnabled -Times 1 -ParameterFilter { $Enabled -eq $false }
        Should -Invoke -ModuleName RemoteAccess -CommandName Set-RdpDenyValue -Times 0
    }
}

Describe 'Backup-RemoteAccessSettings / Restore-RemoteAccessSettings' {
    It 'round-trips SMB1/Guest state and the RDP deny value without a full registry export/import' {
        # Regression test for a real failure on Windows hardware: backing up
        # via a full `reg export` of the Terminal Server key and restoring via
        # `reg import` failed with "Error accessing the registry", because
        # that key tree includes subkeys owned by the actively-running
        # Terminal Services listener that reg.exe cannot overwrite while the
        # service holds them open. Only the single fDenyTSConnections value
        # should round-trip.
        Mock -ModuleName RemoteAccess -CommandName Get-RdpDenyRawValue { 1 }
        Mock -ModuleName RemoteAccess -CommandName Get-Smb1Enabled { $false }
        Mock -ModuleName RemoteAccess -CommandName Get-GuestAccountEnabled { $false }
        Mock -ModuleName RemoteAccess -CommandName Set-Smb1Enabled { }
        Mock -ModuleName RemoteAccess -CommandName Set-GuestAccountEnabled { }
        Mock -ModuleName RemoteAccess -CommandName Remove-RdpDenyValue { }
        InModuleScope -ModuleName RemoteAccess {
            Mock -CommandName Set-ItemProperty -ParameterFilter { $Name -eq 'fDenyTSConnections' } { }
        }

        $backupPath = Join-Path $TestDrive 'RemoteAccess'
        Backup-RemoteAccessSettings -BackupPath $backupPath
        Restore-RemoteAccessSettings -BackupPath $backupPath

        Should -Invoke -ModuleName RemoteAccess -CommandName Set-Smb1Enabled -Times 1 -ParameterFilter { $Enabled -eq $false }
        Should -Invoke -ModuleName RemoteAccess -CommandName Set-GuestAccountEnabled -Times 1 -ParameterFilter { $Enabled -eq $false }
        Should -Invoke -ModuleName RemoteAccess -CommandName Remove-RdpDenyValue -Times 0
        InModuleScope -ModuleName RemoteAccess {
            Should -Invoke -CommandName Set-ItemProperty -ParameterFilter { $Name -eq 'fDenyTSConnections' -and $Value -eq 1 } -Times 1
        }
    }

    It 'removes the RDP deny value on restore when it did not exist at backup time' {
        Mock -ModuleName RemoteAccess -CommandName Get-RdpDenyRawValue { $null }
        Mock -ModuleName RemoteAccess -CommandName Get-Smb1Enabled { $false }
        Mock -ModuleName RemoteAccess -CommandName Get-GuestAccountEnabled { $false }
        Mock -ModuleName RemoteAccess -CommandName Set-Smb1Enabled { }
        Mock -ModuleName RemoteAccess -CommandName Set-GuestAccountEnabled { }
        Mock -ModuleName RemoteAccess -CommandName Remove-RdpDenyValue { }

        $backupPath = Join-Path $TestDrive 'RemoteAccessNoRdp'
        Backup-RemoteAccessSettings -BackupPath $backupPath
        Restore-RemoteAccessSettings -BackupPath $backupPath

        Should -Invoke -ModuleName RemoteAccess -CommandName Remove-RdpDenyValue -Times 1
    }

    It 'throws when restoring without a prior backup' {
        { Restore-RemoteAccessSettings -BackupPath (Join-Path $TestDrive 'missing') } | Should -Throw
    }
}
