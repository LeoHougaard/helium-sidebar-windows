param([switch]$Launch, [switch]$Pause)

$ErrorActionPreference = 'Stop'
trap {
    Write-Host $_.Exception.Message -ForegroundColor Red
    if ($Pause) { Read-Host 'Press Enter to close' | Out-Null }
    exit 1
}
$repository = 'LeoHougaard/helium-sidebar-windows'
$install = Join-Path $env:LOCALAPPDATA 'Helium Sidebar Compact'
$versions = Join-Path $install 'Versions'
$selection = Join-Path $install 'Current.txt'
$profile = Join-Path $env:LOCALAPPDATA 'Helium PR 2367 Compact\User Data'

function Get-BrowserFolder([string]$tag) {
    if ($tag -notmatch '^[0-9][a-zA-Z0-9.-]{0,79}$' -or $tag.EndsWith('.')) {
        throw "Invalid release tag '$tag'."
    }
    Join-Path $versions $tag
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
    exit
}

$gh = (Get-Command gh.exe -ErrorAction SilentlyContinue).Source
if (!$gh) {
    Write-Host 'Installing GitHub CLI for access to your private releases.'
    & winget.exe install --id GitHub.cli --exact --source winget --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw 'GitHub CLI installation failed.' }
    $gh = Join-Path $env:ProgramFiles 'GitHub CLI\gh.exe'
    if (!(Test-Path -LiteralPath $gh -PathType Leaf)) {
        throw 'Open the installer again so Windows can pick up GitHub CLI.'
    }
}

$ErrorActionPreference = 'Continue'
& $gh auth status --hostname github.com *> $null
$signedIn = $LASTEXITCODE -eq 0
$ErrorActionPreference = 'Stop'
if (!$signedIn) {
    & $gh auth login --hostname github.com --web --git-protocol https
    if ($LASTEXITCODE -ne 0) { throw 'GitHub sign-in did not complete.' }
}

$release = & $gh api "repos/$repository/releases/latest" | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw "Could not read releases for $repository. Sign in with an account that has access." }
$assets = @($release.assets | Where-Object { $_.name -like 'Helium-Sidebar-Compact-*-Windows-x64.zip' })
if ($assets.Count -ne 1 -or $assets[0].digest -notmatch '^sha256:[a-fA-F0-9]{64}$') {
    throw 'The latest release must include one Windows x64 package with a SHA-256 digest.'
}
$asset = $assets[0]
$browser = Get-BrowserFolder $release.tag_name
$lock = [Threading.Mutex]::new($false, 'Local\HeliumSidebarCompactInstall')
$locked = $false
$stage = $null
try {
    try { $locked = $lock.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (!$locked) { throw 'Helium Sidebar installation is already running.' }
    New-Item -ItemType Directory -Force -Path $versions | Out-Null
    if (!(Test-Path -LiteralPath (Join-Path $browser 'chrome.exe') -PathType Leaf)) {
        Write-Host "Downloading Helium Sidebar $($release.tag_name)."
        $stage = Join-Path $versions ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $stage | Out-Null
        $archive = Join-Path $stage 'browser.zip'
        & $gh release download $release.tag_name --repo $repository --pattern $asset.name --output $archive
        if ($LASTEXITCODE -ne 0) { throw 'The browser download failed.' }
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
    $next = Join-Path $install 'Current.next'
    [IO.File]::WriteAllText($next, $release.tag_name)
    if (Test-Path -LiteralPath $selection) { [IO.File]::Replace($next, $selection, [NullString]::Value) }
    else { [IO.File]::Move($next, $selection) }

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
    Write-Host "Helium Sidebar $($release.tag_name) is ready. Open Helium Sidebar from Start."
    Write-Host 'If Helium Sidebar is already open, close and reopen it to use a newly installed version.'
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
