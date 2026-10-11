$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/New-Upgrade.ps1'
$latestScriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/Start-LatestUpgrade.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("SwitchAtmosphere-Upgrade-Test-" + [guid]::NewGuid().ToString('N'))

function Write-FixtureFile {
    param([string]$Root, [string]$RelativePath, [string]$Content)
    $path = Join-Path $Root $RelativePath
    [IO.Directory]::CreateDirectory((Split-Path $path -Parent)) | Out-Null
    [IO.File]::WriteAllText($path, $Content)
}

function Assert-Text {
    param([string]$Expected, [string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Missing expected file: $Path" }
    $actual = [IO.File]::ReadAllText($Path)
    if ($actual -cne $Expected) { throw "Unexpected content in $Path`: expected '$Expected', got '$actual'" }
}

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

function New-ZipFixture {
    param([string]$Root, [string]$Name, [hashtable]$Files)
    $source = Join-Path $Root ("src-" + $Name)
    foreach ($entry in $Files.GetEnumerator()) {
        Write-FixtureFile $source $entry.Key $entry.Value
    }
    $destination = Join-Path (Join-Path $Root 'assets') ("$Name.zip")
    [IO.Directory]::CreateDirectory((Split-Path $destination -Parent)) | Out-Null
    [IO.Compression.ZipFile]::CreateFromDirectory($source, $destination)
    return $destination
}

function New-Fixture {
    param([string]$Root)
    $base = Join-Path $Root 'Atmosphere-22.0.0'
    $output = Join-Path $Root 'Atmosphere-23.0.1'
    $assets = Join-Path $Root 'assets'
    [IO.Directory]::CreateDirectory($assets) | Out-Null

    Write-FixtureFile $base 'atmosphere/package3' 'old-package3'
    Write-FixtureFile $base 'atmosphere/contents/1234567890ABCDEF/cheats/test.txt' 'user-cheat'
    Write-FixtureFile $base 'bootloader/hekate_ipl.ini' 'autoboot=2'
    Write-FixtureFile $base 'bootloader/res/icon_switch.bmp' 'user-icon'
    Write-FixtureFile $base 'exosphere.ini' 'blank_prodinfo_sysmmc=1'
    Write-FixtureFile $base 'config/ultrahand/config.ini' 'key_combo=ZL+DDOWN+DRIGHT'
    Write-FixtureFile $base 'hbmenu.nro' 'user-sphaira'
    Write-FixtureFile $base 'switch/sphaira/sphaira.nro' 'user-sphaira'
    Write-FixtureFile $base 'Firmware-22.0.0/old.nca' 'old-firmware'

    $atmosphere = New-ZipFixture $Root 'atmosphere' @{
        'atmosphere/package3' = 'new-package3'
        'atmosphere/stratosphere.romfs' = 'new-romfs'
        'atmosphere/reboot_payload.bin' = 'fusee-from-atmosphere'
        'atmosphere/config_templates/system_settings.ini' = 'new-template'
        'hbmenu.nro' = 'official-hbmenu'
        'switch/daybreak.nro' = 'new-daybreak'
    }
    $hekate = New-ZipFixture $Root 'hekate' @{
        'bootloader/update.bin' = 'new-hekate'
        'bootloader/sys/nyx.bin' = 'new-nyx'
        'bootloader/res/icon_switch.bmp' = 'official-icon'
        'hekate_ctcaer_6.5.4.bin' = 'new-hekate'
    }
    $sysPatch = New-ZipFixture $Root 'sys-patch' @{
        'atmosphere/contents/420000000000000B/exefs.nsp' = 'new-sys-patch'
        'atmosphere/contents/420000000000000B/flags/boot2.flag' = ''
        'switch/.overlays/sys-patch-overlay.ovl' = 'new-sys-patch-overlay'
    }
    $firmware = New-ZipFixture $Root 'firmware' @{
        'new.nca' = 'new-firmware'
    }
    $fusee = Join-Path $assets 'fusee.bin'
    [IO.File]::WriteAllText($fusee, 'new-fusee')

    $manifest = [ordered]@{
        schemaVersion = 1
        targetSystemVersion = '23.0.1'
        artifacts = [ordered]@{}
    }
    foreach ($name in @('atmosphere', 'hekate', 'sysPatch', 'firmware', 'fusee')) {
        $file = switch ($name) {
            'atmosphere' { $atmosphere }
            'hekate' { $hekate }
            'sysPatch' { $sysPatch }
            'firmware' { $firmware }
            'fusee' { $fusee }
        }
        $manifest.artifacts[$name] = [ordered]@{
            file = Split-Path $file -Leaf
            sha256 = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    $manifestPath = Join-Path $Root 'manifest.json'
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8))
    return [pscustomobject]@{
        Base = $base
        Output = $output
        Assets = $assets
        Manifest = $manifestPath
        Report = (Join-Path $Root 'report.json')
    }
}

try {
    [IO.Directory]::CreateDirectory($testRoot) | Out-Null
    $fixture = New-Fixture $testRoot
    & $scriptPath -Manifest $fixture.Manifest -AssetDirectory $fixture.Assets -BaseDirectory $fixture.Base -OutputDirectory $fixture.Output -ReportPath $fixture.Report -Build | Out-Null

    Assert-Text 'new-package3' (Join-Path $fixture.Output 'atmosphere/package3')
    Assert-Text 'new-template' (Join-Path $fixture.Output 'atmosphere/config_templates/system_settings.ini')
    Assert-Text 'new-daybreak' (Join-Path $fixture.Output 'switch/daybreak.nro')
    Assert-Text 'new-nyx' (Join-Path $fixture.Output 'bootloader/sys/nyx.bin')
    Assert-Text 'new-hekate' (Join-Path $fixture.Output 'payload.bin')
    Assert-Text 'new-hekate' (Join-Path $fixture.Output 'bootloader/update.bin')
    Assert-Text 'new-hekate' (Join-Path $fixture.Output 'atmosphere/reboot_payload.bin')
    Assert-Text 'new-fusee' (Join-Path $fixture.Output 'bootloader/payloads/fusee.bin')
    Assert-Text 'new-sys-patch' (Join-Path $fixture.Output 'atmosphere/contents/420000000000000B/exefs.nsp')
    Assert-Text 'new-firmware' (Join-Path $fixture.Output 'Firmware.23.0.1/new.nca')
    Assert-Text 'autoboot=2' (Join-Path $fixture.Output 'bootloader/hekate_ipl.ini')
    Assert-Text 'user-icon' (Join-Path $fixture.Output 'bootloader/res/icon_switch.bmp')
    Assert-Text 'blank_prodinfo_sysmmc=1' (Join-Path $fixture.Output 'exosphere.ini')
    Assert-Text 'user-sphaira' (Join-Path $fixture.Output 'hbmenu.nro')
    Assert-Text 'user-cheat' (Join-Path $fixture.Output 'atmosphere/contents/1234567890ABCDEF/cheats/test.txt')
    if (Test-Path -LiteralPath (Join-Path $fixture.Output 'Firmware-22.0.0')) { throw 'Old firmware was copied into new package' }
    if (-not (Test-Path -LiteralPath $fixture.Report)) { throw 'Upgrade report was not generated' }
    $buildReport = Get-Content -LiteralPath $fixture.Report -Raw | ConvertFrom-Json
    if ('bootloader/hekate_ipl.ini' -notin $buildReport.preservedBasePaths -or
        'atmosphere/contents/1234567890ABCDEF/cheats/test.txt' -notin $buildReport.preservedBasePaths -or
        'Firmware-22.0.0' -notin $buildReport.removedFirmwareDirectories) {
        throw 'Report does not clearly identify preserved files and removed old firmware'
    }
    Write-Output 'PASS: build updates upstream components and preserves local customizations'

    $insideFixture = New-Fixture (Join-Path $testRoot 'report-inside-output')
    $insideReport = Join-Path $insideFixture.Output 'report.json'
    Assert-Fails {
        & $scriptPath -Manifest $insideFixture.Manifest -AssetDirectory $insideFixture.Assets -BaseDirectory $insideFixture.Base -OutputDirectory $insideFixture.Output -ReportPath $insideReport | Out-Null
    } 'Report path cannot be inside the output directory'
    if (Test-Path -LiteralPath $insideFixture.Output) { throw 'Plan-only call created the output directory' }
    Write-Output 'PASS: plan-only rejects a report path inside the package'

    $hashFixture = New-Fixture (Join-Path $testRoot 'bad-hash')
    $hashManifest = Get-Content -LiteralPath $hashFixture.Manifest -Raw | ConvertFrom-Json -AsHashtable
    $hashManifest.artifacts.atmosphere.sha256 = '0' * 64
    [IO.File]::WriteAllText($hashFixture.Manifest, ($hashManifest | ConvertTo-Json -Depth 8))
    Assert-Fails {
        & $scriptPath -Manifest $hashFixture.Manifest -AssetDirectory $hashFixture.Assets -BaseDirectory $hashFixture.Base -OutputDirectory $hashFixture.Output -ReportPath $hashFixture.Report -Build | Out-Null
    } 'SHA-256 mismatch'
    if (Test-Path -LiteralPath $hashFixture.Output) { throw 'Hash failure created an output package' }
    Write-Output 'PASS: invalid artifact hash stops before writing'

    $existingFixture = New-Fixture (Join-Path $testRoot 'existing-output')
    Write-FixtureFile $existingFixture.Output 'sentinel.txt' 'keep-me'
    Assert-Fails {
        & $scriptPath -Manifest $existingFixture.Manifest -AssetDirectory $existingFixture.Assets -BaseDirectory $existingFixture.Base -OutputDirectory $existingFixture.Output -ReportPath $existingFixture.Report -Build | Out-Null
    } 'already exists'
    Assert-Text 'keep-me' (Join-Path $existingFixture.Output 'sentinel.txt')
    Write-Output 'PASS: existing output is never overwritten'

    $zipFixture = New-Fixture (Join-Path $testRoot 'unsafe-zip')
    $zip = Join-Path $zipFixture.Assets 'atmosphere.zip'
    $archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Update)
    try {
        $entry = $archive.CreateEntry('../escape.txt')
        $writer = [IO.StreamWriter]::new($entry.Open())
        try { $writer.Write('escape') }
        finally { $writer.Dispose() }
    }
    finally { $archive.Dispose() }
    $zipManifest = Get-Content -LiteralPath $zipFixture.Manifest -Raw | ConvertFrom-Json -AsHashtable
    $zipManifest.artifacts.atmosphere.sha256 = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($zipFixture.Manifest, ($zipManifest | ConvertTo-Json -Depth 8))
    Assert-Fails {
        & $scriptPath -Manifest $zipFixture.Manifest -AssetDirectory $zipFixture.Assets -BaseDirectory $zipFixture.Base -OutputDirectory $zipFixture.Output -ReportPath $zipFixture.Report -Build | Out-Null
    } 'Unsafe ZIP path'
    if (Test-Path -LiteralPath (Join-Path $zipFixture.Output 'escape.txt')) { throw 'Unsafe ZIP entry escaped into output' }
    Write-Output 'PASS: unsafe ZIP paths are rejected'

    $incompletePatchFixture = New-Fixture (Join-Path $testRoot 'incomplete-sys-patch')
    $patchZip = Join-Path $incompletePatchFixture.Assets 'sys-patch.zip'
    $patchArchive = [IO.Compression.ZipFile]::Open($patchZip, [IO.Compression.ZipArchiveMode]::Update)
    try { $patchArchive.GetEntry('switch/.overlays/sys-patch-overlay.ovl').Delete() }
    finally { $patchArchive.Dispose() }
    $patchManifest = Get-Content -LiteralPath $incompletePatchFixture.Manifest -Raw | ConvertFrom-Json -AsHashtable
    $patchManifest.artifacts.sysPatch.sha256 = (Get-FileHash -LiteralPath $patchZip -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($incompletePatchFixture.Manifest, ($patchManifest | ConvertTo-Json -Depth 8))
    Assert-Fails {
        & $scriptPath -Manifest $incompletePatchFixture.Manifest -AssetDirectory $incompletePatchFixture.Assets `
            -BaseDirectory $incompletePatchFixture.Base -OutputDirectory $incompletePatchFixture.Output `
            -ReportPath $incompletePatchFixture.Report | Out-Null
    } 'sys-patch release is missing required path'
    Write-Output 'PASS: incomplete sys-patch release is rejected'

    $keysFixture = New-Fixture (Join-Path $testRoot 'extra-keys')
    Write-FixtureFile $keysFixture.Base 'switch/private/custom.keys' 'test-key-material'
    Assert-Fails {
        & $scriptPath -Manifest $keysFixture.Manifest -AssetDirectory $keysFixture.Assets `
            -BaseDirectory $keysFixture.Base -OutputDirectory $keysFixture.Output `
            -ReportPath $keysFixture.Report | Out-Null
    } 'Key material found in base package'
    Write-Output 'PASS: any .keys file in the base is rejected'

    $noPatchFixture = New-Fixture (Join-Path $testRoot 'no-sys-patch')
    $noPatchManifest = Get-Content -LiteralPath $noPatchFixture.Manifest -Raw | ConvertFrom-Json -AsHashtable
    $noPatchManifest.artifacts.Remove('sysPatch')
    [IO.File]::WriteAllText($noPatchFixture.Manifest, ($noPatchManifest | ConvertTo-Json -Depth 8))
    & $scriptPath -Manifest $noPatchFixture.Manifest -AssetDirectory $noPatchFixture.Assets -BaseDirectory $noPatchFixture.Base -OutputDirectory $noPatchFixture.Output -ReportPath $noPatchFixture.Report | Out-Null
    if (Test-Path -LiteralPath $noPatchFixture.Output) { throw 'Plan-only call created output package' }
    $noPatchReport = Get-Content -LiteralPath $noPatchFixture.Report -Raw | ConvertFrom-Json
    if (@($noPatchReport.warnings | Where-Object { $_ -like '*sys-patch*' }).Count -ne 1) {
        throw 'Missing explicit warning when sys-patch is not updated'
    }
    Write-Output 'PASS: omitting sys-patch is called out in the plan'

    $latestFixture = New-Fixture (Join-Path $testRoot 'latest-verified-base')
    $packageRoot = Split-Path $latestFixture.Base -Parent
    [IO.Directory]::CreateDirectory((Join-Path $packageRoot 'Atmosphere-24.0.0')) | Out-Null
    $registry = Join-Path $packageRoot 'verified-bases.json'
    [IO.File]::WriteAllText($registry, (@{
        schemaVersion = 1
        bases = @(
            @{ directory = 'Atmosphere-22.0.0'; targetSystemVersion = '22.0.0'; verified = $true },
            @{ directory = 'Atmosphere-24.0.0'; targetSystemVersion = '24.0.0'; verified = $false }
        )
    } | ConvertTo-Json -Depth 5))
    $latestManifest = Get-Content -LiteralPath $latestFixture.Manifest -Raw | ConvertFrom-Json -AsHashtable
    $repositories = @{
        atmosphere = 'Atmosphere-NX/Atmosphere'
        fusee = 'Atmosphere-NX/Atmosphere'
        hekate = 'CTCaer/hekate'
        sysPatch = 'impeeza/sys-patch'
        firmware = 'THZoria/NX_Firmware'
    }
    foreach ($name in $repositories.Keys) {
        $file = [string]$latestManifest.artifacts[$name].file
        $repo = $repositories[$name]
        $latestManifest.artifacts[$name].source = @{
            repository = $repo
            tag = 'fixture'
            assetName = $file
            url = "https://github.com/$repo/releases/download/fixture/$file"
        }
    }
    [IO.File]::WriteAllText($latestFixture.Manifest, ($latestManifest | ConvertTo-Json -Depth 10))
    & $latestScriptPath -PackageRoot $packageRoot -VerifiedBasesPath $registry `
        -AssetDirectory $latestFixture.Assets -ManifestPath $latestFixture.Manifest `
        -OutputDirectory $latestFixture.Output -ReportPath $latestFixture.Report -Offline | Out-Null
    $latestReport = Get-Content -LiteralPath $latestFixture.Report -Raw | ConvertFrom-Json
    if ($latestReport.baseDirectory -ne 'Atmosphere-22.0.0' -or $latestReport.targetSystemVersion -ne '23.0.1') {
        throw 'Latest upgrade did not use the registered local base and locked release version'
    }
    if (Test-Path -LiteralPath $latestFixture.Output) { throw 'Latest plan-only run created output package' }
    Write-Output 'PASS: offline replay plans from the latest verified local package'

    $sameFixture = New-Fixture (Join-Path $testRoot 'same-version')
    $sameRoot = Split-Path $sameFixture.Base -Parent
    Copy-Item -LiteralPath $sameFixture.Base -Destination $sameFixture.Output -Recurse
    $sameRegistry = Join-Path $sameRoot 'verified-bases.json'
    [IO.File]::WriteAllText($sameRegistry, (@{
        schemaVersion = 1
        bases = @(@{ directory = 'Atmosphere-23.0.1'; targetSystemVersion = '23.0.1'; verified = $true })
    } | ConvertTo-Json -Depth 5))
    $sameManifest = Get-Content -LiteralPath $sameFixture.Manifest -Raw | ConvertFrom-Json -AsHashtable
    foreach ($name in $repositories.Keys) {
        $file = [string]$sameManifest.artifacts[$name].file
        $repo = $repositories[$name]
        $sameManifest.artifacts[$name].source = @{
            repository = $repo
            tag = 'fixture'
            assetName = $file
            url = "https://github.com/$repo/releases/download/fixture/$file"
        }
    }
    [IO.File]::WriteAllText($sameFixture.Manifest, ($sameManifest | ConvertTo-Json -Depth 10))
    & $latestScriptPath -PackageRoot $sameRoot -VerifiedBasesPath $sameRegistry `
        -AssetDirectory $sameFixture.Assets -ManifestPath $sameFixture.Manifest `
        -ReportPath $sameFixture.Report -Offline | Out-Null
    $sameReport = Get-Content -LiteralPath $sameFixture.Report -Raw | ConvertFrom-Json
    if ($sameReport.baseDirectory -ne 'Atmosphere-23.0.1' -or
        $sameReport.outputDirectory -ne 'Atmosphere-23.0.1-candidate') {
        throw 'Same-version plan did not use a distinct candidate directory'
    }
    if (Test-Path -LiteralPath (Join-Path $sameRoot 'Atmosphere-23.0.1-candidate')) {
        throw 'Same-version plan-only run created candidate directory'
    }
    Write-Output 'PASS: same-version updates plan into a distinct candidate directory'
}
finally {
    $root = [IO.Path]::GetFullPath($testRoot)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($root.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $root -Leaf) -like 'SwitchAtmosphere-Upgrade-Test-*') {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}
