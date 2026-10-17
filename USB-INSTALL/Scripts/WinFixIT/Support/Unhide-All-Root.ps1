# Unhide-All-Root.ps1
# ===================
# Unhide everything in USB root
Set-Location -LiteralPath (Join-Path $PSScriptRoot '..\..\..')

Get-ChildItem -LiteralPath . -Force | ForEach-Object {
    cmd /c attrib -h -s "$($_.FullName)" 2>$null
}

Write-Host "[PASSED] - Root contents unhidden."