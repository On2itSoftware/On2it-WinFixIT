<#  Build-WindowsISOs.ps1
    ======================
        Purpose: Builds FULL Install.iso and BYPASS Install.iso for the public
                 Build-Your-USB.ps1 build, straight from Microsoft's own
                 servers, instead of shipping pre-built ISOs in the download.
                 Public-build-only -- the in-house Clone-WinFixIT-USB.ps1
                 build keeps using pre-built ISOs copied from the master
                 content, since it has no redistribution exposure. See the
                 project_github_vs_inhouse_iso_policy memory for the decision
                 behind the split.

        Method: - Fido.ps1 (pbatard's official Windows-ISO-link fetcher,
                   vendored unmodified alongside this file -- GPL-3.0, same
                   licence as this repo) is run in its non-interactive
                   command-line mode to get a genuine Microsoft download URL
                   for the current Windows 11 ISO. This is the exact same
                   official-servers mechanism Rufus itself uses to fetch
                   ISOs, not a scrape or a mirror.
                 - That download, completely untouched, becomes
                   FULL Install.iso.
                 - BYPASS Install.iso is built by mounting that same ISO,
                   copying its contents out, then deleting the one file
                   Windows Setup calls to enforce the TPM/Secure Boot/RAM
                   checks: sources\appraiserres.dll. Confirmed against
                   Rufus's own source (2026-09-24): this is the actual
                   mechanism its "Extended Windows 11 Installation" checkbox
                   uses, not a registry-key workaround applied at install
                   time -- so the result behaves the same way a
                   Rufus-modified image would.
                 - The stripped folder is then repackaged as a new ISO using
                   the IMAPI2 COM interface built into Windows (no ADK /
                   oscdimg install needed). It's built as UDF, not plain
                   ISO9660 -- required, not a style choice, since modern
                   install.wim/install.esd routinely exceeds ISO9660's 4 GB
                   single-file limit. It's also deliberately NOT made
                   bootable: Install-SelectedWindowsISO in
                   Install Windows.ps1 only ever Mount-DiskImages an ISO and
                   runs setup.exe from inside it, it never boots from
                   either one.

          Notes: Depends on Invoke-DownloadWithDots and Invoke-RobocopyDotsOnly
                 already being defined in the caller's scope -- Build-Your-USB.ps1
                 dot-sources Robocopy-Common.ps1 and defines
                 Invoke-DownloadWithDots BEFORE dot-sourcing this file.

   Designed by: Brian McGuigan
            of: On2it Software Ltd
       Code by: Claude
       Version: 2 (New-WindowsInstallIsos now writes ISO Descriptions.txt
                itself, every run - fresh build or cached re-use - describing
                exactly what was bypassed and how. Content settled with
                Brian, 2026-09-25: RAM/storage deliberately not listed as
                bypassed, since WinFixIT's own Compatibility Checker already
                covers that ground and there's no value bypassing a real
                hardware shortfall anyway)
         Dated: 25-Sep-26
        Status: ISO-build mechanism not yet proven end-to-end. Needs a live
                test that Windows Setup actually accepts a BYPASS Install.iso
                rebuilt this way (IMAPI2 + appraiserres.dll strip) on real
                unsupported hardware before this replaces the pre-built ISOs
                for real.
#>

# The community-standard way to copy an IMAPI2 result image to a .iso file --
# PowerShell can't call the underlying IStream::Read directly (it needs an
# out-parameter via a raw pointer), so a tiny unsafe C# helper does the copy
# loop. This exact pattern (Create(path, stream, blockSize, totalBlocks)) is
# the same one widely mirrored from the original TechNet Gallery "New-IsoFile"
# script -- not reinvented here, deliberately, since getting the COM interop
# subtly wrong would silently produce a corrupt or truncated ISO.
if (-not ('On2it.ISOFile' -as [type])) {
    $cp = New-Object System.CodeDom.Compiler.CompilerParameters
    $cp.CompilerOptions = '/unsafe'
    Add-Type -CompilerParameters $cp -TypeDefinition @'
namespace On2it {
    public class ISOFile
    {
        public unsafe static void Create(string Path, object Stream, int BlockSize, int TotalBlocks)
        {
            int bytes = 0;
            byte[] buf = new byte[BlockSize];
            var ptr = (System.IntPtr)(&bytes);
            var o = System.IO.File.OpenWrite(Path);
            var i = Stream as System.Runtime.InteropServices.ComTypes.IStream;

            if (o != null) {
                while (TotalBlocks-- > 0) {
                    i.Read(buf, BlockSize, ptr);
                    o.Write(buf, 0, bytes);
                }
                o.Flush();
                o.Close();
            }
        }
    }
}
'@
}

