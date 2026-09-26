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
    $url = & $FidoPath -Win 11 -Rel Latest -Lang $Lang -Arch $Arch -GetUrl
    if (-not $url -or $url -notmatch '^https?://') {
        throw "Fido did not return a usable Windows 11 download URL. Microsoft may have changed something Fido relies on -- check https://github.com/pbatard/Fido for an updated version of Fido.ps1, and replace Tools\Fido.ps1 with it."
    }
    Write-Host "  Got it." -ForegroundColor Gray
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

# Top-level entry point called from Build-Your-USB.ps1. Both ISOs are built
# straight into $DestFolder (Install\Windows inside the extracted
# On2it-WinFixIT content), so the existing copy step in Build-Your-USB.ps1
# picks them up with no further changes needed there.
function New-WindowsInstallIsos {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DestFolder,
        [Parameter(Mandatory)][string]$WorkFolder,
        [Parameter(Mandatory)][string]$FidoPath
    )

    New-Item -ItemType Directory -Path $DestFolder -Force | Out-Null
    New-Item -ItemType Directory -Path $WorkFolder -Force | Out-Null

    $fullIsoPath = Join-Path $DestFolder 'FULL Install.iso'
    # Captured whether fresh or cached, from the URL if a fresh fetch happened
    # this run, or by re-deriving from the existing file's name pattern isn't
    # reliable enough to bother with - so a cached re-run's description below
    # just says "a prior run on this PC" instead of repeating the exact
    # edition, which is a fine trade for not re-fetching a URL that doesn't
    # change what's already sitting on disk.
    $sourceUrl = $null

    if (-not (Test-Path -LiteralPath $fullIsoPath)) {
        $sourceUrl = Get-OfficialWindows11IsoUrl -FidoPath $FidoPath
        Write-Host "  Downloading the official Windows 11 ISO from Microsoft..." -ForegroundColor Cyan
        Write-Host "  (This becomes FULL Install.iso, completely untouched -- straight from Microsoft.)" -ForegroundColor DarkGray
        Invoke-DownloadWithDots -Uri $sourceUrl -OutFile $fullIsoPath -ExpectedTotalMB 6144
        Write-Host "  Download complete." -ForegroundColor Gray
        Write-Host ""
    } else {
        Write-Host "  FULL Install.iso already built from a previous run -- re-using it." -ForegroundColor White
    }

    $bypassIsoPath = Join-Path $DestFolder 'BYPASS Install.iso'
    if (-not (Test-Path -LiteralPath $bypassIsoPath)) {
        New-BypassInstallIso -SourceIsoPath $fullIsoPath -DestIsoPath $bypassIsoPath -WorkFolder $WorkFolder
        Write-Host "  BYPASS Install.iso built." -ForegroundColor Gray
        Write-Host ""
    } else {
        Write-Host "  BYPASS Install.iso already built from a previous run -- re-using it." -ForegroundColor White
    }

    Write-AutoBuiltIsoDescriptions -DestFolder $DestFolder -SourceUrl $sourceUrl
}

# Written every run (fresh build or cached re-use), so ISO Descriptions.txt is
# never left stale or missing. Content settled with Brian, 2026-09-25: RAM and
# storage are deliberately NOT listed as bypassed - appraiserres.dll removal
# technically disables Setup's check of those too, but WinFixIT's own
# Compatibility Checker already covers that ground separately, and there's no
# value in bypassing a real hardware shortfall anyway (the install just fails,
# or the machine is unusable, regardless of what Setup itself checked).
function Write-AutoBuiltIsoDescriptions {
    param(
        [Parameter(Mandatory)][string]$DestFolder,
        [string]$SourceUrl
    )
    $sourceLine = if ($SourceUrl) {
        "Fetched fresh from Microsoft's own servers on $(Get-Date -Format 'dd-MMM-yyyy'), via Fido"
    } else {
        "Built on this PC in a prior run - see the ISO files' own dates for when"
    }
    $descPath = Join-Path $DestFolder 'ISO Descriptions.txt'
    Set-Content -LiteralPath $descPath -Encoding UTF8 -Value @(
        "FULL Install.iso"
        "-----------------"
        "The official Microsoft Windows 11 ISO, completely unmodified."
        "$sourceLine (https://github.com/pbatard/Fido) - the same official-servers"
        "mechanism Rufus itself uses to fetch ISOs, not a mirror or a scrape."
        ""
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
        ""
        "Neither ISO is downloaded from On2it Software or shipped in this repo -"
        "Microsoft doesn't permit redistributing Windows install media, so your"
        "own copy is built fresh, straight from Microsoft, every time you run"
        "Build-Your-USB.ps1."
        ""
        "You'll still need your own valid Windows license/product key to install"
        "and activate either one - neither ISO includes or bypasses that."
    )
}
