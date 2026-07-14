<# Build-Your-USB.ps1
   ==================
       Purpose: Public build script. Downloads the large On2it-WinFixIT content,
                the WinPE boot files, and the (private, unlisted) Scripts bundle
                from Cloudflare R2, then partitions a USB drive and copies
                USB-INSTALL (bundled in this repo) + the downloaded content onto it.

                This is the public counterpart to the internal
                Clone-WinFixIT-USB.ps1 build script used in-house — same
                partitioning/copy logic, but pulls the large content from public
                (or unlisted) download links instead of a local company source
                drive, and does not offer the Courses partition (not distributed
                publicly).

                Source (local, this repo):
                    USB-INSTALL\                  → P1 (FAT32, 1 GB, read-only)

                Source (downloaded from Cloudflare R2):
                    On2it-WinFixIT content         → P2 (NTFS, remainder)
                    WinPE boot files               → P1 (too large for git; bootmgr,
                                                        EFI\, Boot\, sources\boot.wim)
                    Scripts bundle                 → P1\Scripts (hidden after copy)

        Calls:  Tools\sgdisk64.exe for GPT partition naming (optional --
                skipped with a warning if not present)

   Designed by: Brian McGuigan
            of: On2it Software Ltd
       Code by: Claude
       Version: 2
         Dated: 14-Jul-26
        Status: Reviewed and tested against a live R2 bucket; boot files added
                after the original version shipped without them.
#>

