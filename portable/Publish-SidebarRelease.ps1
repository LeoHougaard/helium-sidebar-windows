$ErrorActionPreference = 'Stop'
$tag = $env:TAG
$repository = $env:GITHUB_REPOSITORY
$tagPattern = '^(?<version>[0-9]{1,5}(?:\.[0-9]{1,5}){3})-sidebar-compact(?:-r(?<revision>[1-9][0-9]{0,8}))?$'
$browserPattern = 'Helium-Sidebar-Compact-*-Windows-x64.zip'
$setupName = 'Helium-Sidebar-Public-Setup.zip'

function Get-ReleaseOrder([string]$value) {
    if ($value -notmatch $tagPattern) { throw "Invalid sidebar tag: $value" }
    [PSCustomObject]@{ Version = [version]$Matches.version; Revision = [int]$Matches.revision }
}

$candidate = Get-ReleaseOrder $tag
$latestJson = gh api "repos/$repository/releases/latest"
if ($LASTEXITCODE -ne 0) { throw 'Could not check the currently published release.' }
$latest = $latestJson | ConvertFrom-Json
if ($latest.tag_name -eq $tag) {
    $published = @($latest.assets | Where-Object name -like $browserPattern)
    if ($published.Count -eq 1 -and $published[0].digest -eq $env:DIGEST) {
        Write-Host "$tag is already published."
        return
    }
    throw 'A different package already uses this tag. Use a new revision tag.'
}
$current = Get-ReleaseOrder $latest.tag_name
if ($candidate.Version -lt $current.Version -or
    ($candidate.Version -eq $current.Version -and $candidate.Revision -le $current.Revision)) {
    throw 'Use a release tag newer than the current public release.'
}

if ($env:RELEASE_ID) {
    $draft = gh api "repos/$repository/releases/$env:RELEASE_ID" | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the verified draft.' }
} else {
    $packages = @(Get-ChildItem sidebar-release -File -Filter $browserPattern)
    if ($packages.Count -ne 1) { throw 'Expected one built browser ZIP.' }
    $digest = 'sha256:' + (Get-FileHash -LiteralPath $packages[0].FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($digest -ne $env:DIGEST) { throw 'The built package changed after verification.' }
    gh release create $tag $packages[0].FullName --repo $repository --target $env:GITHUB_SHA --draft --title "Helium Sidebar $tag"
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the draft release.' }
    $releases = gh api --paginate "repos/$repository/releases?per_page=100" --jq '.[] | select(.draft)'
    if ($LASTEXITCODE -ne 0) { throw 'Could not list draft releases.' }
    $draft = $releases | Where-Object { $_ } | ForEach-Object { ConvertFrom-Json -InputObject $_ } |
        Where-Object tag_name -eq $tag | Select-Object -First 1
}

$browser = @($draft.assets | Where-Object name -like $browserPattern)
if (!$draft.draft -or $draft.prerelease -or $draft.tag_name -ne $tag -or $browser.Count -ne 1 -or
    $browser[0].digest -ne $env:DIGEST -or ($env:ASSET_ID -and $browser[0].id -ne $env:ASSET_ID)) {
    throw 'The draft or its browser package changed after verification.'
}

$setup = Join-Path $env:RUNNER_TEMP $setupName
Compress-Archive -LiteralPath 'portable/Helium Sidebar.ps1', 'portable/Install Helium Sidebar.cmd' -DestinationPath $setup -Force
gh release upload $tag $setup --repo $repository --clobber
if ($LASTEXITCODE -ne 0) { throw 'Could not add the installer to the draft.' }

$notesFile = Join-Path $env:RUNNER_TEMP 'sidebar-release-notes.md'
$notes = @"
Download **Helium-Sidebar-Public-Setup.zip**, extract it, and run **Install Helium Sidebar.cmd**. Open **Helium Sidebar** from the Windows Start menu. Existing installations check for updates automatically, or you can run **Update Helium Sidebar** from Start to check now.

After an update downloads, close all Helium Sidebar windows and open it again. Your browser profile stays in place.
"@
if ($draft.body) { $notes += "`n`n" + $draft.body }
$notes | Set-Content -LiteralPath $notesFile -Encoding utf8
gh api --method PATCH "repos/$repository/releases/$($draft.id)" -F draft=false -f make_latest=true -F "body=@$notesFile" --jq .html_url
if ($LASTEXITCODE -ne 0) { throw 'The verified release is still a draft. Retry the publish step.' }
