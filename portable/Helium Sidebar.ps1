param([switch]$Launch, [switch]$Pause, [switch]$Automatic)

$ErrorActionPreference = 'Stop'
trap {
    if ($Automatic) {
        Add-Content -LiteralPath $updateLog -Value "$(Get-Date -Format s) $($_.Exception.Message)" -ErrorAction SilentlyContinue
    } else {
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
    if ($Pause) { Read-Host 'Press Enter to close' | Out-Null }
    exit 1
}
$repository = 'LeoHougaard/helium-sidebar-windows'
$install = Join-Path $env:LOCALAPPDATA 'Helium Sidebar Compact'
$versions = Join-Path $install 'Versions'
$selection = Join-Path $install 'Current.txt'
$previousSelection = Join-Path $install 'Previous.txt'
$lastCheck = Join-Path $install 'Last Update Check'
$updateLog = Join-Path $install 'Update.log'
$profile = Join-Path $env:LOCALAPPDATA 'Helium PR 2367 Compact\User Data'

$releaseTagPattern = '^(?<version>[0-9]{1,5}(?:\.[0-9]{1,5}){3})-sidebar-compact(?:-r(?<revision>[1-9][0-9]{0,8}))?$'

function Get-ReleaseVersion([string]$tag) {
    if ($tag -notmatch $releaseTagPattern) {
        throw "Invalid release tag '$tag'."
    }
    [version]$Matches.version
}

function Get-BrowserFolder([string]$tag) {
    $null = Get-ReleaseVersion $tag
    Join-Path $versions $tag
}

function Remove-OldVersions([string]$current) {
    $root = Get-Item -LiteralPath $versions
    if ($root.Attributes -band [IO.FileAttributes]::ReparsePoint) { return }

    $keep = @($current)
    if (Test-Path -LiteralPath $previousSelection -PathType Leaf) {
        $keep += (Get-Content -LiteralPath $previousSelection -Raw).Trim()
    }
    $running = @(Get-Process -Name chrome -ErrorAction SilentlyContinue | ForEach-Object Path)
    foreach ($folder in Get-ChildItem -LiteralPath $root.FullName -Directory) {
        if ($folder.Name -notmatch $releaseTagPattern -or $folder.Name -in $keep -or
            ($folder.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
        $path = (Resolve-Path -LiteralPath $folder.FullName).ProviderPath
        if ((Split-Path -Parent $path) -ne $root.FullName) { continue }
        if ($running | Where-Object { $_ -and $_.StartsWith($path + '\', [StringComparison]::OrdinalIgnoreCase) }) { continue }
        if (Get-ChildItem -LiteralPath $path -Recurse -Force -Attributes ReparsePoint | Select-Object -First 1) { continue }
        try {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
        } catch {
            Add-Content -LiteralPath $updateLog -Value "$(Get-Date -Format s) Could not remove $($folder.Name): $($_.Exception.Message)" -ErrorAction SilentlyContinue
        }
    }
}

if ($Launch) {
    $browser = Get-BrowserFolder ((Get-Content -LiteralPath $selection -Raw).Trim())
    $preferences = Join-Path $profile 'Default\Preferences'
    if (!(Test-Path -LiteralPath $preferences)) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $preferences) | Out-Null
        [IO.File]::Copy((Join-Path $browser 'Sidebar Defaults.json'), $preferences)
    }
    $arguments = @('--no-first-run', '--no-default-browser-check', ('--user-data-dir="' + $profile + '"'))
    Start-Process -FilePath (Join-Path $browser 'chrome.exe') -WorkingDirectory $browser -ArgumentList $arguments
    $checked = Get-Item -LiteralPath $lastCheck -ErrorAction SilentlyContinue
    if (!$checked -or $checked.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddDays(-1)) {
        $updateArguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Automatic'
        Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $updateArguments -WindowStyle Hidden
    }
    exit
}

$lock = [Threading.Mutex]::new($false, 'Local\HeliumSidebarCompactInstall')
$locked = $false
$stage = $null
try {
    try { $locked = $lock.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (!$locked) {
        if ($Automatic) { return }
        throw 'Helium Sidebar installation is already running.'
    }
    New-Item -ItemType Directory -Force -Path $versions | Out-Null
    if ($Automatic) {
        $checked = Get-Item -LiteralPath $lastCheck -ErrorAction SilentlyContinue
        if ($checked -and $checked.LastWriteTimeUtc -ge [DateTime]::UtcNow.AddDays(-1)) { return }
        [IO.File]::WriteAllText($lastCheck, '')
    }
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repository/releases/latest" -UseBasicParsing -TimeoutSec 30
    $assets = @($release.assets | Where-Object { $_.name -like 'Helium-Sidebar-Compact-*-Windows-x64.zip' })
    if ($assets.Count -ne 1 -or $assets[0].digest -notmatch '^sha256:[a-fA-F0-9]{64}$') {
        throw 'The latest release must include one Windows x64 package with a SHA-256 digest.'
    }
    $asset = $assets[0]
    $browser = Get-BrowserFolder $release.tag_name
    $current = if (Test-Path -LiteralPath $selection -PathType Leaf) { (Get-Content -LiteralPath $selection -Raw).Trim() }
    if ($current) {
        $installedVersion = Get-ReleaseVersion $current
        $availableVersion = Get-ReleaseVersion $release.tag_name
        $installedRevision = if ($current -match '-r(\d+)$') { [int]$Matches[1] } else { 0 }
        $availableRevision = if ($release.tag_name -match '-r(\d+)$') { [int]$Matches[1] } else { 0 }
        if ($availableVersion -lt $installedVersion -or
            ($availableVersion -eq $installedVersion -and $availableRevision -lt $installedRevision)) {
            if ($Automatic) { return }
            throw 'The latest published release is older than your installed version.'
        }
        if ($Automatic -and $current -eq $release.tag_name) {
            Remove-OldVersions $current
            return
        }
    }
    if (!(Test-Path -LiteralPath (Join-Path $browser 'chrome.exe') -PathType Leaf)) {
        if (!$Automatic) { Write-Host "Downloading Helium Sidebar $($release.tag_name)." }
        $stage = Join-Path $versions ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $stage | Out-Null
        $archive = Join-Path $stage 'browser.zip'
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $asset.browser_download_url -UseBasicParsing -OutFile $archive
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $asset.digest.Substring(7)) {
            throw 'The downloaded package did not match the release digest.'
        }
        $unpacked = Join-Path $stage 'Unpacked'
        Expand-Archive -LiteralPath $archive -DestinationPath $unpacked
        $folders = @(Get-ChildItem -LiteralPath $unpacked -Directory)
        if ($folders.Count -ne 1) { throw 'The browser package must have one application folder.' }
        foreach ($file in 'chrome.exe', 'chrome.dll', 'Sidebar Defaults.json') {
            if (!(Test-Path -LiteralPath (Join-Path $folders[0].FullName $file) -PathType Leaf)) {
                throw "The browser package is missing $file."
            }
        }
        [IO.Directory]::Move($folders[0].FullName, $browser)
    }

    $helper = Join-Path $install 'Helium Sidebar.ps1'
    if ($PSCommandPath -ne $helper) { Copy-Item -LiteralPath $PSCommandPath -Destination $helper }
    if ($current -ne $release.tag_name) {
        $next = Join-Path $install 'Current.next'
        [IO.File]::WriteAllText($next, $release.tag_name)
        if ($current) { [IO.File]::Replace($next, $selection, $previousSelection) }
        else { [IO.File]::Move($next, $selection) }
    }

    $programs = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    New-Item -ItemType Directory -Force -Path $programs | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    foreach ($action in @(
        @{Name = 'Helium Sidebar'; Arguments = ' -Launch'; Style = 7},
        @{Name = 'Update Helium Sidebar'; Arguments = ' -Pause'; Style = 1}
    )) {
        $shortcut = $shell.CreateShortcut((Join-Path $programs ($action.Name + '.lnk')))
        $shortcut.TargetPath = Join-Path $PSHOME 'powershell.exe'
        $shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $helper + '"' + $action.Arguments
        $shortcut.WorkingDirectory = $install
        $shortcut.IconLocation = (Join-Path $browser 'chrome.exe') + ',0'
        $shortcut.WindowStyle = $action.Style
        $shortcut.Save()
    }
    Remove-OldVersions $release.tag_name
    if (!$Automatic) {
        Write-Host "Helium Sidebar $($release.tag_name) is ready. Open Helium Sidebar from Start."
        Write-Host 'If Helium Sidebar is already open, close and reopen it to use a newly installed version.'
    }
} finally {
    if ($stage) {
        $stagePath = [IO.Path]::GetFullPath($stage)
        $versionsPath = [IO.Path]::GetFullPath($versions) + '\'
        if ($stagePath.StartsWith($versionsPath, [StringComparison]::OrdinalIgnoreCase) -and
            (Test-Path -LiteralPath $stagePath)) {
            Remove-Item -LiteralPath $stagePath -Recurse -Force
        }
    }
    if ($locked) { $lock.ReleaseMutex() }
    $lock.Dispose()
}
if ($Pause) { Read-Host 'Press Enter to close' | Out-Null }
