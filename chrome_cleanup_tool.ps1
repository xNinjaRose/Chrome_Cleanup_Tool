#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Completely removes Google Chrome from Windows 11, including all app data,
    registry entries, scheduled tasks, and cached files.

.DESCRIPTION
    This script performs a full forensic-level uninstall of Chrome. It checks
    whether Chrome is installed first and exits gracefully if not found.

.NOTES
    Must be run as Administrator.
#>

# ─────────────────────────────────────────────────────────────
#  Helper: Colored output
# ─────────────────────────────────────────────────────────────
function Write-Status  { param([string]$Msg) Write-Host "[*] $Msg" -ForegroundColor Cyan    }
function Write-Success { param([string]$Msg) Write-Host "[+] $Msg" -ForegroundColor Green   }
function Write-Skip    { param([string]$Msg) Write-Host "[-] $Msg" -ForegroundColor Yellow  }
function Write-Fail    { param([string]$Msg) Write-Host "[!] $Msg" -ForegroundColor Red     }

# ─────────────────────────────────────────────────────────────
#  Helper: Take ownership + grant full control, then delete
# ─────────────────────────────────────────────────────────────
function Force-TakeOwnership {
    param([string]$FolderPath)
    try {
        takeown /F "$FolderPath" /R /D Y 2>&1 | Out-Null
        icacls "$FolderPath" /grant "Administrators:(OI)(CI)F" /T /C /Q 2>&1 | Out-Null
    } catch {
        # Non-fatal — best effort
    }
}

function Remove-IfExists {
    param([string]$Path)
    if (Test-Path $Path) {
        try {
            Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
            Write-Success "Removed: $Path"
        } catch {
            # Access denied — take ownership and retry
            Write-Status "Access denied, taking ownership: $Path"
            Force-TakeOwnership $Path
            try {
                Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
                Write-Success "Removed (after ownership fix): $Path"
            } catch {
                Write-Fail "Still could not remove: $Path — $($_.Exception.Message)"
            }
        }
    } else {
        Write-Skip "Not found (skip): $Path"
    }
}

# ─────────────────────────────────────────────────────────────
#  Helper: Safe remove registry key
# ─────────────────────────────────────────────────────────────
function Remove-RegIfExists {
    param([string]$Path)
    if (Test-Path $Path) {
        try {
            Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
            Write-Success "Registry removed: $Path"
        } catch {
            Write-Fail "Could not remove registry key: $Path — $($_.Exception.Message)"
        }
    } else {
        Write-Skip "Registry key not found (skip): $Path"
    }
}

# ═════════════════════════════════════════════════════════════
#  STEP 1 — Check if Chrome is installed
# ═════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "══════════════════════════════════════════════" -ForegroundColor DarkGray
Write-Host "   Google Chrome — Full Removal Script"         -ForegroundColor White
Write-Host "══════════════════════════════════════════════" -ForegroundColor DarkGray
Write-Host ""

$ChromeInstallPaths = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
)

$ChromeFound = $false
foreach ($p in $ChromeInstallPaths) {
    if (Test-Path $p) { $ChromeFound = $true; break }
}

$RegInstallPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Google Chrome",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Google Chrome"
)
foreach ($r in $RegInstallPaths) {
    if (Test-Path $r) { $ChromeFound = $true; break }
}

if (-not $ChromeFound) {
    Write-Skip "Google Chrome does not appear to be installed on this machine."
    Write-Skip "Nothing to remove. Exiting cleanly."
    Write-Host ""
    exit 0
}

Write-Status "Chrome installation detected. Beginning full removal..."
Write-Host ""

# ═════════════════════════════════════════════════════════════
#  STEP 2 — Aggressively kill ALL Chrome-related processes
#           MUST complete before Step 5 touches profile folders.
#           Windows locks profile files while any Chrome process
#           is alive — even background helpers with no window.
# ═════════════════════════════════════════════════════════════
Write-Status "Terminating all Chrome-related processes..."

$ChromeProcessNames = @(
    "chrome",
    "chrome_crashpad_handler",
    "GoogleCrashHandler",
    "GoogleCrashHandler64",
    "GoogleUpdate",
    "software_reporter_tool",
    "elevation_service"
)

