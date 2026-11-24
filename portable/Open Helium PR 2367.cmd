@echo off
setlocal
set "_helium_sidebar_profile=%LOCALAPPDATA%\Helium PR 2367 Compact\User Data"
if not exist "%_helium_sidebar_profile%\Default\Preferences" (
  if not exist "%_helium_sidebar_profile%\Default" mkdir "%_helium_sidebar_profile%\Default"
  copy /Y "%~dp0Sidebar Defaults.json" "%_helium_sidebar_profile%\Default\Preferences" >nul
  if errorlevel 1 exit /b 1
)
start "" "%~dp0chrome.exe" --no-first-run --no-default-browser-check "--user-data-dir=%_helium_sidebar_profile%"
