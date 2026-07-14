@echo off
REM RUN - On2it-WinFixIT.bat
REM ========================
REM
REM       Purpose: Entry point that runs WinFixIT
REM       
REM        Method: Resizes Console Window
REM                Detects On2it-WinFixIT INSTALL partition
REM                Asks for Admin privileges
REM                Launches WinFixIT.ps1 from On2it-WinFixIT INSTALL\Scripts
REM
REM   Designed by: Brian McGuigan
REM            of: On2it Software Ltd
REM       Code by: Copilot
REM       Version: 4
REM         Dated: 21-Jun-26
REM        Status: TESTED

rem --- Detect USB-INSTALL partition ---
set "INSTALL_DRIVE="
for %%D in (A B C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if exist "%%D:\1. Purpose of USB-INSTALL Partition.txt" (
        set "INSTALL_DRIVE=%%D:\"
        goto :foundInstall
    )
)
:foundInstall

if not defined INSTALL_DRIVE (
    echo ERROR: USB-INSTALL partition not found.
    pause
    exit /b 1
)

:: Check for elevation
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -Command "Start-Process '%~f0' -Verb RunAs -WorkingDirectory '%~dp0'"
    exit /b
)

setlocal

set "PSFILE=%INSTALL_DRIVE%Scripts\WinFixIT.ps1"

REM --- Detect PowerShell 7 (pwsh.exe) ---
where pwsh >nul 2>&1
if %errorlevel%==0 (
    set "PSCMD=pwsh.exe"
) else (
    REM --- Fallback to Windows PowerShell 5.1 ---
    set "PSCMD=powershell.exe"
)

REM --- Resize console ---
mode con: cols=120 lines=58

REM --- Launch WinFixIT using best available PowerShell ---
start "WinFixIT" "%PSCMD%" -NoExit -ExecutionPolicy Bypass -File "%PSFILE%"

endlocal
exit /b





