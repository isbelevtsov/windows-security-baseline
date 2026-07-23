# Tests/Common/Config.Tests.ps1
BeforeAll {
    Import-Module "$PSScriptRoot/../../Common/Config.psm1" -Force
}

Describe 'Import-BaselineConfig' {
    It 'throws if the file does not exist' {
        { Import-BaselineConfig -Path (Join-Path $TestDrive 'missing.psd1') } | Should -Throw
    }

    It 'throws if a required section is missing' {
        $path = Join-Path $TestDrive 'incomplete.psd1'
        Set-Content -Path $path -Value '@{ PasswordPolicy = @{} }'
        { Import-BaselineConfig -Path $path } | Should -Throw '*missing required section*'
    }

    It 'loads a config with all required sections' {
        $path = Join-Path $TestDrive 'full.psd1'
        Set-Content -Path $path -Value @'
@{
    PasswordPolicy = @{ MinimumPasswordLength = @{ Value = 14; Description = "min length" } }
    AccountLockout = @{}
    Defender       = @{}
    Firewall       = @{}
    ScreenLock     = @{}
    AuditPolicy    = @{}
    RemoteAccess   = @{}
    BitLocker      = @{}
    LocalAccounts  = @{}
}
'@
        $config = Import-BaselineConfig -Path $path
        $config.PasswordPolicy.MinimumPasswordLength.Value | Should -Be 14
    }

    It 'loads the real shipped Baseline.config.psd1' {
        $config = Import-BaselineConfig -Path "$PSScriptRoot/../../Config/Baseline.config.psd1"
        $config.PasswordPolicy.MinimumPasswordLength.Value | Should -Be 14
        $config.RemoteAccess.DisableRDP.Value | Should -Be $true
        $config.LocalAccounts.DisableAutoLogon.Value | Should -Be $true
    }
}

Describe 'Get-BaselineValue' {
    It 'returns the Value property for a known key' {
        $section = @{ Foo = @{ Value = 42; Description = 'the answer' } }
        Get-BaselineValue -Section $section -Name 'Foo' | Should -Be 42
    }

    It 'throws for an unknown key' {
        $section = @{ Foo = @{ Value = 42 } }
        { Get-BaselineValue -Section $section -Name 'Bar' } | Should -Throw
    }
}

Describe 'Get-BaselineDescription' {
    It 'returns the Description property for a known key' {
        $section = @{ Foo = @{ Value = 42; Description = 'the answer' } }
        Get-BaselineDescription -Section $section -Name 'Foo' | Should -Be 'the answer'
    }

    It 'throws for an unknown key' {
        $section = @{ Foo = @{ Value = 42; Description = 'the answer' } }
        { Get-BaselineDescription -Section $section -Name 'Bar' } | Should -Throw
    }
}
