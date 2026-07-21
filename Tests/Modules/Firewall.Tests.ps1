# Tests/Modules/Firewall.Tests.ps1
BeforeAll {
    Import-Module "$PSScriptRoot/../../Modules/Firewall.psm1" -Force

    function New-TestConfig {
        @{
            EnabledProfiles      = @{ Value = @('Domain', 'Private', 'Public'); Description = 'profiles' }
            DefaultInboundAction = @{ Value = 'Block'; Description = 'inbound' }
            LoggingEnabled       = @{ Value = $true; Description = 'logging' }
        }
    }
}

Describe 'Test-FirewallBaseline' {
    It 'flags a profile with logging disabled' {
        Mock -ModuleName Firewall -CommandName Get-FirewallProfileState {
            param($ProfileName)
            [PSCustomObject]@{ Enabled = $true; DefaultInboundAction = 'Block'; LogAllowed = $false; LogBlocked = $false }
        }

        $results = Test-FirewallBaseline -Config (New-TestConfig)

        @($results | Where-Object { $_.Setting -eq 'Domain.LoggingEnabled' }).Pass | Should -BeFalse
        @($results | Where-Object { $_.Setting -eq 'Domain.DefaultInboundAction' }).Pass | Should -BeTrue
    }
}

Describe 'Set-FirewallBaseline' {
    It 'only reconfigures a profile that is out of compliance' {
        Mock -ModuleName Firewall -CommandName Get-FirewallProfileState {
            param($ProfileName)
            if ($ProfileName -eq 'Public') {
                [PSCustomObject]@{ Enabled = $false; DefaultInboundAction = 'Allow'; LogAllowed = $false; LogBlocked = $false }
            }
            else {
                [PSCustomObject]@{ Enabled = $true; DefaultInboundAction = 'Block'; LogAllowed = $true; LogBlocked = $true }
            }
        }
        Mock -ModuleName Firewall -CommandName Set-FirewallProfileState { }

        Set-FirewallBaseline -Config (New-TestConfig) | Out-Null

        Should -Invoke -ModuleName Firewall -CommandName Set-FirewallProfileState -Times 1 -ParameterFilter { $ProfileName -eq 'Public' }
    }
}

Describe 'Backup-FirewallSettings / Restore-FirewallSettings' {
    It 'exports via netsh advfirewall export' {
        Mock -ModuleName Firewall -CommandName Invoke-NetshBinary { }
        $backupPath = Join-Path $TestDrive 'Firewall'

        $wfwPath = Backup-FirewallSettings -BackupPath $backupPath

        $wfwPath | Should -Be (Join-Path $backupPath 'firewall.wfw')
        Should -Invoke -ModuleName Firewall -CommandName Invoke-NetshBinary -ParameterFilter {
            $Arguments -contains 'export'
        } -Times 1
    }

    It 'imports via netsh advfirewall import' {
        Mock -ModuleName Firewall -CommandName Invoke-NetshBinary { }
        $backupPath = Join-Path $TestDrive 'RestoreFirewall'
        New-Item -Path $backupPath -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $backupPath 'firewall.wfw') -Value 'placeholder'

        Restore-FirewallSettings -BackupPath $backupPath

        Should -Invoke -ModuleName Firewall -CommandName Invoke-NetshBinary -ParameterFilter {
            $Arguments -contains 'import'
        } -Times 1
    }

    It 'throws when restoring without a prior backup' {
        { Restore-FirewallSettings -BackupPath (Join-Path $TestDrive 'missing') } | Should -Throw
    }
}
