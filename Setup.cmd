@echo off
setlocal

rem Single prerequisites entry point for this toolkit: unblocks the repo's
rem scripts, sets a durable execution policy, and code-signs everything
rem (via Tools\Setup-Prerequisites.ps1 / Tools\Sign-Scripts.ps1). Run this
rem once per machine/account before using Invoke-SecurityBaseline.ps1.
rem
rem Any arguments are passed through to Tools\Setup-Prerequisites.ps1, e.g.:
rem   Setup.cmd -Scope LocalMachine -Force
rem   Setup.cmd -CertificateThumbprint A1B2C3D4E5F6...

set "REPO_ROOT=%~dp0"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%REPO_ROOT%Tools\Setup-Prerequisites.ps1" %*
set "EXIT_CODE=%ERRORLEVEL%"

if not "%EXIT_CODE%"=="0" (
    echo.
    echo Setup did not complete successfully ^(exit code %EXIT_CODE%^). See the output above for details.
)

if "%~1"=="" (
    echo.
    pause
)

endlocal & exit /b %EXIT_CODE%
