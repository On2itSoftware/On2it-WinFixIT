# On2it WinFixIT USB

A self-contained Windows Compatibility Checker, Installer, DeBloater, and Advisor — build your own copy of the On2it-WinFixIT USB at home.

- Checks compatibility of any PC to run Windows 11
- Installs it, bypassing its usual TPM requirements, if needed
- Installs Office and any other apps loaded on the USB
- Debloats Windows 11's unwanted apps and settings — with complete advice, and the **pros and cons** of every setting
- Choose what **you** want, or accept our recommended advice — the choice is yours!
- Extensive library of curated off-line and on-line reference material, utilities, and software tools
- Extensible — add your own apps, menu entries, and options simply by adding files and folders to the USB 😊

**A note on Windows installation media**: the Windows ISOs included in the download are sourced from a third party and require your own valid Windows license/product key to install and activate — they're not included with WinFixIT itself.  The included `BYPASS Install.iso` (which skips the usual TPM/Secure Boot checks) was created using Rufus 4.15p.  If you'd rather supply your own, simply substitute your own `FULL Install.iso` and `BYPASS Install.iso` in the `Install\Windows` folder of the `On2it-WinFixIT` partition.  (Office, Project, and Visio installers are *not* included in this public build at all — those are licensed specifically to On2it Software Ltd and won't work with anyone else's key anyway.)

## 📘 User Manual

**[Read the User Manual](USB-INSTALL/WinFixIT%20-%20User%20Manual.pdf)** — click to preview it right here on GitHub, no download required.

## Quick start

No technical experience needed — every step below is exactly what to click.

1. Near the top of this page, click the green **`<> Code`** button, then click **Download ZIP**.
2. It will download to your **Downloads** folder as a `.zip` file.  Open **File Explorer** → **Downloads**, right-click that file, and choose **Extract All...** → **Extract**.  This creates a new folder with all the files in it.
3. Open that new folder and find **`Build-Your-USB.ps1`**.
4. Insert a **32GB or larger** USB drive that you're OK with completely erasing.
5. Right-click `Build-Your-USB.ps1`.
   - If you see **Run with PowerShell** in the menu, click it.
   - If you don't: on Windows 11, the right-click menu is often shortened.  Click **"Show more options"** near the bottom of that menu first — the full menu will appear, and **Run with PowerShell** will be in it.
   - Still not there? Open the **Start menu**, type `PowerShell`, and open it.  In the window that appears, type `cd "` (with the quote mark), then drag the extracted folder from File Explorer into the PowerShell window — it will fill in the folder path automatically.  Type a closing `"` and press **Enter**.  Then type `.\Build-Your-USB.ps1` and press **Enter**.
6. A User Account Control ("do you want to allow this app...") prompt will appear — click **Yes**.  This is expected; the script needs admin rights to partition the USB drive.
7. **Windows may also block the script the first time**, showing a blue "Windows protected your PC" screen, or an "execution policy" error in the PowerShell window.  This is normal for any script downloaded from the internet, not a sign anything's wrong:
   - Blue SmartScreen screen → click **More info**, then **Run anyway**.
   - "Execution policy" error in the PowerShell window → close it, right-click `Build-Your-USB.ps1` → **Properties** → tick **Unblock** near the bottom → **OK**, then repeat step 5.
8. A black PowerShell window will open and ask you questions — which USB drive to use, and a final "Type YES to continue" confirmation before it erases the drive.  Read each prompt and answer it.
9. Then it downloads and copies everything — this takes a while (~11.5GB total), especially on a slower internet connection.  Once downloaded, you can reuse that download to build additional USBs from the same PC without waiting again.
10. When it says the build is complete, unplug and reinsert the USB drive (or just open it fresh in File Explorer), and double-click **`RUN - On2it-WinFixIT.bat`** to start.  This file exists on both partitions of the USB — either one works.

## Requirements

**To build the USB:**
- Windows 10/11
- Administrator rights (requested automatically)
- A USB drive, 32GB or larger, that you're OK with **completely erasing**
- A stable internet connection for the initial download (~11.5GB)

**What the built USB supports:**
- Compatibility Checker and Windows Installer work on any PC — even those without an OS.
- If any version of Windows is already installed, Compatibility Checker can do a somewhat more comprehensive job.
- DeBloater works after Windows 11 has been installed, so it can be used on pre-installed machines.

## Notes

- This build script is the public counterpart to our internal shop build tooling — same partitioning and copy logic, just pointed at a public download instead of our internal file server.

## License

Free for personal, noncommercial use — build it, use it, modify it for yourself.  Reselling, rebranding, or otherwise using it commercially isn't permitted without permission from On2it Software Ltd.  Full terms: [LICENSE](LICENSE) (PolyForm Noncommercial License 1.0.0).

## Support

Support@On2itSoftware.com — comments and suggestions are more than welcome.  😊
