BeforeAll {
    Import-Module "$PSScriptRoot/../../Modules/ScreenLock.psm1" -Force

    function New-TestConfig {
        @{ InactivityTimeoutSeconds = @{ Value = 900; Description = '15 min' } }
    }
}

Describe 'Test-ScreenLockBaseline' {
    It 'fails when the live value differs from config' {
        Mock -ModuleName ScreenLock -CommandName Get-InactivityTimeoutValue { 0 }
        (Test-ScreenLockBaseline -Config (New-TestConfig))[0].Pass | Should -BeFalse
    }

    It 'passes when the live value matches config' {
        Mock -ModuleName ScreenLock -CommandName Get-InactivityTimeoutValue { 900 }
        (Test-ScreenLockBaseline -Config (New-TestConfig))[0].Pass | Should -BeTrue
    }
}

Describe 'Set-ScreenLockBaseline' {
    It 'writes the new value only when it differs from the current one' {
        Mock -ModuleName ScreenLock -CommandName Get-InactivityTimeoutValue { 0 }
        Mock -ModuleName ScreenLock -CommandName Set-InactivityTimeoutValue { }

        $changes = Set-ScreenLockBaseline -Config (New-TestConfig)

        $changes[0].Changed | Should -BeTrue
        Should -Invoke -ModuleName ScreenLock -CommandName Set-InactivityTimeoutValue -Times 1 -ParameterFilter { $Seconds -eq 900 }
    }

    It 'skips writing when already compliant' {
        Mock -ModuleName ScreenLock -CommandName Get-InactivityTimeoutValue { 900 }
        Mock -ModuleName ScreenLock -CommandName Set-InactivityTimeoutValue { }

        $changes = Set-ScreenLockBaseline -Config (New-TestConfig)

        $changes[0].Changed | Should -BeFalse
        Should -Invoke -ModuleName ScreenLock -CommandName Set-InactivityTimeoutValue -Times 0
    }
}

Describe 'Backup-ScreenLockSettings / Restore-ScreenLockSettings' {
    It 'exports the registry key via the reg export wrapper' {
        Mock -ModuleName ScreenLock -CommandName Export-InactivityTimeoutRegistry { }
        $backupPath = Join-Path $TestDrive 'ScreenLock'

        $regPath = Backup-ScreenLockSettings -BackupPath $backupPath

        $regPath | Should -Be (Join-Path $backupPath 'screenlock.reg')
    }

    It 'imports the registry key via the reg import wrapper' {
        Mock -ModuleName ScreenLock -CommandName Import-InactivityTimeoutRegistry { }
        $backupPath = Join-Path $TestDrive 'RestoreScreenLock'
        New-Item -Path $backupPath -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $backupPath 'screenlock.reg') -Value 'placeholder'

        Restore-ScreenLockSettings -BackupPath $backupPath

        Should -Invoke -ModuleName ScreenLock -CommandName Import-InactivityTimeoutRegistry -Times 1
    }

    It 'throws when restoring without a prior backup' {
        { Restore-ScreenLockSettings -BackupPath (Join-Path $TestDrive 'missing') } | Should -Throw
    }
}
