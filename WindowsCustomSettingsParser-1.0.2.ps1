<#
.SUMMARY
    Example INI-driven Windows customization engine

.DESCRIPTION
    Reads a custom settings.ini file and applies selected Windows settings.
    Intended as a starter framework for Intune / MECM / task sequence use.

.PARAMETERS
    .\WindowsCustomSettingsParser-1.0.2.ps1
        -IniPath .\settings.ini <- Path to settings.ini

    Example:
    .\WindowsCustomSettingsParser-1.0.2.ps1 -IniPath "C:\Temp\settings.ini"

.NOTES/REFERENCES
    CurrentVersion = v1.0.2

    Run elevated for most device-level settings.
    User-level HKCU settings should be run in user context or adapted for Default User.


    Changelog:
    5.30.2026 - Initial Script Created. v1.0.2

#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$IniPath = ".\settings.ini"
)

# VARIABLES (RUN)
$ErrorActionPreference = "SilentlyContinue"
$timestamp = (Get-Date).ToString("MM-dd-yyyy-HH:mm:ss")

# START LOGGING
#Get-timestamp for logging
function Get-TimeStamp {  
    return "[{0:MM/dd/yy} {0:HH:mm:ss}]" -f (Get-Date)  
}

#Log path/name/location
$LogPath = "C:\Windows\Logs\WindowsCustomSettingsParser-1.0.2.log"
$LogDir = Split-Path $LogPath
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}
Start-Transcript -Path $logPath -Append

# RUNTIME STATUS
$64Bit=[Environment]::Is64BitProcess
Write-Host "$(Get-TimeStamp) Is64BitProcess = $64Bit" -ForegroundColor Green

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

function Read-IniFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "INI file not found: $Path"
    }

    $ini = @{}
    $currentSection = $null

    foreach ($rawLine in Get-Content -LiteralPath $Path -ErrorAction Stop) {
        $line = $rawLine.Trim()

        # Skip blank lines and comments
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.StartsWith(";") -or $line.StartsWith("#")) { continue }

        # Section
        if ($line -match '^\[(.+)\]$') {
            $currentSection = $matches[1].Trim()
            if (-not $ini.ContainsKey($currentSection)) {
                $ini[$currentSection] = @{}
            }
            continue
        }

        # Key=Value
        if ($line -match '^(.*?)=(.*)$') {
            if (-not $currentSection) {
                throw "Key/value found before any section: $line"
            }

            $key = $matches[1].Trim()
            $value = $matches[2].Trim()

            $ini[$currentSection][$key] = $value
        }
    }

    return $ini
}

function Get-IniValue {
    param(
        [hashtable]$Config,
        [string]$Section,
        [string]$Key,
        $Default = $null
    )

    if ($Config.ContainsKey($Section) -and $Config[$Section].ContainsKey($Key)) {
        return $Config[$Section][$Key]
    }

    return $Default
}

function Get-IniBool {
    param(
        [hashtable]$Config,
        [string]$Section,
        [string]$Key,
        [bool]$Default = $false
    )

    $value = Get-IniValue -Config $Config -Section $Section -Key $Key -Default $null
    if ($null -eq $value) { return $Default }

    switch ($value.ToString().Trim().ToLowerInvariant()) {
        "1"      { return $true }
        "true"   { return $true }
        "yes"    { return $true }
        "0"      { return $false }
        "false"  { return $false }
        "no"     { return $false }
        default  { return $Default }
    }
}

function Ensure-ParentFolder {
    param([string]$Path)

    $parent = Split-Path -Path $Path -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }
}

$script:LogPath = Join-Path $env:ProgramData "Contoso\Logs\configure.log"
$script:LoggingEnabled = $true
$script:RebootRequired = $false

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR","VERBOSE")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[{0}] [{1}] {2}" -f $timestamp, $Level, $Message

    Write-Host $entry

    if ($script:LoggingEnabled) {
        Ensure-ParentFolder -Path $script:LogPath
        Add-Content -LiteralPath $script:LogPath -Value $entry
    }
}

function Initialize-Logging {
    param([hashtable]$Config)

    $loggingPath = Get-IniValue -Config $Config -Section "Logging" -Key "LogPath" -Default $null
    if (-not $loggingPath) {
        $loggingPath = Get-IniValue -Config $Config -Section "General" -Key "LogPath" -Default $script:LogPath
    }

    $script:LogPath = $loggingPath
    $script:LoggingEnabled = Get-IniBool -Config $Config -Section "Logging" -Key "EnableLogging" -Default $true

    Ensure-ParentFolder -Path $script:LogPath
    Write-Log "Logging initialized. LogPath = $script:LogPath"
}

function Set-RegistryValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)]
        [ValidateSet("String","ExpandString","Binary","DWord","QWord","MultiString")]
        [string]$Type
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }

    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
    Write-Log "Registry set: $Path -> $Name = $Value ($Type)" "VERBOSE"
}

function Remove-RegistryValueIfExists {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (Test-Path -LiteralPath $Path) {
        try {
            Remove-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
            Write-Log "Registry removed: $Path -> $Name" "VERBOSE"
        } catch {
            # ignore if absent
        }
    }
}

