#requires -Version 7.0
param(
    [Parameter(Mandatory)] [string]$Manifest,
    [Parameter(Mandatory)] [string]$AssetDirectory,
    [Parameter(Mandatory)] [string]$BaseDirectory,
    [Parameter(Mandatory)] [string]$OutputDirectory,
    [string]$ReportPath,
    [switch]$Build
)

$ErrorActionPreference = 'Stop'

function Get-FullPath {
    param([string]$Path)
    return [IO.Path]::GetFullPath($Path)
}

function Get-RelativePath {
    param([string]$Root, [string]$Path)
    return [IO.Path]::GetRelativePath($Root, $Path).Replace('\', '/')
}

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-Artifact {
    param([string]$Name, [hashtable]$Entry, [string]$Directory)
    if (-not $Entry -or -not $Entry.file -or -not $Entry.sha256) {
        throw "Artifact '$Name' requires file and sha256."
    }
    $file = [string]$Entry.file
    if ($file -ne [IO.Path]::GetFileName($file) -or $file -in @('.', '..')) {
        throw "Artifact '$Name' must use a file name without directories."
    }
    $expected = [string]$Entry.sha256
    if ($expected -notmatch '^[a-fA-F0-9]{64}$') { throw "Artifact '$Name' has an invalid SHA-256." }
    $path = Join-Path $Directory $file
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Artifact '$Name' is missing: $file" }
    $actual = Get-Sha256 $path
    if ($actual -ne $expected.ToLowerInvariant()) { throw "SHA-256 mismatch for artifact '$Name': $file" }
    return $path
}

function Expand-CheckedZip {
    param([string]$ZipPath, [string]$Destination)
    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $archive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($entry in $archive.Entries) {
            $relative = $entry.FullName.Replace('\', '/')
            if ($relative -match '(^/|^[a-zA-Z]:|(^|/)\.\.(/|$)|:)' -or $relative.StartsWith('//')) {
                throw "Unsafe ZIP path in $(Split-Path $ZipPath -Leaf): $relative"
            }
            if (-not $entry.Name) { continue }
            if (-not $seen.Add($relative)) { throw "Duplicate ZIP path in $(Split-Path $ZipPath -Leaf): $relative" }
            $target = Get-FullPath (Join-Path $Destination $relative)
            $prefix = (Get-FullPath $Destination).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
            if (-not $target.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Unsafe ZIP path in $(Split-Path $ZipPath -Leaf): $relative"
            }
            [IO.Directory]::CreateDirectory((Split-Path $target -Parent)) | Out-Null
            $inputStream = $entry.Open()
            try {
                $outputStream = [IO.File]::Create($target)
                try { $inputStream.CopyTo($outputStream) }
                finally { $outputStream.Dispose() }
            }
            finally { $inputStream.Dispose() }
        }
    }
    finally { $archive.Dispose() }
}

function Add-Operation {
    param(
        [Collections.Generic.List[object]]$Operations,
        [Collections.Generic.HashSet[string]]$Seen,
        [string]$RelativePath,
        [string]$Source,
        [string]$Component
    )
    $relative = $RelativePath.Replace('\', '/')
    if (-not $Seen.Add($relative)) { throw "Two artifacts provide the same path: $relative" }
    $Operations.Add([pscustomobject]@{ path = $relative; source = $Source; component = $Component })
}

function Get-ArchiveFiles {
    param([string]$Root)
    return @(Get-ChildItem -LiteralPath $Root -File -Recurse -Force | Sort-Object FullName)
}

function Assert-SafeGeneratedDirectory {
    param([string]$Path, [string]$Parent, [string]$ExpectedPrefix)
    $full = Get-FullPath $Path
    $prefix = (Get-FullPath $Parent).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Split-Path $full -Leaf).StartsWith($ExpectedPrefix, [StringComparison]::Ordinal)) {
        throw "Refusing to remove an unexpected directory: $full"
    }
}

