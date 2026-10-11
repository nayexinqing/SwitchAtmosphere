#requires -Version 7.0
param(
    [string]$PackageRoot,
    [string]$VerifiedBasesPath,
    [string]$AssetDirectory,
    [string]$ManifestPath,
    [string]$OutputDirectory,
    [string]$ReportPath,
    [switch]$Offline,
    [switch]$Build
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'UpgradeSources.psm1') -Force

if (-not $PackageRoot) { $PackageRoot = Split-Path $PSScriptRoot -Parent }
if (-not $VerifiedBasesPath) { $VerifiedBasesPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'config/verified-bases.json' }
if (-not $AssetDirectory) { $AssetDirectory = Join-Path $PackageRoot '.upgrade-cache/assets' }
$PackageRoot = [IO.Path]::GetFullPath($PackageRoot)
$base = Select-VerifiedBase -RegistryPath $VerifiedBasesPath -PackageRoot $PackageRoot

if ($Offline) {
    if (-not $ManifestPath) { throw '-Offline requires -ManifestPath pointing to a previously locked GitHub release manifest.' }
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw "Locked manifest not found: $ManifestPath" }
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -AsHashtable
}
else {
    $releases = Get-GitHubLatestReleases
    $manifest = Select-GitHubReleaseAssets -Releases $releases
}

if ($manifest.schemaVersion -ne 1 -or [string]$manifest.targetSystemVersion -notmatch '^\d+\.\d+\.\d+$') {
    throw 'Invalid locked GitHub release manifest.'
}
$sources = @{
    atmosphere = 'Atmosphere-NX/Atmosphere'
    fusee = 'Atmosphere-NX/Atmosphere'
    hekate = 'CTCaer/hekate'
    sysPatch = 'impeeza/sys-patch'
    firmware = 'THZoria/NX_Firmware'
}
foreach ($name in $sources.Keys) {
    if (-not $manifest.artifacts.Contains($name)) { throw "Locked manifest is missing artifact: $name" }
    $artifact = $manifest.artifacts[$name]
    $repo = $sources[$name]
    if ([string]$artifact.source.repository -ne $repo -or
        [string]$artifact.source.tag -notmatch '^[a-zA-Z0-9._-]+$' -or
        [string]$artifact.source.assetName -ne [IO.Path]::GetFileName([string]$artifact.source.assetName)) {
        throw "Invalid GitHub source metadata for artifact: $name"
    }
    $expectedPrefix = "https://github.com/$repo/releases/download/$($artifact.source.tag)/"
    if (-not ([string]$artifact.source.url).StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Invalid GitHub download URL for artifact: $name"
    }
}

$version = [string]$manifest.targetSystemVersion
if ([version]$version -lt [version]$base.targetSystemVersion) {
    throw "Latest GitHub firmware $version is older than the verified local base $($base.targetSystemVersion)."
}
if (-not $OutputDirectory) {
    $name = if ([version]$version -eq [version]$base.targetSystemVersion) {
        "Atmosphere-$version-candidate"
    }
    else { "Atmosphere-$version" }
    $OutputDirectory = Join-Path $PackageRoot $name
}
if ($Build -and (Test-Path -LiteralPath $OutputDirectory)) {
    throw "Output directory already exists: $OutputDirectory"
}

$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
if (-not $ManifestPath) { $ManifestPath = Join-Path $PackageRoot ".upgrade-cache/locks/release-lock-$version-$stamp.json" }
if (-not $ReportPath) { $ReportPath = Join-Path $PackageRoot ".upgrade-cache/reports/UPGRADE-$version-$stamp.report.json" }

Save-GitHubAssets -Artifacts $manifest.artifacts -AssetDirectory $AssetDirectory -Offline:$Offline
if (-not $Offline) {
    [IO.Directory]::CreateDirectory((Split-Path ([IO.Path]::GetFullPath($ManifestPath)) -Parent)) | Out-Null
    if (Test-Path -LiteralPath $ManifestPath) { throw "Locked manifest already exists: $ManifestPath" }
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($ManifestPath), ($manifest | ConvertTo-Json -Depth 12))
}

& (Join-Path $PSScriptRoot 'New-Upgrade.ps1') -Manifest $ManifestPath `
    -AssetDirectory $AssetDirectory -BaseDirectory $base.path `
    -OutputDirectory $OutputDirectory -ReportPath $ReportPath -Build:$Build