# ─── Self-elevate ──────────────────────────────────────────────────────────────
# Double-clicking / "Run with PowerShell" launches this without admin rights.
# Relaunch elevated (triggers a UAC prompt) and hand off to that instance.
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$PSCommandPath`""
        ) -ErrorAction Stop
    } catch {
        Write-Host ""
        Write-Host "  Failed to elevate to Administrator:" -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        Write-Host "  This usually means UAC was cancelled, or a policy is blocking" -ForegroundColor Yellow
        Write-Host "  elevation for this account. Log in with an administrator" -ForegroundColor Yellow
        Write-Host "  account and try again." -ForegroundColor Yellow
        Write-Host ""
        Read-Host "  Press Enter to close"
    }
    exit
}

# ─── Configuration ────────────────────────────────────────────────────────────
$PostInstallZipUrl  = 'https://pub-ef7ad4a1315f418ea10408fd91c554c7.r2.dev/On2it-WinFixIT.zip'       # public link -- OK to be listed anywhere
$ScriptsZipUrl       = 'https://pub-ef7ad4a1315f418ea10408fd91c554c7.r2.dev/USB-INSTALL-Scripts.zip' # UNLISTED link -- do not publish/index this URL
$BootZipUrl          = 'https://pub-ef7ad4a1315f418ea10408fd91c554c7.r2.dev/USB-INSTALL-Boot.zip'    # public link -- WinPE boot binaries (too large for git)

# SHA256 checksums of the zips above, verified after every download (fresh or
# cached) to catch a truncated/corrupted download before it silently breaks the build.
$PostInstallZipHash = '9CF9870628803A4F1F5BDFB39F1D1A968EC4D1D9CFB2086B8B62365CFF766A52'
$ScriptsZipHash      = 'BB6D151B692CA51053F44C66D8E22FD24B3A547BD2487166DAF184393393BB81'
$BootZipHash         = '7FE946C849DABE3F7D7CBEECAF50E3D01053FFB4DE604765C9E35A03614A141F'

$ScriptRoot   = $PSScriptRoot
$SRC_INSTALL  = Join-Path $ScriptRoot 'USB-INSTALL'
$SGDISK       = Join-Path $ScriptRoot 'Tools\sgdisk64.exe'

$P1_SIZE_MB      = 1024   # USB-INSTALL - FAT32 - 1 GB
$P3_SIZE_MB      = 1024   # Reserved (Courses)  - NTFS - 1 GB, structure only, never populated publicly
$GPT_OVERHEAD_MB = 50     # Safety margin for GPT metadata and alignment

$SAFE_LIST = @(
    '1. Purpose of USB-INSTALL Partition.txt',
    'RUN - On2it-WinFixIT.bat',
    'RUN - Win11-DeBloater.bat',
    'WinFixIT - User Manual.pdf',
    'Logs'
)
# Note: 'Scripts' is intentionally NOT in this list — hidden on the built USB,
# same as the internal distribution build.
# ──────────────────────────────────────────────────────────────────────────────

$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────────────────────────────────────
# 1. Validate prerequisites
# ─────────────────────────────────────────────────────────────────────────────
Clear-Host
Write-Host ""
Write-Host "  ================================================================" -ForegroundColor Cyan
Write-Host "    On2it WinFixIT - Build Your Own USB" -ForegroundColor White
Write-Host "  ================================================================" -ForegroundColor Cyan
Write-Host ""

if ($PostInstallZipUrl -like '*REPLACE-ME*' -or $ScriptsZipUrl -like '*REPLACE-ME*') {
    throw "This script has not been configured yet. Edit Build-Your-USB.ps1 and set PostInstallZipUrl / ScriptsZipUrl to your Cloudflare R2 download links."
}
if (-not (Test-Path $SRC_INSTALL)) {
    throw "USB-INSTALL folder not found next to this script (expected: $SRC_INSTALL)."
}
if (-not (Test-Path $SGDISK)) {
    Write-Host "  NOTE: Tools\sgdisk64.exe not found -- GPT partition names will be" -ForegroundColor Yellow
    Write-Host "  skipped (volume labels will still be set, cosmetic only)." -ForegroundColor Yellow
    Write-Host ""
}

function Test-DownloadHash {
    param(
        [string]$Path,
        [string]$ExpectedHash,
        [string]$Label
    )
    Write-Host "  Verifying $Label integrity..." -ForegroundColor Cyan
    $actualHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($actualHash -ne $ExpectedHash) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        throw "$Label failed its integrity check (checksum mismatch) -- the download is likely corrupted or incomplete. The bad file has been deleted; just re-run this script to try again."
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. Download On2it-WinFixIT content and Scripts bundle
# ─────────────────────────────────────────────────────────────────────────────
$tempRoot       = Join-Path $env:TEMP 'On2it-WinFixIT-Build'
$postZip        = Join-Path $tempRoot 'On2it-WinFixIT.zip'
$postExtract    = Join-Path $tempRoot 'On2it-WinFixIT'
$scriptsZip     = Join-Path $tempRoot 'USB-INSTALL-Scripts.zip'
$scriptsExtract = Join-Path $tempRoot 'Scripts'
$bootZip        = Join-Path $tempRoot 'USB-INSTALL-Boot.zip'
$bootExtract    = Join-Path $tempRoot 'Boot-Files'

New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

if (-not (Test-Path $postZip)) {
    Write-Host "  Downloading On2it-WinFixIT content (large file, this will take a while)..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $PostInstallZipUrl -OutFile $postZip
} else {
    Write-Host "  Using previously downloaded On2it-WinFixIT.zip ($tempRoot)." -ForegroundColor DarkGray
    Write-Host "  Delete that folder to force a fresh download." -ForegroundColor DarkGray
}
Test-DownloadHash -Path $postZip -ExpectedHash $PostInstallZipHash -Label 'On2it-WinFixIT.zip'
if (-not (Test-Path $postExtract)) {
    Write-Host "  Extracting On2it-WinFixIT content..." -ForegroundColor Cyan
    Expand-Archive -Path $postZip -DestinationPath $postExtract -Force
}

if (-not (Test-Path $scriptsZip)) {
    Write-Host "  Downloading Scripts bundle..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $ScriptsZipUrl -OutFile $scriptsZip
} else {
    Write-Host "  Using previously downloaded USB-INSTALL-Scripts.zip ($tempRoot)." -ForegroundColor DarkGray
}
Test-DownloadHash -Path $scriptsZip -ExpectedHash $ScriptsZipHash -Label 'USB-INSTALL-Scripts.zip'
if (-not (Test-Path $scriptsExtract)) {
    Write-Host "  Extracting Scripts bundle..." -ForegroundColor Cyan
    Expand-Archive -Path $scriptsZip -DestinationPath $scriptsExtract -Force
}

if (-not (Test-Path $bootZip)) {
    Write-Host "  Downloading WinPE boot files..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $BootZipUrl -OutFile $bootZip
} else {
    Write-Host "  Using previously downloaded USB-INSTALL-Boot.zip ($tempRoot)." -ForegroundColor DarkGray
}
Test-DownloadHash -Path $bootZip -ExpectedHash $BootZipHash -Label 'USB-INSTALL-Boot.zip'
if (-not (Test-Path $bootExtract)) {
    Write-Host "  Extracting WinPE boot files..." -ForegroundColor Cyan
    Expand-Archive -Path $bootZip -DestinationPath $bootExtract -Force
}

$SRC_POST = $postExtract

Write-Host ""

# ─────────────────────────────────────────────────────────────────────────────
# 3. List and select target USB disk
# ─────────────────────────────────────────────────────────────────────────────
$usbDisks = Get-Disk | Where-Object BusType -eq 'USB'
if (-not $usbDisks) { throw "No USB disks found. Insert the target USB drive and re-run." }

Write-Host "  Available USB disks:" -ForegroundColor Cyan
$usbDisks | Select-Object Number, FriendlyName,
    @{N='Size (GB)'; E={[math]::Round($_.Size / 1GB, 1)}} | Format-Table -AutoSize

$tgtDiskNum = [int](Read-Host "  Enter disk NUMBER of the target USB drive")
$tgtDisk    = Get-Disk -Number $tgtDiskNum

if ($tgtDisk.BusType -ne 'USB') {
    throw "Disk $tgtDiskNum is not a USB drive. Aborted for safety."
}

# If more than one USB drive is attached, disk number/size/friendly name alone
# may not be enough to tell them apart (e.g. two identical drives). If the
# selected drive already has content on it, show what's there as a last check.
if ($usbDisks.Count -gt 1) {
    $existingVolumes = Get-Partition -DiskNumber $tgtDiskNum -ErrorAction SilentlyContinue |
        Get-Volume -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveLetter }

    $foundContent = @()
    foreach ($vol in $existingVolumes) {
        $label = if ($vol.FileSystemLabel) { $vol.FileSystemLabel } else { '(no label)' }
        $items = Get-ChildItem -LiteralPath "$($vol.DriveLetter):\" -Force -ErrorAction SilentlyContinue |
            Select-Object -First 5 -ExpandProperty Name
        if ($items) {
            $more = if (@($items).Count -eq 5) { ', ...' } else { '' }
            $foundContent += "    $($vol.DriveLetter): '$label' contains: $($items -join ', ')$more"
        }
    }

    if ($foundContent.Count -gt 0) {
        Write-Host ""
        Write-Host "  You have more than one USB drive plugged in, and Disk $tgtDiskNum is not empty:" -ForegroundColor Yellow
        $foundContent | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }
        Write-Host ""
        $doubleCheck = Read-Host "  Are you sure this is the right drive? (Y/N)"
        if ($doubleCheck -notmatch '^[Yy]') { throw "Aborted by user." }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. Calculate partition sizes and confirm
# ─────────────────────────────────────────────────────────────────────────────
$diskSizeMB = [math]::Floor($tgtDisk.Size / 1MB)
$P2_SIZE_MB = $diskSizeMB - $P1_SIZE_MB - $P3_SIZE_MB - $GPT_OVERHEAD_MB

if ($P2_SIZE_MB -le 0) {
    throw "Disk is too small for the requested partition layout ($diskSizeMB MB available)."
}

Write-Host ""
Write-Host "  Target  : Disk $tgtDiskNum  $($tgtDisk.FriendlyName)  ($([math]::Round($tgtDisk.Size/1GB,1)) GB)" -ForegroundColor Yellow
Write-Host "  Layout  :"
Write-Host "    P1  USB-INSTALL                  $P1_SIZE_MB MB   FAT32  (read-only after copy)"
Write-Host "    P2  On2it-WinFixIT               $P2_SIZE_MB MB   NTFS"
Write-Host "    P3  Reserved                      $P3_SIZE_MB MB   NTFS  (structure only, not distributed publicly)"
Write-Host ""
Write-Host "  Scripts folder will be HIDDEN on this USB (same as the shop build)." -ForegroundColor Gray
Write-Host ""

# ─────────────────────────────────────────────────────────────────────────────
# 4b. Verify source content fits in planned partitions
# ─────────────────────────────────────────────────────────────────────────────
function Get-FolderSizeMB {
    param([string]$Path)
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    if (-not $sum) { $sum = 0 }
    return [math]::Ceiling($sum / 1MB)
}

Write-Host "  Checking downloaded content sizes..." -ForegroundColor Cyan
$srcInstallMB = (Get-FolderSizeMB $SRC_INSTALL) + (Get-FolderSizeMB $scriptsExtract) + (Get-FolderSizeMB $bootExtract)
$srcPostMB    = Get-FolderSizeMB $SRC_POST

$fitProblems = @()
if ($srcInstallMB -gt $P1_SIZE_MB) {
    $fitProblems += "    USB-INSTALL (+ Scripts): $srcInstallMB MB needed, $P1_SIZE_MB MB available"
}
if ($srcPostMB -gt $P2_SIZE_MB) {
    $fitProblems += "    On2it-WinFixIT: $srcPostMB MB needed, $P2_SIZE_MB MB available"
}

if ($fitProblems.Count -gt 0) {
    Write-Host ""
    Write-Host "  Downloaded content does not fit on this USB:" -ForegroundColor Red
    $fitProblems | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    Write-Host ""
    throw "Aborted: target USB is too small for the content. Use a larger USB (32GB+ recommended)."
}
Write-Host "  All content fits within the planned partitions." -ForegroundColor Green
Write-Host ""

Write-Host "  WARNING: ALL DATA ON DISK $tgtDiskNum WILL BE PERMANENTLY DESTROYED." -ForegroundColor Red
Write-Host ""
$confirm = Read-Host "  Type YES to continue"
if ($confirm -ne 'YES') { throw "Aborted by user." }

# ─────────────────────────────────────────────────────────────────────────────
# 5. Find 3 free drive letters
# ─────────────────────────────────────────────────────────────────────────────
$usedLetters = (Get-PSDrive -PSProvider FileSystem).Name
$free3 = [char[]](90..65) |
    ForEach-Object { [string]$_ } |
    Where-Object   { $_ -notin $usedLetters } |
    Select-Object  -First 3

if ($free3.Count -lt 3) { throw "Not enough free drive letters available." }

$tgtL1 = $free3[0]   # P1 - USB-INSTALL
$tgtL2 = $free3[1]   # P2 - On2it-WinFixIT
$tgtL3 = $free3[2]   # P3 - Reserved

# ─────────────────────────────────────────────────────────────────────────────
# 6. Partition the target USB
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  Partitioning disk $tgtDiskNum..." -ForegroundColor Cyan

$dpScript = @"
select disk $tgtDiskNum
clean
convert mbr
convert gpt
create partition primary size=$P1_SIZE_MB
select partition 1
format fs=fat32 quick
assign letter=$tgtL1
create partition primary size=$P2_SIZE_MB
select partition 2
format fs=ntfs quick
assign letter=$tgtL2
create partition primary
select partition 3
format fs=ntfs quick
assign letter=$tgtL3
exit
"@

$dpFile = [System.IO.Path]::GetTempFileName() + '.txt'
Set-Content -Path $dpFile -Value $dpScript -Encoding ASCII
diskpart /s $dpFile
Remove-Item $dpFile -ErrorAction SilentlyContinue

Start-Sleep -Seconds 5

foreach ($L in @($tgtL1, $tgtL2, $tgtL3)) {
    if (-not (Test-Path "$($L):\")) {
        throw "Drive $L`: did not mount after diskpart. Cannot proceed."
    }
}

