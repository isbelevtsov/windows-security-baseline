Import-Module (Join-Path $PSScriptRoot '..\Common\Config.psm1') -Force

$script:WinlogonRegistryPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

function Get-ManagedLocalUsers {
    [CmdletBinding()]
    param()
    @(Get-LocalUser | Where-Object { $_.Enabled })
}

function Set-LocalUserRequiresPassword {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    # Set-LocalUser has no -PasswordRequired parameter at all (confirmed via
    # Get-Command -Syntax on real hardware - a long-standing gap in the
    # built-in LocalAccounts module). This is the WinNT ADSI provider
    # equivalent, same mechanism used for Set-LocalUserPasswordExpired.
    #
    # Confirmed on real hardware: this throws "The password does not meet
    # the password policy requirements" if the account's CURRENT password
    # doesn't satisfy the active complexity/length policy - which is exactly
    # the blank-password case this function exists to fix, so it can
    # legitimately fail on the very account it's meant to remediate. Callers
    # must call Set-LocalUserPasswordExpired first (which has no such
    # precondition) and treat this call as best-effort, succeeding only once
    # the account already has a compliant password.
    $user = [ADSI]"WinNT://$env:COMPUTERNAME/$Name,user"
    $user.PasswordRequired = $true
    # SetInfo() is a COM method call through the ADSI interop layer, which
    # leaks a stray $null onto the pipeline if its result isn't suppressed -
    # confirmed on real hardware, where an unsuppressed call here silently
    # prepended a $null to Set-LocalAccountsBaseline's returned array.
    $user.SetInfo() | Out-Null
}

function Set-LocalUserPasswordExpired {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    # Set-LocalUser has no "must change password at next logon" parameter -
    # this is the standard WinNT ADSI provider way to set it (works on Home,
    # Pro, and Enterprise, same as Get-/Set-LocalUser, since it's backed by
    # the local SAM rather than Group Policy).
    $user = [ADSI]"WinNT://$env:COMPUTERNAME/$Name,user"
    $user.PasswordExpired = 1
    $user.SetInfo() | Out-Null
}

function Get-AutoLogonEnabled {
    [CmdletBinding()]
    param()
    $item = Get-ItemProperty -Path $script:WinlogonRegistryPath -Name 'AutoAdminLogon' -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $false }
    return ("$($item.AutoAdminLogon)" -eq '1')
}

function Get-AutoLogonDefaultPasswordExists {
    [CmdletBinding()]
    param()
    $item = Get-ItemProperty -Path $script:WinlogonRegistryPath -Name 'DefaultPassword' -ErrorAction SilentlyContinue
    return ($null -ne $item)
}

function Disable-AutoLogon {
    [CmdletBinding()]
    param()
    # AutoAdminLogon is a REG_SZ ('0'/'1'), not a DWord - a common real-world
    # gotcha with this specific value.
    Set-ItemProperty -Path $script:WinlogonRegistryPath -Name 'AutoAdminLogon' -Value '0' -Type String
    # DefaultPassword stores the autologon account's password in plaintext.
    # Disabling autologon alone doesn't remove it - purge it explicitly.
    Remove-ItemProperty -Path $script:WinlogonRegistryPath -Name 'DefaultPassword' -ErrorAction SilentlyContinue
}

function Test-LocalAccountsBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $autoLogonExpected = Get-BaselineValue -Section $Config -Name 'DisableAutoLogon'
    $autoLogonActual = -not (Get-AutoLogonEnabled)

    $results = @(
        [PSCustomObject]@{
            Module = 'LocalAccounts'; Setting = 'AutoLogonDisabled'
            Expected = $autoLogonExpected; Actual = $autoLogonActual; Pass = ($autoLogonActual -eq $autoLogonExpected)
            Description = Get-BaselineDescription -Section $Config -Name 'DisableAutoLogon'
        }
    )

    $passwordExpected = Get-BaselineValue -Section $Config -Name 'RequirePasswordForAllAccounts'
    $passwordDescription = Get-BaselineDescription -Section $Config -Name 'RequirePasswordForAllAccounts'

    foreach ($user in Get-ManagedLocalUsers) {
        $actual = [bool]$user.PasswordRequired
        $results += [PSCustomObject]@{
            Module = 'LocalAccounts'; Setting = "$($user.Name).PasswordRequired"
            Expected = $passwordExpected; Actual = $actual; Pass = ($actual -eq $passwordExpected)
            Description = $passwordDescription
        }
    }

    return $results
}

