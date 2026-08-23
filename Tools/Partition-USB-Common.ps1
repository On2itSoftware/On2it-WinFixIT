<#  Partition-USB-Common.ps1
    ========================
       Purpose: Shared partitioning logic used by BOTH the in-house
                Clone-WinFixIT-USB.ps1 build and the public
                Build-Your-USB.ps1 build. Dot-sourced by each -- do NOT
                inline a second copy of this logic in either script.

                A byte-identical copy of this file lives in the public
                repo at On2it-WinFixIT-USB-Public\Tools\Partition-USB-Common.ps1.
                Run "COPY - Shared Scripts to Public Repo.bat" after editing
                this file to push the change to that copy (it still needs
                a manual `git add/commit/push` in the public repo after that
                to actually publish it).

        Method: Invoke-USBPartitioning creates 2 or 3 partitions (skipping
                the Reserved/Courses partition entirely -- and giving its
                space to P2 instead -- when there's no Courses content to
                put on it), formats/assigns each with a bounded retry (the
                format+assign step is known to be flaky on some USB
                controllers immediately after partition creation), sets
                volume labels, optionally sets GPT partition names via
                sgdisk, and prints one consolidated summary once everything
                has actually succeeded.

                Select-TargetUSBDisk, Show-ExistingPartitions and
                Confirm-WholeDiskWipe (added 2026-08-01) are the shared
                "pick a USB disk, show what's on it, get a whole-disk-wipe
                confirmation" flow, extracted from Clone - WinFixIT
                USB.ps1 at Brian's request so Create - Course Distribution
                USB.ps1 (a lighter-weight, single-partition tool built the
                same day) shows the IDENTICAL disk-identification and
                overwrite-warning UI rather than a second, drifting copy.
                Select-TargetUSBDisk throws on a fatal selection failure
                (matching Clone's original behaviour exactly) - callers
                that loop over multiple USBs in one run (like Create -
                Course Distribution USB.ps1) should wrap the call in
                try/catch and continue their retry loop on failure instead
                of letting the whole script exit.

   Designed by: Brian McGuigan
            of: On2it Software Ltd
       Code by: Claude
       Version: 2 (added shared disk-selection/warning functions)
         Dated: 01-Aug-26
        Status: NEW
#>

function Invoke-DiskpartScript {
    param([string]$Script)
    $dpFile = [System.IO.Path]::GetTempFileName() + '.txt'
    Set-Content -Path $dpFile -Value $Script -Encoding ASCII
    $output = diskpart /s $dpFile
    Remove-Item $dpFile -ErrorAction SilentlyContinue
    return $output
}

# Enumerates USB disks and prompts for a NUMBER if more than one is found -
# skips the question entirely when there's only one. Throws on a fatal
# selection failure (none found, chosen disk isn't USB) - callers that need
# to retry instead of exiting (e.g. a multi-USB loop) should wrap this in
# try/catch. Returns the selected Get-Disk object.
function Select-TargetUSBDisk {
    $usbDisks = @(Get-Disk | Where-Object BusType -eq 'USB')
    if ($usbDisks.Count -eq 0) { throw "No USB disks found. Insert the target USB drive and re-run." }

    if ($usbDisks.Count -eq 1) {
        $tgtDisk = $usbDisks[0]
        Write-Host "  Only one USB disk found: Disk $($tgtDisk.Number)  $($tgtDisk.FriendlyName)  ($([math]::Round($tgtDisk.Size/1GB,1)) GB) - using it." -ForegroundColor Cyan
        return $tgtDisk
    }

    Write-Host "  Available USB disks:" -ForegroundColor Cyan
    # Routed through Out-String/Write-Host rather than left as a bare pipeline
    # object - a bare Format-Table -AutoSize relies on PowerShell's implicit
    # default-formatter timing, which proved unreliable in a freshly-elevated
    # console (confirmed 2026-08-02, Brian: table didn't reliably appear).
    (($usbDisks | Select-Object Number, FriendlyName,
        @{N='Size (GB)'; E={[math]::Round($_.Size / 1GB, 1)}} | Format-Table -AutoSize | Out-String)).TrimEnd() | Write-Host

    # Validated locally with its own retry loop - blank/non-numeric input used
    # to silently cast to disk 0 ([int]'' evaluates to 0 in PowerShell, no
    # exception), sending the whole "insert USB" outer loop back to square
    # one on every wrong keystroke - confirmed 2026-08-02 (Brian, real 2-disk
    # test) as a genuine repeating-error loop, not just a cosmetic annoyance.
    while ($true) {
        Write-Host "  Enter disk NUMBER of the target USB drive: " -NoNewline -ForegroundColor Yellow
        $inputText = Read-Host
        $parsedNum = 0
        if ([int]::TryParse($inputText, [ref]$parsedNum) -and ($usbDisks | Where-Object Number -eq $parsedNum)) {
            return Get-Disk -Number $parsedNum
        }
        Write-Host "  '$inputText' is not one of the disk numbers listed above - try again." -ForegroundColor Red
    }
}

# Lists every partition currently on $Disk (drive letter, label, size) so the
# caller can see exactly what a whole-disk wipe is about to destroy - added
# 2026-08-01 after Brian nearly reformatted a real 3-partition WinFixIT USB
# without realising it, because the warning only named the disk, not its
# contents.
function Show-ExistingPartitions {
    param([Parameter(Mandatory)] $Disk)
    $existingPartitions = @(Get-Partition -DiskNumber $Disk.Number -ErrorAction SilentlyContinue)
    if ($existingPartitions.Count -eq 0) { return }
    Write-Host "  Currently on this disk (EVERYTHING WILL BE ERASED):" -ForegroundColor Yellow
    foreach ($p in $existingPartitions) {
        $vol    = if ($p.DriveLetter) { Get-Volume -Partition $p -ErrorAction SilentlyContinue } else { $null }
        $label  = if ($vol -and $vol.FileSystemLabel) { $vol.FileSystemLabel } else { '(no label)' }
        $letter = if ($p.DriveLetter) { "$($p.DriveLetter):" } else { '   ' }
        Write-Host ("    {0,-3} {1,-28}{2,6:N1} GB" -f $letter, $label, ($p.Size / 1GB)) -ForegroundColor White
    }
}

# Bold whole-disk-destruction warning, requiring the user to type the word
# YES (not just Y/N) to proceed. Returns $true if confirmed.
function Confirm-WholeDiskWipe {
    param([Parameter(Mandatory)] [int]$DiskNum)
    Write-Host "$([char]27)[1m  WARNING: ALL DATA ON DISK $DiskNum WILL BE PERMANENTLY DESTROYED.  $([char]27)[0m" -ForegroundColor Red -BackgroundColor White
    Write-Host ""
    Write-Host "  Type YES to continue: " -NoNewline -ForegroundColor Yellow
    return ((Read-Host) -eq 'YES')
}

# A dot per second during this phase is enough reassurance that it's still
# working without bringing back noisy step-by-step diskpart narration.
function Write-DotsWhileSleeping {
    param([int]$Seconds)
    for ($i = 0; $i -lt $Seconds; $i++) {
        Write-Host -NoNewline '.'
        Start-Sleep -Seconds 1
    }
}

function Invoke-USBPartitioning {
    param(
        [Parameter(Mandatory)] [int]$DiskNum,
        [Parameter(Mandatory)] [bool]$CoursesHasContent,
        [Parameter(Mandatory)] [string]$L1,
        [Parameter(Mandatory)] [string]$L2,
        [string]$L3,
        [Parameter(Mandatory)] [int]$P1SizeMB,
        [Parameter(Mandatory)] [int]$P2SizeMB,
        [int]$P3SizeMB = 0,
        [string]$L2Label = 'On2it-WinFixIT',
        [string]$L3Label = 'Reserved',
        [string]$SgdiskPath
    )

    Write-Host ""
    Write-Host -NoNewline "  Partitioning"

    $createScript = if ($CoursesHasContent) {
@"
select disk $DiskNum
clean
convert mbr
convert gpt
create partition primary size=$P1SizeMB
create partition primary size=$P2SizeMB
create partition primary
exit
"@
    } else {
@"
select disk $DiskNum
clean
convert mbr
convert gpt
create partition primary size=$P1SizeMB
create partition primary
exit
"@
    }
    $null = Invoke-DiskpartScript $createScript
    Write-Host -NoNewline '.'

    Write-DotsWhileSleeping -Seconds 5

    $partPlan = @(
        @{ Num = 1; FS = 'fat32'; Letter = $L1 }
        @{ Num = 2; FS = 'ntfs';  Letter = $L2 }
    )
    if ($CoursesHasContent) {
        $partPlan += @{ Num = 3; FS = 'ntfs'; Letter = $L3 }
    }

    $MAX_FORMAT_ATTEMPTS = 3   # bounded retry for the flaky format/assign step - do not retry forever

    foreach ($p in $partPlan) {
        $mounted = $false
        for ($attempt = 1; $attempt -le $MAX_FORMAT_ATTEMPTS; $attempt++) {
            Write-DotsWhileSleeping -Seconds 2
            $dpOutput = Invoke-DiskpartScript @"
select disk $DiskNum
rescan
select disk $DiskNum
select partition $($p.Num)
format fs=$($p.FS) quick
assign letter=$($p.Letter)
exit
"@
            Write-Host -NoNewline '.'
            Write-DotsWhileSleeping -Seconds 2
            if (Test-Path "$($p.Letter):\") {
                $mounted = $true
                break
            }
            Write-Host ""
            Write-Host "  Partition $($p.Num) format/assign attempt $attempt failed - retrying..." -ForegroundColor Yellow
            Write-Host "  diskpart output for that attempt:" -ForegroundColor DarkGray
            $dpOutput | Where-Object { $_.Trim() } | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        }
        if (-not $mounted) {
            throw "Partition $($p.Num) failed to format/mount after $MAX_FORMAT_ATTEMPTS attempts."
        }
    }

    Set-Volume -DriveLetter $L1 -NewFileSystemLabel 'USB-INSTALL'
    Write-Host -NoNewline '.'
    Set-Volume -DriveLetter $L2 -NewFileSystemLabel $L2Label
    Write-Host -NoNewline '.'
    if ($CoursesHasContent) {
        Set-Volume -DriveLetter $L3 -NewFileSystemLabel $L3Label
        Write-Host -NoNewline '.'
    }

    # sgdisk's own console output is pure noise on the happy path - silent on
    # success, full raw output only shown if a naming operation actually fails.
    function Set-GptPartitionName {
        param([int]$PartitionNum, [string]$Name)
        $sgOutput = & $SgdiskPath --change-name="${PartitionNum}:$Name" "\\.\PhysicalDrive$DiskNum" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  WARNING: Failed to set GPT name for partition $PartitionNum ('$Name') - sgdisk output:" -ForegroundColor Yellow
            $sgOutput | Where-Object { $_.Trim() } | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        }
    }

    if ($SgdiskPath -and (Test-Path $SgdiskPath)) {
        Set-GptPartitionName -PartitionNum 1 -Name 'USB-INSTALL'
        Write-Host -NoNewline '.'
        Set-GptPartitionName -PartitionNum 2 -Name $L2Label
        Write-Host -NoNewline '.'
        if ($CoursesHasContent) {
            Set-GptPartitionName -PartitionNum 3 -Name $L3Label
            Write-Host -NoNewline '.'
        }
    }
    Write-Host ""

    # One consolidated summary now that partitioning, formatting, labelling, and
    # GPT naming have all actually succeeded.
    $partSummary = @(
        @{ Num = 1; Name = 'USB-INSTALL'; SizeMB = $P1SizeMB; FS = 'FAT32' }
        @{ Num = 2; Name = $L2Label;      SizeMB = $P2SizeMB; FS = 'NTFS'  }
    )
    if ($CoursesHasContent) {
        $partSummary += @{ Num = 3; Name = $L3Label; SizeMB = $P3SizeMB; FS = 'NTFS' }
    }
    Write-Host ""
    # Label width is computed from the actual longest label, not a fixed
    # guess - a hardcoded width let "On2it Software Courses" overflow it
    # entirely, gluing "formatted with" straight onto the label with no
    # space at all (confirmed 2026-08-02, Brian). This keeps every "MB"
    # column aligned regardless of how long any partition name is.
    $labels     = $partSummary | ForEach-Object { "Partition $($_.Num) '$($_.Name)'" }
    $maxLabelLen = ($labels | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
    for ($i = 0; $i -lt $partSummary.Count; $i++) {
        $ps = $partSummary[$i]
        Write-Host ("    {0,-$($maxLabelLen + 2)}formatted with {1,8} MB ({2})" -f $labels[$i], $ps.SizeMB.ToString('N0'), $ps.FS) -ForegroundColor Gray
    }
}

# Sets a partition read-only via the modern Storage Management API
# (Set-Partition), falling back to diskpart's "attributes volume set readonly"
# if that fails with "Not Supported" -- confirmed 2026-07-18: some USB
# controllers' drivers don't support the modern API for this at all, but honor
# diskpart's older volume-attribute mechanism instead. Returns $true if either
# method succeeded, $false if neither did (caller should warn, not fail the
# whole build over this -- everything else has already completed successfully
# at this point).
function Set-PartitionReadOnlySafe {
    param(
        [int]$DiskNum,
        [char]$DriveLetter
    )
    $partition = Get-Partition -DriveLetter $DriveLetter
    try {
        Set-Partition -DiskNumber $partition.DiskNumber -PartitionNumber $partition.PartitionNumber -IsReadOnly $true -ErrorAction Stop
        return $true
    } catch {
        $roOutput = Invoke-DiskpartScript @"
select disk $DiskNum
select partition $($partition.PartitionNumber)
attributes volume set readonly
exit
"@
        return ($roOutput -match 'successfully')
    }
}
