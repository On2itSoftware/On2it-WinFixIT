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

1. Download or clone this repository.
2. Insert a **32GB or larger** USB drive.
3. Run `Build-Your-USB.ps1` (right-click → Run with PowerShell, or run from an elevated PowerShell prompt).  It will ask for admin rights automatically.
   - **Windows may block it initially** — since it's a script downloaded from the internet, you may see a blue "Windows protected your PC" SmartScreen screen, or an "execution policy" error.  This is normal, not a sign anything's wrong:
     - SmartScreen screen → click **More info**, then **Run anyway**.
     - Execution policy error → right-click the `.ps1` file → **Properties** → tick **Unblock** → OK, then run it again.
4. Follow the prompts — pick your USB drive, confirm, and let it download and copy the content.  This takes a while (~11.5GB download) — but once downloaded, you can build additional USBs from the same PC without re-downloading.
5. When it's done, run `RUN - On2it-WinFixIT.bat` from the USB-INSTALL or On2it-WinFixIT partition to start — both work.

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
