# Tests/Modules/PowerShellLogging.Tests.ps1
BeforeAll {
    Import-Module "$PSScriptRoot/../../Modules/PowerShellLogging.psm1" -Force

    function New-TestConfig {
        @{
            EnableScriptBlockLogging = @{ Value = $true; Description = 'script block logging' }
            EnableModuleLogging      = @{ Value = $true; Description = 'module logging' }
            EnableTranscription      = @{ Value = $true; Description = 'transcription' }
            TranscriptOutputPath     = @{ Value = (Join-Path $TestDrive 'Transcripts'); Description = 'output path' }
        }
    }

    function Mock-AllCompliant {
        Mock -ModuleName PowerShellLogging -CommandName Get-RegistryDwordOrDefault { param($Path, $Name, $Default) 1 }
        Mock -ModuleName PowerShellLogging -CommandName Get-RegistryStringOrDefault {
            param($Path, $Name, $Default)
            if ($Name -eq '*') { return '*' }
            return (Join-Path $TestDrive 'Transcripts')
        }
    }
}

Describe 'Test-PowerShellLoggingBaseline' {
    It 'passes when everything is already configured' {
        Mock-AllCompliant

        $results = Test-PowerShellLoggingBaseline -Config (New-TestConfig)

        ($results | Where-Object Pass -eq $false).Count | Should -Be 0
    }

    It 'flags script block logging as non-compliant when disabled' {
        Mock -ModuleName PowerShellLogging -CommandName Get-RegistryDwordOrDefault { param($Path, $Name, $Default) 0 }
        Mock -ModuleName PowerShellLogging -CommandName Get-RegistryStringOrDefault { param($Path, $Name, $Default) $null }

        $results = Test-PowerShellLoggingBaseline -Config (New-TestConfig)

        ($results | Where-Object Setting -eq 'ScriptBlockLogging').Pass | Should -BeFalse
    }

    It 'flags module logging as covering all modules only when ModuleNames\* is "*"' {
        Mock -ModuleName PowerShellLogging -CommandName Get-RegistryDwordOrDefault { param($Path, $Name, $Default) 1 }
        Mock -ModuleName PowerShellLogging -CommandName Get-RegistryStringOrDefault {
            param($Path, $Name, $Default)
            if ($Name -eq '*') { return 'SomeSpecificModule' }
            return (Join-Path $TestDrive 'Transcripts')
        }

        $results = Test-PowerShellLoggingBaseline -Config (New-TestConfig)

        ($results | Where-Object Setting -eq 'ModuleLoggingCoversAllModules').Pass | Should -BeFalse
    }

    It 'flags transcription output path as non-compliant when it does not match the configured path' {
        Mock -ModuleName PowerShellLogging -CommandName Get-RegistryDwordOrDefault { param($Path, $Name, $Default) 1 }
        Mock -ModuleName PowerShellLogging -CommandName Get-RegistryStringOrDefault {
            param($Path, $Name, $Default)
            if ($Name -eq '*') { return '*' }
            return 'C:\SomewhereElse'
        }

        $results = Test-PowerShellLoggingBaseline -Config (New-TestConfig)

        ($results | Where-Object Setting -eq 'TranscriptOutputPath').Pass | Should -BeFalse
    }
}

Describe 'Set-PowerShellLoggingBaseline' {
    It 'only writes settings that are out of compliance' {
        Mock -ModuleName PowerShellLogging -CommandName Get-RegistryDwordOrDefault { param($Path, $Name, $Default) 0 }
        Mock -ModuleName PowerShellLogging -CommandName Get-RegistryStringOrDefault { param($Path, $Name, $Default) $null }
        Mock -ModuleName PowerShellLogging -CommandName Set-RegistryDword { }
        Mock -ModuleName PowerShellLogging -CommandName Set-RegistryString { }

        $changes = Set-PowerShellLoggingBaseline -Config (New-TestConfig)

        ($changes | Where-Object Setting -eq 'ScriptBlockLogging').Changed | Should -BeTrue
        Should -Invoke -ModuleName PowerShellLogging -CommandName Set-RegistryDword -Times 1 -ParameterFilter { $Name -eq 'EnableScriptBlockLogging' -and $Value -eq 1 }
        Should -Invoke -ModuleName PowerShellLogging -CommandName Set-RegistryString -Times 1 -ParameterFilter { $Name -eq '*' -and $Value -eq '*' }
        Should -Invoke -ModuleName PowerShellLogging -CommandName Set-RegistryDword -Times 1 -ParameterFilter { $Name -eq 'EnableTranscripting' -and $Value -eq 1 }
    }

    It 'creates the transcript output directory when it does not already exist' {
        Mock -ModuleName PowerShellLogging -CommandName Get-RegistryDwordOrDefault { param($Path, $Name, $Default) 1 }
        Mock -ModuleName PowerShellLogging -CommandName Get-RegistryStringOrDefault {
            param($Path, $Name, $Default)
            if ($Name -eq '*') { return '*' }
            return $null
        }
        Mock -ModuleName PowerShellLogging -CommandName Set-RegistryString { }

        $config = New-TestConfig
        $transcriptPath = Join-Path $TestDrive 'NewTranscripts'
        $config.TranscriptOutputPath.Value = $transcriptPath

        Set-PowerShellLoggingBaseline -Config $config | Out-Null

        Test-Path -Path $transcriptPath | Should -BeTrue
    }
}