# Builds a plain (non-bootable) UDF ISO from a folder's contents -- see the
# file header for why UDF, and why non-bootable is fine for this use.
function New-DataIso {
    param(
        [Parameter(Mandatory)][string]$SourceFolder,
        [Parameter(Mandatory)][string]$DestIsoPath,
        [string]$VolumeLabel = 'BYPASS_INSTALL'
    )
    if (Test-Path -LiteralPath $DestIsoPath) { Remove-Item -LiteralPath $DestIsoPath -Force }

    $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $fsi.FileSystemsToCreate = 4   # UDF only
    $fsi.UDFRevision = 0x0250      # what real Windows installation media itself uses
    # FreeMediaBlocks is the ACTUAL fix for the size failure below, not
    # UDFRevision (tried and confirmed insufficient on its own, 2026-09-25,
    # Brian live test). IMAPI2 defaults this to 332,800 blocks -- roughly a
    # standard 650 MB CD's capacity -- and enforces it regardless of which
    # filesystem/revision is selected, failing with "Adding 'boot.wim' would
    # result in a result image having a size larger than the current
    # configured limit" on a genuine ~8 GB Windows 11 image (my own earlier
    # test only used a few bytes of dummy content, so it never exercised
    # this). 0 means unlimited.
    $fsi.FreeMediaBlocks = 0
    $fsi.VolumeName = $VolumeLabel
    $fsi.Root.AddTree($SourceFolder, $false) | Out-Null

    $image = $fsi.CreateResultImage()
    [On2it.ISOFile]::Create($DestIsoPath, $image.ImageStream, $image.BlockSize, $image.TotalBlocks)
}

function Get-OfficialWindows11IsoUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FidoPath,
        [string]$Lang = 'English International',
        [string]$Arch = 'x64'
    )
    Write-Host "  Asking Microsoft for the current official Windows 11 ISO download link..." -ForegroundColor Cyan
    # Edition deliberately NOT pinned -- Fido defaults to the first edition
    # Microsoft's own API returns, which for the standard Windows 11 consumer
    # download is the combined Home/Pro retail image (the same one you'd get
    # manually from Microsoft's own "Download Windows 11 Disk Image" page).
    # Setup itself picks the right one to install based on the machine's
    # existing licence/entitlement.
    # 6>&1 captures Fido's OWN Write-Host output too, not just its final
    # return value - Write-Host targets the Information stream (#6) in
    # PowerShell 5+, and this is genuinely capturable that way (confirmed for
    # real, 2026-09-26, against a live Sentinel rejection: "Error: Sentinel
    # marked this request as rejected." came back as an InformationRecord,
    # not silently lost). Needed so the caller can show Fido's own real
    # reason in red, rather than a generic guess.
    $allOutput = & $FidoPath -Win 11 -Rel Latest -Lang $Lang -Arch $Arch -GetUrl 6>&1
    $url = $allOutput | Where-Object { $_ -is [string] -and $_ -match '^https?://' } | Select-Object -Last 1

    if (-not $url) {
        # Returns $null rather than throwing -- moved 2026-09-26 so the CALLER
        # (New-WindowsInstallIsos) can print a single, consistently coloured
        # explanation instead of a plain thrown exception message (which only
        # ever prints in one colour, no matter how the string is laid out).
        # The captured message goes in a script-scope variable rather than
        # changing this function's return type (still just a URL string or
        # $null) - keeps the success path's contract simple.
        $script:LastFidoErrorMessage = (($allOutput | ForEach-Object { $_.ToString() }) -join ' ').Trim()
        return $null
    }
    # Microsoft's own filename in the URL path carries the real release (e.g.
    # "Win11_25H2_EnglishInternational_x64_v2.iso") - shown so it's obvious
    # exactly what got fetched, not just that something did. Brian, 2026-09-26:
    # "Would it be possible to confirm what the latest version it got is?"
    $isoFileName = ($url -split '\?')[0].Split('/')[-1]
    Write-Host "  Got it: $isoFileName" -ForegroundColor Gray
    return $url
}