function Set-ServiceStartup {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]
        [ValidateSet("Automatic","Manual","Disabled")]
        [string]$StartupType
    )

    try {
        Set-Service -Name $Name -StartupType $StartupType -ErrorAction Stop
        Write-Log "Service startup set: $Name = $StartupType"
    } catch {
        Write-Log "Failed setting service startup for $Name. $_" "WARN"
    }
}

function Test-IsLaptop {
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        # 2 = Mobile, common laptop indicator; 3 = Workstation
        return ($cs.PCSystemType -eq 2)
    } catch {
        Write-Log "Could not determine laptop state. $_" "WARN"
        return $false
    }
}

function Test-IsVM {
    try {
        $model = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).Model
        $manufacturer = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).Manufacturer
        $combo = "$manufacturer $model".ToLowerInvariant()

        $vmMarkers = @("virtual", "vmware", "hyper-v", "kvm", "virtualbox", "xen", "qemu")
        foreach ($marker in $vmMarkers) {
            if ($combo -like "*$marker*") { return $true }
        }
        return $false
    } catch {
        Write-Log "Could not determine VM state. $_" "WARN"
        return $false
    }
}

function Test-IsDomainJoined {
    try {
        return (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).PartOfDomain
    } catch {
        Write-Log "Could not determine domain join state. $_" "WARN"
        return $false
    }
}

function Test-IsAzureADJoined {
    try {
        $output = & dsregcmd.exe /status 2>$null
        if ($output -match 'AzureAdJoined\s*:\s*YES') {
            return $true
        }
        return $false
    } catch {
        Write-Log "Could not determine Entra join state. $_" "WARN"
        return $false
    }
}

function Compare-VersionAtLeast {
    param(
        [string]$Current,
        [string]$Minimum
    )

    try {
        return ([version]$Current -ge [version]$Minimum)
    } catch {
        Write-Log "Version comparison failed. Current='$Current' Minimum='$Minimum'. $_" "WARN"
        return $true
    }
}

function Evaluate-Conditions {
    param([hashtable]$Config)

    $onlyIfDomainJoined = Get-IniBool -Config $Config -Section "Conditions" -Key "OnlyIfDomainJoined" -Default $false
    $onlyIfAzureADJoined = Get-IniBool -Config $Config -Section "Conditions" -Key "OnlyIfAzureADJoined" -Default $false
    $onlyIfLaptop = Get-IniBool -Config $Config -Section "Conditions" -Key "OnlyIfLaptop" -Default $false
    $onlyIfDesktop = Get-IniBool -Config $Config -Section "Conditions" -Key "OnlyIfDesktop" -Default $false
    $minimumOSVersion = Get-IniValue -Config $Config -Section "Conditions" -Key "MinimumOSVersion" -Default $null

    $skipIfLaptop = Get-IniBool -Config $Config -Section "Execution" -Key "SkipIfLaptop" -Default $false
    $skipIfVM = Get-IniBool -Config $Config -Section "Execution" -Key "SkipIfVM" -Default $false

    $isLaptop = Test-IsLaptop
    $isVM = Test-IsVM
    $isDomainJoined = Test-IsDomainJoined
    $isAzureADJoined = Test-IsAzureADJoined
    $currentOSVersion = [System.Environment]::OSVersion.Version.ToString()

    Write-Log "Condition snapshot: Laptop=$isLaptop, VM=$isVM, DomainJoined=$isDomainJoined, AzureADJoined=$isAzureADJoined, OSVersion=$currentOSVersion"

    if ($skipIfLaptop -and $isLaptop) {
        Write-Log "Execution skipped because SkipIfLaptop=1 and device is detected as laptop." "WARN"
        return $false
    }

    if ($skipIfVM -and $isVM) {
        Write-Log "Execution skipped because SkipIfVM=1 and device is detected as VM." "WARN"
        return $false
    }

    if ($onlyIfDomainJoined -and -not $isDomainJoined) {
        Write-Log "Execution blocked because OnlyIfDomainJoined=1 and device is not domain joined." "WARN"
        return $false
    }

    if ($onlyIfAzureADJoined -and -not $isAzureADJoined) {
        Write-Log "Execution blocked because OnlyIfAzureADJoined=1 and device is not Azure AD / Entra joined." "WARN"
        return $false
    }

    if ($onlyIfLaptop -and -not $isLaptop) {
        Write-Log "Execution blocked because OnlyIfLaptop=1 and device is not detected as laptop." "WARN"
        return $false
    }

    if ($onlyIfDesktop -and $isLaptop) {
        Write-Log "Execution blocked because OnlyIfDesktop=1 and device is detected as laptop." "WARN"
        return $false
    }

    if ($minimumOSVersion) {
        if (-not (Compare-VersionAtLeast -Current $currentOSVersion -Minimum $minimumOSVersion)) {
            Write-Log "Execution blocked because current OS version '$currentOSVersion' is below MinimumOSVersion '$minimumOSVersion'." "WARN"
            return $false
        }
    }

    return $true
}

function Should-RunSection {
    param(
        [hashtable]$Config,
        [string]$ExecutionKey
    )

    return (Get-IniBool -Config $Config -Section "Execution" -Key $ExecutionKey -Default $false)
}

# ------------------------------------------------------------
# Section handlers
# ------------------------------------------------------------

