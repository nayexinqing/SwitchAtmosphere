$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/New-ReleaseBundle.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('SwitchAtmosphere-Release-Test-' + [guid]::NewGuid().ToString('N'))

function Write-FixtureFile {
    param([string]$Root, [string]$RelativePath, [string]$Content)
    $path = Join-Path $Root $RelativePath
    [IO.Directory]::CreateDirectory((Split-Path $path -Parent)) | Out-Null
    [IO.File]::WriteAllText($path, $Content)
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

function New-PackageFixture {
    param([string]$Root)
    $package = Join-Path $Root 'Atmosphere-23.0.1'
    Write-FixtureFile $package 'atmosphere/package3' 'package3'
    Write-FixtureFile $package 'atmosphere/contents/420000000000000B/exefs.nsp' 'sys-patch'
    Write-FixtureFile $package 'atmosphere/contents/010007B010FCC000/cheats/abcd.txt' 'game-cheat'
    Write-FixtureFile $package 'bootloader/update.bin' 'hekate'
    Write-FixtureFile $package 'bootloader/sys/nyx.bin' 'nyx'
    Write-FixtureFile $package 'bootloader/payloads/fusee.bin' 'fusee'
    Write-FixtureFile $package 'bootloader/hekate_ipl.ini' 'autoboot=2'
    Write-FixtureFile $package 'bootloader/res/emunand.bmp' 'custom-icon'
    Write-FixtureFile $package 'config/ultrahand/config.ini' 'default_lang=zh-cn'
    Write-FixtureFile $package 'switch/sphaira/sphaira.nro' 'sphaira'
    Write-FixtureFile $package 'switch/dbi/dbi.config' 'Password=private-test'
    Write-FixtureFile $package 'Firmware.23.0.1/a.nca' 'firmware'
    Write-FixtureFile $package 'payload.bin' 'hekate'
    Write-FixtureFile $package 'exosphere.ini' 'blank_prodinfo_emummc=1'
    Write-FixtureFile $package 'lakka/storage/.cache/ssh/ssh_host_ed25519_key' 'private-test-key'
    Write-FixtureFile $package 'lakka/storage/roms/test.zip' 'private-rom'
    return $package
}

try {
    [IO.Directory]::CreateDirectory($testRoot) | Out-Null
    $package = New-PackageFixture (Join-Path $testRoot 'good')
    $planPath = Join-Path $testRoot 'release-plan.json'
    & $scriptPath -PackageDirectory $package -TargetSystemVersion '23.0.1' -PlanPath $planPath -VerifiedSeed | Out-Null
    $plan = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json
    $included = @($plan.included | ForEach-Object path)
    $excluded = @($plan.excluded | ForEach-Object path)
    foreach ($path in @('atmosphere/package3', 'bootloader/hekate_ipl.ini', 'bootloader/res/emunand.bmp',
            'Firmware.23.0.1/a.nca', 'atmosphere/contents/420000000000000B/exefs.nsp')) {
        if ($path -notin $included) { throw "Expected included path missing: $path" }
    }
    if (@($included | Where-Object { $_ -like 'lakka/*' -or $_ -like '*cheats*' }).Count -ne 0 -or
        'lakka/storage/.cache/ssh/ssh_host_ed25519_key' -notin $excluded -or
        'switch/dbi/dbi.config' -notin $excluded -or
        'atmosphere/contents/010007B010FCC000/cheats/abcd.txt' -notin $excluded) {
        throw 'Lakka private data, app credentials or game modifications were not excluded'
    }
    if (Test-Path -LiteralPath (Join-Path $testRoot 'Atmosphere-23.0.1.zip')) {
        throw 'Plan-only call created an archive'
    }
    Write-Output 'PASS: release plan preserves defaults and excludes Lakka and game modifications'

    $planHash = (Get-FileHash -LiteralPath $planPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $output = Join-Path $testRoot 'dist'
    & $scriptPath -PackageDirectory $package -TargetSystemVersion '23.0.1' -PlanPath $planPath `
        -VerifiedSeed -Build -ApprovedPlanSha256 $planHash -OutputDirectory $output | Out-Null
    $zipPath = Join-Path $output 'Atmosphere-23.0.1.zip'
    $archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try { $entryPaths = @($archive.Entries | ForEach-Object FullName) }
    finally { $archive.Dispose() }
    if ('bootloader/hekate_ipl.ini' -notin $entryPaths -or 'Firmware.23.0.1/a.nca' -notin $entryPaths -or
        @($entryPaths | Where-Object { $_ -like 'lakka/*' -or $_ -like '*cheats*' }).Count -ne 0) {
        throw 'Release ZIP has incorrect contents'
    }
    $release = Get-Content -LiteralPath (Join-Path $output 'Atmosphere-23.0.1.release.json') -Raw | ConvertFrom-Json
    $zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($release.sha256 -ne $zipHash -or $release.planSha256 -ne $planHash) {
        throw 'Release metadata does not match the ZIP or approved plan'
    }
    Write-Output 'PASS: approved plan builds a ZIP with verifiable hashes'

    Assert-Fails {
        & $scriptPath -PackageDirectory $package -TargetSystemVersion '23.0.1' -PlanPath $planPath `
            -VerifiedSeed -Build -ApprovedPlanSha256 ('0' * 64) -OutputDirectory (Join-Path $testRoot 'bad-hash')
    } 'Approved plan SHA-256 mismatch'
    Write-Output 'PASS: incorrect plan approval hash is rejected'

    Write-FixtureFile $package 'bootloader/res/emunand.bmp' 'tampered-icon'
    Assert-Fails {
        & $scriptPath -PackageDirectory $package -TargetSystemVersion '23.0.1' -PlanPath $planPath `
            -VerifiedSeed -Build -ApprovedPlanSha256 $planHash -OutputDirectory (Join-Path $testRoot 'tampered')
    } 'Package changed after release plan'
    Write-Output 'PASS: changes after review stop packaging'

    $unknown = New-PackageFixture (Join-Path $testRoot 'unknown')
    Write-FixtureFile $unknown 'Nintendo/account.dat' 'private'
    Assert-Fails {
        & $scriptPath -PackageDirectory $unknown -TargetSystemVersion '23.0.1' `
            -PlanPath (Join-Path $testRoot 'unknown-plan.json') -VerifiedSeed
    } 'Unknown top-level path'
    Write-Output 'PASS: unexpected top-level paths are rejected'

    $secret = New-PackageFixture (Join-Path $testRoot 'secret')
    Write-FixtureFile $secret 'bootloader/payloads/id_ed25519' 'private-test-key'
    Assert-Fails {
        & $scriptPath -PackageDirectory $secret -TargetSystemVersion '23.0.1' `
            -PlanPath (Join-Path $testRoot 'secret-plan.json') -VerifiedSeed
    } 'Key material found'
    Write-Output 'PASS: keys outside the excluded Lakka tree are rejected'
}
finally {
    $root = [IO.Path]::GetFullPath($testRoot)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($root.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path $root -Leaf) -like 'SwitchAtmosphere-Release-Test-*') {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}
