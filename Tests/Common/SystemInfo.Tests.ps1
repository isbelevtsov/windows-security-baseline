BeforeAll {
    Import-Module "$PSScriptRoot/../../Common/SystemInfo.psm1" -Force
}

Describe 'Test-BaselineElevation' {
    It 'returns a boolean without throwing' {
        { Test-BaselineElevation } | Should -Not -Throw
    }
}

Describe 'Get-WindowsEditionInfo' {
    It 'classifies a Home caption correctly' {
        Mock -ModuleName SystemInfo -CommandName Get-OperatingSystemCimInstance {
            [PSCustomObject]@{ Caption = 'Microsoft Windows 11 Home'; BuildNumber = '22631' }
        }
        $result = Get-WindowsEditionInfo
        $result.Edition | Should -Be 'Home'
        $result.Build | Should -Be '22631'
    }

    It 'classifies a Pro caption correctly' {
        Mock -ModuleName SystemInfo -CommandName Get-OperatingSystemCimInstance {
            [PSCustomObject]@{ Caption = 'Microsoft Windows 11 Pro'; BuildNumber = '22631' }
        }
        (Get-WindowsEditionInfo).Edition | Should -Be 'Pro'
    }

    It 'classifies an Enterprise caption correctly' {
        Mock -ModuleName SystemInfo -CommandName Get-OperatingSystemCimInstance {
            [PSCustomObject]@{ Caption = 'Microsoft Windows 11 Enterprise'; BuildNumber = '22631' }
        }
        (Get-WindowsEditionInfo).Edition | Should -Be 'Enterprise'
    }

    It 'falls back to Other for an unrecognized caption' {
        Mock -ModuleName SystemInfo -CommandName Get-OperatingSystemCimInstance {
            [PSCustomObject]@{ Caption = 'Some Future Windows SKU'; BuildNumber = '99999' }
        }
        (Get-WindowsEditionInfo).Edition | Should -Be 'Other'
    }
}
