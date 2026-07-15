@echo off
REM RUN - Build-Your-USB.bat
REM ========================
REM
REM       Purpose: Launches Build-Your-USB.ps1 with the flags it needs to run
REM                reliably on a fresh Windows install.
REM
REM        Method: Runs PowerShell with -ExecutionPolicy Bypass (so the script
REM                isn't blocked by a machine's default Restricted policy) and
REM                -NoExit (so the window stays open and shows any error,
REM                instead of flashing shut before it can be read).
REM                Build-Your-USB.ps1 itself then handles requesting admin
REM                rights (a UAC prompt) once it starts running.
REM
REM   Designed by: Brian McGuigan
REM            of: On2it Software Ltd
REM       Code by: Claude
REM       Version: 1
REM         Dated: 15-Jul-26
REM        Status: NEW

powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0Build-Your-USB.ps1"
