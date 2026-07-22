<#
.SYNOPSIS
    Code-signs every .ps1/.psm1 file in this repository so it can run under
    RemoteSigned or AllSigned execution policy without Unblock-File or
    -ExecutionPolicy Bypass.

.DESCRIPTION
    Standalone/workgroup devices have no domain to push a trusted CA root via
    Group Policy, so this creates (or reuses) a self-signed code-signing
    certificate, installs it into the LocalMachine Trusted Root and Trusted
    Publisher stores so Windows considers it trusted, and signs every script
    in the repo with it.

    Run this once per machine that will execute the toolkit, from an elevated
    PowerShell session. Re-run it any time a script file changes — editing a
    signed file invalidates its signature.

    If your organization already has a code-signing certificate (issued by an
    internal CA or a public one), pass its thumbprint via
    -CertificateThumbprint instead of creating a new self-signed certificate.

.PARAMETER Subject
    Subject name for a newly created self-signed certificate. Ignored if
    -CertificateThumbprint is supplied.

.PARAMETER CertificateThumbprint
    Thumbprint of an existing code-signing certificate (in CurrentUser\My or
    LocalMachine\My) to use instead of creating a self-signed one.

.PARAMETER TimestampSigning
    Add a trusted timestamp to each signature (requires internet access to
    reach the timestamp server) so the signature remains valid after the
    certificate itself expires. Not needed for a short-lived internal
    deployment; off by default since these are offline/workgroup devices.

.EXAMPLE
    .\Tools\Sign-Scripts.ps1

.EXAMPLE
    .\Tools\Sign-Scripts.ps1 -CertificateThumbprint 'A1B2C3D4E5F6...'
#>
[CmdletBinding()]
param(
    [string]$Subject = 'CN=SecurityBaseline Code Signing',
    [string]$CertificateThumbprint,
    [switch]$TimestampSigning
)

function Get-OrCreateSigningCertificate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Subject,
        [string]$Thumbprint
    )

    if ($Thumbprint) {
        $existing = Get-ChildItem -Path Cert:\CurrentUser\My, Cert:\LocalMachine\My -CodeSigningCert -ErrorAction SilentlyContinue |
            Where-Object { $_.Thumbprint -eq $Thumbprint } | Select-Object -First 1
        if (-not $existing) {
            throw "No certificate with thumbprint '$Thumbprint' found in CurrentUser\My or LocalMachine\My."
        }
        return $existing
    }

    $existing = Get-ChildItem -Path Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -eq $Subject } | Sort-Object -Property NotAfter -Descending | Select-Object -First 1
    if ($existing -and $existing.NotAfter -gt (Get-Date)) {
        Write-Host "Reusing existing signing certificate: $($existing.Thumbprint)"
        return $existing
    }

    Write-Host "Creating new self-signed code-signing certificate: $Subject"
    return New-SelfSignedCertificate -Type CodeSigningCert -Subject $Subject `
        -KeyUsage DigitalSignature -FriendlyName 'SecurityBaseline Code Signing' `
        -NotAfter (Get-Date).AddYears(5) -CertStoreLocation Cert:\CurrentUser\My
}

function Install-TrustedCertificate {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Certificate)

    $tempPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "securitybaseline-signing-$($Certificate.Thumbprint).cer"
    Export-Certificate -Cert $Certificate -FilePath $tempPath -Force | Out-Null

    foreach ($storePath in 'Cert:\LocalMachine\Root', 'Cert:\LocalMachine\TrustedPublisher') {
        $alreadyTrusted = Get-ChildItem -Path $storePath -ErrorAction SilentlyContinue |
            Where-Object { $_.Thumbprint -eq $Certificate.Thumbprint }
        if (-not $alreadyTrusted) {
            Import-Certificate -FilePath $tempPath -CertStoreLocation $storePath | Out-Null
            Write-Host "Installed certificate into $storePath"
        }
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

$isElevated = ([System.Security.Principal.WindowsPrincipal][System.Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isElevated) {
    throw 'This script must be run from an elevated (Administrator) PowerShell session, since it installs certificates into the LocalMachine store.'
}

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$certificate = Get-OrCreateSigningCertificate -Subject $Subject -Thumbprint $CertificateThumbprint
Install-TrustedCertificate -Certificate $certificate
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
