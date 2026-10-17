@echo off
REM HIDE - Menu Files.bat
REM =====================
REM
REM       Purpose: Recursively hides the menu-plumbing files (Menu
REM                Introduction.txt, Option Description.txt, Start.bat) and
REM                encrypted Course Notes (.encrypted) throughout whichever
REM                menu tree this .bat is copied into and run from - so
REM                students Browse a clean folder structure in Explorer
REM                without seeing the behind-the-scenes files.
REM
REM        Method: Copy this .bat anywhere inside (or at the root of) a
REM                menu tree - e.g. the "On2it Software Courses" folder, or
REM                a WinFixIT Install tree - and run it there. It hides
REM                everything from that folder down. Delegates to the
REM                general-purpose Hide-FilesByNameOrExtension.ps1.
REM
REM    IMPORTANT: The Hidden attribute is a display convenience, not
REM                security - "Show hidden files" in Explorer instantly
REM                reveals everything again. This deters casual browsing
REM                only, same spirit as other tricks in this scheme.
REM
REM   Designed by: Brian McGuigan / Claude
REM            of: On2it Software Ltd
REM       Version: 1
REM         Dated: 30-Jul-26
REM        Status: NEW

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "D:\Company\WinFixIT\Development\USB-INSTALL\Scripts\WinFixIT\Hide-FilesByNameOrExtension.ps1" -RootFolder "%~dp0" -FileNames "Menu Introduction.txt","Option Description.txt","Start.bat" -Extensions ".encrypted"
pause
