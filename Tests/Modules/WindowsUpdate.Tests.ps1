# Tests/Modules/WindowsUpdate.Tests.ps1
BeforeAll {
    Import-Module "$PSScriptRoot/../../Modules/WindowsUpdate.psm1" -Force

    function New-TestConfig {
        @{
            AutomaticUpdatesEnabled = @{ Value = $true; Description = 'auto updates' }
            DeferQualityUpdatesDays = @{ Value = 0; Description = 'defer days' }
        }
    }
}

Describe 'Test-WindowsUpdateBaseline' {
    It 'flags the service as non-compliant when disabled' {
        Mock -ModuleName WindowsUpdate -CommandName Get-WindowsUpdateServiceStartType { 'Disabled' }
        Mock -ModuleName WindowsUpdate -CommandName Get-RegistryDwordOrDefault { param($Path, $Name, $Default) $Default }

        $results = Test-WindowsUpdateBaseline -Config (New-TestConfig)

        ($results | Where-Object Setting -eq 'ServiceNotDisabled').Pass | Should -BeFalse
    }

    It 'passes the service when not disabled' {
        Mock -ModuleName WindowsUpdate -CommandName Get-WindowsUpdateServiceStartType { 'Manual' }
        Mock -ModuleName WindowsUpdate -CommandName Get-RegistryDwordOrDefault { param($Path, $Name, $Default) $Default }

        $results = Test-WindowsUpdateBaseline -Config (New-TestConfig)

        ($results | Where-Object Setting -eq 'ServiceNotDisabled').Pass | Should -BeTrue
    }

    It 'defaults to compliant values when no policy registry keys exist yet' {
        # Confirmed on real hardware: a standalone device with no policy ever
        # configured has none of these registry values at all, and Windows'
        # own out-of-box behavior in that state is automatic download+install
        # - so an unconfigured machine should read as compliant, not fail
        # until this module has run once.
        Mock -ModuleName WindowsUpdate -CommandName Get-WindowsUpdateServiceStartType { 'Manual' }
        Mock -ModuleName WindowsUpdate -CommandName Get-RegistryDwordOrDefault { param($Path, $Name, $Default) $Default }

        $results = Test-WindowsUpdateBaseline -Config (New-TestConfig)

        ($results | Where-Object Setting -eq 'AutomaticUpdatesEnabled').Pass | Should -BeTrue
        ($results | Where-Object Setting -eq 'AutoDownloadAndInstall').Pass | Should -BeTrue
        ($results | Where-Object Setting -eq 'DeferQualityUpdatesDays').Pass | Should -BeTrue
    }

    It 'flags NoAutoUpdate when set to disable automatic updates' {
        Mock -ModuleName WindowsUpdate -CommandName Get-WindowsUpdateServiceStartType { 'Manual' }
        Mock -ModuleName WindowsUpdate -CommandName Get-RegistryDwordOrDefault {
            param($Path, $Name, $Default)
            if ($Name -eq 'NoAutoUpdate') { return 1 }
            return $Default
        }

        $results = Test-WindowsUpdateBaseline -Config (New-TestConfig)

        ($results | Where-Object Setting -eq 'AutomaticUpdatesEnabled').Pass | Should -BeFalse
    }

    It 'passes DeferQualityUpdatesDays when the actual deferral is less than the configured maximum' {
        Mock -ModuleName WindowsUpdate -CommandName Get-WindowsUpdateServiceStartType { 'Manual' }
        Mock -ModuleName WindowsUpdate -CommandName Get-RegistryDwordOrDefault { param($Path, $Name, $Default) $Default }

        $config = New-TestConfig
        $config.DeferQualityUpdatesDays.Value = 5

        $results = Test-WindowsUpdateBaseline -Config $config

        ($results | Where-Object Setting -eq 'DeferQualityUpdatesDays').Pass | Should -BeTrue
    }
}

