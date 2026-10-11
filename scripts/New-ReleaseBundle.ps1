#requires -Version 7.0
param(
    [Parameter(Mandatory)] [string]$PackageDirectory,
    [Parameter(Mandatory)] [string]$TargetSystemVersion,
    [Parameter(Mandatory)] [string]$PlanPath,
    [string]$SourceManifestPath,
    [string]$UpgradeReportPath,
    [switch]$VerifiedSeed,
    [switch]$Build,
    [string]$ApprovedPlanSha256,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'

function Get-Hash {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-Relative {
    param([string]$Root, [string]$Path)
    return [IO.Path]::GetRelativePath($Root, $Path).Replace('\', '/')
}

function Test-InsideDirectory {
    param([string]$Directory, [string]$Path)
    $prefix = $Directory.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    return $Path.Equals($Directory, [StringComparison]::OrdinalIgnoreCase) -or
        $Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Get-ReleaseDisposition {
    param([string]$RelativePath, [string]$Version)
    $parts = $RelativePath.Split('/')
    $root = $parts[0]
    if ($root -ceq 'lakka') { return 'exclude:lakka' }
    if ($RelativePath -match '(?i)(^|/)(?:[^/]*\.keys|id_rsa|id_ed25519|ssh_host_[^/]*_key|[^/]*\.pem|[^/]*\.p12|[^/]*\.pfx)$') {
        throw "Key material found in package: $RelativePath"
    }
    if ($root -match '^Firmware[.\-]') {
        if ($root -cne "Firmware.$Version" -or $parts.Count -ne 2 -or $parts[1] -notmatch '(?i)\.nca$') {
            throw "Unexpected firmware path in package: $RelativePath"
        }
        return 'include'
    }
    if ($RelativePath -match '(?i)(^|/)(?:storage|savefiles|saves|roms|backup|cache|logs|crash_reports|fatal_errors)(/|$)' -or
        $RelativePath -match '(?i)\.(?:log|sav|srm)$') {
        return 'exclude:user-data'
    }
    if ($RelativePath -match '(?i)^switch/[^/]+/[^/]+\.config$') {
        return 'exclude:app-configuration'
    }
    if ($RelativePath -match '^atmosphere/contents/([^/]+)/') {
        if ($Matches[1] -cnotin @('420000000000000B', '420000000007E51A', '00FF0000636C6BFF')) {
            return 'exclude:game-modification'
        }
    }
    if ($root -cin @('atmosphere', 'bootloader', 'config', 'switch', 'warmboot_mariko')) {
        return 'include'
    }
    if ($RelativePath -cin @('boot.dat', 'sdloader.enc', 'exosphere.ini', 'hbmenu.nro', 'hbmenu.nsp', 'payload.bin')) {
        return 'include'
    }
    throw "Unknown top-level path in package: $RelativePath"
}

function Assert-NoEmbeddedPrivateKey {
    param([string]$Path, [string]$RelativePath)
    $stream = [IO.File]::OpenRead($Path)
    try {
        $buffer = [byte[]]::new(8192)
        $count = $stream.Read($buffer, 0, $buffer.Length)
        $prefix = [Text.Encoding]::ASCII.GetString($buffer, 0, $count)
        if ($prefix -match '-----BEGIN (?:OPENSSH |RSA |EC |DSA )?PRIVATE KEY-----') {
            throw "Key material found in package: $RelativePath"
        }
    }
    finally { $stream.Dispose() }
}

function Get-ReleasePlan {
    param(
        [string]$Package,
        [string]$Version,
        [string]$Mode,
        [string]$SourceHash,
        [string]$ReportHash
    )
    foreach ($directory in (Get-ChildItem -LiteralPath $Package -Directory -Recurse -Force)) {
        if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Package directory cannot contain links: $(Get-Relative $Package $directory.FullName)"
        }
    }
    $included = [Collections.Generic.List[object]]::new()
    $excluded = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in (Get-ChildItem -LiteralPath $Package -File -Recurse -Force | Sort-Object FullName)) {
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Package cannot contain file links: $(Get-Relative $Package $file.FullName)"
        }
        $relative = Get-Relative $Package $file.FullName
        if (-not $seen.Add($relative)) { throw "Duplicate package path: $relative" }
        $disposition = Get-ReleaseDisposition $relative $Version
        if ($disposition -ne 'include') {
            $excluded.Add([ordered]@{ path = $relative; reason = $disposition.Substring(8) })
            continue
        }
        Assert-NoEmbeddedPrivateKey $file.FullName $relative
        $included.Add([ordered]@{
            path = $relative
            sizeBytes = $file.Length
            sha256 = Get-Hash $file.FullName
        })
    }
    foreach ($required in @('atmosphere/package3', 'bootloader/update.bin', 'bootloader/sys/nyx.bin',
            'bootloader/payloads/fusee.bin', 'payload.bin')) {
        if (-not $seen.Contains($required)) { throw "Package is missing required path: $required" }
    }
    if (-not @($included | Where-Object { $_.path -like "Firmware.$Version/*.nca" }).Count) {
        throw "Package contains no Firmware.$Version NCA files."
    }
    return [ordered]@{
        schemaVersion = 1
        targetSystemVersion = $Version
        packageDirectory = $Package
        sourceMode = $Mode
        sourceManifestSha256 = $SourceHash
        upgradeReportSha256 = $ReportHash
        included = @($included | Sort-Object path)
        excluded = @($excluded | Sort-Object path)
    }
}

if ($TargetSystemVersion -notmatch '^\d+\.\d+\.\d+$') { throw "Invalid target system version: $TargetSystemVersion" }
$package = [IO.Path]::GetFullPath($PackageDirectory)
if (-not (Test-Path -LiteralPath $package -PathType Container)) { throw "Package directory not found: $package" }
if ((Split-Path $package -Leaf) -cne "Atmosphere-$TargetSystemVersion") {
    throw "Package directory must be named Atmosphere-$TargetSystemVersion."
}
$planFile = [IO.Path]::GetFullPath($PlanPath)
if (Test-InsideDirectory $package $planFile) { throw 'Release plan cannot be inside the package directory.' }
if ($VerifiedSeed -and ($SourceManifestPath -or $UpgradeReportPath)) {
    throw 'Verified seed cannot also have upgrade source files.'
}
if (-not $VerifiedSeed -and (-not $SourceManifestPath -or -not $UpgradeReportPath)) {
    throw 'Upgrade release requires both source manifest and upgrade report; use -VerifiedSeed for the initial base.'
}
$mode = if ($VerifiedSeed) { 'verified-seed' } else { 'upgrade' }
$sourceHash = $null
$reportHash = $null
$sourceSpec = $null
if ($mode -eq 'upgrade') {
    $sourcePath = [IO.Path]::GetFullPath($SourceManifestPath)
    $reportPath = [IO.Path]::GetFullPath($UpgradeReportPath)
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
        throw 'Upgrade source manifest or report is missing.'
    }
    $sourceSpec = Get-Content -LiteralPath $sourcePath -Raw | ConvertFrom-Json -AsHashtable
    $reportSpec = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json -AsHashtable
    if ($sourceSpec.schemaVersion -ne 1 -or [string]$sourceSpec.targetSystemVersion -cne $TargetSystemVersion -or
        [string]$reportSpec.targetSystemVersion -cne $TargetSystemVersion -or
        $reportSpec.built -ne $true -or [string]$reportSpec.outputDirectory -cne (Split-Path $package -Leaf)) {
        throw 'Upgrade source manifest or report does not match the built package.'
    }
    $sourceHash = Get-Hash $sourcePath
    $reportHash = Get-Hash $reportPath
}

