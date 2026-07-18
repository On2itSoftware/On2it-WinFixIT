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

**[Read the User Manual](https://raw.githubusercontent.com/On2itSoftware/On2it-WinFixIT/master/USB-INSTALL/WinFixIT%20-%20User%20Manual.pdf)** — opens on its own in your browser's PDF viewer, full width.

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
8. Then it downloads and copies everything — this takes a while (~11.5GB total), especially on a slower internet connection.  Once downloaded, you can reuse that download to build additional USBs from the same PC without waiting again.
9. When it says the build is complete, unplug and reinsert the USB drive (or just open it fresh in File Explorer).
   - **On a PC with Windows already installed**: double-click **`RUN - On2it-WinFixIT.bat`** to start.  This file exists on both partitions of the USB — either one works.
   - **On a PC with no OS installed at all**: set your BIOS to boot from the USB drive, and follow the on-screen prompts.

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

- This build script is the public counterpart to our internal in-house build tooling — same partitioning and copy logic, just pointed at a public download instead of our internal file server.

## License

Free for personal, noncommercial use — build it, use it, modify it for yourself.  Reselling, rebranding, or otherwise using it commercially isn't permitted without permission from On2it Software Ltd.  Full terms: [LICENSE](LICENSE) (PolyForm Noncommercial License 1.0.0).

## Support

Support@On2itSoftware.com — comments and suggestions are more than welcome.  😊
