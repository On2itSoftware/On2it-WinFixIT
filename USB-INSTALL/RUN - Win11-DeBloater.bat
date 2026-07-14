@echo off
REM RUN - Win11-DeBloater.bat
REM =========================

:: Resize console
mode con: cols=100 lines=25

:: Set usbRoot to the folder this script lives in
set "usbRoot=%~dp0"

:: Check for elevation
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:: Launch the Winstaller script with elevation
pushd "%usbRoot%Scripts"
powershell.exe -NoExit -ExecutionPolicy Bypass -File "DeBloater.ps1"
popd