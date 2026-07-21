BeforeAll {
    Import-Module "$PSScriptRoot/../../Common/Logging.psm1" -Force
}

Describe 'Write-BaselineLog' {
    It 'creates the log directory if it does not exist' {
        $logPath = Join-Path $TestDrive 'nested/dir/test.log'
        Write-BaselineLog -Message 'hello' -LogPath $logPath
        Test-Path $logPath | Should -BeTrue
    }

    It 'writes a line containing the level and message' {
        $logPath = Join-Path $TestDrive 'test.log'
        Write-BaselineLog -Message 'something happened' -Level 'Warn' -LogPath $logPath
        $content = Get-Content -Path $logPath -Raw
        $content | Should -Match '\[Warn\] something happened'
    }

    It 'appends multiple messages rather than overwriting' {
        $logPath = Join-Path $TestDrive 'append.log'
        Write-BaselineLog -Message 'first' -LogPath $logPath
        Write-BaselineLog -Message 'second' -LogPath $logPath
        (Get-Content -Path $logPath).Count | Should -Be 2
    }

    It 'defaults to Info level' {
        $logPath = Join-Path $TestDrive 'default.log'
        Write-BaselineLog -Message 'plain message' -LogPath $logPath
        Get-Content -Path $logPath -Raw | Should -Match '\[Info\] plain message'
    }
}