$manifestPath = Get-FullPath $Manifest
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Manifest not found: $manifestPath" }
$spec = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
if ($spec.schemaVersion -ne 1) { throw 'Unsupported manifest schemaVersion; expected 1.' }
$version = [string]$spec.targetSystemVersion
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'targetSystemVersion must be a numeric version such as 23.0.1.' }
$base = Get-FullPath $BaseDirectory
$assets = Get-FullPath $AssetDirectory
$output = Get-FullPath $OutputDirectory
if (-not (Test-Path -LiteralPath $base -PathType Container)) { throw "Base directory not found: $base" }
if (-not (Test-Path -LiteralPath $assets -PathType Container)) { throw "Asset directory not found: $assets" }
$basePrefix = $base.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
if ($output -eq $base -or $output.StartsWith($basePrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Output directory cannot be the base directory or inside it.'
}
if ($Build -and (Test-Path -LiteralPath $output)) { throw "Output directory already exists: $output" }
if (-not $ReportPath) {
    $ReportPath = Join-Path (Split-Path $output -Parent) ("UPGRADE-$version.report.json")
}
$report = Get-FullPath $ReportPath
if ($report -eq $manifestPath -or $report.StartsWith($basePrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Report path cannot overwrite the manifest or a file in the base directory.'
}
$outputPrefix = $output.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
if ($report -eq $output -or $report.StartsWith($outputPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Report path cannot be inside the output directory.'
}

$required = @('atmosphere', 'hekate', 'fusee', 'firmware')
foreach ($name in $required) {
    if (-not $spec.artifacts.ContainsKey($name)) { throw "Manifest is missing required artifact '$name'." }
}
$artifactPaths = @{}
foreach ($name in @($required + @('sysPatch'))) {
    if ($spec.artifacts.ContainsKey($name)) {
        $artifactPaths[$name] = Assert-Artifact $name $spec.artifacts[$name] $assets
    }
}

$tempParent = Get-FullPath ([IO.Path]::GetTempPath())
$tempRoot = Join-Path $tempParent ("SwitchAtmosphere-Upgrade-" + [guid]::NewGuid().ToString('N'))
$stage = $null
try {
    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    $expanded = @{}
    foreach ($name in @('atmosphere', 'hekate', 'firmware', 'sysPatch')) {
        if ($artifactPaths.ContainsKey($name)) {
            $destination = Join-Path $tempRoot $name
            Expand-CheckedZip $artifactPaths[$name] $destination
            $expanded[$name] = $destination
        }
    }

    $operations = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $ignoredUpstream = [Collections.Generic.List[string]]::new()
    foreach ($file in (Get-ArchiveFiles $expanded.atmosphere)) {
        $rel = Get-RelativePath $expanded.atmosphere $file.FullName
        if ($rel -eq 'hbmenu.nro' -or $rel -eq 'atmosphere/reboot_payload.bin' -or
            $rel -match '^atmosphere/(config|hosts|contents)/') {
            $ignoredUpstream.Add("atmosphere:$rel")
        }
        elseif ($rel -match '^atmosphere/' -or $rel -in @('switch/daybreak.nro', 'switch/haze.nro', 'switch/reboot_to_payload.nro')) {
            Add-Operation $operations $seen $rel $file.FullName 'atmosphere'
        }
        else { throw "Unrecognized Atmosphere release file; review before upgrading: $rel" }
    }

    $hekatePayload = $null
    $hekateUpdate = $null
    foreach ($file in (Get-ArchiveFiles $expanded.hekate)) {
        $rel = Get-RelativePath $expanded.hekate $file.FullName
        if ($rel -match '^hekate_ctcaer_[^/]+\.bin$') { $hekatePayload = $file.FullName }
        elseif ($rel -eq 'bootloader/update.bin') {
            $hekateUpdate = $file.FullName
            Add-Operation $operations $seen $rel $file.FullName 'hekate'
        }
        elseif ($rel -match '^bootloader/sys/') { Add-Operation $operations $seen $rel $file.FullName 'hekate' }
        elseif ($rel -match '^bootloader/res/') { $ignoredUpstream.Add("hekate:$rel") }
        else { throw "Unrecognized hekate release file; review before upgrading: $rel" }
    }
    if (-not $hekatePayload -or -not $hekateUpdate) { throw 'hekate ZIP must contain its root payload and bootloader/update.bin.' }
    if ((Get-Sha256 $hekatePayload) -ne (Get-Sha256 $hekateUpdate)) {
        throw 'hekate payload and bootloader/update.bin differ; review the release before upgrading.'
    }
    Add-Operation $operations $seen 'payload.bin' $hekatePayload 'hekate'
    Add-Operation $operations $seen 'atmosphere/reboot_payload.bin' $hekatePayload 'hekate'
    Add-Operation $operations $seen 'bootloader/payloads/fusee.bin' $artifactPaths.fusee 'fusee'

    if ($expanded.ContainsKey('sysPatch')) {
        foreach ($file in (Get-ArchiveFiles $expanded.sysPatch)) {
            $rel = Get-RelativePath $expanded.sysPatch $file.FullName
            if ($rel -match '^atmosphere/contents/420000000000000B/' -or $rel -eq 'switch/.overlays/sys-patch-overlay.ovl') {
                Add-Operation $operations $seen $rel $file.FullName 'sysPatch'
            }
            else { throw "Unrecognized sys-patch release file; review before upgrading: $rel" }
        }
        foreach ($path in @('atmosphere/contents/420000000000000B/exefs.nsp', 'switch/.overlays/sys-patch-overlay.ovl')) {
            if (-not $seen.Contains($path)) { throw "sys-patch release is missing required path: $path" }
        }
    }

    $firmwareFiles = @(Get-ArchiveFiles $expanded.firmware)
    if ($firmwareFiles.Count -eq 0) { throw 'Firmware ZIP contains no files.' }
    foreach ($file in $firmwareFiles) {
        $rel = Get-RelativePath $expanded.firmware $file.FullName
        $prefix = "Firmware.$version/"
        if ($rel.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { $rel = $rel.Substring($prefix.Length) }
        if ($rel.Contains('/') -or $rel -notmatch '(?i)\.nca$') {
            throw "Unexpected firmware ZIP entry; review before upgrading: $rel"
        }
        Add-Operation $operations $seen "Firmware.$version/$rel" $file.FullName 'firmware'
    }

    $essential = @('atmosphere/package3', 'bootloader/update.bin', 'bootloader/sys/nyx.bin',
        'payload.bin', 'atmosphere/reboot_payload.bin', 'bootloader/payloads/fusee.bin')
    foreach ($path in $essential) {
        if (-not $seen.Contains($path)) { throw "Release assets are missing required path: $path" }
    }

    $changes = @(
        foreach ($operation in $operations) {
            $old = Join-Path $base $operation.path
            $newHash = Get-Sha256 $operation.source
            $oldHash = if (Test-Path -LiteralPath $old -PathType Leaf) { Get-Sha256 $old } else { $null }
            $action = if (-not $oldHash) { 'add' } elseif ($oldHash -eq $newHash) { 'identical' } else { 'replace' }
            [ordered]@{
                path = $operation.path
                component = $operation.component
                action = $action
                previousSha256 = $oldHash
                sha256 = $newHash
            }
        }
    )

    $baseFiles = @(Get-ArchiveFiles $base)
    $preservedBasePaths = [Collections.Generic.List[string]]::new()
    $excludedBasePaths = [Collections.Generic.List[string]]::new()
    $oldFirmwareDirectories = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $baseFiles) {
        $rel = Get-RelativePath $base $file.FullName
        if ($rel -match '^Firmware[.\\-]') {
            [void]$oldFirmwareDirectories.Add(($rel -split '/')[0])
            continue
        }
        if ($rel -match '^lakka/') {
            $excludedBasePaths.Add($rel)
            continue
        }
        if ($rel -match '(?i)(^|/)(?:[^/]*\.(?:key|keys|jks|keystore|pem|p12|pfx|der|crt|cer)|id_rsa|id_ed25519|ssh_host_[^/]*_key)$') {
            throw "Key material found in base package: $rel"
        }
        if (-not $seen.Contains($rel)) { $preservedBasePaths.Add($rel) }
    }

    $result = [ordered]@{
        targetSystemVersion = $version
        baseDirectory = Split-Path $base -Leaf
        outputDirectory = Split-Path $output -Leaf
        built = [bool]$Build
        artifacts = $spec.artifacts
        changes = @($changes | Sort-Object path)
        ignoredUpstreamPaths = @($ignoredUpstream | Sort-Object)
        preservedBasePaths = @($preservedBasePaths | Sort-Object)
        excludedBasePaths = @($excludedBasePaths | Sort-Object)
        removedFirmwareDirectories = @($oldFirmwareDirectories | Sort-Object)
        firmwareFileCount = $firmwareFiles.Count
        warnings = if (-not $expanded.ContainsKey('sysPatch')) { @('sys-patch was not updated; the base package version is preserved and compatibility must be checked.') } else { @() }
    }

    if ($Build) {
        $parent = Split-Path $output -Parent
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw "Output parent does not exist: $parent" }
        $stage = Join-Path $parent ((Split-Path $output -Leaf) + '.build-' + [guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($stage) | Out-Null
        foreach ($file in $baseFiles) {
            $rel = Get-RelativePath $base $file.FullName
            if ($rel -match '^Firmware[.\\-]' -or $rel -match '^lakka/') { continue }
            $destination = Join-Path $stage $rel
            [IO.Directory]::CreateDirectory((Split-Path $destination -Parent)) | Out-Null
            Copy-Item -LiteralPath $file.FullName -Destination $destination
        }
        foreach ($operation in $operations) {
            $destination = Join-Path $stage $operation.path
            [IO.Directory]::CreateDirectory((Split-Path $destination -Parent)) | Out-Null
            Copy-Item -LiteralPath $operation.source -Destination $destination -Force
        }
        Move-Item -LiteralPath $stage -Destination $output
        $stage = $null
    }

    [IO.Directory]::CreateDirectory((Split-Path $report -Parent)) | Out-Null
    [IO.File]::WriteAllText($report, ($result | ConvertTo-Json -Depth 12))
    [pscustomobject]@{
        Target = $output
        Built = [bool]$Build
        Changed = @($changes | Where-Object { $_.action -ne 'identical' }).Count
        Identical = @($changes | Where-Object { $_.action -eq 'identical' }).Count
        Report = $report
    }
}
finally {
    if ($stage -and (Test-Path -LiteralPath $stage)) {
        Assert-SafeGeneratedDirectory $stage (Split-Path $output -Parent) ((Split-Path $output -Leaf) + '.build-')
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
    if (Test-Path -LiteralPath $tempRoot) {
        Assert-SafeGeneratedDirectory $tempRoot $tempParent 'SwitchAtmosphere-Upgrade-'
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