Describe 'Set-WindowsUpdateBaseline' {
    It 'only touches settings that are out of compliance' {
        Mock -ModuleName WindowsUpdate -CommandName Get-WindowsUpdateServiceStartType { 'Disabled' }
        Mock -ModuleName WindowsUpdate -CommandName Get-RegistryDwordOrDefault { param($Path, $Name, $Default) $Default }
        Mock -ModuleName WindowsUpdate -CommandName Set-WindowsUpdateServiceStartType { }
        Mock -ModuleName WindowsUpdate -CommandName Set-RegistryDword { }

        $changes = Set-WindowsUpdateBaseline -Config (New-TestConfig)

        ($changes | Where-Object Setting -eq 'ServiceNotDisabled').Changed | Should -BeTrue
        ($changes | Where-Object Setting -eq 'AutomaticUpdatesEnabled').Changed | Should -BeFalse
        Should -Invoke -ModuleName WindowsUpdate -CommandName Set-WindowsUpdateServiceStartType -Times 1 -ParameterFilter { $StartupType -eq 'Manual' }
        Should -Invoke -ModuleName WindowsUpdate -CommandName Set-RegistryDword -Times 0
    }
}

Describe 'Backup-WindowsUpdateSettings / Restore-WindowsUpdateSettings' {
    It 'round-trips all values, removing them on restore when they did not exist at backup time' {
        Mock -ModuleName WindowsUpdate -CommandName Get-WindowsUpdateServiceStartType { 'Manual' }
        Mock -ModuleName WindowsUpdate -CommandName Test-RegistryValueExists { $false }
        Mock -ModuleName WindowsUpdate -CommandName Get-RegistryDwordOrDefault { param($Path, $Name, $Default) $Default }

        $backupPath = Join-Path $TestDrive 'WindowsUpdate'
        Backup-WindowsUpdateSettings -BackupPath $backupPath

        Mock -ModuleName WindowsUpdate -CommandName Set-WindowsUpdateServiceStartType { }
        Mock -ModuleName WindowsUpdate -CommandName Set-RegistryDword { }
        Mock -ModuleName WindowsUpdate -CommandName Remove-RegistryValue { }

        Restore-WindowsUpdateSettings -BackupPath $backupPath

        Should -Invoke -ModuleName WindowsUpdate -CommandName Set-WindowsUpdateServiceStartType -Times 1 -ParameterFilter { $StartupType -eq 'Manual' }
        Should -Invoke -ModuleName WindowsUpdate -CommandName Remove-RegistryValue -Times 1 -ParameterFilter { $Name -eq 'NoAutoUpdate' }
        Should -Invoke -ModuleName WindowsUpdate -CommandName Remove-RegistryValue -Times 1 -ParameterFilter { $Name -eq 'AUOptions' }
        Should -Invoke -ModuleName WindowsUpdate -CommandName Remove-RegistryValue -Times 1 -ParameterFilter { $Name -eq 'DeferQualityUpdatesPeriodInDays' }
        Should -Invoke -ModuleName WindowsUpdate -CommandName Set-RegistryDword -Times 0
    }

    It 'restores existing values with their exact backed-up value' {
        Mock -ModuleName WindowsUpdate -CommandName Get-WindowsUpdateServiceStartType { 'Manual' }
        Mock -ModuleName WindowsUpdate -CommandName Test-RegistryValueExists -ParameterFilter { $Name -eq 'NoAutoUpdate' } { $true }
        Mock -ModuleName WindowsUpdate -CommandName Test-RegistryValueExists -ParameterFilter { $Name -ne 'NoAutoUpdate' } { $false }
        Mock -ModuleName WindowsUpdate -CommandName Get-RegistryDwordOrDefault {
            param($Path, $Name, $Default)
            if ($Name -eq 'NoAutoUpdate') { return 1 }
            return $Default
        }

        $backupPath = Join-Path $TestDrive 'WindowsUpdateExisting'
        Backup-WindowsUpdateSettings -BackupPath $backupPath

        Mock -ModuleName WindowsUpdate -CommandName Set-WindowsUpdateServiceStartType { }
        Mock -ModuleName WindowsUpdate -CommandName Set-RegistryDword { }
        Mock -ModuleName WindowsUpdate -CommandName Remove-RegistryValue { }

        Restore-WindowsUpdateSettings -BackupPath $backupPath

        Should -Invoke -ModuleName WindowsUpdate -CommandName Set-RegistryDword -Times 1 -ParameterFilter { $Name -eq 'NoAutoUpdate' -and $Value -eq 1 }
    }

    It 'throws when restoring without a prior backup' {
        { Restore-WindowsUpdateSettings -BackupPath (Join-Path $TestDrive 'missing') } | Should -Throw
    }
}