function Apply-SystemSection {
    param([hashtable]$Config)

    Write-Log "Applying [System] section..."

    if (Get-IniBool -Config $Config -Section "System" -Key "SetTimeZone" -Default $false) {
        $tz = Get-IniValue -Config $Config -Section "System" -Key "TimeZone" -Default $null
        if ($tz) {
            try {
                Set-TimeZone -Id $tz -ErrorAction Stop
                Write-Log "Time zone set to '$tz'"
            } catch {
                Write-Log "Failed to set time zone '$tz'. $_" "ERROR"
            }
        }
    }

    if (Get-IniBool -Config $Config -Section "System" -Key "DisableFirstLogonAnimation" -Default $false) {
        Set-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "EnableFirstLogonAnimation" -Value 0 -Type DWord
    }

    if (Get-IniBool -Config $Config -Section "System" -Key "DisableConsumerFeatures" -Default $false) {
        Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Name "DisableWindowsConsumerFeatures" -Value 1 -Type DWord
    }

    if (Get-IniBool -Config $Config -Section "System" -Key "DisableLockScreen" -Default $false) {
        Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" -Name "NoLockScreen" -Value 1 -Type DWord
    }

    $fastStartup = Get-IniValue -Config $Config -Section "System" -Key "EnableFastStartup" -Default $null
    if ($null -ne $fastStartup -and $fastStartup -ne "") {
        $hiberboot = if ($fastStartup -eq "1") { 1 } else { 0 }
        Set-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" -Name "HiberbootEnabled" -Value $hiberboot -Type DWord
    }

    $computerNamePrefix = Get-IniValue -Config $Config -Section "System" -Key "ComputerNamePrefix" -Default $null
    if ($computerNamePrefix) {
        Write-Log "ComputerNamePrefix is defined as '$computerNamePrefix' but renaming logic is not implemented in this starter script." "WARN"
    }
}

function Apply-ExplorerSection {
    param([hashtable]$Config)

    Write-Log "Applying [Explorer] section..."

    # HKCU - user context recommended
    $path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"

    $showFileExtensions = Get-IniValue -Config $Config -Section "Explorer" -Key "ShowFileExtensions" -Default $null
    if ($null -ne $showFileExtensions -and $showFileExtensions -ne "") {
        # HideFileExt = 0 means show extensions
        $value = if ($showFileExtensions -eq "1") { 0 } else { 1 }
        Set-RegistryValue -Path $path -Name "HideFileExt" -Value $value -Type DWord
    }

    $showHidden = Get-IniValue -Config $Config -Section "Explorer" -Key "ShowHiddenFiles" -Default $null
    if ($null -ne $showHidden -and $showHidden -ne "") {
        # Hidden = 1 show hidden, 2 hide hidden
        $value = if ($showHidden -eq "1") { 1 } else { 2 }
        Set-RegistryValue -Path $path -Name "Hidden" -Value $value -Type DWord
    }

    $hideProtectedOS = Get-IniValue -Config $Config -Section "Explorer" -Key "HideProtectedOSFiles" -Default $null
    if ($null -ne $hideProtectedOS -and $hideProtectedOS -ne "") {
        # ShowSuperHidden = 0 hide protected OS files, 1 show them
        $value = if ($hideProtectedOS -eq "1") { 0 } else { 1 }
        Set-RegistryValue -Path $path -Name "ShowSuperHidden" -Value $value -Type DWord
    }

    $openToThisPC = Get-IniValue -Config $Config -Section "Explorer" -Key "OpenFileExplorerToThisPC" -Default $null
    if ($null -ne $openToThisPC -and $openToThisPC -ne "") {
        # LaunchTo = 1 This PC, 2 Quick Access/Home (behavior varies by OS build)
        $value = if ($openToThisPC -eq "1") { 1 } else { 2 }
        Set-RegistryValue -Path $path -Name "LaunchTo" -Value $value -Type DWord
    }

    $separateProcess = Get-IniValue -Config $Config -Section "Explorer" -Key "LaunchFolderWindowsInSeparateProcess" -Default $null
    if ($null -ne $separateProcess -and $separateProcess -ne "") {
        $value = if ($separateProcess -eq "1") { 1 } else { 0 }
        Set-RegistryValue -Path $path -Name "SeparateProcess" -Value $value -Type DWord
    }

    Write-Log "Explorer section complete. Note: HKCU settings should run in user context for end-user effect." "WARN"
}

