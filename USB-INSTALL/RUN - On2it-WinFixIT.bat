@echo off
REM RUN - On2it-WinFixIT.bat
REM ========================
REM
REM       Purpose: Entry point that runs WinFixIT. This is a SINGLE file kept
REM                identical in two locations - USB-INSTALL (where it lives
REM                alongside WinFixIT.ps1) and On2it-WinFixIT (for users who
REM                look in that partition first). Not a real-launcher-plus-
REM                redirect pair - genuinely the same file, duplicated, per
REM                Brian (2026-08-05): "We need to have one file that works
REM                in both development and on the final USB, without being
REM                changed... Even if we have copies of it in two locations."
REM
REM        Method: Resizes Console Window
REM                Detects the USB-INSTALL partition three ways, in order:
REM                  1. A real USB with separate drive letters - scan for
REM                     USB-INSTALL's marker file at each drive's root.
REM                  2. Not on a real USB, and THIS copy is the one sitting
REM                     directly inside USB-INSTALL itself - check own folder.
REM                  3. Not on a real USB, and THIS copy is the one sitting
REM                     inside On2it-WinFixIT instead - check the sibling
REM                     "..\USB-INSTALL\" folder next to it.
REM                Asks for Admin privileges
REM                Launches WinFixIT.ps1 from the USB-INSTALL partition found above
REM
REM   Designed by: Brian McGuigan
REM            of: On2it Software Ltd
REM       Code by: Copilot / Claude
REM       Version: 5 (single file duplicated to both locations, not a proxy pair)
REM         Dated: 05-Aug-26
REM        Status: TESTED

rem --- Detect USB-INSTALL partition ---
set "INSTALL_DRIVE="
for %%D in (A B C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if exist "%%D:\1. Purpose of USB-INSTALL Partition.txt" (
        set "INSTALL_DRIVE=%%D:\"
        goto :foundInstall
    )
)

rem --- Not on a real USB: this copy may already live inside USB-INSTALL itself ---
if exist "%~dp01. Purpose of USB-INSTALL Partition.txt" (
    set "INSTALL_DRIVE=%~dp0"
    goto :foundInstall
)

rem --- Or this copy lives inside On2it-WinFixIT, with USB-INSTALL as its sibling ---
if exist "%~dp0..\USB-INSTALL\1. Purpose of USB-INSTALL Partition.txt" (
    set "INSTALL_DRIVE=%~dp0..\USB-INSTALL\"
    goto :foundInstall
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