function New-BypassInstallIso {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceIsoPath,
        [Parameter(Mandatory)][string]$DestIsoPath,
        [Parameter(Mandatory)][string]$WorkFolder
    )

    Write-Host "  Building BYPASS Install.iso from the official ISO..." -ForegroundColor Cyan

    $extractFolder = Join-Path $WorkFolder 'BYPASS-Extract'
    if (Test-Path -LiteralPath $extractFolder) { Remove-Item -LiteralPath $extractFolder -Recurse -Force }
    New-Item -ItemType Directory -Path $extractFolder -Force | Out-Null

    $mount = Mount-DiskImage -ImagePath $SourceIsoPath -PassThru -ErrorAction Stop
    try {
        $driveLetter = ($mount | Get-Volume).DriveLetter
        Write-Host "    Copying installation files out to build the bypass version..." -ForegroundColor Gray
        $exitCode = Invoke-RobocopyDotsOnly -RobocopyArgs @(
            "$driveLetter`:\\", "$extractFolder\\", '/E', '/COPY:DAT', '/DCOPY:DAT', '/NFL', '/NDL', '/NJH', '/NJS', '/R:2', '/W:5'
        )
        if ($exitCode -ge 8) { throw "Robocopy failed copying the official ISO's contents (exit $exitCode)." }
    } finally {
        Dismount-DiskImage -ImagePath $SourceIsoPath | Out-Null
    }

    # This one file is what Windows Setup calls to enforce the TPM/Secure
    # Boot/RAM checks -- see file header. Emptied rather than deleted,
    # matching Rufus's own behaviour, in case Setup only checks that the
    # file is present and readable, not that it's non-empty.
    $appraiser = Join-Path $extractFolder 'sources\appraiserres.dll'
    if (Test-Path -LiteralPath $appraiser) {
        # Confirmed for real, 2026-09-25 (Brian, live test): failed here with
        # "Access to the path '...appraiserres.dll' is denied." ISO9660/UDF
        # media is always read-only, and the robocopy pass above (/COPY:DAT)
        # deliberately carries file Attributes across too - so the extracted
        # copy on real disk inherits the ReadOnly flag from the mounted ISO,
        # even though it's sitting on a perfectly writable NTFS folder.
        (Get-Item -LiteralPath $appraiser -Force).IsReadOnly = $false
        Set-Content -LiteralPath $appraiser -Value $null -NoNewline
    } else {
        Write-Host "    WARNING: sources\appraiserres.dll not found in the official ISO -- Microsoft may have" -ForegroundColor Yellow
        Write-Host "    restructured Windows 11 install media. The bypass may not work; please check" -ForegroundColor Yellow
        Write-Host "    for an On2it-WinFixIT update." -ForegroundColor Yellow
    }

    Write-Host "    Packaging the bypass version as an ISO (this can take a few minutes)..." -ForegroundColor Gray
    New-DataIso -SourceFolder $extractFolder -DestIsoPath $DestIsoPath -VolumeLabel 'CCCOMA_X64FRE_EN-US_DV9'

    Remove-Item -LiteralPath $extractFolder -Recurse -Force -ErrorAction SilentlyContinue
}

