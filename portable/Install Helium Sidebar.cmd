@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Helium Sidebar.ps1"
if errorlevel 1 echo Helium Sidebar setup could not finish.
pause
