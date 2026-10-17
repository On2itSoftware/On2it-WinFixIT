<# Win11-DeBloater.ps1
   ===================

Purpose: Enables an installed version of Windows 11, to be de-bloated of 
        Applications and Settings that the user does not want to use.

Method: It displays a Form on the left-hand side of the screen displaying
        various Options that the user can choose to Remove or keep.  
        The DeBloater can be run in two modes:
        
    Initial Run
        All Options on the left default to our recommendations.
        To follow all of them, simply click the PERFORM Selected Options
        Button.  To see advice on any Option or Button and make you own 
        selections, simply point at what you are interrested in.  
        Advice will appear in the right hand panel. 

        As each Option runs, a Task Log will display om the right-hand side.

    Subsequent Runs
        You can re-run the DeBloater at any time, if you change your mind 
        about any Option.  (Some larger options will require separate 
        re-installation.)

        This Script:
            Merely Dot-Sources all the Scripts required to build the Debloater,
            and initiates the Main-Line to start the Debloater.
            
            By dot sourcing all the Scripts first, then calling Main-Line to 
            start the DeBloater, it enables us to order the Scripts in ‘Top Down’ Order.  
            So that you see the ‘Big-Picture’ first, before getting into the details.

            This is NOT the order of most Powershell Scripts, as Powershell likes to 
            know the details before they are used.  So most Powershell Scripts, 
            tend to be ordered ‘Bottom-Up’.  

   Designed by: Brian McGuigan
            of: On2it Software ltd
       Code by: Copilot
       Version: 1
         Dated: 18-Dec-25
        Status: Being Tested
#>


# force Powershell to use Explicit Variables, or generate warnings
Set-StrictMode -Version Latest

# Set global error log path early so it is always defined
$global:DeBloaterErrorLog = Join-Path (Split-Path $PSScriptRoot -Parent) 'Logs\DeBloater-Errors.txt'

# Load WinForms assemblies globally
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing


# ============================================================================================
# Class Definition: SmoothScrollPanel
# ===========================================================================================

Add-Type -TypeDefinition @"
using System;
using System.Drawing;
using System.Windows.Forms;

public class SmoothScrollPanel : Panel
{
    protected override void OnMouseWheel(MouseEventArgs e)
    {
        int scrollStep = 30;
        int newY = -this.AutoScrollPosition.Y - (e.Delta / 120 * scrollStep);

        this.AutoScrollPosition = new Point(
            -this.AutoScrollPosition.X,
            newY
        );
    }
}
"@ -ReferencedAssemblies "System.Windows.Forms","System.Drawing","System.ComponentModel.Primitives","System.Drawing.Primitives" -ErrorAction Stop
 

# =============================================================================================
# Script-Level Variable Definitions
# =============================================================================================
# These variables are initialized as soon as the script is dot-sourced or run. They provide
# global state and references for all UI controls, data structures, and logic throughout the script.
# By defining them at the script level, it ensures that they are available to all functions and 
# event handlers, and that they are initialized in a consistent way. 
# By defining them in Windows11-DeBloater.ps1, it ensures that they are defined before any of the 
# dot-sourced scripts run, so that those scripts can reference them without causing errors due to 
# undefined variables.
#
# This block ensures strict mode compatibility and makes dependencies clear for maintainability.
# Note that some of these variables are redundant with later initializations, but they ensure that 
# all variables are defined at the script level for strict mode, even if their values are set later.

# --- General State and Data ---
if (-not (Test-Path variable:script:SkipModifyRecommendedOption)) { $script:SkipModifyRecommendedOption = $false }
$script:PrintAdvicePanelHandler = { Print-AdvicePanel }
$script:adviceByGroup   = @{}
$script:adviceByOption  = @{}
$script:CurrentTaskLog  = @()
$script:DetailedTaskLog = @()
$script:SummaryTaskLog  = @()
$script:AdviceFontSize  = 20  # 10pt
$script:CurrentTask     = ""
$script:isBulkUpdate    = $false
$script:SelectAllInProgress = $false
$script:isScrolling     = $false
$script:PendingSummary  = $null
$script:PauseLatch      = $false
$script:RemoveMSAccount = $true
$script:selectedOption  = $null
$script:TickCheckbox    = $false
$script:SelectALLrecommendedOptions_Checked = $false
$script:isHoveringOverOption   = $false
$script:PendingSummary  = $null
$script:LogFontSize     = 18  # 9pt (fs value is points * 2)
$script:rtfLogHistory   = "{\rtf1\ansi\fs$($script:LogFontSize)}"

