@echo off
REM RUN - Build-Your-USB.bat
REM ========================
REM
REM       Purpose: Launches Build-Your-USB.ps1 with the flags it needs to run
REM                reliably on a fresh Windows install.
REM
REM        Method: Runs PowerShell with -ExecutionPolicy Bypass (so the script
REM                isn't blocked by a machine's default Restricted policy).
REM                Build-Your-USB.ps1 itself then handles requesting admin
REM                rights (a UAC prompt) once it starts running.
REM
REM                Deliberately does NOT use -NoExit - Brian, 2026-08-24: the
REM                elevated relaunch left its own window open at a bare
REM                PowerShell prompt after finishing (fixed by dropping
REM                -NoExit there), but this FIRST, non-elevated instance had
REM                the exact same problem for the exact same reason - it's
REM                also started with -NoExit, so its own `exit` (right after
REM                handing off to the elevated relaunch) gets swallowed by
REM                the same Windows PowerShell quirk, leaving THIS window
REM                sitting open behind the elevated one too. Not needed
REM                either way - Build-Your-USB.ps1 already has its own
REM                "Press Enter to close" pause on every error path, so
REM                nothing flashes shut unread.
REM
REM   Designed by: Brian McGuigan
REM            of: On2it Software Ltd
REM       Code by: Claude
REM       Version: 2 (dropped -NoExit - was leaving this window open behind
REM                the elevated one)
REM         Dated: 24-Aug-26
REM        Status: NEW

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-Your-USB.ps1"
