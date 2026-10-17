# On2it WinFixIT USB

**WinFixIT is a FREE USB Toolkit and App**.  It has a: Windows 11 Compatibility Checker, BYPASS Installer and DeBloater.  With an Expandable Library of: Installable Apps, extensive, curated Reference Material, Utilities and Software Tools.  Build your own FREE copy of the On2it-WinFixIT USB at home.

- **Windows 11 Compatibility Checker** — works even before Windows is installed
- **BYPASS Installer** — installs Windows 11 on older hardware, bypassing Microsoft's TPM and Secure Boot requirements where necessary
- **Comprehensive DeBloater** — over 80 options, each with full plain-English advice, not just a checkbox and a technical name

![DeBloater showing real advice for the "Remove OneDrive" option](Docs/WinFixIT%20-%20DeBloater%20Screenshot.jpg)

Every option gets this treatment — not just a checkbox and a technical name, but real, opinionated, plain-English advice on what it actually does and whether you'd want it.

**Its Expandable Library** contains installable apps, curated reference material, utilities and software tools (currently 60 menus, 225 options) — and you can add your own, simply by adding files and folders.

**Why I built it**:  I spent over half a century building software.  I'd more or less retired, but was still teaching people to use computers, just to keep my hand in.  Then I upgraded to Windows 11 myself.  It left me thoroughly confused by the bloat and the setup involved.  I didn't want my students facing the same thing.  So, I reviewed what others had done.  Everything I could find, seemed aimed at technical users.

I wanted something that gave even novices sound technical advice.  So, I built WinFixIT, with two AI helpers — Copilot, then Claude, who supplied the expertise in PowerShell and Windows' internals that I didn't have.

It's free — please try it, I'd love your feedback.

This is the first time I have used AI to develop anything.  But in my whole career, I've never carried the same tools forward from one project to the next.  So, I suppose the more things change, the more they stay the same.  Though this time is the first time I didn't need to do the typing! 😊  I did however, still need to do all the testing! 😒

Connect with me on [LinkedIn](https://www.linkedin.com/in/BrianMcGuigan/) to see what else I've done. Or direct using Brian@On2itSoftware.com

**Windows installation**:  You do not have to include a Windows Installer on your USB.  The Compatibility Checker, DeBloater, and Library all work just fine without it.  If you want your USB to be able to install Windows 11, a copy of the latest version will be downloaded straight from Microsoft's official servers.  (It uses [Fido](https://github.com/pbatard/Fido), the same official-download mechanism Rufus uses.)  So, WinFixIT's **FULL Install.iso** is the untouched Microsoft image.

WinFixIT's **BYPASS Install.iso** is that same image with the one file Windows Setup uses to enforce its TPM 2.0/Secure Boot/supported-CPU checks emptied out (Setup expects the file to still exist, just unreadable) — plus a few registry values WinFixIT sets automatically right before Setup runs, since on Windows 11 builds 26000 and up (25H2 and later) the emptied file alone isn't enough by itself anymore.  Both techniques are traced from Rufus's own source code — the same approach used by its "Extended Windows 11 Installation" option.  Credit and thanks to Pete Batard and the [Rufus project](https://rufus.ie).

RAM and storage aren't touched — Compatibility Checker already covers those, and there's no point bypassing a genuine hardware shortfall.  You'll still need your own valid Windows license/product key to install and activate either one.

If Microsoft's automatic download doesn't work for you, the build walks you through getting your own copy instead — via Microsoft's Media Creation Tool, or a Windows ISO you already have.  WinFixIT will still build a BYPASS Install.iso from it for you.

## Is it safe?

**Nothing here is hidden.** Here's exactly what BYPASS Install.iso changes, and what it doesn't:

- `sources\appraiserres.dll` is emptied (zero bytes), not deleted — Setup expects the file to still exist, just unreadable as a real check.
- Right before Setup runs, WinFixIT sets these registry values — see `Set-Windows11BypassRegistryKeys` in [`Install Windows.ps1`](USB-INSTALL/Scripts/WinFixIT/Install%20Windows.ps1), the real, live source, not a copy that could fall out of step with it:
  - `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\HwReqChk\HwReqChkVars` → `SQ_SecureBootCapable=TRUE`, `SQ_SecureBootEnabled=TRUE`, `SQ_TpmVersion=2`, `SQ_RamMB=8192`
  - `HKLM\SYSTEM\Setup\MoSetup\AllowUpgradesWithUnsupportedTPMOrCPU` → `1`
- That's the whole mechanism — both techniques traced from Rufus's own source code, credited above. RAM and storage checks aren't touched at all.

**Your FULL Install.iso download is verified** against Microsoft's own published SHA256 hash before BYPASS Install.iso is built from it — see `Test-FullInstallIsoHash` in [`Build-WindowsISOs.ps1`](Tools/Build-WindowsISOs.ps1). If it doesn't match, you're told plainly and shown how to check it yourself directly against Microsoft's page, not just told to trust it.

**The rest of WinFixIT's own source is here too**, not just the BYPASS mechanism — under [`USB-INSTALL/Scripts`](https://github.com/On2itSoftware/On2it-WinFixIT/tree/master/USB-INSTALL/Scripts), including [DeBloater's text-file-driven UI](USB-INSTALL/Scripts/DeBloater/UI.ps1) and the [options/advice text it reads](USB-INSTALL/Scripts/DeBloater/UI-GroupsAndOptions.rtf). (A few things are deliberately left out: On2it Software Courses — a separate product WinFixIT merely integrates with — third-party driver binaries, and runtime logs. Everything that's WinFixIT's own code is here.)