# Pass 1 — PowerShell Stop-Process
foreach ($name in $ChromeProcessNames) {
    Get-Process -Name $name -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

# Pass 2 — taskkill /F /T kills child processes too, catches anything Stop-Process missed
foreach ($name in $ChromeProcessNames) {
    taskkill /F /IM "$name.exe" /T 2>&1 | Out-Null
}

# Pass 3 — catch any renamed/versioned helpers by their executable path
Get-Process -ErrorAction SilentlyContinue | Where-Object {
    try { $_.MainModule.FileName -like "*Google\Chrome*" } catch { $false }
} | ForEach-Object {
    taskkill /F /PID $_.Id /T 2>&1 | Out-Null
}

# Give Windows time to fully release all file handles
Write-Status "Waiting for file handles to release..."
Start-Sleep -Seconds 5

# Safety check — if Chrome is somehow still alive, stop and warn the user
$StillRunning = Get-Process -Name "chrome" -ErrorAction SilentlyContinue
if ($StillRunning) {
    Write-Fail "Chrome is still running after all kill attempts."
    Write-Fail "Please close Chrome manually then re-run this script."
    exit 1
} else {
    Write-Success "All Chrome processes terminated."
}

# ═════════════════════════════════════════════════════════════
#  STEP 3 — Run the official uninstaller (if present)
# ═════════════════════════════════════════════════════════════
Write-Host ""
Write-Status "Looking for Chrome's built-in uninstaller..."

$UninstallerPaths = @(
    "$env:ProgramFiles\Google\Chrome\Application\*\Installer\setup.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\*\Installer\setup.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\*\Installer\setup.exe"
)

$UninstallerFound = $false
foreach ($pattern in $UninstallerPaths) {
    $match = Get-Item $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($match) {
        Write-Status "Running official uninstaller: $($match.FullName)"
        try {
            Start-Process -FilePath $match.FullName `
                -ArgumentList "--uninstall --system-level --verbose-logging --force-uninstall" `
                -Wait -ErrorAction Stop
            Write-Success "Official uninstaller completed."
        } catch {
            Write-Fail "Official uninstaller failed (continuing anyway): $($_.Exception.Message)"
        }
        $UninstallerFound = $true
        Start-Sleep -Seconds 3
        break
    }
}

if (-not $UninstallerFound) {
    Write-Skip "Official uninstaller not found — proceeding with manual removal."
}

# ═════════════════════════════════════════════════════════════
#  STEP 4 — Remove installation directories
# ═════════════════════════════════════════════════════════════
Write-Host ""
Write-Status "Removing Chrome installation folders..."

$InstallDirs = @(
    "$env:ProgramFiles\Google\Chrome",
    "${env:ProgramFiles(x86)}\Google\Chrome",
    "$env:LOCALAPPDATA\Google\Chrome"
)
foreach ($dir in $InstallDirs) { Remove-IfExists $dir }

$GoogleDirs = @(
    "$env:ProgramFiles\Google\Update",
    "${env:ProgramFiles(x86)}\Google\Update",
    "$env:LOCALAPPDATA\Google\Update"
)
foreach ($dir in $GoogleDirs) { Remove-IfExists $dir }

# ═════════════════════════════════════════════════════════════
#  STEP 5 — Remove user profile / app data
#           Safe to run now — all processes killed in Step 2
# ═════════════════════════════════════════════════════════════
Write-Host ""
Write-Status "Removing user profile and cached data..."

$UserDataPaths = @(
    "$env:LOCALAPPDATA\Google\Chrome",
    "$env:APPDATA\Google\Chrome",
    "$env:LOCALAPPDATA\Google\CrashReports",
    "$env:TEMP\Chrome*",
    "$env:TEMP\google*"
)
foreach ($p in $UserDataPaths) { Remove-IfExists $p }

# All other user profiles on this machine
$UserProfiles = Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue
foreach ($profile in $UserProfiles) {
    $OtherUserPaths = @(
        "$($profile.FullName)\AppData\Local\Google\Chrome",
        "$($profile.FullName)\AppData\Roaming\Google\Chrome",
        "$($profile.FullName)\AppData\Local\Google\CrashReports"
    )
    foreach ($p in $OtherUserPaths) { Remove-IfExists $p }
}

# ═════════════════════════════════════════════════════════════
#  STEP 6 — Remove registry entries
# ═════════════════════════════════════════════════════════════
Write-Host ""
Write-Status "Scrubbing registry entries..."

$RegistryKeys = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Google Chrome",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Google Chrome",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Google Chrome",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe",
    "HKLM:\SOFTWARE\Google\Chrome",
    "HKLM:\SOFTWARE\WOW6432Node\Google\Chrome",
    "HKCU:\SOFTWARE\Google\Chrome",
    "HKLM:\SOFTWARE\Google\Update",
    "HKLM:\SOFTWARE\WOW6432Node\Google\Update",
    "HKCU:\SOFTWARE\Google\Update",
    "HKLM:\SOFTWARE\Policies\Google\Chrome",
    "HKLM:\SOFTWARE\WOW6432Node\Policies\Google\Chrome",
    "HKCU:\SOFTWARE\Policies\Google\Chrome",
    "HKCR:\ChromeHTML",
    "HKCR:\ChromiumHTM",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.html\UserChoice",
    "HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Compatibility Assistant\Store"
)
foreach ($key in $RegistryKeys) { Remove-RegIfExists $key }