function Apply-TaskbarSection {
    param([hashtable]$Config)

    Write-Log "Applying [Taskbar] section..."

    # HKCU - user context recommended
    $advancedPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"

    $alignment = Get-IniValue -Config $Config -Section "Taskbar" -Key "Alignment" -Default $null
    if ($alignment) {
        switch ($alignment.ToLowerInvariant()) {
            "left"   { Set-RegistryValue -Path $advancedPath -Name "TaskbarAl" -Value 0 -Type DWord }
            "center" { Set-RegistryValue -Path $advancedPath -Name "TaskbarAl" -Value 1 -Type DWord }
            default  { Write-Log "Unknown Taskbar Alignment '$alignment'. Expected Left or Center." "WARN" }
        }
    }

    $showWidgets = Get-IniValue -Config $Config -Section "Taskbar" -Key "ShowWidgets" -Default $null
    if ($null -ne $showWidgets -and $showWidgets -ne "") {
        $value = if ($showWidgets -eq "1") { 1 } else { 0 }
        Set-RegistryValue -Path $advancedPath -Name "TaskbarDa" -Value $value -Type DWord
    }

    $showChat = Get-IniValue -Config $Config -Section "Taskbar" -Key "ShowChat" -Default $null
    if ($null -ne $showChat -and $showChat -ne "") {
        $value = if ($showChat -eq "1") { 1 } else { 0 }
        Set-RegistryValue -Path $advancedPath -Name "TaskbarMn" -Value $value -Type DWord
    }

    $showTaskView = Get-IniValue -Config $Config -Section "Taskbar" -Key "ShowTaskViewButton" -Default $null
    if ($null -ne $showTaskView -and $showTaskView -ne "") {
        $value = if ($showTaskView -eq "1") { 1 } else { 0 }
        Set-RegistryValue -Path $advancedPath -Name "ShowTaskViewButton" -Value $value -Type DWord
    }

    $showSearch = Get-IniValue -Config $Config -Section "Taskbar" -Key "ShowSearchBox" -Default $null
    if ($null -ne $showSearch -and $showSearch -ne "") {
        # SearchboxTaskbarMode commonly: 0 hidden, 1 icon, 2 box
        $value = if ($showSearch -eq "1") { 1 } else { 0 }
        Set-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" -Name "SearchboxTaskbarMode" -Value $value -Type DWord
    }

    Write-Log "Taskbar section complete. Note: HKCU settings should run in user context for end-user effect." "WARN"
}

function Apply-StartMenuSection {
    param([hashtable]$Config)

    Write-Log "Applying [StartMenu] section..."

    $applyLayout = Get-IniBool -Config $Config -Section "StartMenu" -Key "ApplyStartLayout" -Default $false
    $layoutFile = Get-IniValue -Config $Config -Section "StartMenu" -Key "StartLayoutFile" -Default $null

    if ($applyLayout -and $layoutFile) {
        if (Test-Path -LiteralPath $layoutFile) {
            Write-Log "Start layout file is present at '$layoutFile'. Apply method is environment-specific, so only logging in starter script." "WARN"
        } else {
            Write-Log "Start layout file not found: $layoutFile" "WARN"
        }
    }

    $disableSuggestions = Get-IniValue -Config $Config -Section "StartMenu" -Key "DisableSuggestions" -Default $null
    if ($null -ne $disableSuggestions -and $disableSuggestions -ne "") {
        $value = if ($disableSuggestions -eq "1") { 0 } else { 1 }
        Set-RegistryValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name "SystemPaneSuggestionsEnabled" -Value $value -Type DWord
    }

    Write-Log "StartMenu section complete. Pinning apps and modern layout import are left as environment-specific customizations." "WARN"
}

function Apply-DesktopSection {
    param([hashtable]$Config)

    Write-Log "Applying [Desktop] section..."

    # Theme / dark mode (HKCU)
    $personalize = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"

    if (Get-IniBool -Config $Config -Section "Desktop" -Key "EnableDarkMode" -Default $false) {
        Set-RegistryValue -Path $personalize -Name "AppsUseLightTheme" -Value 0 -Type DWord
        Set-RegistryValue -Path $personalize -Name "SystemUsesLightTheme" -Value 0 -Type DWord
    }

    if (Get-IniBool -Config $Config -Section "Desktop" -Key "EnableLightMode" -Default $false) {
        Set-RegistryValue -Path $personalize -Name "AppsUseLightTheme" -Value 1 -Type DWord
        Set-RegistryValue -Path $personalize -Name "SystemUsesLightTheme" -Value 1 -Type DWord
    }

    $wallpaper = Get-IniValue -Config $Config -Section "Desktop" -Key "WallpaperPath" -Default $null
    if ($wallpaper) {
        if (Test-Path -LiteralPath $wallpaper) {
            Set-RegistryValue -Path "HKCU:\Control Panel\Desktop" -Name "Wallpaper" -Value $wallpaper -Type String
            Write-Log "Wallpaper registry value staged. User logoff/logon or refresh may be required."
        } else {
            Write-Log "Wallpaper file not found: $wallpaper" "WARN"
        }
    }

    Write-Log "Desktop section complete. Note: HKCU settings should run in user context for end-user effect." "WARN"
}

function Apply-RemoteDesktopSection {
    param([hashtable]$Config)

    Write-Log "Applying [RemoteDesktop] section..."

    $enableRDP = Get-IniValue -Config $Config -Section "RemoteDesktop" -Key "EnableRDP" -Default $null
    if ($null -ne $enableRDP -and $enableRDP -ne "") {
        $deny = if ($enableRDP -eq "1") { 0 } else { 1 }
        Set-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value $deny -Type DWord
    }

    $requireNLA = Get-IniValue -Config $Config -Section "RemoteDesktop" -Key "RequireNLA" -Default $null
    if ($null -ne $requireNLA -and $requireNLA -ne "") {
        $value = if ($requireNLA -eq "1") { 1 } else { 0 }
        Set-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name "UserAuthentication" -Value $value -Type DWord
    }

    if (Get-IniBool -Config $Config -Section "RemoteDesktop" -Key "SetFirewallRules" -Default $false) {
        try {
            Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction Stop | Out-Null
            Write-Log "Enabled firewall rules for Remote Desktop"
        } catch {
            Write-Log "Failed to enable Remote Desktop firewall rules. $_" "ERROR"
        }
    }

    if (Get-IniBool -Config $Config -Section "RemoteDesktop" -Key "AllowMultipleSessions" -Default $false) {
        Write-Log "AllowMultipleSessions requested, but stock Windows client behavior is limited. Custom implementation not included." "WARN"
    }
}