# Prints the step-by-step Media Creation Tool walkthrough, pauses for the
# user to go do it, then reports whether FULL Install.iso showed up. Shared
# by BOTH: New-WindowsInstallIsos's own inline fallback (when the automatic
# fetch fails, right there in the same run - added 2026-09-26, Brian: "THERE
# ARE TWO WAYS FORWARD... I should not be necessary to re-run the script")
# and Build-Your-USB.ps1's 'S' path (choosing this up front, without trying
# automatic first). One copy, so the two can't drift out of sync with
# each other the way a duplicated inline copy would.
function Show-ManualIsoInstructions {
    param([Parameter(Mandatory)][string]$DestFolder)

    Write-Host "    (1) If you already have a Windows 11 ISO that you wish to use, then you can use that:" -ForegroundColor White
    Write-Host ""
    Write-Host "    (2) If not then use Microsoft's Media Creation Tool to create one." -ForegroundColor White
    Write-Host "        1. Leave this Window open for reference, and in your browser, go to:" -ForegroundColor Gray
    Write-Host "           https://www.microsoft.com/software-download/windows11" -ForegroundColor Gray
    Write-Host "        2. Scroll to the 'Create Windows 11 Installation Media' section" -ForegroundColor Gray
    Write-Host "           (NOT 'Windows 11 Installation Assistant' - that's for a different purpose)." -ForegroundColor Gray
    Write-Host "        3. Click its 'Download Now' button. This downloads a file called" -ForegroundColor Gray
    Write-Host "           MediaCreationToolW11.exe to your Downloads folder." -ForegroundColor Gray
    Write-Host "        4. Double-click MediaCreationToolW11.exe to run it. Click Yes if" -ForegroundColor Gray
    Write-Host "           Windows asks for permission." -ForegroundColor Gray
    Write-Host "        5. Click Accept on the licence terms screen." -ForegroundColor Gray
    Write-Host "        6. Choose 'Create installation media (USB flash drive, DVD, or ISO file) for another PC'," -ForegroundColor Gray
    Write-Host "           then click Next." -ForegroundColor Gray
    Write-Host "        7. Leave 'Use the recommended options for this PC' ticked, then Next." -ForegroundColor Gray
    Write-Host "        8. Choose 'ISO file' (NOT 'USB flash drive'), then click Next." -ForegroundColor Gray
    Write-Host "        9. Choose where to save it (e.g. your Desktop), then click Save." -ForegroundColor Gray
    Write-Host "           This downloads Windows and builds the ISO - it can take a while." -ForegroundColor Gray
    Write-Host "       10. When it finishes, click Finish." -ForegroundColor Gray
    Write-Host ""
    Write-Host "     Rename your ISO file to exactly:" -ForegroundColor Gray
    Write-Host "         FULL Install.iso" -ForegroundColor Gray
    Write-Host "     and move it into:" -ForegroundColor Gray
    Write-Host "         $DestFolder" -ForegroundColor Gray
    Write-Host ""
    Write-Host "     Your 'FULL Install.iso' will be used to create a 'BYPASS Install.iso' for you," -ForegroundColor White
    Write-Host "     bypassing its TPM 2.0, Secure Boot, and supported-CPU checks." -ForegroundColor White
    Write-Host ""
    Write-Host "  Press Enter once it's there: " -NoNewline -ForegroundColor Yellow
    Read-Host
    Write-Host ""

    $suppliedFullPath = Join-Path $DestFolder 'FULL Install.iso'
    return (Test-Path -LiteralPath $suppliedFullPath)
}

