@echo off
set SCRIPT_DIR=%~dp0
pushd "%SCRIPT_DIR%"

rem =====================================
rem  ADB Wi-Fi Auto Install
rem =====================================

rem Prefer pwsh (PowerShell Core) if available; fall back to Windows PowerShell
where pwsh >nul 2>nul
if %errorlevel%==0 (
  pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%adb-wifi-autoinstall.ps1"
) else (
  powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%adb-wifi-autoinstall.ps1"
)

popd

pause