# --- UI Controls (initialized later) ---
$script:form          = $null
$script:panelLeft     = $null
$script:panelDivider  = $null
$script:advicePanel   = $null
$script:adviceLabel   = $null
$script:GroupHeading  = $null
$script:adviceHeading = $null
$script:adviceRTbox   = $null
$script:TaskLogRTbox  = $null
$script:optionsControlPanel       = $null
$script:optionsControlPanelLabel  = $null
$script:btnSelectAllRecommended   = $null
$script:btnClearAll               = $null
$script:btnPerformSelectedOptions = $null
$script:btnPrintAdvice            = $null
$script:btnCreateDocumentation    = $null
$script:TaskLogControlPanel       = $null
$script:lblTaskLogControlPanel    = $null
$script:cmbTaskLogOptions         = $null
$script:btnContinue               = $null
$script:printControlPanel         = $null
$script:lblPrintControlPanel      = $null
$script:btnPrintOptionsSelected   = $null
$script:postPerformPanel          = $null
$script:lblPostPerformPanel       = $null
$script:btnSaveOptionsUsed        = $null
$script:printLblMid               = 0
$script:postPerformLblMid         = 0
$script:scrollTip                 = $null
$script:closeBtn                  = $null
$script:waitForm                  = $null

# --- Controls created later but referenced early (for strict mode) ---
# (Redundant with above, but ensures all are initialized)
$script:form          = $null
$script:panelLeft     = $null
$script:adviceRTbox   = $null
$script:adviceHeading = $null
$script:advicePanel   = $null
$script:TaskLogRTbox  = $null


#  DOT-SOURCE SHARED SUBROUTINES WITH ERROR HANDLING
# ==================================================

# Dot-source only the main scripts required for operation
. "$PSScriptRoot\DeBloater\UI.ps1"
. "$PSScriptRoot\DeBloater\PERFORM-SelectedOptions.ps1"