Describe 'Backup-PowerShellLoggingSettings / Restore-PowerShellLoggingSettings' {
    It 'round-trips values, removing them on restore when they did not exist at backup time' {
        Mock -ModuleName PowerShellLogging -CommandName Test-RegistryValueExists { $false }
        Mock -ModuleName PowerShellLogging -CommandName Get-RegistryDwordOrDefault { param($Path, $Name, $Default) $Default }
        Mock -ModuleName PowerShellLogging -CommandName Get-RegistryStringOrDefault { param($Path, $Name, $Default) $Default }

        $backupPath = Join-Path $TestDrive 'PowerShellLogging'
        Backup-PowerShellLoggingSettings -BackupPath $backupPath

        Mock -ModuleName PowerShellLogging -CommandName Set-RegistryDword { }
        Mock -ModuleName PowerShellLogging -CommandName Set-RegistryString { }
        Mock -ModuleName PowerShellLogging -CommandName Remove-RegistryValue { }

        Restore-PowerShellLoggingSettings -BackupPath $backupPath

        Should -Invoke -ModuleName PowerShellLogging -CommandName Remove-RegistryValue -Times 1 -ParameterFilter { $Name -eq 'EnableScriptBlockLogging' }
        Should -Invoke -ModuleName PowerShellLogging -CommandName Remove-RegistryValue -Times 1 -ParameterFilter { $Name -eq 'EnableModuleLogging' }
        Should -Invoke -ModuleName PowerShellLogging -CommandName Remove-RegistryValue -Times 1 -ParameterFilter { $Name -eq '*' }
        Should -Invoke -ModuleName PowerShellLogging -CommandName Remove-RegistryValue -Times 1 -ParameterFilter { $Name -eq 'EnableTranscripting' }
        Should -Invoke -ModuleName PowerShellLogging -CommandName Remove-RegistryValue -Times 1 -ParameterFilter { $Name -eq 'OutputDirectory' }
    }

    It 'restores existing values with their exact backed-up value' {
        Mock -ModuleName PowerShellLogging -CommandName Test-RegistryValueExists -ParameterFilter { $Name -eq 'EnableScriptBlockLogging' } { $true }
        Mock -ModuleName PowerShellLogging -CommandName Test-RegistryValueExists -ParameterFilter { $Name -ne 'EnableScriptBlockLogging' } { $false }
        Mock -ModuleName PowerShellLogging -CommandName Get-RegistryDwordOrDefault {
            param($Path, $Name, $Default)
            if ($Name -eq 'EnableScriptBlockLogging') { return 1 }
            return $Default
        }
        Mock -ModuleName PowerShellLogging -CommandName Get-RegistryStringOrDefault { param($Path, $Name, $Default) $Default }

        $backupPath = Join-Path $TestDrive 'PowerShellLoggingExisting'
        Backup-PowerShellLoggingSettings -BackupPath $backupPath

        Mock -ModuleName PowerShellLogging -CommandName Set-RegistryDword { }
        Mock -ModuleName PowerShellLogging -CommandName Set-RegistryString { }
        Mock -ModuleName PowerShellLogging -CommandName Remove-RegistryValue { }

        Restore-PowerShellLoggingSettings -BackupPath $backupPath

        Should -Invoke -ModuleName PowerShellLogging -CommandName Set-RegistryDword -Times 1 -ParameterFilter { $Name -eq 'EnableScriptBlockLogging' -and $Value -eq 1 }
    }

    It 'throws when restoring without a prior backup' {
        { Restore-PowerShellLoggingSettings -BackupPath (Join-Path $TestDrive 'missing') } | Should -Throw
    }
}