if ($Build) {
    if ($ApprovedPlanSha256 -notmatch '^[a-fA-F0-9]{64}$') { throw '-Build requires -ApprovedPlanSha256.' }
    if (-not $OutputDirectory) { throw '-Build requires -OutputDirectory.' }
    if (-not (Test-Path -LiteralPath $planFile -PathType Leaf)) { throw "Release plan not found: $planFile" }
    if ((Get-Hash $planFile) -ne $ApprovedPlanSha256.ToLowerInvariant()) {
        throw 'Approved plan SHA-256 mismatch.'
    }
    $output = [IO.Path]::GetFullPath($OutputDirectory)
    if (Test-InsideDirectory $package $output) { throw 'Release output cannot be inside the package directory.' }
    if (Test-Path -LiteralPath $output) { throw "Release output already exists: $output" }
    if (-not (Test-Path -LiteralPath (Split-Path $output -Parent) -PathType Container)) {
        throw "Release output parent does not exist: $(Split-Path $output -Parent)"
    }
    $approved = Get-Content -LiteralPath $planFile -Raw | ConvertFrom-Json -AsHashtable
    $current = Get-ReleasePlan $package $TargetSystemVersion $mode $sourceHash $reportHash
    if (($approved | ConvertTo-Json -Depth 12 -Compress) -cne ($current | ConvertTo-Json -Depth 12 -Compress)) {
        throw 'Package changed after release plan; regenerate and review it.'
    }

    $stage = Join-Path (Split-Path $output -Parent) ((Split-Path $output -Leaf) + '.release-build-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.Directory]::CreateDirectory($stage) | Out-Null
        $zipName = "Atmosphere-$TargetSystemVersion.zip"
        $zipPath = Join-Path $stage $zipName
        $archive = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($entry in $current.included) {
                $zipEntry = $archive.CreateEntry([string]$entry.path, [IO.Compression.CompressionLevel]::Optimal)
                $zipEntry.LastWriteTime = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
                $inputStream = [IO.File]::OpenRead((Join-Path $package ([string]$entry.path)))
                try {
                    $outputStream = $zipEntry.Open()
                    try { $inputStream.CopyTo($outputStream) }
                    finally { $outputStream.Dispose() }
                }
                finally { $inputStream.Dispose() }
            }
        }
        finally { $archive.Dispose() }
        $zipHash = Get-Hash $zipPath
        $planHash = Get-Hash $planFile
        $metadata = [ordered]@{
            schemaVersion = 1
            targetSystemVersion = $TargetSystemVersion
            file = $zipName
            sha256 = $zipHash
            sizeBytes = (Get-Item -LiteralPath $zipPath).Length
            planSha256 = $planHash
            sourceMode = $mode
            sourceManifestSha256 = $sourceHash
            upgradeReportSha256 = $reportHash
            sourceArtifacts = if ($sourceSpec) { $sourceSpec.artifacts } else { $null }
            included = $current.included
            excludedCount = $current.excluded.Count
        }
        [IO.File]::WriteAllText((Join-Path $stage "Atmosphere-$TargetSystemVersion.release.json"),
            ($metadata | ConvertTo-Json -Depth 12))
        [IO.File]::WriteAllText((Join-Path $stage "Atmosphere-$TargetSystemVersion.sha256"),
            "$zipHash  $zipName`n")
        Move-Item -LiteralPath $stage -Destination $output
        $stage = $null
        [pscustomobject]@{ Zip = Join-Path $output $zipName; Sha256 = $zipHash; Included = $current.included.Count; Excluded = $current.excluded.Count }
    }
    finally {
        if ($stage -and (Test-Path -LiteralPath $stage)) {
            $expected = (Split-Path $output -Leaf) + '.release-build-'
            if ((Split-Path $stage -Leaf).StartsWith($expected, [StringComparison]::Ordinal) -and
                (Split-Path $stage -Parent) -eq (Split-Path $output -Parent)) {
                Remove-Item -LiteralPath $stage -Recurse -Force
            }
        }
    }
}
else {
    if (Test-Path -LiteralPath $planFile) { throw "Release plan already exists: $planFile" }
    $current = Get-ReleasePlan $package $TargetSystemVersion $mode $sourceHash $reportHash
    [IO.Directory]::CreateDirectory((Split-Path $planFile -Parent)) | Out-Null
    [IO.File]::WriteAllText($planFile, ($current | ConvertTo-Json -Depth 12))
    [pscustomobject]@{ Plan = $planFile; Sha256 = Get-Hash $planFile; Included = $current.included.Count; Excluded = $current.excluded.Count }
}
