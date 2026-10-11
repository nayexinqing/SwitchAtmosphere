Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Select-VerifiedBase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$RegistryPath,
        [Parameter(Mandatory)] [string]$PackageRoot
    )

    if (-not (Test-Path -LiteralPath $RegistryPath -PathType Leaf)) {
        throw "Verified-base registry not found: $RegistryPath"
    }
    if (-not (Test-Path -LiteralPath $PackageRoot -PathType Container)) {
        throw "Package root not found: $PackageRoot"
    }
    $registry = Get-Content -LiteralPath $RegistryPath -Raw | ConvertFrom-Json -AsHashtable
    if ($registry.schemaVersion -ne 1 -or -not $registry.bases) {
        throw 'Invalid verified-base registry; expected schemaVersion 1 and bases.'
    }

    $candidates = @(
        foreach ($entry in $registry.bases) {
            if ($entry.verified -ne $true) { continue }
            $version = [string]$entry.targetSystemVersion
            if ($version -notmatch '^\d+\.\d+\.\d+$') {
                throw "Invalid verified base version: $version"
            }
            $name = [string]$entry.directory
            if ($name -cne "Atmosphere-$version") {
                throw "Verified base directory must be Atmosphere-$version`: $name"
            }
            $path = Join-Path ([IO.Path]::GetFullPath($PackageRoot)) $name
            if (-not (Test-Path -LiteralPath $path -PathType Container)) { continue }
            $item = Get-Item -LiteralPath $path -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Verified base directory cannot be a link: $path"
            }
            [pscustomobject]@{
                directory = $name
                targetSystemVersion = $version
                path = $path
            }
        }
    )
    if ($candidates.Count -eq 0) { throw "No registered verified package directory exists in: $PackageRoot" }
    return $candidates | Sort-Object { [version]$_.targetSystemVersion } -Descending | Select-Object -First 1
}

function Get-GitHubLatestReleases {
    [CmdletBinding()]
    param([string]$TargetSystemVersion)

    if ($TargetSystemVersion -and $TargetSystemVersion -notmatch '^\d+\.\d+\.\d+$') {
        throw "Invalid target system version: $TargetSystemVersion"
    }

    $releases = [ordered]@{}
    foreach ($repository in @('Atmosphere-NX/Atmosphere', 'CTCaer/hekate', 'impeeza/sys-patch', 'THZoria/NX_Firmware')) {
        $endpoint = if ($repository -eq 'THZoria/NX_Firmware' -and $TargetSystemVersion) {
            "tags/$TargetSystemVersion"
        }
        else { 'latest' }
        $uri = "https://api.github.com/repos/$repository/releases/$endpoint"
        try {
            $releases[$repository] = Invoke-RestMethod -Uri $uri -Headers @{
                Accept = 'application/vnd.github+json'
                'User-Agent' = 'SwitchAtmosphere-upgrade-workflow'
            } -ErrorAction Stop
        }
        catch { throw "Cannot read GitHub release for $repository ($endpoint): $($_.Exception.Message)" }
    }
    return $releases
}