The options/advice file is genuine RTF, not plain text — GitHub will show it as raw markup rather than formatted. That's not an oversight: DeBloater's advice panel is a WinForms `RichTextBox`, and that file's actual formatting (bold, colour) is what gives each option's advice its emphasis in the real UI. Download it and open it in WordPad or Word to see it as intended, or just read past the `\pard\plain` control codes — the advice text itself is plain English either way.

**Microsoft's own position:** installing on hardware that doesn't meet their stated requirements means you're not guaranteed to receive updates, including security updates, and Microsoft doesn't support it. That's a real tradeoff, not a technicality — it's yours to weigh, not ours to hide.

## 🎬 Watch the Video Preview (8:30)

[![Watch the WinFixIT Video Preview](Docs/WinFixIT%20-%20Video%20Preview%20Thumbnail.jpg)](https://youtu.be/QLdRPbDRlnM)

See it in action — the Compatibility Checker, BYPASS Installer, DeBloater, and the Library, all walked through.

## 👀 Quick Preview

**[Read the Quick Preview](https://raw.githubusercontent.com/On2itSoftware/On2it-WinFixIT/master/Docs/WinFixIT%20-%20Quick%20Preview.pdf)** — opens on its own in your browser's PDF viewer, full width.  Real screenshots from the system itself — see what it actually looks like before you download anything.

## 📘 User Manual

**[Read the User Manual](https://raw.githubusercontent.com/On2itSoftware/On2it-WinFixIT/master/On2it-WinFixIT/WinFixIT%20-%20User%20Manual.pdf)** — opens on its own in your browser's PDF viewer, full width.  There are 92 pages of it, including screenshots of even the Windows Setup process, for the uninitiated.  You should not need to read it, as I have gone to great lengths to ensure WinFixIT explains itself at every stage, as you go through it.  Let me know, did I succeed?  

## 📥 Illustrated Download and Quickstart Guide

**[Read the Illustrated Download and Quickstart Guide](https://raw.githubusercontent.com/On2itSoftware/On2it-WinFixIT/master/Docs/WinFixIT%20-%20Downloading%20from%20GitHub.pdf)** — opens on its own in your browser's PDF viewer, full width.  Screenshots for every step below, plus what to expect once the build itself gets going.

## Quick start

No technical experience needed — every step below is exactly what to click.

1. Near the top of this page, click the green **`<> Code`** button, then click **Download ZIP**.
2. It will download to your **Downloads** folder as a `.zip` file.  Open **File Explorer** → **Downloads**, right-click that file, and choose **Extract All...** → **Extract**.  This creates a new folder with all the files in it.
3. Open that new folder and find **`RUN - Build-Your-USB.bat`**.
4. Insert a **32GB or larger** USB drive that you're OK with completely erasing.
5. Double-click **`RUN - Build-Your-USB.bat`**.
   - You may see an "Open File - Security Warning" box first, since this was downloaded from the internet.  Click **Run** (or **Open**) to continue — this is normal for any downloaded program, not a sign anything's wrong.
   - You may also see a blue **"Windows protected your PC"** SmartScreen screen.  If so, click **More info**, then **Run anyway**.
6. A User Account Control box ("do you want to allow this app...") will appear — click **Yes**.  This is expected; the script needs admin rights to partition the USB drive.
7. A black window will open and ask you questions — which USB drive to use, and a final "Type YES to continue" confirmation before it erases the drive.  Read each prompt and answer it.
8. Then it downloads and copies everything — this takes a while (~16GB total), especially on a slower internet connection.  Once downloaded, you can reuse that download to build additional USBs from the same PC without waiting again.
9. When it says the build is complete, unplug and reinsert the USB drive (or just open it fresh in File Explorer).
   - **On a PC with Windows already installed**: double-click **`RUN - On2it-WinFixIT.bat`** to start.  This file exists on both partitions of the USB — either one works.
   - **On a PC with no OS installed at all**: set your BIOS to boot from the USB drive, and follow the on-screen prompts.

## Requirements

**To build the USB:**
- Windows 10/11
- Administrator rights (requested automatically)
- A USB drive, 32GB or larger, that you're OK with **completely erasing**
- A stable internet connection for the initial download (~16GB)

**What the built USB supports:**
- Compatibility Checker and Windows Installer work on any PC — even those without an OS.
- If any version of Windows is already installed, Compatibility Checker can do a somewhat more comprehensive job.
- DeBloater works after Windows 11 has been installed, so it can be used on pre-installed machines.

## License

Free and open source, under the GNU General Public License v3.0 (GPL-3.0) — use it, share it, modify it, even build on it commercially, as long as anything you distribute (including modified versions) stays licensed under GPL-3.0 too.  Full terms: [LICENSE](LICENSE).

## Support

Support@On2itSoftware.com — comments and suggestions are more than welcome.  😊

