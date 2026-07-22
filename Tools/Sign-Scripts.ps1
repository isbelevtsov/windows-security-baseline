<#
.SYNOPSIS
    Code-signs every .ps1/.psm1 file in this repository so it can run under
    RemoteSigned or AllSigned execution policy without Unblock-File or
    -ExecutionPolicy Bypass.

.DESCRIPTION
    Standalone/workgroup devices have no domain to push a trusted CA root via
    Group Policy, so this creates (or reuses) a self-signed code-signing
    certificate, installs it into a Trusted Root/Trusted Publisher store so
    Windows considers it trusted, and signs every script in the repo with it.

    SECURITY NOTE: adding a certificate to a Trusted Root store is not scoped
    to "PowerShell script signing" — that store is consulted for all
    certificate chain validation in its scope (TLS, S/MIME, other code
    signing). By default this script scopes both the private key and the
    trust grant to the CURRENT USER only (Cert:\CurrentUser\*), so the trust
    decision only affects certificate validation for the account that's
    actually going to run the toolkit, not every account on the machine. Use
    -Scope LocalMachine only if multiple accounts need to run signed scripts,
    and understand that this grants those scripts' signer root-level trust
    machine-wide, for every purpose Windows uses that store for — not just
    PowerShell.

    The generated private key is created non-exportable, so it cannot be
    copied off this machine even if the certificate store is compromised —
    though a process running as the same user could still use it to sign
    additional scripts.

    Run this once per machine (or account) that will execute the toolkit.
    Re-run it any time a script file changes — editing a signed file
    invalidates its signature.

    If your organization already has a code-signing certificate (issued by an
    internal CA or a public one), pass its thumbprint via
    -CertificateThumbprint instead of creating a new self-signed certificate
    — this avoids the self-signed root-trust tradeoff entirely, since a
    properly issued certificate chains to a CA your machine already trusts.

.PARAMETER Subject
    Subject name for a newly created self-signed certificate. Ignored if
    -CertificateThumbprint is supplied.

.PARAMETER CertificateThumbprint
    Thumbprint of an existing code-signing certificate (in CurrentUser\My or
    LocalMachine\My) to use instead of creating a self-signed one. Preferred
    over a self-signed certificate when available, since it avoids granting
    new root-level trust.

.PARAMETER Scope
    'CurrentUser' (default): private key and trust grant are scoped to the
    account running this script — only that account's certificate
    validation is affected. 'LocalMachine': trust is granted to every
    account on the machine; requires an elevated session and a second,
    explicit confirmation given the wider blast radius.

.PARAMETER TimestampSigning
    Add a trusted timestamp to each signature (requires internet access to
    reach the timestamp server) so the signature remains valid after the
    certificate itself expires. Not needed for a short-lived internal
    deployment; off by default since these are offline/workgroup devices.

.PARAMETER Force
    Skip the interactive confirmation before installing a new certificate
    into a Trusted Root store. Use in unattended/scripted contexts only,
    after you've reviewed what this script does.

.EXAMPLE
    .\Tools\Sign-Scripts.ps1

.EXAMPLE
    .\Tools\Sign-Scripts.ps1 -CertificateThumbprint 'A1B2C3D4E5F6...'

.EXAMPLE
    .\Tools\Sign-Scripts.ps1 -Scope LocalMachine
#>
[CmdletBinding()]
param(
    [string]$Subject = 'CN=SecurityBaseline Code Signing',
    [string]$CertificateThumbprint,
    [ValidateSet('CurrentUser', 'LocalMachine')][string]$Scope = 'CurrentUser',
    [switch]$TimestampSigning,
    [switch]$Force
)

