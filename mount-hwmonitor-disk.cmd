@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%scripts\mount-hwmonitor-disk.ps1"

title HWMONITOR disk mount
cd /d "%SCRIPT_DIR%"

echo HWMONITOR disk mount
echo.

where powershell.exe >nul 2>nul
if errorlevel 1 (
    echo ERROR: PowerShell was not found.
    echo.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%"
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if not "%EXIT_CODE%"=="0" (
    echo Finished with errors. Exit code: %EXIT_CODE%
) else (
    echo Finished successfully.
)
echo.
pause
exit /b %EXIT_CODE%