function Apply-SecuritySection {
    param([hashtable]$Config)

    Write-Log "Applying [Security] section..."

    $enableUAC = Get-IniValue -Config $Config -Section "Security" -Key "EnableUAC" -Default $null
    if ($null -ne $enableUAC -and $enableUAC -ne "") {
        $value = if ($enableUAC -eq "1") { 1 } else { 0 }
        Set-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "EnableLUA" -Value $value -Type DWord
        $script:RebootRequired = $true
    }

    $uacLevel = Get-IniValue -Config $Config -Section "Security" -Key "UACLevel" -Default $null
    if ($uacLevel) {
        switch ($uacLevel) {
            "0" {
                Set-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "ConsentPromptBehaviorAdmin" -Value 0 -Type DWord
            }
            "1" {
                Set-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "ConsentPromptBehaviorAdmin" -Value 1 -Type DWord
            }
            "2" {
                Set-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "ConsentPromptBehaviorAdmin" -Value 2 -Type DWord
            }
            "3" {
                Set-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "ConsentPromptBehaviorAdmin" -Value 5 -Type DWord
            }
            default {
                Write-Log "Unknown UACLevel '$uacLevel'. Expected 0/1/2/3." "WARN"
            }
        }
    }

    $disableUSB = Get-IniValue -Config $Config -Section "Security" -Key "DisableUSBStorage" -Default $null
    if ($null -ne $disableUSB -and $disableUSB -ne "") {
        # Start=4 disables USBSTOR service, Start=3 manual/default-ish
        $value = if ($disableUSB -eq "1") { 4 } else { 3 }
        Set-RegistryValue -Path "HKLM:\SYSTEM\CurrentControlSet\Services\USBSTOR" -Name "Start" -Value $value -Type DWord
    }

    $enableFirewall = Get-IniValue -Config $Config -Section "Security" -Key "EnableFirewall" -Default $null
    if ($null -ne $enableFirewall -and $enableFirewall -ne "") {
        try {
            if ($enableFirewall -eq "1") {
                Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled True -ErrorAction Stop
                Write-Log "Windows Firewall enabled for Domain/Private/Public"
            } else {
                Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled False -ErrorAction Stop
                Write-Log "Windows Firewall disabled for Domain/Private/Public"
            }
        } catch {
            Write-Log "Failed to set firewall state. $_" "ERROR"
        }
    }

    $defenderRealtime = Get-IniValue -Config $Config -Section "Security" -Key "EnableDefenderRealtimeMonitoring" -Default $null
    if ($null -ne $defenderRealtime -and $defenderRealtime -ne "") {
        try {
            if ($defenderRealtime -eq "1") {
                Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop
                Write-Log "Defender real-time monitoring enabled"
            } else {
                Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop
                Write-Log "Defender real-time monitoring disabled"
            }
        } catch {
            Write-Log "Failed to set Defender real-time monitoring (tamper protection or policy may block this). $_" "WARN"
        }
    }

    $disablePasswordReveal = Get-IniValue -Config $Config -Section "Security" -Key "DisablePasswordReveal" -Default $null
    if ($null -ne $disablePasswordReveal -and $disablePasswordReveal -ne "") {
        $value = if ($disablePasswordReveal -eq "1") { 1 } else { 0 }
        Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredUI" -Name "DisablePasswordReveal" -Value $value -Type DWord
    }

    $requireCtrlAltDel = Get-IniValue -Config $Config -Section "Security" -Key "RequireCtrlAltDel" -Default $null
    if ($null -ne $requireCtrlAltDel -and $requireCtrlAltDel -ne "") {
        # DisableCAD = 0 requires Ctrl+Alt+Del, 1 does not require
        $value = if ($requireCtrlAltDel -eq "1") { 0 } else { 1 }
        Set-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "DisableCAD" -Value $value -Type DWord
    }

    if (Get-IniBool -Config $Config -Section "Security" -Key "EnableBitLocker" -Default $false) {
        Write-Log "EnableBitLocker requested. BitLocker enablement is environment-specific (TPM, escrow, encryption method) and not fully implemented in this starter script." "WARN"
    }

    if (Get-IniBool -Config $Config -Section "Security" -Key "EnableSmartScreen" -Default $false) {
        Write-Log "EnableSmartScreen requested. Best handled via policy/Intune Settings Catalog or CSP. Not fully implemented here." "WARN"
    }
}

