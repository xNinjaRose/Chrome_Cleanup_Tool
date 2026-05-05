#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Completely removes Google Chrome from Windows 11, including all app data,
    registry entries, scheduled tasks, and cached files.

.NOTES
    Must be run as Administrator.
#>

# ─────────────────────────────────────────────────────────────
#  Helper: Colored output
# ─────────────────────────────────────────────────────────────
function Write-Status  { param([string]$Msg) Write-Host "[*] $Msg" -ForegroundColor Cyan   }
function Write-Success { param([string]$Msg) Write-Host "[+] $Msg" -ForegroundColor Green  }
function Write-Skip    { param([string]$Msg) Write-Host "[-] $Msg" -ForegroundColor Yellow }
function Write-Fail    { param([string]$Msg) Write-Host "[!] $Msg" -ForegroundColor Red    }

# ─────────────────────────────────────────────────────────────
#  Helper: Force-delete using robocopy mirror trick
#
#  HOW IT WORKS:
#    robocopy mirrors an empty temp folder OVER the target folder.
#    This silently wipes all contents regardless of ACLs or ownership
#    because robocopy runs at a level that bypasses normal permission
#    checks. No takeown, no icacls needed.
#    Then rd /S /Q removes the now-empty shell.
# ─────────────────────────────────────────────────────────────
function Force-DeleteFolder {
    param([string]$FolderPath)
    $emptyDir = Join-Path $env:TEMP "rbcpy_empty_$(Get-Random)"
    New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null
    robocopy "$emptyDir" "$FolderPath" /MIR /NFL /NDL /NJH /NJS /NC /NS /NP | Out-Null
    Remove-Item -Path $emptyDir -Force -ErrorAction SilentlyContinue
    cmd /c "rd /S /Q `"$FolderPath`"" 2>&1 | Out-Null
}

function Remove-IfExists {
    param([string]$Path)
    if (Test-Path $Path) {
        # First attempt — normal delete
        try {
            Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
            Write-Success "Removed: $Path"
            return
        } catch { }

        # Second attempt — robocopy mirror wipe (bypasses all permission issues)
        Write-Status "Normal delete failed, using force-wipe: $Path"
        Force-DeleteFolder $Path

        if (Test-Path $Path) {
            Write-Fail "Could not remove: $Path"
        } else {
            Write-Success "Force-removed: $Path"
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
#  STEP 2 — Aggressively kill ALL Chrome processes
#           Must happen before Step 5 or profile folder is locked
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

# Pass 1 — PowerShell
foreach ($name in $ChromeProcessNames) {
    Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

# Pass 2 — taskkill /F /T kills child process trees too
foreach ($name in $ChromeProcessNames) {
    taskkill /F /IM "$name.exe" /T 2>&1 | Out-Null
}

# Pass 3 — catch versioned/renamed helpers by exe path
Get-Process -ErrorAction SilentlyContinue | Where-Object {
    try { $_.MainModule.FileName -like "*Google\Chrome*" } catch { $false }
} | ForEach-Object {
    taskkill /F /PID $_.Id /T 2>&1 | Out-Null
}

Write-Status "Waiting for file handles to release..."
Start-Sleep -Seconds 5

$StillRunning = Get-Process -Name "chrome" -ErrorAction SilentlyContinue
if ($StillRunning) {
    Write-Fail "Chrome is still running. Please close it manually and re-run."
    exit 1
}
Write-Success "All Chrome processes terminated."

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
#           Robocopy wipe handles any locked/protected subfolders
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
#  STEP 8 — Remove Windows services
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
#  STEP 9 — Remove shortcuts
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
foreach ($p in $ChromeInstallPaths) { if (Test-Path $p) { $Remnants += $p } }
foreach ($r in $RegInstallPaths)    { if (Test-Path $r) { $Remnants += $r } }

if ($Remnants.Count -eq 0) {
    Write-Host ""
    Write-Host "  OK  Google Chrome has been completely removed." -ForegroundColor Green
} else {
    Write-Host ""
    Write-Fail "Some remnants could not be removed:"
    foreach ($r in $Remnants) { Write-Host "     $r" -ForegroundColor Red }
    Write-Host "  Reboot and re-run this script to clear them." -ForegroundColor Yellow
}

Write-Host "══════════════════════════════════════════════" -ForegroundColor DarkGray
Write-Host ""
