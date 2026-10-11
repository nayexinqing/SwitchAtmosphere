$ErrorActionPreference = 'Stop'

$modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/UpgradeSources.psm1'
Import-Module $modulePath -Force
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('SwitchAtmosphere-Sources-Test-' + [guid]::NewGuid().ToString('N'))

function Assert-Fails {
    param([scriptblock]$Action, [string]$MessagePart)
    $failed = $false
    try { & $Action | Out-Null }
    catch {
        if ($_.Exception.Message -notlike "*$MessagePart*") { throw }
        $failed = $true
    }
    if (-not $failed) { throw "Expected failure containing '$MessagePart'" }
}

function New-Asset {
    param([string]$Repository, [string]$Tag, [string]$Name, [string]$Hash)
    return @{
        name = $Name
        digest = "sha256:$Hash"
        browser_download_url = "https://github.com/$Repository/releases/download/$Tag/$Name"
    }
}

try {
    [IO.Directory]::CreateDirectory($testRoot) | Out-Null
    foreach ($name in @('Atmosphere-22.0.0', 'Atmosphere-23.0.1', 'Atmosphere-24.0.0')) {
        [IO.Directory]::CreateDirectory((Join-Path $testRoot $name)) | Out-Null
    }
    $registryPath = Join-Path $testRoot 'verified-bases.json'
    [IO.File]::WriteAllText($registryPath, (@{
        schemaVersion = 1
        bases = @(
            @{ directory = 'Atmosphere-22.0.0'; targetSystemVersion = '22.0.0'; verified = $true },
            @{ directory = 'Atmosphere-23.0.1'; targetSystemVersion = '23.0.1'; verified = $true },
            @{ directory = 'Atmosphere-24.0.0'; targetSystemVersion = '24.0.0'; verified = $false }
        )
    } | ConvertTo-Json -Depth 5))
    $selected = Select-VerifiedBase -RegistryPath $registryPath -PackageRoot $testRoot
    if ($selected.targetSystemVersion -ne '23.0.1' -or $selected.directory -ne 'Atmosphere-23.0.1') {
        throw 'Latest verified local package was not selected'
    }
    Write-Output 'PASS: highest verified local package is selected'

    [IO.Directory]::Delete((Join-Path $testRoot 'Atmosphere-24.0.0'))
    $registryData = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json -AsHashtable
    $registryData.bases[2].verified = $true
    [IO.File]::WriteAllText($registryPath, ($registryData | ConvertTo-Json -Depth 5))
    $selectedWithMissing = Select-VerifiedBase -RegistryPath $registryPath -PackageRoot $testRoot
    if ($selectedWithMissing.directory -ne 'Atmosphere-23.0.1') {
        throw 'Missing registered directory blocked a valid local base'
    }
    Write-Output 'PASS: missing registered packages are skipped'
    $emptyPackageRoot = Join-Path $testRoot 'empty-packages'
    [IO.Directory]::CreateDirectory($emptyPackageRoot) | Out-Null
    Assert-Fails {
        Select-VerifiedBase -RegistryPath $registryPath -PackageRoot $emptyPackageRoot
    } 'No registered verified package directory exists'
    Write-Output 'PASS: no local verified package produces a clear error'

    $hash = 'a' * 64
    $releases = @{
        'Atmosphere-NX/Atmosphere' = @{
            tag_name = '1.12.0'; published_at = '2026-09-27T23:21:53Z'; draft = $false; prerelease = $false
            assets = @(
                (New-Asset 'Atmosphere-NX/Atmosphere' '1.12.0' 'atmosphere-1.12.0-master.zip' $hash),
                (New-Asset 'Atmosphere-NX/Atmosphere' '1.12.0' 'fusee.bin' $hash)
            )
        }
        'CTCaer/hekate' = @{
            tag_name = 'v6.5.4'; published_at = '2026-09-28T00:06:10Z'; draft = $false; prerelease = $false
            assets = @(
                (New-Asset 'CTCaer/hekate' 'v6.5.4' 'hekate_ctcaer_6.5.4_Nyx_1.9.4.zip' $hash),
                (New-Asset 'CTCaer/hekate' 'v6.5.4' 'hekate_ctcaer_6.5.4.bin' $hash),
                (New-Asset 'CTCaer/hekate' 'v6.5.4' 'hekate_ctcaer_6.5.4__ram8GB.bin' $hash)
            )
        }
        'impeeza/sys-patch' = @{
            tag_name = 'v1.6.2.3'; published_at = '2026-06-17T08:03:39Z'; draft = $false; prerelease = $false
            assets = @((New-Asset 'impeeza/sys-patch' 'v1.6.2.3' 'sys-patch-v1.6.2.3.zip' $hash))
        }
        'THZoria/NX_Firmware' = @{
            tag_name = '23.0.1'; published_at = '2026-10-01T01:54:25Z'; draft = $false; prerelease = $false
            assets = @((New-Asset 'THZoria/NX_Firmware' '23.0.1' 'Firmware.23.0.1.zip' $hash))
        }
    }
    $resolved = Select-GitHubReleaseAssets -Releases $releases
    if ($resolved.targetSystemVersion -ne '23.0.1' -or $resolved.artifacts.Count -ne 5) {
        throw 'Release selection returned the wrong version or asset count'
    }
    if ($resolved.artifacts.firmware.source.repository -ne 'THZoria/NX_Firmware' -or
        $resolved.artifacts.sysPatch.source.repository -ne 'impeeza/sys-patch' -or
        $resolved.artifacts.hekate.file -ne 'hekate_ctcaer_6.5.4_Nyx_1.9.4.zip' -or
        $resolved.artifacts.fusee.file -ne 'fusee-1.12.0.bin' -or
        $resolved.artifacts.fusee.source.assetName -ne 'fusee.bin') {
        throw 'Release assets were selected from the wrong source'
    }
    Write-Output 'PASS: GitHub release assets are pinned by repository, tag, name and digest'

    $targeted = Select-GitHubReleaseAssets -Releases $releases -TargetSystemVersion '23.0.1'
    if ($targeted.targetSystemVersion -ne '23.0.1') { throw 'Explicit firmware version was not selected' }
    Assert-Fails {
        Select-GitHubReleaseAssets -Releases $releases -TargetSystemVersion '23.0.0'
    } 'does not match requested'
    Write-Output 'PASS: explicitly requested firmware version must match release tag'

    $releases['Atmosphere-NX/Atmosphere'].assets[0].name = 'atmosphere-1.11.9-master.zip'
    Assert-Fails { Select-GitHubReleaseAssets -Releases $releases } 'Atmosphere ZIP'
    $releases['Atmosphere-NX/Atmosphere'].assets[0].name = 'atmosphere-1.12.0-master.zip'
    $releases['CTCaer/hekate'].assets[0].name = 'hekate_ctcaer_6.5.3_Nyx_1.9.4.zip'
    Assert-Fails { Select-GitHubReleaseAssets -Releases $releases } 'hekate/Nyx ZIP'
    $releases['CTCaer/hekate'].assets[0].name = 'hekate_ctcaer_6.5.4_Nyx_1.9.4.zip'
    $releases['impeeza/sys-patch'].assets[0].name = 'sys-patch-v1.6.2.2.zip'
    Assert-Fails { Select-GitHubReleaseAssets -Releases $releases } 'sys-patch ZIP'
    $releases['impeeza/sys-patch'].assets[0].name = 'sys-patch-v1.6.2.3.zip'
    Write-Output 'PASS: selected ZIP names must match their GitHub release tags'

    $releases['impeeza/sys-patch'].assets[0].digest = $null
    Assert-Fails { Select-GitHubReleaseAssets -Releases $releases } 'SHA-256 digest'
    Write-Output 'PASS: release assets without SHA-256 digest are rejected'

    $releases['impeeza/sys-patch'].assets[0].digest = "sha256:$hash"
    $releases['THZoria/NX_Firmware'].assets[0].name = 'Firmware.22.0.0.zip'
    Assert-Fails { Select-GitHubReleaseAssets -Releases $releases } 'Firmware.23.0.1.zip'
    Write-Output 'PASS: firmware asset must match its release tag'

    $cache = Join-Path $testRoot 'cache'
    [IO.Directory]::CreateDirectory($cache) | Out-Null
    $cachedFile = Join-Path $cache 'fusee-test.bin'
    [IO.File]::WriteAllText($cachedFile, 'verified-asset')
    $cachedHash = (Get-FileHash -LiteralPath $cachedFile -Algorithm SHA256).Hash.ToLowerInvariant()
    $cachedArtifacts = [ordered]@{
        fusee = [ordered]@{ file = 'fusee-test.bin'; sha256 = $cachedHash }
    }
    Save-GitHubAssets -Artifacts $cachedArtifacts -AssetDirectory $cache -Offline
    [IO.File]::WriteAllText($cachedFile, 'tampered-asset')
    Assert-Fails { Save-GitHubAssets -Artifacts $cachedArtifacts -AssetDirectory $cache -Offline } 'Cached SHA-256 mismatch'
    Remove-Item -LiteralPath $cachedFile
    Assert-Fails { Save-GitHubAssets -Artifacts $cachedArtifacts -AssetDirectory $cache -Offline } 'Offline cache is missing'
    Write-Output 'PASS: offline cache replay requires matching bytes for every asset'
}
finally {
    $root = [IO.Path]::GetFullPath($testRoot)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($root.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path $root -Leaf) -like 'SwitchAtmosphere-Sources-Test-*') {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}
