<#
.SYNOPSIS
    One-shot prerequisites for running this toolkit: unblocks repo scripts,
    sets a durable execution policy, and code-signs everything so no
    per-session bypass is ever needed again.

.DESCRIPTION
    Combines the setup steps described in the README into a single entry
    point (see Setup.cmd at the repo root for a double-clickable wrapper):

      1. Unblock-File on every .ps1/.psm1 in the repo, in case it was
         downloaded or copied rather than `git clone`d - Windows marks
         files from another machine as blocked regardless of execution
         policy.
      2. Set-ExecutionPolicy RemoteSigned, at -Scope (durable - unlike
         -Scope Process, this persists across sessions - and narrowly
         scoped: RemoteSigned still requires downloaded scripts to be
         signed, it only trusts locally-authored ones).
      3. Run Tools\Sign-Scripts.ps1, which creates or reuses a code-signing
         certificate and signs every script - after which RemoteSigned is
         sufficient to run the toolkit with no bypass at all.

    All parameters other than -Scope are passed through to Sign-Scripts.ps1
    unchanged; see its help (Get-Help .\Tools\Sign-Scripts.ps1 -Full) for
    what each one does and the trust tradeoffs of -Scope LocalMachine.

.PARAMETER Subject
    See Tools\Sign-Scripts.ps1.

.PARAMETER CertificateThumbprint
    See Tools\Sign-Scripts.ps1.

.PARAMETER Scope
    'CurrentUser' (default): execution policy and certificate trust are set
    for the account running this script only - no elevation required.
    'LocalMachine': both are set machine-wide, extending trust to every
    account; requires an elevated session (checked up front here, and
    again inside Sign-Scripts.ps1's own confirmation prompt).

.PARAMETER TimestampSigning
    See Tools\Sign-Scripts.ps1.

.PARAMETER Force
    See Tools\Sign-Scripts.ps1. Also skips this script's own confirmation
    prompts, for unattended/scripted use.

.EXAMPLE
    .\Tools\Setup-Prerequisites.ps1

.EXAMPLE
    .\Tools\Setup-Prerequisites.ps1 -Scope LocalMachine -Force
#>
[CmdletBinding()]
param(
    [string]$Subject = 'CN=SecurityBaseline Code Signing',
    [string]$CertificateThumbprint,
    [ValidateSet('CurrentUser', 'LocalMachine')][string]$Scope = 'CurrentUser',
    [switch]$TimestampSigning,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Test-CurrentUserElevated {
    [CmdletBinding()]
    param()
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

if ($Scope -eq 'LocalMachine' -and -not (Test-CurrentUserElevated)) {
    throw '-Scope LocalMachine requires an elevated (Administrator) PowerShell session, since it sets the execution policy and certificate trust for every account on this machine. Re-run from an elevated prompt, or omit -Scope to default to CurrentUser (no elevation needed).'
}

$repoRoot = Split-Path -Path $PSScriptRoot -Parent

Write-Host '== Step 1/3: Unblocking repository scripts ==' -ForegroundColor Cyan
$scriptFiles = @(Get-ChildItem -Path $repoRoot -Recurse -Include '*.ps1', '*.psm1' -File)
$scriptFiles | Unblock-File
Write-Host "Unblocked $($scriptFiles.Count) file(s)."

Write-Host "`n== Step 2/3: Setting execution policy (RemoteSigned, scope: $Scope) ==" -ForegroundColor Cyan
try {
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope $Scope -Force -ErrorAction Stop
}
catch {
    # Setup.cmd launches this script with `powershell.exe -ExecutionPolicy
    # Bypass` so it can run regardless of whatever policy is already in
    # effect - but that itself sets a Process-scope override, and Process
    # always outranks CurrentUser/LocalMachine when PowerShell resolves the
    # *effective* policy for the running process. Set-ExecutionPolicy still
    # writes the requested value at the requested scope in that situation;
    # it just also raises this as a (non-terminating, were it not for
    # -ErrorAction Stop) error to flag that it won't take effect until a new
    # process starts without that override. Confirm the write actually
    # landed before deciding whether this is really fatal.
    if ((Get-ExecutionPolicy -Scope $Scope) -eq 'RemoteSigned') {
        Write-Host "Execution policy set to RemoteSigned at $Scope scope (won't affect this already-running process, which was started with a Process-scope Bypass override - future sessions will use it)." -ForegroundColor Yellow
    }
    else {
        throw
    }
}

Write-Host "`n== Step 3/3: Signing repository scripts ==" -ForegroundColor Cyan
$signScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Sign-Scripts.ps1'
$signParams = @{
    Subject = $Subject
    Scope   = $Scope
}
if ($CertificateThumbprint) { $signParams.CertificateThumbprint = $CertificateThumbprint }
if ($TimestampSigning)      { $signParams.TimestampSigning = $true }
if ($Force)                 { $signParams.Force = $true }

& $signScriptPath @signParams

Write-Host "`nPrerequisites complete. You can now run, with no execution-policy bypass needed:" -ForegroundColor Green
Write-Host '  .\Invoke-SecurityBaseline.ps1 -Mode Audit'
