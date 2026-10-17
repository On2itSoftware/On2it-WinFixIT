<#  Windows 11 BYPASS Registry Keys, Reference Copy.ps1
    =====================================================
       Purpose: A READ-ONLY reference copy of the exact function WinFixIT
                runs, on your own machine, immediately before launching
                Windows Setup for a BYPASS Install -- published here so the
                single most legally/ethically sensitive piece of WinFixIT's
                code (the part that defeats Microsoft's hardware-eligibility
                check) is inspectable by anyone, before they ever run
                anything, not just after.

                This file is NOT dot-sourced or executed by anything in
                this repo. The real, live copy -- the one actually run --
                lives in Install Windows.ps1, part of WinFixIT's main
                toolkit (Compatibility Checker, DeBloater, Library, etc.),
                which is downloaded as part of the ~16GB build but isn't
                itself kept in this public source repo. See the main
                README's "Is it safe?" section for the full picture,
                including what Test-FullInstallIsoHash (in
                Build-WindowsISOs.ps1, right here in this repo) verifies
                before this ever runs.

                IMPORTANT for future maintainers: this is a manually kept
                copy, not a build artifact. If
                Set-Windows11BypassRegistryKeys in Install Windows.ps1 ever
                changes, update this file to match by hand -- nothing
                enforces that automatically.

        Method: Traced from Rufus's own source (res/setup/setup.c, Pete
                Batard, GPL-3.0 -- same licence as this repo, same author
                as the vendored Fido.ps1). For Windows 11 builds 26000+
                (covers both 25H2, build 26200, and 26H2, build 26300),
                emptying sources\appraiserres.dll is no longer enough on
                its own -- the real check still runs, it just needs these
                registry values present first, so it reads them as genuine
                hardware readings and reports "compliant" regardless of
                actual hardware. Clears a few stale AppCompatFlags cache
                keys first, in case a previous blocked attempt left markers
                behind -- same as Rufus does.

   Designed by: Brian McGuigan
            of: On2it Software Ltd
       Code by: Claude
       Version: 1 (copied verbatim from Install Windows.ps1's own
                Set-Windows11BypassRegistryKeys, Version 1, 17-Oct-2026)
         Dated: 17-Oct-26
#>
function Set-Windows11BypassRegistryKeys {
    [CmdletBinding()]
    param ()

    $compatFlagsBase = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags'

    foreach ($staleKey in 'CompatMarkers', 'Shared', 'TargetVersionUpgradeExperienceIndicators') {
        $path = Join-Path $compatFlagsBase $staleKey
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $hwReqChkPath = Join-Path $compatFlagsBase 'HwReqChk'
    if (-not (Test-Path -LiteralPath $hwReqChkPath)) {
        New-Item -Path $hwReqChkPath -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $hwReqChkPath -Name 'HwReqChkVars' -Type MultiString -Value @(
        'SQ_SecureBootCapable=TRUE'
        'SQ_SecureBootEnabled=TRUE'
        'SQ_TpmVersion=2'
        'SQ_RamMB=8192'
    )

    $moSetupPath = 'HKLM:\SYSTEM\Setup\MoSetup'
    if (-not (Test-Path -LiteralPath $moSetupPath)) {
        New-Item -Path $moSetupPath -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $moSetupPath -Name 'AllowUpgradesWithUnsupportedTPMOrCPU' -Type DWord -Value 1

}  # END of - function Set-Windows11BypassRegistryKeys
