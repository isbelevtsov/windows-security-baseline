BeforeAll {
    Import-Module "$PSScriptRoot/../../Modules/Defender.psm1" -Force

    function New-TestConfig {
        @{
            RealTimeProtection = @{ Value = $true; Description = 'rtp' }
            CloudProtection    = @{ Value = $true; Description = 'cloud' }
            PUAProtection      = @{ Value = 'Enabled'; Description = 'pua' }
        }
    }
}

Describe 'Test-DefenderBaseline' {
    It 'reports Pass=$true for every setting when live state already matches config' {
        Mock -ModuleName Defender -CommandName Get-DefenderPreference {
            [PSCustomObject]@{ DisableRealtimeMonitoring = $false; MAPSReporting = 2; PUAProtection = 1 }
        }
        $results = Test-DefenderBaseline -Config (New-TestConfig)
        @($results | Where-Object { -not $_.Pass }).Count | Should -Be 0
    }

    It 'reports Pass=$false when real-time protection is disabled' {
        Mock -ModuleName Defender -CommandName Get-DefenderPreference {
            [PSCustomObject]@{ DisableRealtimeMonitoring = $true; MAPSReporting = 2; PUAProtection = 1 }
        }
        $results = Test-DefenderBaseline -Config (New-TestConfig)
        ($results | Where-Object Setting -eq 'RealTimeProtection').Pass | Should -BeFalse
    }
}

Describe 'Set-DefenderBaseline' {
    It 'only calls Set-DefenderPreference for settings that are out of compliance' {
        Mock -ModuleName Defender -CommandName Get-DefenderPreference {
            [PSCustomObject]@{ DisableRealtimeMonitoring = $true; MAPSReporting = 2; PUAProtection = 1 }
        }
        Mock -ModuleName Defender -CommandName Set-DefenderPreference { }

        $changes = Set-DefenderBaseline -Config (New-TestConfig)

        Should -Invoke -ModuleName Defender -CommandName Set-DefenderPreference -Times 1
        ($changes | Where-Object Setting -eq 'RealTimeProtection').Changed | Should -BeTrue
        ($changes | Where-Object Setting -eq 'CloudProtection').Changed | Should -BeFalse
    }
}

Describe 'Backup-DefenderSettings / Restore-DefenderSettings' {
    It 'round-trips preference values through backup and restore' {
        Mock -ModuleName Defender -CommandName Get-DefenderPreference {
            [PSCustomObject]@{ DisableRealtimeMonitoring = $false; MAPSReporting = 2; PUAProtection = 1 }
        }
        Mock -ModuleName Defender -CommandName Set-DefenderPreference { }

        $backupPath = Join-Path $TestDrive 'Defender'
        Backup-DefenderSettings -BackupPath $backupPath
        Restore-DefenderSettings -BackupPath $backupPath

        Should -Invoke -ModuleName Defender -CommandName Set-DefenderPreference -Times 1 -ParameterFilter {
            $Settings.DisableRealtimeMonitoring -eq $false -and $Settings.MAPSReporting -eq 2 -and $Settings.PUAProtection -eq 1
        }
    }

    It 'throws when restoring without a prior backup' {
        { Restore-DefenderSettings -BackupPath (Join-Path $TestDrive 'missing') } | Should -Throw
    }
}