function Apply-WindowsUpdateSection {
    param([hashtable]$Config)

    Write-Log "Applying [WindowsUpdate] section..."

    if (Get-IniBool -Config $Config -Section "WindowsUpdate" -Key "SetWUServer" -Default $false) {
        $url = Get-IniValue -Config $Config -Section "WindowsUpdate" -Key "WUServerURL" -Default $null
        if ($url) {
            Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "WUServer" -Value $url -Type String
            Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "WUStatusServer" -Value $url -Type String
            Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "UseWUServer" -Value 1 -Type DWord
            Write-Log "Configured WSUS server to '$url'"
        } else {
            Write-Log "SetWUServer=1 but WUServerURL is blank." "WARN"
        }
    }

    $autoInstall = Get-IniValue -Config $Config -Section "WindowsUpdate" -Key "AutoInstallUpdates" -Default $null
    if ($null -ne $autoInstall -and $autoInstall -ne "") {
        # AUOptions 4 = auto download and schedule install, 2 = notify download
        $value = if ($autoInstall -eq "1") { 4 } else { 2 }
        Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AUOptions" -Value $value -Type DWord
    }

    $start = Get-IniValue -Config $Config -Section "WindowsUpdate" -Key "ActiveHoursStart" -Default $null
    $end = Get-IniValue -Config $Config -Section "WindowsUpdate" -Key "ActiveHoursEnd" -Default $null
    if ($start) {
        Set-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "ActiveHoursStart" -Value ([int]$start) -Type DWord
    }
    if ($end) {
        Set-RegistryValue -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "ActiveHoursEnd" -Value ([int]$end) -Type DWord
    }

    $pauseUpdates = Get-IniValue -Config $Config -Section "WindowsUpdate" -Key "PauseUpdates" -Default $null
    if ($null -ne $pauseUpdates -and $pauseUpdates -ne "") {
        Write-Log "PauseUpdates is defined but not implemented in this starter script. Prefer policy/CSP for update controls." "WARN"
    }
}

function Apply-WindowsFeaturesSection {
    param([hashtable]$Config)

    Write-Log "Applying [WindowsFeatures] section..."

    $featureMap = @{
        "EnableNetFx3"       = "NetFx3"
        "EnableHyperV"       = "Microsoft-Hyper-V-All"
        "EnableTelnetClient" = "TelnetClient"
        "EnableSMB1"         = "SMB1Protocol"
        "EnableWSL"          = "Microsoft-Windows-Subsystem-Linux"
        "EnableSandbox"      = "Containers-DisposableClientVM"
    }

    foreach ($key in $featureMap.Keys) {
        $desired = Get-IniValue -Config $Config -Section "WindowsFeatures" -Key $key -Default $null
        if ($null -eq $desired -or $desired -eq "") { continue }

        $featureName = $featureMap[$key]
        try {
            if ($desired -eq "1") {
                Enable-WindowsOptionalFeature -Online -FeatureName $featureName -All -NoRestart -ErrorAction Stop | Out-Null
                Write-Log "Enabled Windows feature: $featureName"
                $script:RebootRequired = $true
            } else {
                Disable-WindowsOptionalFeature -Online -FeatureName $featureName -NoRestart -ErrorAction Stop | Out-Null
                Write-Log "Disabled Windows feature: $featureName"
                $script:RebootRequired = $true
            }
        } catch {
            Write-Log "Failed to set Windows feature '$featureName'. $_" "WARN"
        }
    }

    if (Get-IniBool -Config $Config -Section "WindowsFeatures" -Key "EnableRSAT" -Default $false) {
        Write-Log "EnableRSAT requested. RSAT installation method varies by OS/version and is not fully implemented in this starter script." "WARN"
    }
}

function Apply-ApplicationsSection {
    param([hashtable]$Config)

    Write-Log "Applying [Applications] section..."

    Write-Log "Application installs/removals are placeholders in this starter script. Recommended: package each app and call installers from a known source folder." "WARN"

    $appKeys = @(
        "InstallChrome","InstallEdge","Install7Zip","InstallNotepadPP",
        "InstallOffice","InstallTeams","RemoveXbox","RemoveBloatware","RemoveConsumerApps"
    )

    foreach ($key in $appKeys) {
        $value = Get-IniValue -Config $Config -Section "Applications" -Key $key -Default $null
        if ($null -ne $value -and $value -ne "") {
            Write-Log "Applications::$key = $value"
        }
    }
}

function Apply-OfficeSection {
    param([hashtable]$Config)

    Write-Log "Applying [Office] section..."

    Write-Log "Office settings are best handled via Office Deployment Tool, Intune Administrative Templates, or Settings Catalog. Starter script logs requested values only." "WARN"

    foreach ($key in $Config["Office"].Keys) {
        Write-Log "Office::$key = $($Config["Office"][$key])"
    }
}

function Apply-OneDriveSection {
    param([hashtable]$Config)

    Write-Log "Applying [OneDrive] section..."

    Write-Log "OneDrive settings are best handled via GPO/Intune policy. Starter script logs requested values only." "WARN"

    foreach ($key in $Config["OneDrive"].Keys) {
        Write-Log "OneDrive::$key = $($Config["OneDrive"][$key])"
    }
}

function Apply-NetworkSection {
    param([hashtable]$Config)

    Write-Log "Applying [Network] section..."

    Write-Log "Network configuration is highly environment-specific (adapter names, proxy scope, DNS, static IP). Starter script logs requested values only." "WARN"

    foreach ($key in $Config["Network"].Keys) {
        Write-Log "Network::$key = $($Config["Network"][$key])"
    }
}

function Apply-PrintersSection {
    param([hashtable]$Config)

    Write-Log "Applying [Printers] section..."

    Write-Log "Printer deployment is environment-specific (server shares, IP printers, drivers). Starter script logs requested values only." "WARN"

    foreach ($key in $Config["Printers"].Keys) {
        Write-Log "Printers::$key = $($Config["Printers"][$key])"
    }
}

