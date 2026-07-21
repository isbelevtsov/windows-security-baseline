Import-Module (Join-Path $PSScriptRoot '..\Common\Config.psm1') -Force

function Invoke-AuditPolBinary {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments)
    & auditpol.exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "auditpol.exe failed with exit code $LASTEXITCODE (arguments: $($Arguments -join ' '))"
    }
}

function ConvertTo-AuditPolFlags {
    param(
        [Parameter(Mandatory)][ValidateSet('Success', 'Failure', 'SuccessAndFailure', 'NoAuditing')][string]$Outcome
    )

    switch ($Outcome) {
        'Success'           { @{ Success = 'enable'; Failure = 'disable' } }
        'Failure'           { @{ Success = 'disable'; Failure = 'enable' } }
        'SuccessAndFailure' { @{ Success = 'enable'; Failure = 'enable' } }
        'NoAuditing'        { @{ Success = 'disable'; Failure = 'disable' } }
    }
}

function Get-AuditSubcategorySetting {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Subcategory)

    $csv = Invoke-AuditPolBinary -Arguments @('/get', "/subcategory:$Subcategory", '/r')
    $row = $csv | ConvertFrom-Csv | Select-Object -First 1
    if (-not $row) {
        return $null
    }

    switch ($row.'Inclusion Setting') {
        'Success and Failure' { return 'SuccessAndFailure' }
        'Success'             { return 'Success' }
        'Failure'             { return 'Failure' }
        default               { return 'NoAuditing' }
    }
}

function Set-AuditSubcategorySetting {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Subcategory,
        [Parameter(Mandatory)][string]$Outcome
    )

    $flags = ConvertTo-AuditPolFlags -Outcome $Outcome
    Invoke-AuditPolBinary -Arguments @('/set', "/subcategory:$Subcategory", "/success:$($flags.Success)", "/failure:$($flags.Failure)") | Out-Null
}

function Test-AuditPolicyBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $categories = Get-BaselineValue -Section $Config -Name 'Categories'
    $description = Get-BaselineDescription -Section $Config -Name 'Categories'

    $results = foreach ($subcategory in $categories.Keys) {
        $expected = $categories[$subcategory]
        $actual = Get-AuditSubcategorySetting -Subcategory $subcategory

        [PSCustomObject]@{
            Module      = 'AuditPolicy'
            Setting     = $subcategory
            Expected    = $expected
            Actual      = $actual
            Pass        = ($actual -eq $expected)
            Description = $description
        }
    }

    return $results
}

function Backup-AuditPolicySettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    New-Item -Path $BackupPath -ItemType Directory -Force | Out-Null
    $csvPath = Join-Path -Path $BackupPath -ChildPath 'audit-policy.csv'
    Invoke-AuditPolBinary -Arguments @('/backup', "/file:$csvPath") | Out-Null
    return $csvPath
}

function Set-AuditPolicyBaseline {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)

    $categories = Get-BaselineValue -Section $Config -Name 'Categories'

    $changes = foreach ($subcategory in $categories.Keys) {
        $expected = $categories[$subcategory]
        $before = Get-AuditSubcategorySetting -Subcategory $subcategory
        $changed = ($before -ne $expected)

        if ($changed) {
            Set-AuditSubcategorySetting -Subcategory $subcategory -Outcome $expected
        }

        [PSCustomObject]@{
            Module  = 'AuditPolicy'
            Setting = $subcategory
            Before  = $before
            After   = $expected
            Changed = $changed
        }
    }

    return $changes
}

function Restore-AuditPolicySettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BackupPath)

    $csvPath = Join-Path -Path $BackupPath -ChildPath 'audit-policy.csv'
    if (-not (Test-Path -Path $csvPath)) {
        throw "No audit policy backup found at '$csvPath'."
    }
    Invoke-AuditPolBinary -Arguments @('/restore', "/file:$csvPath") | Out-Null
}

Export-ModuleMember -Function Test-AuditPolicyBaseline, Backup-AuditPolicySettings, Set-AuditPolicyBaseline, Restore-AuditPolicySettings
