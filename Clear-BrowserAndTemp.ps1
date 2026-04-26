# Clear-BrowserAndTemp.ps1
# Clears Chrome/Edge browsing data and Windows temp files (no admin required)

#region Helpers

function Write-Status {
    param([string]$Message, [string]$Color = 'Cyan')
    Write-Host "`n$Message" -ForegroundColor $Color
}

function Remove-SafePath {
    param([string]$Path)
    if (Test-Path $Path) {
        try {
            Remove-Item -Path $Path -Recurse -Force -ErrorAction SilentlyContinue
            return $true
        } catch {
            return $false
        }
    }
    return $false
}

function Get-SizeString {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N2} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N2} KB' -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Measure-PathSize {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return 0 }
    try {
        (Get-ChildItem -Path $Path -Recurse -Force -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
    } catch { 0 }
}

function Stop-BrowserIfRunning {
    param([string]$ProcessName, [string]$BrowserName)
    $procs = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue
    if ($procs) {
        Write-Host "  [!] $BrowserName is running. Attempting to close gracefully..." -ForegroundColor Yellow
        $procs | ForEach-Object { $_.CloseMainWindow() | Out-Null }
        Start-Sleep -Seconds 2
        # Force kill if still alive
        Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        Write-Host "  [+] $BrowserName closed." -ForegroundColor Green
    }
}

#endregion

#region Config

$script:TotalFreed = 0L

# Chrome profile base paths (supports multiple profiles)
$ChromeBase   = "$env:LOCALAPPDATA\Google\Chrome\User Data"
# Edge profile base paths
$EdgeBase     = "$env:LOCALAPPDATA\Microsoft\Edge\User Data"

# Per-profile sub-folders to wipe
$ProfileFolders = @(
    'Cache',
    'Cache2',
    'Code Cache',
    'GPUCache',
    'Service Worker\CacheStorage',
    'Service Worker\ScriptCache',
    'Network Action Predictor',
    'Cookies',
    'Cookies-journal',
    'History',
    'History-journal',
    'Visited Links',
    'Web Data',
    'Web Data-journal',
    'Favicons',
    'Favicons-journal',
    'Login Data',
    'Login Data-journal',
    'Shortcuts',
    'Shortcuts-journal',
    'Current Session',
    'Current Tabs',
    'Last Session',
    'Last Tabs',
    'Top Sites',
    'Top Sites-journal',
    'QuotaManager',
    'QuotaManager-journal',
    'IndexedDB',
    'Local Storage\leveldb',
    'Session Storage',
    'databases',
    'Extension State',
    'Extension Rules',
    'DawnCache',
    'VideoDecodeStats'
)

# Shared caches outside profiles
$BrowserSharedFolders = @(
    'GrShaderCache',
    'ShaderCache'
)

# Windows temp locations (user-level only)
$TempPaths = @(
    $env:TEMP,
    $env:TMP,
    "$env:LOCALAPPDATA\Temp",
    "$env:LOCALAPPDATA\Microsoft\Windows\INetCache",
    "$env:LOCALAPPDATA\Microsoft\Windows\Temporary Internet Files",
    "$env:APPDATA\Microsoft\Windows\Recent",
    "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\ThumbCacheToDelete",
    "$env:LOCALAPPDATA\CrashDumps"
)

#endregion

#region Functions

function Clear-BrowserProfiles {
    param(
        [string]$BasePath,
        [string]$BrowserName,
        [string]$ProcessName
    )

    Write-Status "[$BrowserName] Clearing browsing data..." 'Cyan'

    if (-not (Test-Path $BasePath)) {
        Write-Host "  [-] $BrowserName not found. Skipping." -ForegroundColor DarkGray
        return
    }

    Stop-BrowserIfRunning -ProcessName $ProcessName -BrowserName $BrowserName

    # Discover all profile folders (Default, Profile 1, Profile 2, ...)
    $profiles = @('Default') + (Get-ChildItem -Path $BasePath -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^Profile \d+$' } |
        Select-Object -ExpandProperty Name)

    foreach ($profile in $profiles) {
        $profilePath = Join-Path $BasePath $profile
        if (-not (Test-Path $profilePath)) { continue }

        Write-Host "  -> Profile: $profile" -ForegroundColor White

        foreach ($folder in $ProfileFolders) {
            $target = Join-Path $profilePath $folder
            $size   = Measure-PathSize $target
            if (Remove-SafePath $target) {
                $script:TotalFreed += $size
                Write-Host "     [OK] $folder  ($(Get-SizeString $size))" -ForegroundColor Green
            }
        }
    }

    # Shared browser-level caches
    foreach ($folder in $BrowserSharedFolders) {
        $target = Join-Path $BasePath $folder
        $size   = Measure-PathSize $target
        if (Remove-SafePath $target) {
            $script:TotalFreed += $size
            Write-Host "  [OK] Shared/$folder  ($(Get-SizeString $size))" -ForegroundColor Green
        }
    }
}

function Clear-WindowsTempFiles {
    Write-Status '[Windows] Clearing temp & cache files...' 'Cyan'

    foreach ($path in $TempPaths) {
        if (-not (Test-Path $path)) { continue }

        Write-Host "  -> $path" -ForegroundColor White

        Get-ChildItem -Path $path -Force -ErrorAction SilentlyContinue |
            ForEach-Object {
                $size = if ($_.PSIsContainer) { Measure-PathSize $_.FullName } else { $_.Length }
                try {
                    Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                    $script:TotalFreed += $size
                } catch { <# locked file – skip #> }
            }
        Write-Host "     [OK] Done" -ForegroundColor Green
    }

    # Prefetch (user-accessible on modern Windows without admin)
    $prefetch = "$env:SystemRoot\Prefetch"
    if (Test-Path $prefetch) {
        Write-Host "  -> Prefetch" -ForegroundColor White
        Get-ChildItem -Path $prefetch -Filter '*.pf' -Force -ErrorAction SilentlyContinue |
            ForEach-Object {
                $size = $_.Length
                try {
                    Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                    $script:TotalFreed += $size
                } catch { }
            }
        Write-Host "     [OK] Done (some files may be locked by system)" -ForegroundColor Green
    }
}

#endregion

#region Main

Clear-Host
Write-Host '============================================' -ForegroundColor Magenta
Write-Host '   Browser & Temp File Cleaner (No Admin)  ' -ForegroundColor Magenta
Write-Host '============================================' -ForegroundColor Magenta
Write-Host "  User    : $env:USERNAME"
Write-Host "  Machine : $env:COMPUTERNAME"
Write-Host "  Date    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host ''

Clear-BrowserProfiles -BasePath $ChromeBase -BrowserName 'Google Chrome' -ProcessName 'chrome'
Clear-BrowserProfiles -BasePath $EdgeBase   -BrowserName 'Microsoft Edge' -ProcessName 'msedge'
Clear-WindowsTempFiles

Write-Host ''
Write-Host '============================================' -ForegroundColor Magenta
Write-Host "  Total space freed : $(Get-SizeString $script:TotalFreed)" -ForegroundColor Yellow
Write-Host '  Cleanup complete!' -ForegroundColor Green
Write-Host '============================================' -ForegroundColor Magenta

#endregion
