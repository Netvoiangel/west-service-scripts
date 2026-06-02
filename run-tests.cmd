@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "TEST_SCRIPT=%SCRIPT_DIR%tests\run-tests.ps1"

title west-service-scripts tests
cd /d "%SCRIPT_DIR%"

echo west-service-scripts tests
echo.

where powershell.exe >nul 2>nul
if errorlevel 1 (
    echo ERROR: PowerShell was not found.
    echo.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%TEST_SCRIPT%"
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if not "%EXIT_CODE%"=="0" (
    echo Tests failed. Exit code: %EXIT_CODE%
) else (
    echo Tests passed.
)
echo.
pause
exit /b %EXIT_CODE%
