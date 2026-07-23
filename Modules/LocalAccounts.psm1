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

function New-CompliantTemporaryPassword {
    [CmdletBinding()]
    param()

    # Deliberately not read from the PasswordPolicy module's config - each
    # module here only ever receives its own config section (see
    # Set-LocalAccountsBaseline/Common/Orchestrator.psm1), and coupling this
    # one to another module's settings would break that isolation. 24
    # characters covering all four character classes comfortably satisfies
    # any reasonable length/complexity policy regardless of what's
    # configured, so there's no need to read it.
    $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower = 'abcdefghijkmnopqrstuvwxyz'
    $digits = '23456789'
    $symbols = '!@#$%^&*-_=+?'
    $all = $upper + $lower + $digits + $symbols
    $length = 24

    # RandomNumberGenerator's static Fill() method doesn't exist in .NET
    # Framework (confirmed on real hardware under Windows PowerShell 5.1,
    # which targets .NET Framework, not .NET Core/5+) - use the classic
    # instance-based Create()/GetBytes() API, which works on both.
    $bytes = [byte[]]::new($length)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    }
    finally {
        $rng.Dispose()
    }

    $chars = for ($i = 0; $i -lt $length; $i++) { $all[$bytes[$i] % $all.Length] }
    # Force at least one of each character class into fixed positions so
    # complexity requirements are met regardless of what the random draw
    # produced everywhere else.
    $chars[0] = $upper[$bytes[0] % $upper.Length]
    $chars[1] = $lower[$bytes[1] % $lower.Length]
    $chars[2] = $digits[$bytes[2] % $digits.Length]
    $chars[3] = $symbols[$bytes[3] % $symbols.Length]

    -join $chars
}

function Set-LocalUserTemporaryPassword {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][securestring]$Password
    )
    Set-LocalUser -Name $Name -Password $Password
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
    $tempPasswordFolder = Get-BaselineValue -Section $Config -Name 'TemporaryPasswordPath'

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
            # Forcing "must change password at next logon" alone is not
            # enough: confirmed on real hardware (a VM rebooted after an
            # earlier Apply run) that an account with a genuinely blank
            # password never showed a change prompt at the logon screen at
            # all - Windows' blank-password logon path evidently doesn't
            # always route through the credential-entry step that flag
            # relies on. The only remediation that closes the gap
            # unconditionally is to invalidate the blank password right now
            # by setting a real one, which also resolves the chicken-and-egg
            # problem below (PasswordRequired can only be set once the
            # current password is compliant).
            $tempPassword = New-CompliantTemporaryPassword
            $securePassword = ConvertTo-SecureString -String $tempPassword -AsPlainText -Force
            Set-LocalUserTemporaryPassword -Name $userName -Password $securePassword

            # Still force a change at next logon on top of that, so the
            # admin-generated temporary password doesn't linger - the
            # account holder uses it once, then picks their own.
            Set-LocalUserPasswordExpired -Name $userName

            $note = "Account '$userName' allowed a blank password (PasswordRequired was False). A temporary password has been set and the account has been forced to change it at next logon."
            $requirePasswordSucceeded = $true
            try {
                Set-LocalUserRequiresPassword -Name $userName
            }
            catch {
                $requirePasswordSucceeded = $false
                $note = "$note Could not yet mark it as requiring a password: $($_.Exception.Message) This is expected while the account's current password still doesn't meet policy - it will succeed automatically on a later Apply run, once the user has changed it."
            }

            if (-not (Test-Path -Path $tempPasswordFolder)) {
                New-Item -Path $tempPasswordFolder -ItemType Directory -Force | Out-Null
            }
            $tempPasswordFile = Join-Path -Path $tempPasswordFolder -ChildPath "$userName-temp-password.txt"
            Set-Content -Path $tempPasswordFile -Value $tempPassword
            $note = "$note Temporary password written in plaintext to '$tempPasswordFile' - secure or relocate it, and delete it once the account holder has logged in and set their own password."

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
