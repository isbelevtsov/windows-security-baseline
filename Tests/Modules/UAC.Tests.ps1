# Tests/Modules/UAC.Tests.ps1
BeforeAll {
    Import-Module "$PSScriptRoot/../../Modules/UAC.psm1" -Force

    function New-TestConfig {
        @{
            EnableLUA                  = @{ Value = $true; Description = 'enable UAC' }
            ConsentPromptBehaviorAdmin = @{ Value = 2; Description = 'consent prompt' }
            PromptOnSecureDesktop      = @{ Value = $true; Description = 'secure desktop' }
        }
    }
}

Describe 'Test-UACBaseline' {
    It 'passes when all settings already match the configured baseline' {
        Mock -ModuleName UAC -CommandName Get-RegistryDwordOrDefault {
            param($Path, $Name, $Default)
            switch ($Name) {
                'EnableLUA' { 1 }
                'ConsentPromptBehaviorAdmin' { 2 }
                'PromptOnSecureDesktop' { 1 }
            }
        }

        $results = Test-UACBaseline -Config (New-TestConfig)

        ($results | Where-Object Pass -eq $false).Count | Should -Be 0
    }

    It 'flags EnableLUA as non-compliant when UAC is disabled' {
        Mock -ModuleName UAC -CommandName Get-RegistryDwordOrDefault {
            param($Path, $Name, $Default)
            if ($Name -eq 'EnableLUA') { return 0 }
            return $Default
        }

        $results = Test-UACBaseline -Config (New-TestConfig)

        ($results | Where-Object Setting -eq 'EnableLUA').Pass | Should -BeFalse
    }

    It 'flags ConsentPromptBehaviorAdmin as non-compliant when set to silently elevate' {
        Mock -ModuleName UAC -CommandName Get-RegistryDwordOrDefault {
            param($Path, $Name, $Default)
            if ($Name -eq 'ConsentPromptBehaviorAdmin') { return 0 }
            return $Default
        }

        $results = Test-UACBaseline -Config (New-TestConfig)

        ($results | Where-Object Setting -eq 'ConsentPromptBehaviorAdmin').Pass | Should -BeFalse
    }
}

Describe 'Set-UACBaseline' {
    It 'only writes settings that are out of compliance' {
        Mock -ModuleName UAC -CommandName Get-RegistryDwordOrDefault {
            param($Path, $Name, $Default)
            if ($Name -eq 'ConsentPromptBehaviorAdmin') { return 0 }
            return 1
        }
        Mock -ModuleName UAC -CommandName Set-RegistryDword { }

        $changes = Set-UACBaseline -Config (New-TestConfig)

        ($changes | Where-Object Setting -eq 'ConsentPromptBehaviorAdmin').Changed | Should -BeTrue
        ($changes | Where-Object Setting -eq 'EnableLUA').Changed | Should -BeFalse
        Should -Invoke -ModuleName UAC -CommandName Set-RegistryDword -Times 1 -ParameterFilter { $Name -eq 'ConsentPromptBehaviorAdmin' -and $Value -eq 2 }
    }
}

Describe 'Backup-UACSettings / Restore-UACSettings' {
    It 'removes values on restore when they did not exist at backup time' {
        Mock -ModuleName UAC -CommandName Test-RegistryValueExists { $false }
        Mock -ModuleName UAC -CommandName Get-RegistryDwordOrDefault { param($Path, $Name, $Default) $Default }

        $backupPath = Join-Path $TestDrive 'UAC'
        Backup-UACSettings -BackupPath $backupPath

        Mock -ModuleName UAC -CommandName Set-RegistryDword { }
        Mock -ModuleName UAC -CommandName Remove-RegistryValue { }

        Restore-UACSettings -BackupPath $backupPath

        Should -Invoke -ModuleName UAC -CommandName Remove-RegistryValue -Times 1 -ParameterFilter { $Name -eq 'EnableLUA' }
        Should -Invoke -ModuleName UAC -CommandName Remove-RegistryValue -Times 1 -ParameterFilter { $Name -eq 'ConsentPromptBehaviorAdmin' }
        Should -Invoke -ModuleName UAC -CommandName Remove-RegistryValue -Times 1 -ParameterFilter { $Name -eq 'PromptOnSecureDesktop' }
    }

    It 'restores the exact backed-up value when it existed' {
        Mock -ModuleName UAC -CommandName Test-RegistryValueExists { $true }
        Mock -ModuleName UAC -CommandName Get-RegistryDwordOrDefault {
            param($Path, $Name, $Default)
            if ($Name -eq 'ConsentPromptBehaviorAdmin') { return 5 }
            return $Default
        }

        $backupPath = Join-Path $TestDrive 'UACExisting'
        Backup-UACSettings -BackupPath $backupPath

        Mock -ModuleName UAC -CommandName Set-RegistryDword { }
        Mock -ModuleName UAC -CommandName Remove-RegistryValue { }

        Restore-UACSettings -BackupPath $backupPath

        Should -Invoke -ModuleName UAC -CommandName Set-RegistryDword -Times 1 -ParameterFilter { $Name -eq 'ConsentPromptBehaviorAdmin' -and $Value -eq 5 }
    }

    It 'throws when restoring without a prior backup' {
        { Restore-UACSettings -BackupPath (Join-Path $TestDrive 'missing') } | Should -Throw
    }
}