function Apply-CertificatesSection {
    param([hashtable]$Config)

    Write-Log "Applying [Certificates] section..."

    $rootImport = Get-IniBool -Config $Config -Section "Certificates" -Key "ImportRootCert" -Default $false
    $rootPath = Get-IniValue -Config $Config -Section "Certificates" -Key "RootCertPath" -Default $null

    if ($rootImport -and $rootPath) {
        if (Test-Path -LiteralPath $rootPath) {
            try {
                Import-Certificate -FilePath $rootPath -CertStoreLocation "Cert:\LocalMachine\Root" -ErrorAction Stop | Out-Null
                Write-Log "Imported root certificate: $rootPath"
            } catch {
                Write-Log "Failed to import root certificate '$rootPath'. $_" "ERROR"
            }
        } else {
            Write-Log "Root certificate file not found: $rootPath" "WARN"
        }
    }

    $intImport = Get-IniBool -Config $Config -Section "Certificates" -Key "ImportIntermediateCert" -Default $false
    $intPath = Get-IniValue -Config $Config -Section "Certificates" -Key "IntermediateCertPath" -Default $null

    if ($intImport -and $intPath) {
        if (Test-Path -LiteralPath $intPath) {
            try {
                Import-Certificate -FilePath $intPath -CertStoreLocation "Cert:\LocalMachine\CA" -ErrorAction Stop | Out-Null
                Write-Log "Imported intermediate certificate: $intPath"
            } catch {
                Write-Log "Failed to import intermediate certificate '$intPath'. $_" "ERROR"
            }
        } else {
            Write-Log "Intermediate certificate file not found: $intPath" "WARN"
        }
    }
}

function Apply-PowerSection {
    param([hashtable]$Config)

    Write-Log "Applying [Power] section..."

    $plan = Get-IniValue -Config $Config -Section "Power" -Key "PowerPlan" -Default $null
    if ($plan) {
        switch ($plan.ToLowerInvariant()) {
            "balanced" {
                & powercfg.exe /setactive SCHEME_BALANCED | Out-Null
                Write-Log "Power plan set to Balanced"
            }
            "high" {
                & powercfg.exe /setactive SCHEME_MIN | Out-Null
                Write-Log "Power plan set to High performance"
            }
            "saver" {
                & powercfg.exe /setactive SCHEME_MAX | Out-Null
                Write-Log "Power plan set to Power saver"
            }
            default {
                # assume GUID or custom scheme
                & powercfg.exe /setactive $plan | Out-Null
                Write-Log "Power plan set to custom scheme '$plan'"
            }
        }
    }

    $sleepAC = Get-IniValue -Config $Config -Section "Power" -Key "SleepTimeoutAC" -Default $null
    if ($sleepAC) {
        & powercfg.exe /change standby-timeout-ac $sleepAC | Out-Null
        Write-Log "Sleep timeout AC set to $sleepAC minute(s)"
    }

    $sleepDC = Get-IniValue -Config $Config -Section "Power" -Key "SleepTimeoutDC" -Default $null
    if ($sleepDC) {
        & powercfg.exe /change standby-timeout-dc $sleepDC | Out-Null
        Write-Log "Sleep timeout DC set to $sleepDC minute(s)"
    }

    $hibernate = Get-IniValue -Config $Config -Section "Power" -Key "HibernateEnabled" -Default $null
    if ($null -ne $hibernate -and $hibernate -ne "") {
        if ($hibernate -eq "1") {
            & powercfg.exe /hibernate on | Out-Null
            Write-Log "Hibernate enabled"
        } else {
            & powercfg.exe /hibernate off | Out-Null
            Write-Log "Hibernate disabled"
        }
    }

    $lidAction = Get-IniValue -Config $Config -Section "Power" -Key "LidCloseAction" -Default $null
    if ($lidAction) {
        Write-Log "LidCloseAction '$lidAction' requested. Detailed power subgroup handling is not implemented in this starter script." "WARN"
    }
}

function Apply-DevicesSection {
    param([hashtable]$Config)

    Write-Log "Applying [Devices] section..."

    $disableRemovable = Get-IniValue -Config $Config -Section "Devices" -Key "DisableRemovableStorage" -Default $null
    if ($null -ne $disableRemovable -and $disableRemovable -ne "") {
        # Policy-based deny all removable storage classes
        $value = if ($disableRemovable -eq "1") { 1 } else { 0 }
        Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices" -Name "Deny_All" -Value $value -Type DWord
    }

    foreach ($key in @("DisableCamera","DisableBluetooth","DisableWiFi","AllowPrinters")) {
        $value = Get-IniValue -Config $Config -Section "Devices" -Key $key -Default $null
        if ($null -ne $value -and $value -ne "") {
            Write-Log "Devices::$key = $value requested. Hardware-specific implementation not included in starter script." "WARN"
        }
    }
}

function Apply-BrandingSection {
    param([hashtable]$Config)

    Write-Log "Applying [Branding] section..."

    foreach ($key in $Config["Branding"].Keys) {
        Write-Log "Branding::$key = $($Config["Branding"][$key])"
    }

    Write-Log "OEM branding application is environment-specific and not fully implemented in this starter script." "WARN"
}