function Backup-LocalAccountsSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    New-Item -Path $BackupPath -ItemType Directory -Force | Out-Null
    $statePath = Join-Path -Path $BackupPath -ChildPath 'local-accounts-state.json'

    $autoLogonItem = Get-ItemProperty -Path $script:WinlogonRegistryPath -Name 'AutoAdminLogon' -ErrorAction SilentlyContinue
    $userNameItem  = Get-ItemProperty -Path $script:WinlogonRegistryPath -Name 'DefaultUserName' -ErrorAction SilentlyContinue
    $domainItem    = Get-ItemProperty -Path $script:WinlogonRegistryPath -Name 'DefaultDomainName' -ErrorAction SilentlyContinue

    $userStates = @(Get-ManagedLocalUsers | ForEach-Object {
        [PSCustomObject]@{ Name = $_.Name; PasswordRequired = [bool]$_.PasswordRequired }
    })

    # DefaultPassword is deliberately never read or written to this backup -
    # it's a plaintext credential, and copying it into a backup file would
    # be a worse exposure than leaving it in the registry. Restore never
    # re-creates it either; see Restore-LocalAccountsSettings.
    [PSCustomObject]@{
        AutoAdminLogonExisted    = ($null -ne $autoLogonItem)
        AutoAdminLogonValue      = $(if ($autoLogonItem) { "$($autoLogonItem.AutoAdminLogon)" } else { $null })
        DefaultUserNameExisted   = ($null -ne $userNameItem)
        DefaultUserNameValue     = $(if ($userNameItem) { $userNameItem.DefaultUserName } else { $null })
        DefaultDomainNameExisted = ($null -ne $domainItem)
        DefaultDomainNameValue   = $(if ($domainItem) { $domainItem.DefaultDomainName } else { $null })
        Users                    = $userStates
    } | ConvertTo-Json | Set-Content -Path $statePath

    return $statePath
}

function Set-LocalAccountsBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $before = Test-LocalAccountsBaseline -Config $Config
    $changes = @()

    $autoLogonResult = $before | Where-Object { $_.Setting -eq 'AutoLogonDisabled' }
    if (-not $autoLogonResult.Pass) {
        $hadStoredPassword = Get-AutoLogonDefaultPasswordExists
        Disable-AutoLogon
        $changes += [PSCustomObject]@{
            Module  = 'LocalAccounts'
            Setting = 'AutoLogonDisabled'
            Before  = $autoLogonResult.Actual
            After   = $true
            Changed = $true
            Note    = $(if ($hadStoredPassword) { "A plaintext autologon password was stored in the registry (Winlogon\DefaultPassword) and has been removed." } else { $null })
        }
    }
    else {
        $changes += [PSCustomObject]@{ Module = 'LocalAccounts'; Setting = 'AutoLogonDisabled'; Before = $autoLogonResult.Actual; After = $autoLogonResult.Actual; Changed = $false }
    }

    foreach ($result in @($before | Where-Object { $_.Setting -like '*.PasswordRequired' })) {
        $userName = $result.Setting -replace '\.PasswordRequired$', ''

        if (-not $result.Pass) {
            # Force the password change first - unlike the PasswordRequired
            # flip below, this doesn't validate the account's current
            # password against policy, so it always succeeds regardless of
            # whether that password is blank or otherwise non-compliant.
            Set-LocalUserPasswordExpired -Name $userName

            $note = "Account '$userName' allowed a blank password (PasswordRequired was False) and has been forced to change its password at next logon, since its current password could not otherwise be verified."
            $requirePasswordSucceeded = $true
            try {
                Set-LocalUserRequiresPassword -Name $userName
            }
            catch {
                $requirePasswordSucceeded = $false
                $note = "$note Could not yet mark it as requiring a password: $($_.Exception.Message) This is expected while the account's current password still doesn't meet policy - it will succeed automatically on a later Apply run, once the user has changed it."
            }

            $changes += [PSCustomObject]@{
                Module  = 'LocalAccounts'
                Setting = $result.Setting
                Before  = $result.Actual
                After   = $requirePasswordSucceeded
                Changed = $true
                Note    = $note
            }
        }
        else {
            $changes += [PSCustomObject]@{ Module = 'LocalAccounts'; Setting = $result.Setting; Before = $result.Actual; After = $result.Actual; Changed = $false }
        }
    }

    return $changes
}

function Restore-LocalAccountsSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    $statePath = Join-Path -Path $BackupPath -ChildPath 'local-accounts-state.json'
    if (-not (Test-Path -Path $statePath)) {
        throw "No local accounts backup found at '$statePath'."
    }
    $saved = Get-Content -Path $statePath -Raw | ConvertFrom-Json

    if ($saved.AutoAdminLogonExisted) {
        Set-ItemProperty -Path $script:WinlogonRegistryPath -Name 'AutoAdminLogon' -Value $saved.AutoAdminLogonValue -Type String
    }
    else {
        Remove-ItemProperty -Path $script:WinlogonRegistryPath -Name 'AutoAdminLogon' -ErrorAction SilentlyContinue
    }

    if ($saved.DefaultUserNameExisted) {
        Set-ItemProperty -Path $script:WinlogonRegistryPath -Name 'DefaultUserName' -Value $saved.DefaultUserNameValue -Type String
    }
    if ($saved.DefaultDomainNameExisted) {
        Set-ItemProperty -Path $script:WinlogonRegistryPath -Name 'DefaultDomainName' -Value $saved.DefaultDomainNameValue -Type String
    }
    # DefaultPassword is intentionally never restored - see
    # Backup-LocalAccountsSettings. Re-enabling autologon after a restore
    # (if it was previously on) will require the password to be re-entered
    # once by hand; that's a deliberate one-way door, not a bug.

    foreach ($user in @($saved.Users)) {
        if ($user.PasswordRequired) {
            Set-LocalUserRequiresPassword -Name $user.Name
        }
        # PasswordRequired = $false is never restored: re-permitting a blank
        # password would be a security regression this toolkit won't perform
        # automatically, even on Restore.
    }
}

Export-ModuleMember -Function Test-LocalAccountsBaseline, Backup-LocalAccountsSettings, Set-LocalAccountsBaseline, Restore-LocalAccountsSettings