# MUICache cleanup
Write-Status "Cleaning MUICache entries for Chrome..."
$MUICachePath = "HKCU:\SOFTWARE\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache"
if (Test-Path $MUICachePath) {
    try {
        $MUIEntries = Get-Item $MUICachePath | Select-Object -ExpandProperty Property |
                      Where-Object { $_ -like "*chrome*" }
        foreach ($entry in $MUIEntries) {
            Remove-ItemProperty -Path $MUICachePath -Name $entry -Force -ErrorAction SilentlyContinue
            Write-Success "MUICache entry removed: $entry"
        }
    } catch {
        Write-Fail "Could not clean MUICache: $($_.Exception.Message)"
    }
}

# ═════════════════════════════════════════════════════════════
#  STEP 7 — Remove scheduled tasks
# ═════════════════════════════════════════════════════════════
Write-Host ""
Write-Status "Removing Chrome scheduled tasks..."

$Tasks = Get-ScheduledTask -ErrorAction SilentlyContinue |
         Where-Object { $_.TaskName -like "*Google*" -or $_.TaskName -like "*Chrome*" }

if ($Tasks) {
    foreach ($task in $Tasks) {
        try {
            Unregister-ScheduledTask -TaskName $task.TaskName -Confirm:$false -ErrorAction Stop
            Write-Success "Scheduled task removed: $($task.TaskName)"
        } catch {
            Write-Fail "Could not remove task: $($task.TaskName) — $($_.Exception.Message)"
        }
    }
} else {
    Write-Skip "No Chrome/Google scheduled tasks found."
}

# ═════════════════════════════════════════════════════════════
#  STEP 8 — Remove Windows services (GoogleUpdate)
# ═════════════════════════════════════════════════════════════
Write-Host ""
Write-Status "Removing Google Update services..."

$Services = @("gupdate", "gupdatem")
foreach ($svc in $Services) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($s) {
        try {
            Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
            sc.exe delete $svc | Out-Null
            Write-Success "Service removed: $svc"
        } catch {
            Write-Fail "Could not remove service: $svc — $($_.Exception.Message)"
        }
    } else {
        Write-Skip "Service not found (skip): $svc"
    }
}

# ═════════════════════════════════════════════════════════════
#  STEP 9 — Remove Start Menu / Desktop shortcuts
# ═════════════════════════════════════════════════════════════
Write-Host ""
Write-Status "Removing shortcuts..."

$ShortcutPaths = @(
    "$env:PUBLIC\Desktop\Google Chrome.lnk",
    "$env:USERPROFILE\Desktop\Google Chrome.lnk",
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Google Chrome.lnk",
    "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Google Chrome.lnk"
)
foreach ($s in $ShortcutPaths) { Remove-IfExists $s }

foreach ($profile in $UserProfiles) {
    Remove-IfExists "$($profile.FullName)\Desktop\Google Chrome.lnk"
    Remove-IfExists "$($profile.FullName)\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Google Chrome.lnk"
}

# ═════════════════════════════════════════════════════════════
#  STEP 10 — Final verification
# ═════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "══════════════════════════════════════════════" -ForegroundColor DarkGray
Write-Status "Running final verification check..."

$Remnants = @()
foreach ($p in $ChromeInstallPaths) {
    if (Test-Path $p) { $Remnants += $p }
}
foreach ($r in $RegInstallPaths) {
    if (Test-Path $r) { $Remnants += $r }
}

if ($Remnants.Count -eq 0) {
    Write-Host ""
    Write-Host "  v  Google Chrome has been completely removed." -ForegroundColor Green
} else {
    Write-Host ""
    Write-Fail "Some remnants could not be removed:"
    foreach ($r in $Remnants) { Write-Host "     $r" -ForegroundColor Red }
    Write-Host "  You may need to reboot and re-run this script, or remove these manually." -ForegroundColor Yellow
}

Write-Host "══════════════════════════════════════════════" -ForegroundColor DarkGray
Write-Host ""
