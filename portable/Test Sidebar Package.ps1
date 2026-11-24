param(
    [Parameter(Mandatory)][string]$Archive,
    [Parameter(Mandatory)][string]$Tag,
    [Parameter(Mandatory)][string]$TestDirectory
)

$ErrorActionPreference = 'Stop'
if ($Tag -notmatch '^(?<version>[0-9]{1,5}(?:\.[0-9]{1,5}){3})-sidebar-compact(?:-r[1-9][0-9]{0,8})?$') {
    throw "Invalid sidebar release tag: $Tag"
}
$expectedVersion = $Matches.version
$unpacked = Join-Path $TestDirectory 'browser'
Expand-Archive -LiteralPath $Archive -DestinationPath $unpacked
$folders = @(Get-ChildItem -LiteralPath $unpacked -Directory)
if ($folders.Count -ne 1) { throw 'Expected one application folder.' }
$app = $folders[0].FullName
$chrome = Get-Item -LiteralPath (Join-Path $app 'chrome.exe')
if ($chrome.VersionInfo.FileVersion -ne $expectedVersion) {
    throw "Expected Helium $expectedVersion, found $($chrome.VersionInfo.FileVersion)."
}
$null = Get-Item -LiteralPath (Join-Path $app 'chrome.dll')
$preferences = Join-Path $app 'Sidebar Defaults.json'
$browserSettings = (Get-Content -LiteralPath $preferences -Raw | ConvertFrom-Json).helium.browser
if ($browserSettings.layout -ne 2 -or $browserSettings.zen_mode -ne $true -or
    $browserSettings.vertical_address_bar_in_sidebar -ne $true) {
    throw 'The package does not default to the compact sidebar layout.'
}

$profile = Join-Path $TestDirectory 'profile'
$defaultProfile = New-Item -Path (Join-Path $profile 'Default') -ItemType Directory -Force
Copy-Item -LiteralPath $preferences -Destination (Join-Path $defaultProfile.FullName 'Preferences')
$output = Join-Path $TestDirectory 'page.html'
$errors = Join-Path $TestDirectory 'browser.log'
$arguments = @('--headless', '--disable-background-networking', '--no-first-run', '--dump-dom',
    ('--user-data-dir="' + $profile + '"'), 'data:text/html,<p>HeliumSidebarReleaseCheck</p>')
$process = Start-Process -FilePath $chrome.FullName -ArgumentList $arguments -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $output -RedirectStandardError $errors
try {
    $null = $process.Handle
    if (!$process.WaitForExit(60000)) { throw 'The browser did not load the test page within one minute.' }
    if (($null -ne $process.ExitCode -and $process.ExitCode -ne 0) -or
        (Get-Content -LiteralPath $output -Raw) -notmatch 'HeliumSidebarReleaseCheck') {
        Get-Content -LiteralPath $errors -Tail 10
        throw "The packaged browser could not load the test page (exit code: $($process.ExitCode))."
    }
    Write-Host "Verified that packaged Helium $expectedVersion starts and loads a page."
} finally {
    if (!$process.HasExited) { Stop-Process -Id $process.Id -Force }
    $process.Dispose()
}
