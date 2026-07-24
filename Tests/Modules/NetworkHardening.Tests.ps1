# Tests/Modules/NetworkHardening.Tests.ps1
BeforeAll {
    Import-Module "$PSScriptRoot/../../Modules/NetworkHardening.psm1" -Force

    function New-TestConfig {
        @{
            LmCompatibilityLevel = @{ Value = 5; Description = 'NTLM restriction' }
            DisableLLMNR         = @{ Value = $true; Description = 'LLMNR' }
        }
    }
}

Describe 'Test-NetworkHardeningBaseline' {
    It 'passes LmCompatibilityLevel when the actual value meets or exceeds the configured minimum' {
        Mock -ModuleName NetworkHardening -CommandName Get-RegistryDwordOrDefault {
            param($Path, $Name, $Default)
            if ($Name -eq 'LmCompatibilityLevel') { return 5 }
            return 1
        }

        $results = Test-NetworkHardeningBaseline -Config (New-TestConfig)

        ($results | Where-Object Setting -eq 'LmCompatibilityLevel').Pass | Should -BeTrue
    }

    It 'flags LmCompatibilityLevel as non-compliant when below the configured minimum' {
        Mock -ModuleName NetworkHardening -CommandName Get-RegistryDwordOrDefault {
            param($Path, $Name, $Default)
            if ($Name -eq 'LmCompatibilityLevel') { return 1 }
            return 1
        }

        $results = Test-NetworkHardeningBaseline -Config (New-TestConfig)

        ($results | Where-Object Setting -eq 'LmCompatibilityLevel').Pass | Should -BeFalse
    }

    It 'flags LLMNR as non-compliant when multicast is still enabled' {
        Mock -ModuleName NetworkHardening -CommandName Get-RegistryDwordOrDefault {
            param($Path, $Name, $Default)
            if ($Name -eq 'EnableMulticast') { return 1 }
            return 5
        }

        $results = Test-NetworkHardeningBaseline -Config (New-TestConfig)

        ($results | Where-Object Setting -eq 'LLMNRDisabled').Pass | Should -BeFalse
    }

    It 'passes LLMNR when multicast is disabled' {
        Mock -ModuleName NetworkHardening -CommandName Get-RegistryDwordOrDefault {
            param($Path, $Name, $Default)
            if ($Name -eq 'EnableMulticast') { return 0 }
            return 5
        }

        $results = Test-NetworkHardeningBaseline -Config (New-TestConfig)

        ($results | Where-Object Setting -eq 'LLMNRDisabled').Pass | Should -BeTrue
    }
}

Describe 'Set-NetworkHardeningBaseline' {
    It 'only writes settings that are out of compliance' {
        Mock -ModuleName NetworkHardening -CommandName Get-RegistryDwordOrDefault {
            param($Path, $Name, $Default)
            if ($Name -eq 'LmCompatibilityLevel') { return 1 }
            if ($Name -eq 'EnableMulticast') { return 0 }
        }
        Mock -ModuleName NetworkHardening -CommandName Set-RegistryDword { }

        $changes = Set-NetworkHardeningBaseline -Config (New-TestConfig)

        ($changes | Where-Object Setting -eq 'LmCompatibilityLevel').Changed | Should -BeTrue
        ($changes | Where-Object Setting -eq 'LLMNRDisabled').Changed | Should -BeFalse
        Should -Invoke -ModuleName NetworkHardening -CommandName Set-RegistryDword -Times 1 -ParameterFilter { $Name -eq 'LmCompatibilityLevel' -and $Value -eq 5 }
    }

    It 'sets EnableMulticast to 0 to disable LLMNR' {
        Mock -ModuleName NetworkHardening -CommandName Get-RegistryDwordOrDefault {
            param($Path, $Name, $Default)
            if ($Name -eq 'LmCompatibilityLevel') { return 5 }
            if ($Name -eq 'EnableMulticast') { return 1 }
        }
        Mock -ModuleName NetworkHardening -CommandName Set-RegistryDword { }

        Set-NetworkHardeningBaseline -Config (New-TestConfig) | Out-Null

        Should -Invoke -ModuleName NetworkHardening -CommandName Set-RegistryDword -Times 1 -ParameterFilter { $Name -eq 'EnableMulticast' -and $Value -eq 0 }
    }
}

Describe 'Backup-NetworkHardeningSettings / Restore-NetworkHardeningSettings' {
    It 'removes values on restore when they did not exist at backup time' {
        Mock -ModuleName NetworkHardening -CommandName Test-RegistryValueExists { $false }
        Mock -ModuleName NetworkHardening -CommandName Get-RegistryDwordOrDefault { param($Path, $Name, $Default) $Default }

        $backupPath = Join-Path $TestDrive 'NetworkHardening'
        Backup-NetworkHardeningSettings -BackupPath $backupPath

        Mock -ModuleName NetworkHardening -CommandName Set-RegistryDword { }
        Mock -ModuleName NetworkHardening -CommandName Remove-RegistryValue { }

        Restore-NetworkHardeningSettings -BackupPath $backupPath

        Should -Invoke -ModuleName NetworkHardening -CommandName Remove-RegistryValue -Times 1 -ParameterFilter { $Name -eq 'LmCompatibilityLevel' }
        Should -Invoke -ModuleName NetworkHardening -CommandName Remove-RegistryValue -Times 1 -ParameterFilter { $Name -eq 'EnableMulticast' }
    }

    It 'restores the exact backed-up value when it existed' {
        Mock -ModuleName NetworkHardening -CommandName Test-RegistryValueExists { $true }
        Mock -ModuleName NetworkHardening -CommandName Get-RegistryDwordOrDefault {
            param($Path, $Name, $Default)
            if ($Name -eq 'LmCompatibilityLevel') { return 3 }
            return $Default
        }

        $backupPath = Join-Path $TestDrive 'NetworkHardeningExisting'
        Backup-NetworkHardeningSettings -BackupPath $backupPath

        Mock -ModuleName NetworkHardening -CommandName Set-RegistryDword { }
        Mock -ModuleName NetworkHardening -CommandName Remove-RegistryValue { }

        Restore-NetworkHardeningSettings -BackupPath $backupPath

        Should -Invoke -ModuleName NetworkHardening -CommandName Set-RegistryDword -Times 1 -ParameterFilter { $Name -eq 'LmCompatibilityLevel' -and $Value -eq 3 }
    }

    It 'throws when restoring without a prior backup' {
        { Restore-NetworkHardeningSettings -BackupPath (Join-Path $TestDrive 'missing') } | Should -Throw
    }
}
