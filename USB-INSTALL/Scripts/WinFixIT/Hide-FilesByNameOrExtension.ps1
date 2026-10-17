<#  Hide-FilesByNameOrExtension.ps1
    ================================

       Purpose: General-purpose utility - recursively walks a folder tree
                and sets (or, with -Unhide, clears) the Windows Hidden
                attribute on every file matching a given list of exact
                filenames and/or extensions. Built so Brian can hide the
                menu-plumbing files (`Menu Introduction.txt`,
                `Option Description.txt`, `Start.bat`) and encrypted
                Course Notes (`.encrypted`) throughout a menu tree, without
                students seeing them while browsing the USB in Explorer.

                NOTE: the Hidden attribute is a display convenience, not
                security - anyone who ticks "Show hidden files" in
                Explorer (or runs `dir /a`, `Get-ChildItem -Force`, etc.)
                sees everything again instantly. This deters casual
                browsing, same spirit as the Course Notes trigger-file
                naming trick; it is not a substitute for the encryption
                itself.

        Method: -FileNames matches by exact filename (case-insensitive).
                -Extensions matches by file extension (case-insensitive;
                works whether or not you include the leading dot).
                A file only needs to match ONE of the two lists to be
                affected. Supports -WhatIf/-Confirm (SupportsShouldProcess)
                since it changes file attributes across a whole tree -
                run with -WhatIf first to preview what would change.

   Designed by: Brian McGuigan / Claude
            of: On2it Software Ltd
       Version: 2 (tree listing: folders White, files Gray; dropped the
                redundant "Files hidden..." header line - callers already
                print their own)
         Dated: 20-Aug-26
        Status: NEW
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory=$true)][string]$RootFolder,
    [string[]]$FileNames = @(),
    [string[]]$Extensions = @(),
    [switch]$Unhide
)

if (-not (Test-Path -LiteralPath $RootFolder)) {
    Write-Host "  ERROR: Folder not found: $RootFolder" -ForegroundColor Red
    exit 1
}

if ($FileNames.Count -eq 0 -and $Extensions.Count -eq 0) {
    Write-Host "  ERROR: Supply at least one -FileNames or -Extensions value." -ForegroundColor Red
    exit 1
}

# Normalise extensions to always include the leading dot, so callers can
# pass either ".encrypted" or "encrypted".
$normalisedExtensions = $Extensions | ForEach-Object {
    if ($_.StartsWith('.')) { $_ } else { ".$_" }
}

# -ErrorAction SilentlyContinue: skips inaccessible items instead of crashing
# the whole run. Found 2026-08-11 (Brian, real test) - CREATE - WinFixIT
# USB.ps1 now calls this against a raw partition root (to hide Courses menu-
# plumbing files), and every Windows-formatted volume has a "System Volume
# Information" folder there that's access-denied even to admins. This tool
# previously only ever ran a level or two deep inside a menu tree, so it
# never hit that folder before.
$allFiles = Get-ChildItem -LiteralPath $RootFolder -Recurse -File -Force -ErrorAction SilentlyContinue

$matched = $allFiles | Where-Object {
    ($FileNames -icontains $_.Name) -or ($normalisedExtensions -icontains $_.Extension)
}

if ($matched.Count -eq 0) {
    Write-Host "  No matching files found under:" -ForegroundColor Yellow
    Write-Host "    $RootFolder" -ForegroundColor Yellow
    Write-Host ""
    exit 0
}

$changedCount   = 0
$unchangedCount = 0

# Tree of changed files only (unchanged files were never shown in the old
# per-file output either) - [ordered] hashtables so insertion order is
# preserved until the render step re-sorts folders by CreationTime.
function New-TreeNode { [ordered]@{ Files = [System.Collections.Generic.List[string]]::new(); Folders = [ordered]@{} } }
$tree = New-TreeNode

foreach ($file in $matched) {
    $relativePath  = $file.FullName.Substring($RootFolder.TrimEnd('\').Length + 1)
    $isHidden      = [bool]($file.Attributes -band [System.IO.FileAttributes]::Hidden)
    $needsChange   = if ($Unhide) { $isHidden } else { -not $isHidden }

    if (-not $needsChange) {
        $unchangedCount++
        continue
    }

    # Counted here, before ShouldProcess - under -WhatIf, ShouldProcess
    # prints its own preview line and deliberately returns $false so the
    # attribute change below is skipped, but this file still DID need
    # changing, so the summary count should reflect that either way.
    $changedCount++

    $actionText = if ($Unhide) { "Unhide" } else { "Hide" }
    if ($PSCmdlet.ShouldProcess($relativePath, $actionText)) {
        if ($Unhide) {
            $file.Attributes = $file.Attributes -band (-bnot [System.IO.FileAttributes]::Hidden)
        }
        else {
            $file.Attributes = $file.Attributes -bor [System.IO.FileAttributes]::Hidden
        }

        $segments = $relativePath -split '\\'
        $node = $tree
        for ($i = 0; $i -lt $segments.Count - 1; $i++) {
            if (-not $node.Folders.Contains($segments[$i])) { $node.Folders[$segments[$i]] = New-TreeNode }
            $node = $node.Folders[$segments[$i]]
        }
        $node.Files.Add($segments[-1])
    }
}

# Renders the tree with folders in DateCreated order - the same ordering
# WinFixIT's own menus use (see Select-CourseFolders elsewhere), so this
# listing reads in the same order the Options actually appear on screen.
# Folders in White, files in Gray - Brian, 2026-08-20: "it would be a good
# idea to differentiate between Folders and Files" - lets the tree shape
# read at a glance instead of every line looking the same.
function Write-TreeNode {
    param($Node, [string]$PathPrefix, [int]$Depth)
    $indent = '   ' * $Depth
    foreach ($f in ($Node.Files | Sort-Object)) {
        Write-Host "$indent$f" -ForegroundColor DarkGray
    }
    $sortedFolderNames = $Node.Folders.Keys | ForEach-Object {
        [PSCustomObject]@{ Name = $_; Created = (Get-Item -LiteralPath (Join-Path $PathPrefix $_) -Force).CreationTime }
    } | Sort-Object Created | Select-Object -ExpandProperty Name

    foreach ($folderName in $sortedFolderNames) {
        Write-Host "$indent$folderName" -ForegroundColor White
        Write-TreeNode -Node $Node.Folders[$folderName] -PathPrefix (Join-Path $PathPrefix $folderName) -Depth ($Depth + 1)
    }
}

# No "Files hidden..." header here any more - every caller already prints
# its own explanatory header (e.g. "Hiding menu-plumbing files on Courses
# partition") immediately before calling this script, so this line was
# always a redundant repeat of that. Brian, 2026-08-20: "not needed."
if ($changedCount -gt 0) {
    Write-TreeNode -Node $tree -PathPrefix $RootFolder -Depth 1
}

Write-Host ""
Write-Host "  Done - $changedCount file(s) changed, $unchangedCount already correct." -ForegroundColor Green
Write-Host ""
