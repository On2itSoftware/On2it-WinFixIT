<#  Launch-Menu.ps1
    ===============

       Purpose: Generic entry point for the WinFixIT menu engine.
                Can be pointed at any folder on any partition simply by
                specifying -MenuRoot and -TopLevelTitle in the calling .bat file.

        Method: Dot-sources the shared subroutines from the same WinFixIT folder,
                then calls Display-MenuFor with the supplied parameters.

   Designed by: Brian McGuigan
            of: On2it Software Ltd
       Version: 1
         Dated: 26-May-26
        Status: NEW
#>
param(
    [Parameter(Mandatory=$true)][string]$MenuRoot,
    [Parameter(Mandatory=$true)][string]$TopLevelTitle
)

. "$PSScriptRoot\USER Prompting.ps1"
. "$PSScriptRoot\Extensible Dynamic Menus.ps1"

Display-MenuFor `
    -FolderPath $MenuRoot `
    -TopLevelTitle $TopLevelTitle `
    -NoCallerToReturnTo

# Display-MenuFor only returns here once navigation has fully unwound back to this
# entry point. Nothing left to do - let the script end and the window close itself
# (the launcher .bat no longer passes -NoExit, so a clean exit here closes cleanly).