function Get-OrCreateSigningCertificate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Subject,
        [string]$Thumbprint,
        [Parameter(Mandatory)][ValidateSet('CurrentUser', 'LocalMachine')][string]$Scope
    )

    if ($Thumbprint) {
        $existing = Get-ChildItem -Path Cert:\CurrentUser\My, Cert:\LocalMachine\My -CodeSigningCert -ErrorAction SilentlyContinue |
            Where-Object { $_.Thumbprint -eq $Thumbprint } | Select-Object -First 1
        if (-not $existing) {
            throw "No certificate with thumbprint '$Thumbprint' found in CurrentUser\My or LocalMachine\My."
        }
        return $existing
    }

    $myStorePath = "Cert:\$Scope\My"
    $existing = Get-ChildItem -Path $myStorePath -CodeSigningCert -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -eq $Subject } | Sort-Object -Property NotAfter -Descending | Select-Object -First 1
    if ($existing -and $existing.NotAfter -gt (Get-Date)) {
        Write-Host "Reusing existing signing certificate: $($existing.Thumbprint)"
        return $existing
    }

    Write-Host "Creating new self-signed code-signing certificate: $Subject (scope: $Scope, non-exportable private key)"
    return New-SelfSignedCertificate -Type CodeSigningCert -Subject $Subject `
        -KeyUsage DigitalSignature -FriendlyName 'SecurityBaseline Code Signing' `
        -NotAfter (Get-Date).AddYears(5) -CertStoreLocation $myStorePath `
        -KeyExportPolicy NonExportable
}

function Install-TrustedCertificate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Certificate,
        [Parameter(Mandatory)][ValidateSet('CurrentUser', 'LocalMachine')][string]$Scope,
        [switch]$Force
    )

    $rootStorePath = "Cert:\$Scope\Root"
    $publisherStorePath = "Cert:\$Scope\TrustedPublisher"

    $alreadyInRoot = Get-ChildItem -Path $rootStorePath -ErrorAction SilentlyContinue |
        Where-Object { $_.Thumbprint -eq $Certificate.Thumbprint }
    $alreadyInPublisher = Get-ChildItem -Path $publisherStorePath -ErrorAction SilentlyContinue |
        Where-Object { $_.Thumbprint -eq $Certificate.Thumbprint }

    if (-not $alreadyInRoot -or -not $alreadyInPublisher) {
        Write-Warning "About to add certificate '$($Certificate.Thumbprint)' ($($Certificate.Subject)) to the $Scope Trusted Root and Trusted Publisher stores."
        Write-Warning "This grants that certificate root-level trust for ALL certificate validation in $Scope scope (TLS, S/MIME, other code signing) - not just this repo's scripts."
        if ($Scope -eq 'LocalMachine') {
            Write-Warning "LocalMachine scope extends this trust to EVERY account on this machine."
        }

        if (-not $Force) {
            $confirmation = Read-Host "Type 'yes' to continue, anything else to abort"
            if ($confirmation -ne 'yes') {
                throw 'Aborted: certificate was not installed into the trust store, and scripts were not signed.'
            }
        }
    }

    $tempPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "securitybaseline-signing-$($Certificate.Thumbprint).cer"
    Export-Certificate -Cert $Certificate -FilePath $tempPath -Force | Out-Null

    if (-not $alreadyInRoot) {
        Import-Certificate -FilePath $tempPath -CertStoreLocation $rootStorePath | Out-Null
        Write-Host "Installed certificate into $rootStorePath"
    }
    if (-not $alreadyInPublisher) {
        Import-Certificate -FilePath $tempPath -CertStoreLocation $publisherStorePath | Out-Null
        Write-Host "Installed certificate into $publisherStorePath"
    }

    Remove-Item -Path $tempPath -Force -ErrorAction SilentlyContinue
}

function Set-RepositorySignatures {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Certificate,
        [Parameter(Mandatory)][string]$RepoRoot,
        [switch]$TimestampSigning
    )

    $files = Get-ChildItem -Path $RepoRoot -Recurse -Include '*.ps1', '*.psm1' -File

    $results = foreach ($file in $files) {
        $signParams = @{ FilePath = $file.FullName; Certificate = $Certificate }
        if ($TimestampSigning) {
            $signParams.TimestampServer = 'http://timestamp.digicert.com'
        }
        $signature = Set-AuthenticodeSignature @signParams
        [PSCustomObject]@{
            File   = $file.FullName.Substring($RepoRoot.Length + 1)
            Status = $signature.Status
        }
    }

    return $results
}

if ($Scope -eq 'LocalMachine') {
    $isElevated = ([System.Security.Principal.WindowsPrincipal][System.Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isElevated) {
        throw '-Scope LocalMachine requires an elevated (Administrator) PowerShell session, since it installs certificates into machine-wide stores trusted by every account.'
    }
}

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$certificate = Get-OrCreateSigningCertificate -Subject $Subject -Thumbprint $CertificateThumbprint -Scope $Scope
Install-TrustedCertificate -Certificate $certificate -Scope $Scope -Force:$Force
$results = Set-RepositorySignatures -Certificate $certificate -RepoRoot $repoRoot -TimestampSigning:$TimestampSigning

$results | Format-Table -AutoSize

$failed = @($results | Where-Object { $_.Status -ne 'Valid' })
if ($failed.Count -gt 0) {
    Write-Warning "$($failed.Count) file(s) did not sign successfully (or aren't trusted yet) - check the Status column above."
}
else {
    Write-Host "All $($results.Count) file(s) signed successfully with certificate $($certificate.Thumbprint)."
    Write-Host "You can now run the toolkit under 'RemoteSigned' or 'AllSigned' execution policy without bypassing anything."
}
