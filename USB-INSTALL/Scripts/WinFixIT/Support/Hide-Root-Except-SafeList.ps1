# HIDE-Root-Except-SafeList.ps1
# =============================
# This script hides all files and folders in the root directory of the USB
# drive except for those specified in the safe list.

Set-Location -LiteralPath (Join-Path $PSScriptRoot '..\..\..')

# Define safe list (case-insensitive match)
$safeList = @(
    '1. Purpose of USB-INSTALL Partition.txt',
    'RUN - On2it-WinFixIT.bat',
    'RUN - Win11-DeBloater.bat',
    'Scripts',
    'Logs'
)

Get-ChildItem -LiteralPath . -Force | ForEach-Object {
    if ($safeList -notcontains $_.Name) {
        cmd /c attrib +h +s "$($_.FullName)" 2>$null
    }
}

Write-Host "[PASSED] - Root contents hidden except safe list."