# Top-level entry point called from Build-Your-USB.ps1. Both ISOs are built
# straight into $DestFolder (Install\Windows inside the extracted
# On2it-WinFixIT content), so the existing copy step in Build-Your-USB.ps1
# picks them up with no further changes needed there.
function New-WindowsInstallIsos {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DestFolder,
        [Parameter(Mandatory)][string]$WorkFolder,
        [Parameter(Mandatory)][string]$FidoPath,
        # Set by Build-Your-USB.ps1's 'S' path to skip straight to the manual
        # walkthrough without wasting time on an automatic attempt the user
        # already knows won't work (e.g. a network already Sentinel-blocked).
        [switch]$SkipAutomatic
    )

    New-Item -ItemType Directory -Path $DestFolder -Force | Out-Null
    New-Item -ItemType Directory -Path $WorkFolder -Force | Out-Null

    $fullIsoPath = Join-Path $DestFolder 'FULL Install.iso'
    $bypassIsoPathCheck = Join-Path $DestFolder 'BYPASS Install.iso'

    # Ask, don't silently assume - Brian, 2026-09-27: "How do we know that
    # they are not obsolete copies?" Checking freshness against Microsoft
    # would mean another automated hit against the same Sentinel-sensitive
    # endpoint on every single run, even when the cache is fine - not worth
    # it given we're already fighting that block. Age is a plain local file
    # timestamp instead, no network contact needed, and the user (who knows
    # whether a new Windows release has shipped recently) makes the actual
    # call. Only asked when BOTH already exist - a partial cache (one file
    # present, not the other) is unusual enough to just fall through to the
    # existing per-file handling below instead.
    if ((Test-Path -LiteralPath $fullIsoPath) -and (Test-Path -LiteralPath $bypassIsoPathCheck)) {
        $fullAgeDays = [math]::Floor(((Get-Date) - (Get-Item -LiteralPath $fullIsoPath).LastWriteTime).TotalDays)
        $bypassAgeDays = [math]::Floor(((Get-Date) - (Get-Item -LiteralPath $bypassIsoPathCheck).LastWriteTime).TotalDays)
        Write-Host "  I already have a:" -ForegroundColor White
        Write-Host "       FULL Install.iso    created $fullAgeDays day$(if ($fullAgeDays -ne 1) { 's' }) ago" -ForegroundColor White
        Write-Host "       BYPASS Install.iso  created $bypassAgeDays day$(if ($bypassAgeDays -ne 1) { 's' }) ago" -ForegroundColor White
        Write-Host "  Would you like to Re-use them or create New ones? (R/N): " -NoNewline -ForegroundColor Yellow
        $reuseChoice = Read-Host
        Write-Host ""
        if ($reuseChoice -match '^[Nn]') {
            Remove-Item -LiteralPath $fullIsoPath -Force
            Remove-Item -LiteralPath $bypassIsoPathCheck -Force
        }
    }
    # Captured whether fresh or cached, from the URL if a fresh fetch happened
    # this run, or by re-deriving from the existing file's name pattern isn't
    # reliable enough to bother with - so a cached re-run's description below
    # just says "a prior run on this PC" instead of repeating the exact
    # edition, which is a fine trade for not re-fetching a URL that doesn't
    # change what's already sitting on disk.
    $sourceUrl = $null

    # Deliberately does NOT throw/abort the whole build if this ultimately
    # fails - Windows install media is optional precisely so its absence
    # never has to block the rest of the USB (Compatibility Checker,
    # DeBloater, and the Library all work without it). On total failure this
    # writes the same "add it yourself later, no rebuild needed" description
    # the N (skip entirely) path uses, then returns normally.
    $gaveUpOnWindowsInstall = $false

    if ($SkipAutomatic -and -not (Test-Path -LiteralPath $fullIsoPath)) {
        if (-not (Show-ManualIsoInstructions -DestFolder $DestFolder)) {
            $gaveUpOnWindowsInstall = $true
        }
    }

    if ((-not $gaveUpOnWindowsInstall) -and -not (Test-Path -LiteralPath $fullIsoPath)) {
        # Falls through to the SAME manual walkthrough inline, right here, on
        # ANY failure of the automatic attempt - Sentinel block, Fido needing
        # an update, or anything else - rather than making the user close the
        # window and re-run the whole script just to reach the fallback that
        # was one prompt away the whole time.
        $sourceUrl = Get-OfficialWindows11IsoUrl -FidoPath $FidoPath
        if ($sourceUrl) {
            Write-Host "  Downloading the official Windows 11 ISO from Microsoft..." -ForegroundColor Cyan
            Write-Host "  (This becomes FULL Install.iso, completely untouched -- straight from Microsoft.)" -ForegroundColor DarkGray
            Invoke-DownloadWithDots -Uri $sourceUrl -OutFile $fullIsoPath -ExpectedTotalMB 6810
            Write-Host "  Download complete." -ForegroundColor Gray
            Write-Host ""
        } else {
            Write-Host ""
            # Strip a leading "Error:"/"Error :" from Fido's own message before
            # prepending our own "ERROR -" - otherwise this reads as the
            # redundant "ERROR - Error: ...". Confirmed for real, 2026-09-26,
            # against a live Sentinel rejection: Fido's captured message was
            # literally "Error: Sentinel marked this request as rejected."
            $fidoMsg = if ($script:LastFidoErrorMessage) {
                $script:LastFidoErrorMessage -replace '^\s*Error\s*:\s*', ''
            } else {
                "No specific reason was given."
            }
            Write-Host "  ERROR - $fidoMsg" -ForegroundColor Red
            Write-Host "  This script wasn't able to get a Windows 11 download link from Microsoft automatically just now." -ForegroundColor Red
            Write-Host ""
            Write-Host "  This can happen for a couple of reasons:" -ForegroundColor Gray
            Write-Host "    (1) Microsoft's own anti-automation protection may have rejected the request outright," -ForegroundColor Gray
            Write-Host "        especially after several automated requests from this network in a short time." -ForegroundColor Gray
            Write-Host "        If so, this may not clear quickly, and isn't something this script can work around." -ForegroundColor Gray
            Write-Host "    (2) Microsoft may have changed something this script's automatic-download step relies on," -ForegroundColor Gray
            Write-Host "        and it may need an update." -ForegroundColor Gray
            Write-Host ""
            Write-Host "  Either way, you can still build this USB right now:" -ForegroundColor White
            Write-Host ""
            if (Show-ManualIsoInstructions -DestFolder $DestFolder) {
                $sourceUrl = $null   # got it manually this time, not via Fido - description below should say so
            } else {
                $gaveUpOnWindowsInstall = $true
            }
        }
    } elseif (-not $gaveUpOnWindowsInstall) {
        # Genuinely ambiguous whether this is a prior automated run's own
        # download or something the user placed here themselves (e.g. via
        # Microsoft's Media Creation Tool, added 2026-09-26 as the fallback
        # when Fido itself is blocked - see project_github_vs_inhouse_iso_policy
        # memory, "Sentinel" finding) - wording below stays honest about that
        # rather than assuming either one.
        Write-Host "  FULL Install.iso already present -- re-using it." -ForegroundColor White
    }

    if ($gaveUpOnWindowsInstall) {
        Write-Host "  FULL Install.iso still isn't in place - continuing without Windows install" -ForegroundColor Gray
        Write-Host "  media for now. Add your own FULL Install.iso, BYPASS Install.iso, and" -ForegroundColor Gray
        Write-Host "  ISO Descriptions.txt to:" -ForegroundColor Gray
        Write-Host "  $DestFolder" -ForegroundColor Gray
        Write-Host "  any time - no need to rebuild the USB." -ForegroundColor Gray
        Write-Host ""
        Set-Content -LiteralPath (Join-Path $DestFolder 'ISO Descriptions.txt') -Encoding UTF8 -Value @(
            "No Windows installation media is included on this USB."
            ""
            "Neither the automatic download from Microsoft nor the manual Media Creation"
            "Tool option worked out when this USB was built. Compatibility Checker,"
            "DeBloater, and the Library all still work fully without it."
            ""
            "If you get FULL Install.iso and BYPASS Install.iso later, just add them (and"
            "your own description of them here) to this folder - no need to rebuild the USB."
        )
        return
    }

    $bypassIsoPath = Join-Path $DestFolder 'BYPASS Install.iso'
    $bypassBuiltByUs = $false
    if (-not (Test-Path -LiteralPath $bypassIsoPath)) {
        New-BypassInstallIso -SourceIsoPath $fullIsoPath -DestIsoPath $bypassIsoPath -WorkFolder $WorkFolder
        $bypassBuiltByUs = $true
        Write-Host "  BYPASS Install.iso built." -ForegroundColor Gray
        Write-Host ""
    } else {
        Write-Host "  BYPASS Install.iso already present -- re-using it." -ForegroundColor White
    }

    Write-AutoBuiltIsoDescriptions -DestFolder $DestFolder -SourceUrl $sourceUrl -BypassBuiltByUs $bypassBuiltByUs
}