# =======================================================================================
# Startup Function Check 
# =======================================================================================
# Check that all required functions are loaded, before we start the Main-Line.  
# This is to ensure that the script can run without errors due to missing functions.
# If any are missing, it will print an error message and exit, rather than starting the Main-Line and crashing later on.
# Only functions that have caused errors during development are included in this check, 
# to avoid it being too onerous to maintain. 
$requiredFunctions = @(
    'Modify-RecommendedOption',
    'Setup-ScrollTip',
    'Enable-PanelWheel'
)
 $missing = @($requiredFunctions | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
if ($missing.Count -gt 0) {
    Write-Host "[ERROR] The following required functions are missing: $($missing -join ', ')" -ForegroundColor Red
    Write-Host "[ERROR] Please check that all scripts are dot-sourced correctly and no errors occurred during loading." -ForegroundColor Red
    exit 1
} else {
    Write-Host ""
    Write-Host "Windows DeBloater Starting"
}

# =======================================================================================
# Script-level lookup tables
# =======================================================================================
# These HAVE to be done After dot-sourcing so the they can use dot-sourced Function

$script:AppLookup = @{
    "Outlook for Windows" = @{
        Type        = "Application"
        PackageName = "OutlookForWindows"
    }
    "Dev Home" = @{
        Type        = "Application"
        PackageName = "Microsoft.DevHome"
    }
    "3D Viewer" = @{
        Type        = "Application"
        PackageName = "Microsoft.Microsoft3DViewer"
    }
    "Mixed Reality" = @{
        Type        = "Application"
        PackageName = "Microsoft.MixedReality.Portal"
    }
    "Paint 3D" = @{
        Type        = "Application"
        PackageName = "Microsoft.MSPaint"
    }
    "Movies & TV" = @{
        Type        = "Application"
        PackageName = "Microsoft.ZuneVideo"
    }
    "Skype" = @{
        Type        = "Application"
        PackageName = "Microsoft.SkypeApp"
    }
    "Internet Explorer" = @{
        Type        = "Application"
        PackageName = "Microsoft.InternetExplorer"
    }
    "Windows Media Player (classic)" = @{
        Type        = "Application"
        PackageName = "Microsoft.WindowsMediaPlayer"
    }
    "Windows Fax and Scan" = @{
        Type        = "Application"
        PackageName = "Microsoft.WindowsFaxAndScan"
    }
    "OneDrive" = @{
        Type        = "Service"
        ServiceName = "OneDrive"
    }
    "BitLocker" = @{
        Type        = "Service"
        ServiceName = "BitLocker"
    }
    "Xbox" = @{
        Type         = "Shortcut"
        ShortcutName = "Xbox"
    }
    "Solitaire" = @{
        Type        = "Application"
        PackageName = "Microsoft.MicrosoftSolitaireCollection"
    }
    "LinkedIn" = @{
        Type        = "Application"
        PackageName = "Microsoft.LinkedIn"   # or "LinkedInforWindows" depending on build
    }
   "Outlook IN the Start Menu" = @{
        Type         = "Shortcut"
        ShortcutName = "Outlook"
        Location     = "StartMenu"
    }
    "File Explorer IN the Start Menu" = @{
        Type         = "Shortcut"
        ShortcutName = "File Explorer"
        Location     = "StartMenu"
    }

    "Calculator IN the Start Menu" = @{
        Type         = "Shortcut"
        ShortcutName = "Calculator"
        Location     = "StartMenu"
    }

    "Notepad IN the Start Menu" = @{
        Type         = "Shortcut"
        ShortcutName = "Notepad"
        Location     = "StartMenu"
    }

    "Snipping Tool IN the Start Menu" = @{
        Type         = "Shortcut"
        ShortcutName = "Snipping Tool"
        Location     = "StartMenu"
    }

    "Photos IN the Start Menu" = @{
        Type         = "Shortcut"
        ShortcutName = "Photos"
        Location     = "StartMenu"
    }
    "Calculator" = @{
        Type         = "Shortcut"
        ShortcutName = "Calculator"
        PackageName  = "Microsoft.WindowsCalculator"
        AppID        = "Microsoft.WindowsCalculator"
    }
    "Notepad" = @{
        Type         = "Shortcut"
        ShortcutName = "Notepad"
        PackageName  = "Microsoft.WindowsNotepad"
        AppID        = "Microsoft.WindowsNotepad"
    }
    "Snipping Tool" = @{
        Type         = "Shortcut"
        ShortcutName = "Snipping Tool"
        PackageName  = "Microsoft.ScreenSketch"
        AppID        = "Microsoft.ScreenSketch"
    }
    "Photos" = @{
        Type         = "Shortcut"
        ShortcutName = "Photos"
        PackageName  = "Microsoft.Windows.Photos"
        AppID        = "Microsoft.Windows.Photos"
    }
    "File Explorer" = @{
        Type         = "Shortcut"
        ShortcutName = "File Explorer"
    }
    "Outlook" = @{
        Type         = "Shortcut"
        ShortcutName = "Outlook"
        PackageName  = "OutlookForWindows"
        AppID        = "OutlookForWindows"
    }
    "Use Long Search Bar" = @{
        Type        = "Service"
        ServiceName = "SearchBar"
    }
    "CoPilot" = @{
        Type        = "Service"
        ServiceName = "CoPilot"
    }
    "CoPilot Application" = @{
        Type        = "Application"
        PackageName = "Microsoft.Copilot"
    }
    "Recall Application" = @{
        Type        = "Application"
        PackageName = "Microsoft.Recall"
    }
    "File Manager" = @{
        Type         = "Shortcut"
        DisplayName  = "File Manager"
        ShortcutName = "File Explorer"
    }
    "Edge" = @{
        Type         = "Shortcut"
        ShortcutName = "Edge"  # Will be re-set by Get-EdgeShortcutName after all functions are loaded
        PackageName  = "Microsoft.Edge"
    }
    "Microsoft Store" = @{
        Type        = "Application"
        PackageName = "Microsoft.WindowsStore"
    }
    "Recycle Bin" = @{
        Type       = "Toggle"
        RegistryId = "RecycleBinDesktop"
    }

    "Windows Spotlight Service" = @{
        Type        = "Service"
        ServiceName = "WindowsSpotlight"
    }
    "Windows Search Service" = @{
        Type        = "Service"
        ServiceName = "WSearch"
    }
    "Snap Assist" = @{
        Type        = "Feature"
        RegistryId  = "SnapAssist"
    }
    "Clipboard History" = @{
        Type        = "Feature"
        RegistryId  = "ClipboardHistory"
    }
    "Scheduler Responsiveness Mode" = @{
        Type       = "Feature"
        RegistryId = "SchedulerResponsivenessMode"
    }

    "Reduced Background Task Latency" = @{
        Type       = "Feature"
        RegistryId = "ReducedBackgroundTaskLatency"
    }
} # END of - $AppLookup

# After $script:AppLookup is defined, update Edge shortcut dynamically
$script:AppLookup["Edge"].ShortcutName = Get-EdgeShortcutName


$script:RegistryLookup = @{

    # --- Privacy / Telemetry ---
    "AdvertisingID" = @{
        DisplayName = "Advertising ID"
        Category    = "Privacy"
        Path        = "HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo"
        ValueName   = "Enabled"
        Enabled     = 1   # allow tracking
        Disabled    = 0   # disable tracking
        Type        = "DWord"
    }
    "TailoredExperiences" = @{
        DisplayName = "Tailored Experiences"
        Category    = "Privacy"
        Path        = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy"
        ValueName   = "TailoredExperiencesWithDiagnosticDataEnabled"
        Enabled     = 1   # personalisation on
        Disabled    = 0   # personalisation off
        Type        = "DWord"
    }
    "InkingTypingPersonalisation" = @{
        DisplayName = "Inking and Typing Personalisation"
        Category    = "Privacy"
        Path        = "HKCU:\Software\Microsoft\InputPersonalization"
        ValueName   = "RestrictImplicitTextCollection"
        Enabled     = 0   # collection allowed (personalisation ON)
        Disabled    = 1   # collection restricted (personalisation OFF)
        Type        = "DWord"
        # Note: RestrictImplicitInkCollection at same path also recommended
    }
    "LocationTracking" = @{
        DisplayName = "Location Tracking"
        Category    = "Privacy"
        Path        = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors"
        ValueName   = "DisableLocation"
        Enabled     = 0   # location on
        Disabled    = 1   # location off
        Type        = "DWord"
    }
    "ActivityHistory" = @{
        DisplayName = "Activity History"
        Category    = "Privacy"
        Path        = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"
        ValueName   = "PublishUserActivities"
        Enabled     = 1   # history on
        Disabled    = 0   # history off
        Type        = "DWord"
    }
    "FeedbackFrequency" = @{
        DisplayName = "Feedback Frequency"
        Category    = "Privacy"
        Path        = "HKCU:\Software\Microsoft\Siuf\Rules"
        ValueName   = "NumberOfSIUFInPeriod"
        Enabled     = 1   # frequent feedback prompts
        Disabled    = 0   # disable feedback prompts
        Type        = "DWord"
    }
    "TelemetryLevel" = @{
        DisplayName = "Diagnostic Data Upload"
        Category    = "Privacy"
        Path        = "HKLM:\Software\Policies\Microsoft\Windows\DataCollection"
        ValueName   = "AllowTelemetry"
        Enabled     = 3   # full telemetry
        Disabled    = 0   # security only
        Type        = "DWord"
    }
    "CloudContentSuggestions" = @{
        DisplayName = "Cloud Content Suggestions"
        Category    = "Privacy"
        Path        = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
        ValueName   = "SubscribedContent-338393Enabled"
        Enabled     = 1   # suggestions on
        Disabled    = 0   # suggestions off
        Type        = "DWord"
    }
    "WebSearchInStartMenu" = @{
        DisplayName = "Web Search in Start Menu"
        Category    = "Privacy"
        Path        = "HKCU:\Software\Policies\Microsoft\Windows\Explorer"
        ValueName   = "DisableSearchBoxSuggestions"
        Enabled     = 0   # web search on
        Disabled    = 1   # web search off
        Type        = "DWord"
    }
    "SmartScreenFilter" = @{
        DisplayName = "SmartScreen Filter"
        Category    = "Privacy"
        Path        = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"
        ValueName   = "EnableSmartScreen"
        Enabled     = 1   # SmartScreen on
        Disabled    = 0   # SmartScreen off
        Type        = "DWord"
    }
    "EdgeTelemetry" = @{
        DisplayName = "Microsoft Edge Telemetry"
        Category    = "Privacy"
        Path        = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
        ValueName   = "MetricsReportingEnabled"
        Enabled     = 1   # telemetry on
        Disabled    = 0   # telemetry off
        Type        = "DWord"
    }
    "CEIP" = @{
        DisplayName = "Customer Experience Improvement Program"
        Category    = "Privacy"
        Path        = "HKLM:\SOFTWARE\Policies\Microsoft\SQMClient\Windows"
        ValueName   = "CEIPEnable"
        Enabled     = 1   # CEIP on
        Disabled    = 0   # CEIP off
        Type        = "DWord"
    }
    # --- Desktop Icons ---
    "RecycleBinDesktop" = @{
        DisplayName = "Recycle Bin"
        Category    = "ShellIcon"
        Path        = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel"
        ValueName   = "{645FF040-5081-101B-9F08-00AA002F954E}"
        Enabled     = 0   # visible
        Disabled    = 1   # hidden
        Type        = "DWord"
    }

    "ThisPCDesktop" = @{
        DisplayName = "This PC"
        Category    = "ShellIcon"
        Path        = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel"
        ValueName   = "{20D04FE0-3AEA-1069-A2D8-08002B30309D}"
        Enabled     = 0   # visible
        Disabled    = 1   # hidden
        Type        = "DWord"
    }

    # --- Start Menu ---
    "StartMenuSuggestions" = @{
        DisplayName = "Start Menu Recommendations"
        Category    = "StartMenu"
        Path        = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
        ValueName   = "SubscribedContent-338388Enabled"
        Enabled     = 1   # suggestions on
        Disabled    = 0   # suggestions off
        Type        = "DWord"
    }
    "StartMenuRecentlyAdded" = @{
        DisplayName = "Recently Added Apps"
        Category    = "StartMenu"
        Path        = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
        ValueName   = "Start_TrackProgs"
        Enabled     = 1   # show recently added
        Disabled    = 0   # hide
        Type        = "DWord"
    }

    # --- Taskbar ---
    "TaskbarWidgets" = @{
        DisplayName = "Widgets"
        Category    = "Taskbar"
        Path        = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
        ValueName   = "TaskbarDa"
        Enabled     = 1   # widgets on
        Disabled    = 0   # widgets off
        Type        = "DWord"
    }
    "WidgetsNewsAndInterests" = @{
        DisplayName = "Widgets Service"
        Category    = "Taskbar"
        Path        = "HKLM:\SOFTWARE\Policies\Microsoft\Dsh"
        ValueName   = "AllowNewsAndInterests"
        Enabled     = 1   # Widgets on
        Disabled    = 0   # Widgets off
        Type        = "DWord"
    }
    "TaskbarSearch" = @{
        DisplayName = "Search Box"
        Category    = "Taskbar"
        Path        = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"
        ValueName   = "SearchboxTaskbarMode"
        Enabled     = 1   # search box visible
        Disabled    = 0   # hidden
        Type        = "DWord"
    }

    # --- Window Management ---
    "SnapAssist" = @{
        DisplayName = "Snap Assist"
        Category    = "WindowManagement"
        Path        = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
        ValueName   = "EnableSnapAssistFlyout"
        Enabled     = 1   # Snap Assist on
        Disabled    = 0   # Snap Assist off
        Type        = "DWord"
    }

    # --- Productivity ---
    "ClipboardHistory" = @{
        DisplayName = "Clipboard History"
        Category    = "Productivity"
        Path        = "HKCU:\Software\Microsoft\Clipboard"
        ValueName   = "EnableClipboardHistory"
        Enabled     = 1   # Clipboard History on
        Disabled    = 0   # Clipboard History off
        Type        = "DWord"
    }

    "SuggestedActions" = @{
        DisplayName = "Suggested Actions"
        Category    = "SystemExperience"
        Path        = "HKCU:\Software\Microsoft\Windows\CurrentVersion\SmartActionPlatform\SmartClipboard"
        ValueName   = "Disabled"
        Enabled     = 0   # suggested actions on
        Disabled    = 1   # suggested actions off
        Type        = "DWord"
    }
    "SuggestedActionsService" = @{
        DisplayName = "Suggested Actions Service"
        Category    = "SystemExperience"
        Path        = "HKCU:\Software\Microsoft\Windows\CurrentVersion\SmartActionPlatform\SmartClipboard"
        ValueName   = "Disabled"
        Enabled     = 0   # suggested actions on
        Disabled    = 1   # suggested actions off
        Type        = "DWord"
    }
    "AutoPlay" = @{
        DisplayName = "AutoPlay"
        Category    = "SystemExperience"
        Path        = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers"
        ValueName   = "DisableAutoplay"
        Enabled     = 0   # AutoPlay on
        Disabled    = 1   # AutoPlay off
        Type        = "DWord"
    }
    "NearbySharing" = @{
        DisplayName = "Nearby Sharing"
        Category    = "SystemExperience"
        Path        = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CDP"
        ValueName   = "NearShareChannelUserAuthzPolicy"
        Enabled     = 1   # sharing on (my devices)
        Disabled    = 0   # sharing off
        Type        = "DWord"
    }
    "TipsAndSuggestions" = @{
        DisplayName = "Tips and Suggestions"
        Category    = "SystemExperience"
        Path        = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"
        ValueName   = "DisableSoftLanding"
        Enabled     = 0   # tips on
        Disabled    = 1   # tips off
        Type        = "DWord"
    }
    "LockScreenSpotlight" = @{
        DisplayName = "Lock Screen Spotlight"
        Category    = "SystemExperience"
        Path        = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
        ValueName   = "RotatingLockScreenOverlayEnabled"
        Enabled     = 1   # spotlight on
        Disabled    = 0   # spotlight off
        Type        = "DWord"
    }
    "SuggestedApps" = @{
        DisplayName = "Suggested Apps"
        Category    = "SystemExperience"
        Path        = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
        ValueName   = "SilentInstalledAppsEnabled"
        Enabled     = 1   # suggested apps on
        Disabled    = 0   # suggested apps off
        Type        = "DWord"
    }
    "SuggestedContentInSettings" = @{
        DisplayName = "Suggested Content in Settings"
        Category    = "SystemExperience"
        Path        = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
        ValueName   = "SubscribedContent-338393Enabled"
        Enabled     = 1   # suggested content on
        Disabled    = 0   # suggested content off
        Type        = "DWord"
    }
    "AutomaticAppLaunching" = @{
        DisplayName = "Automatic App Launching"
        Category    = "SystemExperience"
        Path        = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
        ValueName   = "ContentDeliveryAllowed"
        Enabled     = 1   # auto launching on
        Disabled    = 0   # auto launching off
        Type        = "DWord"
    }
    # --- File Explorer ---
    "FileExtensions" = @{
        DisplayName = "File Extensions"
        Category    = "FileExplorer"
        Path        = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
        ValueName   = "HideFileExt"
        Enabled     = 1   # extensions hidden (Windows default)
        Disabled    = 0   # extensions shown
        ShowState   = "Disabled"
        Type        = "DWord"
    }
    "HiddenFiles" = @{
        DisplayName = "Hidden Files"
        Category    = "FileExplorer"
        Path        = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
        ValueName   = "Hidden"
        Enabled     = 2   # files hidden (Windows default)
        Disabled    = 1   # files shown
        ShowState   = "Disabled"
        Type        = "DWord"
    }
    "FrequentFolders" = @{
        DisplayName = "Frequent Folders"
        Category    = "FileExplorer"
        Path        = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer"
        ValueName   = "ShowFrequent"
        Enabled     = 1   # frequent folders shown
        Disabled    = 0   # frequent folders hidden
        Type        = "DWord"
    }
    "RecentFiles" = @{
        DisplayName = "Recent Files"
        Category    = "FileExplorer"
        Path        = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer"
        ValueName   = "ShowRecent"
        Enabled     = 1   # recent files shown
        Disabled    = 0   # recent files hidden
        Type        = "DWord"
    }
    # --- Notifications ---
    "NotificationBadges" = @{
        DisplayName = "Notification Badges"
        Category    = "Notifications"
        Path        = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
        ValueName   = "TaskbarBadges"
        Enabled     = 1   # badges on
        Disabled    = 0   # badges off
        Type        = "DWord"
    }
    "NotificationSounds" = @{
        DisplayName = "Notification Sounds"
        Category    = "Notifications"
        Path        = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings"
        ValueName   = "NOC_GLOBAL_SETTING_ALLOW_NOTIFICATION_SOUND"
        Enabled     = 1   # sounds on
        Disabled    = 0   # sounds off
        Type        = "DWord"
    }
    # --- Network ---
    "IPv6" = @{
        DisplayName    = "IPv6"
        Category       = "Network"
        Path           = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters"
        ValueName      = "DisabledComponents"
        Enabled        = 0   # IPv6 on
        Disabled       = 255 # IPv6 off
        Type           = "DWord"
        RebootRequired = $true
    }
    # --- Services (controlled via registry Start value) ---
    "XboxGameBarService" = @{
        DisplayName    = "Xbox Game Bar Service"
        Category       = "Service"
        Path           = "HKLM:\SYSTEM\CurrentControlSet\Services\BcastDVRUserService"
        ValueName      = "Start"
        Enabled        = 3   # Manual
        Disabled       = 4   # Disabled
        Type           = "DWord"
        RebootRequired = $true
    }
    "GameDVRService" = @{
        DisplayName    = "Game DVR and Capture Service"
        Category       = "Service"
        Path           = "HKLM:\SYSTEM\CurrentControlSet\Services\BcastDVRUserService"
        ValueName      = "Start"
        Enabled        = 3   # Manual
        Disabled       = 4   # Disabled
        Type           = "DWord"
        RebootRequired = $true
    }
    "WindowsSpotlightSvc" = @{
        DisplayName    = "Windows Spotlight Service"
        Category       = "Service"
        Path           = "HKLM:\SYSTEM\CurrentControlSet\Services\WpnUserService"
        ValueName      = "Start"
        Enabled        = 2   # Automatic
        Disabled       = 4   # Disabled
        Type           = "DWord"
        RebootRequired = $true
    }
    # --- Power ---
    "FastStartup" = @{
        DisplayName = "Fast Startup"
        Category    = "Power"
        Path        = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power"
        ValueName   = "HiberbootEnabled"
        Enabled     = 1   # Fast Startup on
        Disabled    = 0   # Fast Startup off
        Type        = "DWord"
    }
    "Hibernation" = @{
        DisplayName = "Hibernation"
        Category    = "Power"
        Path        = "HKLM:\SYSTEM\CurrentControlSet\Control\Power"
        ValueName   = "HibernateEnabled"
        Enabled     = 1   # Hibernation on
        Disabled    = 0   # Hibernation off
        Type        = "DWord"
    }
    "SchedulerResponsivenessMode" = @{
        DisplayName = "Scheduler Responsiveness Mode"
        Category    = "Performance"
        Path        = "HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl"
        ValueName   = "Win32PrioritySeparation"
        Enabled     = 0x26   # responsiveness mode
        Disabled    = 0x2    # Windows default
        Type        = "DWord"
    }
    "ReducedBackgroundTaskLatency" = @{
        DisplayName = "Reduced Background Task Latency"
        Category    = "Performance"
        Path        = "HKLM:\SYSTEM\CurrentControlSet\Control\Power"
        ValueName   = "EcoQoSDisabled"
        Enabled     = 1   # low latency
        Disabled    = 0   # allow EcoQoS
        Type        = "DWord"
    }
    # --- Visual Effects ---
    "TransparencyEffects" = @{
        DisplayName = "Transparency Effects"
        Category    = "VisualEffects"
        Path        = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize"
        ValueName   = "EnableTransparency"
        Enabled     = 1   # transparency on
        Disabled    = 0   # transparency off
        Type        = "DWord"
    }
    "WindowAnimations" = @{
        DisplayName = "Window Animations"
        Category    = "VisualEffects"
        Path        = "HKCU:\Control Panel\Desktop\WindowMetrics"
        ValueName   = "MinAnimate"
        Enabled     = "1"   # animations on
        Disabled    = "0"   # animations off
        Type        = "String"
    }
    # --- Windows Update ---
    "AutomaticDriverUpdates" = @{
        DisplayName = "Automatic Driver Updates"
        Category    = "WindowsUpdate"
        Path        = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
        ValueName   = "ExcludeWUDriversInQualityUpdate"
        Enabled     = 0   # driver updates allowed
        Disabled    = 1   # driver updates blocked
        Type        = "DWord"
    }
    "DeliveryOptimisation" = @{
        DisplayName = "Delivery Optimisation"
        Category    = "WindowsUpdate"
        Path        = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization"
        ValueName   = "DODownloadMode"
        Enabled     = 3   # P2P enabled (internet peers)
        Disabled    = 0   # HTTP only, no P2P
        Type        = "DWord"
    }
} # END of - $RegistryLookup

$script:StartAppMap = @{
    # Core inbox apps
    'Calculator' = @{
        Package      = 'Microsoft.WindowsCalculator'
        AppIdPattern = 'Microsoft.WindowsCalculator'
    }
    'Notepad' = @{
        Package      = 'Microsoft.WindowsNotepad'
        AppIdPattern = 'Microsoft.WindowsNotepad'
    }
    'Snipping Tool' = @{
        Package      = 'Microsoft.ScreenSketch'   # Snipping Tool is ScreenSketch in Win11
        AppIdPattern = 'Microsoft.ScreenSketch'
    }
    'Photos' = @{
        Package      = 'Microsoft.Windows.Photos'
        AppIdPattern = 'Microsoft.Windows.Photos'
    }
    'Paint' = @{
        Package      = 'Microsoft.Paint'
        AppIdPattern = 'Microsoft.Paint'
    }
    'Camera' = @{
        Package      = 'Microsoft.WindowsCamera'
        AppIdPattern = 'Microsoft.WindowsCamera'
    }
    'File Explorer' = @{
        Package      = $null   # handled via .lnk only
        AppIdPattern = $null
    }

    # Communication apps
    'Outlook' = @{
        Package      = 'OutlookForWindows'        # new Outlook app
        AppIdPattern = 'OutlookForWindows'
    }
    'Mail and Calendar' = @{
        Package      = 'microsoft.windowscommunicationsapps' # legacy Mail/Calendar
        AppIdPattern = 'microsoft.windowscommunicationsapps'
    }
    'Teams' = @{
        Package      = 'MicrosoftTeams'
        AppIdPattern = 'MicrosoftTeams'
    }
    'OneDrive' = @{
        Package      = 'Microsoft.OneDrive'
        AppIdPattern = 'Microsoft.OneDrive'
    }

    # Optional / bundled apps
    'Solitaire' = @{
        Package      = 'Microsoft.MicrosoftSolitaireCollection'
        AppIdPattern = 'Microsoft.MicrosoftSolitaireCollection'
    }
    'Dev Home' = @{
        Package      = 'Microsoft.DevHome'
        AppIdPattern = 'Microsoft.DevHome'
    }
    'Paint 3D' = @{
        Package      = 'Microsoft.MSPaint'
        AppIdPattern = 'Microsoft.MSPaint'
    }
     'Movies & TV' = @{
        Package      = 'Microsoft.ZuneVideo'
        AppIdPattern = 'Microsoft.ZuneVideo'
   }
    'Xbox' = @{
        Package      = 'Microsoft.XboxApp'
        AppIdPattern = 'Microsoft.XboxApp'
    }
    'LinkedIn' = @{
        Package      = 'LinkedInforWindows'
        AppIdPattern = 'LinkedInforWindows'
    }
    'Mixed Reality' = @{
        Package      = 'Microsoft.MixedReality.Portal'
        AppIdPattern = 'Microsoft.MixedReality.Portal'
    }
} # END of - StartAppMap


$script:ServiceLookup = @{

    "WindowsSearch" = @{
        DisplayName    = "Windows Search Service"
        ServiceName    = "WSearch"
        DefaultStartup = "Automatic"
    }
    "XboxLiveAuthManager" = @{
        DisplayName    = "Xbox Live Auth Manager"
        ServiceName    = "XblAuthManager"
        DefaultStartup = "Manual"
    }
    "XboxAccessoryManagement" = @{
        DisplayName    = "Xbox Accessory Management Service"
        ServiceName    = "XboxGipSvc"
        DefaultStartup = "Manual"
    }
    "XboxGameBar" = @{
        DisplayName    = "Xbox Game Bar Service"
        ServiceName    = "BcastDVRUserService"
        DefaultStartup = "Manual"
    }
    "GameDVR" = @{
        DisplayName    = "Game DVR and Capture Service"
        ServiceName    = "BcastDVRUserService"
        DefaultStartup = "Manual"
    }
    "WidgetsService" = @{
        DisplayName    = "Widgets Service"
        ServiceName    = "WpnUserService"
        DefaultStartup = "Manual"
    }
    "WindowsSpotlightService" = @{
        DisplayName    = "Windows Spotlight Service"
        ServiceName    = "WpnUserService"
        DefaultStartup = "Automatic"
    }


} # END of - $script:ServiceLookup


# =======================================================================================
# Run Main-Line
# =======================================================================================
Main-Line   # Starts Execution, after everything has been defined
            # Main-Line is actually defined in Win11-DeBloater-UI.ps1. 
            # This has been made possible by dot-sourcing Win11-DeBloater-UI.ps1 above.

# --- Dump all errors to the log file at the end of the run ---S
if ($Error.Count -gt 0) {
    "`n=== ERRORS DETECTED ===" | Out-File -FilePath $global:DeBloaterErrorLog -Encoding UTF8
    $Error | Out-File -FilePath $global:DeBloaterErrorLog -Append -Encoding UTF8
}