function Apply-CustomSection {
    param([hashtable]$Config)

    Write-Log "Applying [Custom] section..."

    $regImport = Get-IniValue -Config $Config -Section "Custom" -Key "RegistryFileImport" -Default $null
    if ($regImport) {
        if (Test-Path -LiteralPath $regImport) {
            try {
                & reg.exe import "`"$regImport`"" | Out-Null
                Write-Log "Imported registry file: $regImport"
            } catch {
                Write-Log "Failed importing registry file '$regImport'. $_" "ERROR"
            }
        } else {
            Write-Log "Registry file not found: $regImport" "WARN"
        }
    }

    foreach ($scriptKey in @("RunScript1","RunScript2")) {
        $scriptPath = Get-IniValue -Config $Config -Section "Custom" -Key $scriptKey -Default $null
        if ($scriptPath) {
            if (Test-Path -LiteralPath $scriptPath) {
                try {
                    Write-Log "Executing PowerShell script: $scriptPath"
                    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath
                    Write-Log "Completed PowerShell script: $scriptPath"
                } catch {
                    Write-Log "Failed executing script '$scriptPath'. $_" "ERROR"
                }
            } else {
                Write-Log "Custom script not found: $scriptPath" "WARN"
            }
        }
    }

    $customCommand = Get-IniValue -Config $Config -Section "Custom" -Key "CustomCommand" -Default $null
    if ($customCommand) {
        try {
            Write-Log "Executing custom command: $customCommand"
            & cmd.exe /c $customCommand
            Write-Log "Completed custom command."
        } catch {
            Write-Log "Failed executing custom command '$customCommand'. $_" "ERROR"
        }
    }
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------

try {
    $config = Read-IniFile -Path $IniPath
    Initialize-Logging -Config $config

    Write-Log "INI file loaded from: $IniPath"
    Write-Log "Schema version: $(Get-IniValue -Config $config -Section 'General' -Key 'ConfigVersion' -Default 'Unknown')"

    if (-not (Evaluate-Conditions -Config $config)) {
        Write-Log "Conditions not met. Exiting." "WARN"
        exit 0
    }

    if (Should-RunSection -Config $config -ExecutionKey "RunSystemSection") {
        Apply-SystemSection -Config $config
    }

    if (Should-RunSection -Config $config -ExecutionKey "RunExplorerSection") {
        Apply-ExplorerSection -Config $config
    }

    if (Should-RunSection -Config $config -ExecutionKey "RunTaskbarSection") {
        Apply-TaskbarSection -Config $config
    }

    if (Should-RunSection -Config $config -ExecutionKey "RunStartMenuSection") {
        Apply-StartMenuSection -Config $config
    }

    if (Should-RunSection -Config $config -ExecutionKey "RunDesktopSection") {
        Apply-DesktopSection -Config $config
    }

    if (Should-RunSection -Config $config -ExecutionKey "RunRemoteDesktopSection") {
        Apply-RemoteDesktopSection -Config $config
    }

    if (Should-RunSection -Config $config -ExecutionKey "RunSecuritySection") {
        Apply-SecuritySection -Config $config
    }

    if (Should-RunSection -Config $config -ExecutionKey "RunWindowsUpdateSection") {
        Apply-WindowsUpdateSection -Config $config
    }

    if (Should-RunSection -Config $config -ExecutionKey "RunWindowsFeaturesSection") {
        Apply-WindowsFeaturesSection -Config $config
    }

    if (Should-RunSection -Config $config -ExecutionKey "RunApplicationsSection") {
        Apply-ApplicationsSection -Config $config
    }

    if (Should-RunSection -Config $config -ExecutionKey "RunOfficeSection" -and $config.ContainsKey("Office")) {
        Apply-OfficeSection -Config $config
    }

    if (Should-RunSection -Config $config -ExecutionKey "RunOneDriveSection" -and $config.ContainsKey("OneDrive")) {
        Apply-OneDriveSection -Config $config
    }

    if (Should-RunSection -Config $config -ExecutionKey "RunNetworkSection") {
        Apply-NetworkSection -Config $config
    }

    if (Should-RunSection -Config $config -ExecutionKey "RunPrintersSection") {
        Apply-PrintersSection -Config $config
    }

    if (Should-RunSection -Config $config -ExecutionKey "RunCertificatesSection") {
        Apply-CertificatesSection -Config $config
    }

    if (Should-RunSection -Config $config -ExecutionKey "RunPowerSection") {
        Apply-PowerSection -Config $config
    }

    if (Should-RunSection -Config $config -ExecutionKey "RunDevicesSection") {
        Apply-DevicesSection -Config $config
    }

    if ($config.ContainsKey("Branding")) {
        Apply-BrandingSection -Config $config
    }

    if ($config.ContainsKey("Custom")) {
        Apply-CustomSection -Config $config
    }

    $forceReboot = Get-IniBool -Config $config -Section "Execution" -Key "ForceReboot" -Default $false
    $rebootIfRequired = Get-IniBool -Config $config -Section "Execution" -Key "RebootIfRequired" -Default $false

    if ($forceReboot) {
        Write-Log "ForceReboot=1. Rebooting now..." "WARN"
        Restart-Computer -Force
    } elseif ($rebootIfRequired -and $script:RebootRequired) {
        Write-Log "Reboot required by one or more operations. Rebooting now..." "WARN"
        Restart-Computer -Force
    } else {
        Write-Log "Configuration processing complete."
    }

    exit 0
}
catch {
    try {
        Write-Log "Fatal error: $_" "ERROR"
    } catch {
        Write-Error $_
    }
    exit 1
}

Stop-Transcript