# Written every run (fresh build or cached re-use), so ISO Descriptions.txt is
# never left stale or missing. Content settled with Brian, 2026-09-25: RAM and
# storage are deliberately NOT listed as bypassed - appraiserres.dll removal
# technically disables Setup's check of those too, but WinFixIT's own
# Compatibility Checker already covers that ground separately, and there's no
# value in bypassing a real hardware shortfall anyway (the install just fails,
# or the machine is unusable, regardless of what Setup itself checked).
#
# BypassBuiltByUs added 2026-09-26 alongside the "get FULL Install.iso
# yourself" fallback: if BYPASS Install.iso already existed rather than being
# built just now, it might be a genuine prior build of ours, OR something the
# user supplied themselves their own way - describing it as "built by
# stripping appraiserres.dll" would be an outright false claim in the second
# case, so that description is only ever written for a BYPASS this function
# actually built itself, this run.
function Write-AutoBuiltIsoDescriptions {
    param(
        [Parameter(Mandatory)][string]$DestFolder,
        [string]$SourceUrl,
        [bool]$BypassBuiltByUs = $true
    )
    $sourceLine = if ($SourceUrl) {
        "Fetched fresh from Microsoft's own servers on $(Get-Date -Format 'dd-MMM-yyyy'), via" +
        " Fido (https://github.com/pbatard/Fido) - the same official-servers mechanism Rufus" +
        " itself uses to fetch ISOs, not a mirror or a scrape."
    } else {
        "Was already present when this build ran, rather than freshly fetched - either from a" +
        " prior automated run, or supplied manually (e.g. via Microsoft's Media Creation Tool)." +
        " See this file's own date for when."
    }
    $bypassSection = if ($BypassBuiltByUs) {
        @(
            "BYPASS Install.iso"
            "-------------------"
            "The same official ISO, with one file removed: sources\appraiserres.dll -"
            "the file Windows Setup calls to enforce its hardware eligibility checks."
            "This is the same mechanism Rufus's own 'Extended Windows 11 Installation'"
            "option uses, not a registry-key workaround applied at install time."
            ""
            "Bypasses:"
            "  - TPM 2.0"
            "  - Secure Boot"
            "  - Supported-CPU family/model restriction"
            ""
            "Does NOT bypass, and doesn't need to:"
            "  - Minimum RAM (4GB) / storage (64GB) - WinFixIT's own Compatibility"
            "    Checker already checks these separately, before you ever reach this"
            "    choice. Bypassing a real hardware shortfall wouldn't help anyway -"
            "    the install would still fail, or the machine would be unusable."
            "  - The Microsoft-account/internet-connection requirement during setup -"
            "    WinFixIT's DeBloater already lets you disable or remove that"
            "    requirement after install."
        )
    } else {
        @(
            "BYPASS Install.iso"
            "-------------------"
            "This file already existed when this build ran, rather than being built by"
            "this script just now - so this description can't honestly say how it was"
            "made. If you supplied it yourself, you'll know how it was built and what"
            "it does or doesn't bypass."
        )
    }

    $descPath = Join-Path $DestFolder 'ISO Descriptions.txt'
    Set-Content -LiteralPath $descPath -Encoding UTF8 -Value (@(
        "FULL Install.iso"
        "-----------------"
        "The official Microsoft Windows 11 ISO, completely unmodified."
        $sourceLine
        ""
    ) + $bypassSection + @(
        ""
        "Neither ISO is downloaded from On2it Software or shipped in this repo -"
        "Microsoft doesn't permit redistributing Windows install media, so your"
        "own copy is built fresh, straight from Microsoft, every time you run"
        "Build-Your-USB.ps1."
        ""
        "You'll still need your own valid Windows license/product key to install"
        "and activate either one - neither ISO includes or bypasses that."
    ))
}