function Select-SingleReleaseAsset {
    param(
        [string]$Repository,
        [object]$Release,
        [string]$Pattern,
        [string]$Description,
        [string]$CacheName
    )

    $tag = [string]$Release.tag_name
    if ($tag -notmatch '^[a-zA-Z0-9._-]+$') { throw "Invalid GitHub release tag for $Repository`: $tag" }
    if ($Release.draft -eq $true -or $Release.prerelease -eq $true) {
        throw "Latest release for $Repository is draft or prerelease; review it manually."
    }
    $assets = @($Release.assets | Where-Object { [string]$_.name -match $Pattern })
    if ($assets.Count -ne 1) {
        throw "Expected exactly one $Description asset in $Repository@$tag; found $($assets.Count)."
    }
    $asset = $assets[0]
    $name = [string]$asset.name
    if ($name -ne [IO.Path]::GetFileName($name) -or $name -in @('.', '..')) {
        throw "Unsafe GitHub asset name in $Repository@$tag`: $name"
    }
    $digest = [string]$asset.digest
    $digestMatch = [regex]::Match($digest, '^sha256:([a-fA-F0-9]{64})$')
    if (-not $digestMatch.Success) {
        throw "GitHub asset has no SHA-256 digest: $Repository@$tag/$name"
    }
    $url = [string]$asset.browser_download_url
    $expectedPrefix = "https://github.com/$Repository/releases/download/$tag/"
    if (-not $url.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unexpected GitHub asset URL for $Repository@$tag/$name`: $url"
    }
    if (-not $CacheName) { $CacheName = $name }
    if ($CacheName -ne [IO.Path]::GetFileName($CacheName) -or $CacheName -in @('.', '..')) {
        throw "Unsafe cache file name: $CacheName"
    }
    return [ordered]@{
        file = $CacheName
        sha256 = $digestMatch.Groups[1].Value.ToLowerInvariant()
        source = [ordered]@{
            repository = $Repository
            tag = $tag
            assetName = $name
            url = $url
            publishedAt = [string]$Release.published_at
        }
    }
}

function Select-GitHubReleaseAssets {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary]$Releases,
        [string]$TargetSystemVersion
    )

    foreach ($repository in @('Atmosphere-NX/Atmosphere', 'CTCaer/hekate', 'impeeza/sys-patch', 'THZoria/NX_Firmware')) {
        if (-not $Releases.Contains($repository)) { throw "Missing GitHub release metadata: $repository" }
    }
    $firmwareTag = [string]$Releases['THZoria/NX_Firmware'].tag_name
    if ($firmwareTag -notmatch '^\d+\.\d+\.\d+$') {
        throw "Firmware release tag must be a numeric system version: $firmwareTag"
    }
    if ($TargetSystemVersion -and $firmwareTag -cne $TargetSystemVersion) {
        throw "Firmware release tag $firmwareTag does not match requested $TargetSystemVersion."
    }
    $atmosphereTag = [string]$Releases['Atmosphere-NX/Atmosphere'].tag_name
    $hekateTag = [string]$Releases['CTCaer/hekate'].tag_name
    $sysPatchTag = [string]$Releases['impeeza/sys-patch'].tag_name
    $atmosphereVersion = [regex]::Escape($atmosphereTag)
    $hekateVersion = [regex]::Escape(($hekateTag -replace '^v', ''))
    $sysPatchVersion = [regex]::Escape($sysPatchTag)
    $firmwareAsset = [regex]::Escape("Firmware.$firmwareTag.zip")
    $artifacts = [ordered]@{
        atmosphere = Select-SingleReleaseAsset 'Atmosphere-NX/Atmosphere' $Releases['Atmosphere-NX/Atmosphere'] "^atmosphere-$atmosphereVersion(?:-[^/]+)?\.zip`$" 'Atmosphere ZIP' ''
        fusee = Select-SingleReleaseAsset 'Atmosphere-NX/Atmosphere' $Releases['Atmosphere-NX/Atmosphere'] '^fusee\.bin$' 'fusee.bin' "fusee-$atmosphereTag.bin"
        hekate = Select-SingleReleaseAsset 'CTCaer/hekate' $Releases['CTCaer/hekate'] "^hekate_ctcaer_$hekateVersion`_Nyx_[0-9.]+\.zip`$" 'hekate/Nyx ZIP' ''
        sysPatch = Select-SingleReleaseAsset 'impeeza/sys-patch' $Releases['impeeza/sys-patch'] "^sys-patch-$sysPatchVersion\.zip`$" 'sys-patch ZIP' ''
        firmware = Select-SingleReleaseAsset 'THZoria/NX_Firmware' $Releases['THZoria/NX_Firmware'] "^$firmwareAsset`$" "Firmware.$firmwareTag.zip" ''
    }
    return [ordered]@{
        schemaVersion = 1
        targetSystemVersion = $firmwareTag
        artifacts = $artifacts
    }
}

function Save-GitHubAssets {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary]$Artifacts,
        [Parameter(Mandatory)] [string]$AssetDirectory,
        [switch]$Offline
    )

    [IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($AssetDirectory)) | Out-Null
    foreach ($artifact in $Artifacts.Values) {
        $fileName = [string]$artifact.file
        if ($fileName -ne [IO.Path]::GetFileName($fileName) -or $fileName -in @('.', '..')) {
            throw "Unsafe cache file name: $fileName"
        }
        $expectedHash = [string]$artifact.sha256
        if ($expectedHash -notmatch '^[a-fA-F0-9]{64}$') { throw "Invalid asset SHA-256: $fileName" }
        $path = Join-Path $AssetDirectory $fileName
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            if ($Offline) { throw "Offline cache is missing GitHub asset: $fileName" }
            $temp = "$path.download-$([guid]::NewGuid().ToString('N'))"
            try {
                Invoke-WebRequest -Uri ([string]$artifact.source.url) -OutFile $temp -Headers @{
                    'User-Agent' = 'SwitchAtmosphere-upgrade-workflow'
                } -ErrorAction Stop
                $downloadHash = (Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($downloadHash -ne $expectedHash.ToLowerInvariant()) {
                    throw "Downloaded SHA-256 mismatch for GitHub asset: $fileName"
                }
                Move-Item -LiteralPath $temp -Destination $path
            }
            finally {
                if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
            }
        }
        $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $expectedHash.ToLowerInvariant()) {
            throw "Cached SHA-256 mismatch for GitHub asset: $fileName"
        }
    }
}

Export-ModuleMember -Function Select-VerifiedBase, Get-GitHubLatestReleases, Select-GitHubReleaseAssets, Save-GitHubAssets
