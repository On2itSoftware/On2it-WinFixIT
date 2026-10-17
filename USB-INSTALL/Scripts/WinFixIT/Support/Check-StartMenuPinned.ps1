# Quick diagnostic script to check Start Menu pinned area structure
# Exports Start Menu layout and displays the pinnedList property

$exportPath = Join-Path $env:TEMP "StartLayout.json"
Export-StartLayout -Path $exportPath -ErrorAction Stop

$json = Get-Content $exportPath -Raw | ConvertFrom-Json

if ($json.pinnedList) {
    Write-Host "PinnedList property found. Listing pinned items:"
    $json.pinnedList | Format-List
} else {
    Write-Host "No pinnedList property found. Here is the top-level structure:"
    $json | Get-Member
    Write-Host "Full JSON content:"
    $json
}