Write-Host "  Setting volume labels..." -ForegroundColor Cyan
Set-Volume -DriveLetter $tgtL1 -NewFileSystemLabel 'USB-INSTALL'
Set-Volume -DriveLetter $tgtL2 -NewFileSystemLabel 'On2it-WinFixIT'
Set-Volume -DriveLetter $tgtL3 -NewFileSystemLabel 'Reserved'

if (Test-Path $SGDISK) {
    Write-Host "  Setting GPT partition names..." -ForegroundColor Cyan
    & $SGDISK --change-name=1:"USB-INSTALL"                "\\.\PhysicalDrive$tgtDiskNum"
    & $SGDISK --change-name=2:"On2it-WinFixIT" "\\.\PhysicalDrive$tgtDiskNum"
    & $SGDISK --change-name=3:"Reserved"                   "\\.\PhysicalDrive$tgtDiskNum"
}

# ─────────────────────────────────────────────────────────────────────────────
# 7. Copy content
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  Copying USB-INSTALL..." -ForegroundColor Cyan
robocopy "$SRC_INSTALL\\" "$tgtL1`:\\" /E /COPY:DAT /DCOPY:DAT /NFL /NDL /NJH /NJS /R:2 /W:5 `
    /XD "System Volume Information"
if ($LASTEXITCODE -ge 8) { throw "Robocopy failed on USB-INSTALL (exit $LASTEXITCODE)." }

Write-Host "  Copying WinPE boot files..." -ForegroundColor Cyan
robocopy "$bootExtract\\" "$tgtL1`:\\" /E /COPY:DAT /DCOPY:DAT /NFL /NDL /NJH /NJS /R:2 /W:5 `
    /XD "System Volume Information"
