@echo off
REM Reboot-To-BIOS.bat
REM ==================
REM
REM       Purpose: Reboots directly into UEFI Firmware Settings (BIOS)
REM
REM        Method: Checks for admin privileges and UEFI firmware,
REM                then issues shutdown /r /fw /t 0
REM
REM   Designed by: Brian McGuigan
REM            of: On2it Software Ltd
REM       Code by: Claude
REM       Version: 1
REM         Dated: 25-Jun-26

:: Check for admin privileges
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:: Check for UEFI (PEFirmwareType = 2 means UEFI, 1 means Legacy BIOS)
powershell -Command "exit ((Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control' -Name PEFirmwareType -ErrorAction SilentlyContinue).PEFirmwareType -eq 2 ? 0 : 1)"
if %errorlevel% neq 0 (
    echo.
    echo  This PC uses a Legacy BIOS - direct firmware reboot is not supported.
    echo  Please press the appropriate key at startup instead ^(Del, F2, F10 etc.^)
    echo.
    pause
    exit /b 1
)

echo.
echo  Rebooting into UEFI Firmware Settings...
echo  Your PC will restart in 5 seconds.
echo.
timeout /t 5
shutdown /r /fw /t 0