if ($LASTEXITCODE -ge 8) { throw "Robocopy failed on WinPE boot files (exit $LASTEXITCODE)." }

Write-Host "  Copying Scripts (will be hidden)..." -ForegroundColor Cyan
robocopy "$scriptsExtract\\" "$tgtL1`:\Scripts\\" /E /COPY:DAT /DCOPY:DAT /NFL /NDL /NJH /NJS /R:2 /W:5 `
    /XD "System Volume Information"
if ($LASTEXITCODE -ge 8) { throw "Robocopy failed on Scripts (exit $LASTEXITCODE)." }

Write-Host "  Copying On2it-WinFixIT..." -ForegroundColor Cyan
robocopy "$SRC_POST\\" "$tgtL2`:\\" /E /COPY:DAT /DCOPY:DAT /NFL /NDL /NJH /NJS /R:2 /W:5 `
    /XD "System Volume Information"
if ($LASTEXITCODE -ge 8) { throw "Robocopy failed on On2it-WinFixIT (exit $LASTEXITCODE)." }

# ─────────────────────────────────────────────────────────────────────────────
# 8. Hide Scripts folder on USB-INSTALL
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  Hiding Scripts and system files on USB-INSTALL..." -ForegroundColor Cyan

Get-ChildItem -LiteralPath "$tgtL1`:\" -Force | ForEach-Object {
    if ($SAFE_LIST -notcontains $_.Name) {
        cmd /c attrib +h +s "$($_.FullName)" 2>$null
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# 9. Set USB-INSTALL partition read-only
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "  Setting USB-INSTALL partition read-only..." -ForegroundColor Cyan
$partition = Get-Partition -DriveLetter $tgtL1
Set-Partition -DiskNumber $partition.DiskNumber -PartitionNumber $partition.PartitionNumber -IsReadOnly $true

# ─────────────────────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  ================================================================" -ForegroundColor Green
Write-Host "    Your On2it WinFixIT USB is ready!" -ForegroundColor Green
Write-Host "  ================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Drive letters assigned:" -ForegroundColor Gray
Write-Host "    $tgtL1`:  USB-INSTALL                  (FAT32, read-only)" -ForegroundColor White
Write-Host "    $tgtL2`:  On2it-WinFixIT               (NTFS)" -ForegroundColor White
Write-Host "    $tgtL3`:  Reserved                      (NTFS, empty)" -ForegroundColor White
Write-Host ""
Write-Host "  Run 'RUN - On2it-WinFixIT.bat' on the USB-INSTALL partition to start." -ForegroundColor Gray
Write-Host ""
