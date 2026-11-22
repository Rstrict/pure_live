[CmdletBinding()]
param(
    # local_ci needs Windows Native Assets archives. Release builds leave
    # this switch unset and also prefetch the Android media-kit/FFmpeg assets.
    [switch] $SkipAndroidMedia
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$persistentRoot = if ($env:PURE_LIVE_NATIVE_CACHE) {
    $env:PURE_LIVE_NATIVE_CACHE
} elseif ($env:RUNNER_TOOL_CACHE) {
    Join-Path $env:RUNNER_TOOL_CACHE 'pure-live-native'
} else {
    Join-Path $env:LOCALAPPDATA 'PureLive\native-cache'
}

function Test-VerifiedFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Sha256
    )
    return (Test-Path -LiteralPath $Path) -and
        ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -eq $Sha256)
}

function Install-VerifiedAsset {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$CachePath,
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Sha256
    )

    if (Test-VerifiedFile -Path $Destination -Sha256 $Sha256) {
        Write-Host "Verified $Name"
        return
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $CachePath) | Out-Null

    if (-not (Test-VerifiedFile -Path $CachePath -Sha256 $Sha256)) {
        $partial = "$CachePath.partial"
        Remove-Item -LiteralPath $CachePath,$partial -Force -ErrorAction SilentlyContinue
        & curl.exe -L --fail --retry 10 --retry-all-errors --connect-timeout 20 `
            --max-time 600 --continue-at - --output $partial $Url
        if ($LASTEXITCODE) { exit $LASTEXITCODE }
        if (-not (Test-VerifiedFile -Path $partial -Sha256 $Sha256)) {
            Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
            throw "SHA-256 mismatch for $Name"
        }
        Move-Item -LiteralPath $partial -Destination $CachePath -Force
    }

    Copy-Item -LiteralPath $CachePath -Destination $Destination -Force
    if (-not (Test-VerifiedFile -Path $Destination -Sha256 $Sha256)) {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        throw "SHA-256 mismatch after installing $Name"
    }
    Write-Host "Verified $Name (persistent cache: $persistentRoot)"
}

function Get-LockedPackageVersion {
    param([Parameter(Mandatory = $true)][string]$PackageName)

    $lockPath = Join-Path $repoRoot 'pubspec.lock'
    if (-not (Test-Path -LiteralPath $lockPath)) {
        throw "pubspec.lock is required before native dependency prefetch"
    }

    $lines = Get-Content -LiteralPath $lockPath
    $insidePackage = $false
    foreach ($line in $lines) {
        if ($line -match '^  ([A-Za-z0-9_]+):$') {
            $insidePackage = $Matches[1] -eq $PackageName
            continue
        }
        if ($insidePackage -and $line -match '^    version: "([^"]+)"$') {
            return $Matches[1]
        }
    }
    throw "Locked package version not found: $PackageName"
}

function Get-FFmpegBuilderProfile {
    $packageVersion = Get-LockedPackageVersion -PackageName 'ffmpeg_kit_extended_flutter'
    $profiles = @{
        # ffmpeg_kit_extended_flutter 0.5.13 / FFmpeg 8.1.2
        '0.5.13' = @{
            BuilderVersion = '0.10.5'
            AndroidSha256 = 'c3cc680706a24669a41cb078f2d9983aac3d17188ebef1db50c73b388471000d'
            WindowsSha256 = '8dd4bb294f4a99987e293ab0915a40e5e921edb64b56fe829a8a9f067be4c66c'
        }
        # ffmpeg_kit_extended_flutter 0.6.0 / FFmpeg 9.0.1
        '0.6.0' = @{
            BuilderVersion = '0.11.0'
            AndroidSha256 = '2b66caaaefbe5032ffe6e32d87e1af398653ec8dbbc193f4481dd4f562f2182d'
            WindowsSha256 = '2367fbc6ecd7c5df1995c5c0cf5d95f65a99396d4d3fe9d1968c683d3481c125'
        }
        # ffmpeg_kit_extended_flutter 0.6.2 / FFmpeg 9.0.2.
        #
        # These are the upstream builder assets, not project-rebuilt ones. The
        # 0.6.2 hook has no URL override and verifies whatever it downloads
        # against the digest of the asset on that upstream release, so seeding its
        # cache with different bytes only makes it delete them and fail the hash
        # check. Both hashes below were confirmed by downloading the upstream
        # archives and hashing them.
        '0.6.2' = @{
            BuilderVersion = '0.11.1'
            CacheVersion = '0.11.1-ffmpeg-9.0.2-b1'
            AndroidSha256 = 'b214c2aafb20af5416989600826b2b7cb59c8f1572fb78547cc4a222b65134fc'
            WindowsSha256 = 'ac4f7c6893eb2d2a7d9c1c7a08e8cad42105b509d097ce2b2eceabcdcbd7cb47'
        }
    }
    $profile = $profiles[$packageVersion]
    if ($null -eq $profile) {
        throw "No reviewed native-asset profile for ffmpeg_kit_extended_flutter $packageVersion"
    }
    # Strict mode throws on a missing hashtable key, so an optional override is
    # probed rather than read. No profile currently overrides the URLs: the 0.6.2
    # hook has no override hook of its own, so the upstream releases are what it
    # will accept.
    $androidOverride = if ($profile.ContainsKey('AndroidUrl')) { $profile.AndroidUrl } else { $null }
    $windowsOverride = if ($profile.ContainsKey('WindowsUrl')) { $profile.WindowsUrl } else { $null }
    return @{
        PackageVersion = $packageVersion
        BuilderVersion = $profile.BuilderVersion
        CacheVersion = if ($profile.CacheVersion) { $profile.CacheVersion } else { $profile.BuilderVersion }
        AndroidSha256 = $profile.AndroidSha256
        WindowsSha256 = $profile.WindowsSha256
        AndroidUrl = if ($androidOverride) { $androidOverride } else { "https://github.com/akashskypatel/ffmpeg-kit-builders/releases/download/v$($profile.BuilderVersion)-android/bundle-base-shared-lgpl-release.aar" }
        WindowsUrl = if ($windowsOverride) { $windowsOverride } else { "https://github.com/akashskypatel/ffmpeg-kit-builders/releases/download/v$($profile.BuilderVersion)-windows/bundle-base-windows-x86_64-shared-lgpl.zip" }
    }
}

function Reset-FFmpegWindowsExtractionIfNeeded {
    param(
        [Parameter(Mandatory = $true)][string]$HookWindowsRoot,
        [Parameter(Mandatory = $true)][string]$BuilderVersion
    )

    $stampPath = Join-Path $HookWindowsRoot '.pure-live-builder-version'
    $installedVersion = if (Test-Path -LiteralPath $stampPath) {
        (Get-Content -LiteralPath $stampPath -Raw).Trim()
    } else {
        ''
    }
    if ($installedVersion -eq $BuilderVersion) { return }

    $extractionPath = Join-Path $HookWindowsRoot 'bundle-base-windows-x86_64-shared-lgpl'
    if (Test-Path -LiteralPath $extractionPath) {
        $resolvedRepo = [IO.Path]::GetFullPath($repoRoot).TrimEnd('\')
        $resolvedTarget = [IO.Path]::GetFullPath($extractionPath)
        $expectedRoot = [IO.Path]::GetFullPath(
            (Join-Path $repoRoot '.dart_tool\hooks_runner\shared\ffmpeg_kit_extended_flutter\build\ffmpeg_kit_cache\windows')
        ).TrimEnd('\')
        if (-not $resolvedTarget.StartsWith("$expectedRoot\", [StringComparison]::OrdinalIgnoreCase) -or
            -not $resolvedTarget.StartsWith("$resolvedRepo\", [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to reset unexpected FFmpeg extraction path: $resolvedTarget"
        }
        Remove-Item -LiteralPath $resolvedTarget -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $HookWindowsRoot | Out-Null
    Set-Content -LiteralPath $stampPath -Value $BuilderVersion -NoNewline
}

$ffmpegProfile = Get-FFmpegBuilderProfile
$ffmpegBuilderVersion = $ffmpegProfile.BuilderVersion
$ffmpegCacheVersion = $ffmpegProfile.CacheVersion
$ffmpegHookCacheRoot = Join-Path $repoRoot '.dart_tool\hooks_runner\shared\ffmpeg_kit_extended_flutter\build\ffmpeg_kit_cache'
Write-Host "FFmpeg native profile: package $($ffmpegProfile.PackageVersion), builder $ffmpegBuilderVersion, native $ffmpegCacheVersion"

function Get-MediaKitBundleCatalog {
    $configPath = Join-Path $repoRoot '.dart_tool\package_config.json'
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $package = @($config.packages | Where-Object { $_.name -eq 'media_kit' })
    if ($package.Count -ne 1) { throw 'Expected exactly one resolved media_kit package' }
    # Path dependencies (the vendored third_party/media_kit) carry a rootUri
    # relative to package_config.json; git/hosted ones are absolute file URIs.
    $rootUri = [Uri]::new([Uri]::new($configPath), [string]$package[0].rootUri)
    $packageRoot = $rootUri.LocalPath
    $catalogPath = Join-Path $packageRoot 'hook\native_bundles.json'
    $catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
    if ($catalog.schema -ne 1) { throw "Unsupported media_kit bundle catalog: $catalogPath" }
    return $catalog.bundles
}

$mediaKitBundles = Get-MediaKitBundleCatalog
$mediaKitHookCacheRoot = Join-Path $repoRoot '.dart_tool\hooks_runner\shared\media_kit\build\prebuilt'
$mediaTargets = @('windows_x64')
if (-not $SkipAndroidMedia) {
    $mediaTargets += @('android_arm64', 'android_arm', 'android_x64', 'android_ia32')
}
foreach ($target in $mediaTargets) {
    $asset = $mediaKitBundles.$target
    if ($null -eq $asset) { throw "Missing media_kit native bundle: $target" }
    if ($asset.url -notmatch '^https://' -or $asset.sha256 -notmatch '^[a-f0-9]{64}$') {
        throw "Invalid media_kit native bundle: $target"
    }
    $archiveName = "archive.$($asset.format)"
    Install-VerifiedAsset `
        -Name "media_kit $target" `
        -Destination (Join-Path $mediaKitHookCacheRoot "$($asset.sha256)\$archiveName") `
        -CachePath (Join-Path $persistentRoot "media-kit\native-assets\$($asset.sha256)\$archiveName") `
        -Url $asset.url `
        -Sha256 $asset.sha256
}

if (-not $SkipAndroidMedia) {

    $ffmpegAndroidName = 'bundle-base-shared-lgpl-release.aar'
    Install-VerifiedAsset `
        -Name $ffmpegAndroidName `
        -Destination (Join-Path $ffmpegHookCacheRoot "android\$ffmpegAndroidName") `
        -CachePath (Join-Path $persistentRoot "ffmpeg-kit\v$ffmpegCacheVersion-android\$ffmpegAndroidName") `
        -Url $ffmpegProfile.AndroidUrl `
        -Sha256 $ffmpegProfile.AndroidSha256
}

# The ffmpeg_kit Native Assets hook uses Dart HttpClient, which may stall on a
# GitHub release-asset redirect on some Windows networks. Seed both platform
# caches from verified persistent files before invoking Flutter. Resolve the
# builder version from pubspec.lock so rolling the Dart package backward or
# forward can never silently mix another release's native FFmpeg binaries.
$ffmpegWindowsName = 'bundle-base-windows-x86_64-shared-lgpl.zip'
$ffmpegWindowsRoot = Join-Path $ffmpegHookCacheRoot 'windows'
Reset-FFmpegWindowsExtractionIfNeeded `
    -HookWindowsRoot $ffmpegWindowsRoot `
    -BuilderVersion $ffmpegCacheVersion
Install-VerifiedAsset `
    -Name $ffmpegWindowsName `
    -Destination (Join-Path $ffmpegWindowsRoot $ffmpegWindowsName) `
    -CachePath (Join-Path $persistentRoot "ffmpeg-kit\v$ffmpegCacheVersion-windows\$ffmpegWindowsName") `
    -Url $ffmpegProfile.WindowsUrl `
    -Sha256 $ffmpegProfile.WindowsSha256

# Extract the verified archive ourselves.
#
# The hook extracts with `powershell -command Expand-Archive ... -Force` into a
# `<name>.extracting` directory and then renames it. When that archive's entries
# share the destination's own basename (they do here: the zip has a single
# `bundle-base-windows-x86_64-shared-lgpl/` root), `-Force` deletes the just
# created item and the per-entry write then fails with DirectoryNotFound, while
# the exit code stays 0 — so the hook records an "extract complete" marker over an
# empty tree and every later build fails listing a directory that is not there.
#
# Extracting with .NET's ZipFile avoids that path entirely and is byte-identical
# in layout, so the hook's own extraction step becomes a no-op.
$ffmpegWindowsZip = Join-Path $ffmpegWindowsRoot $ffmpegWindowsName
$ffmpegWindowsExtractRoot = Join-Path $ffmpegWindowsRoot ([IO.Path]::GetFileNameWithoutExtension($ffmpegWindowsName))
$ffmpegWindowsMarker = Join-Path $ffmpegWindowsExtractRoot '.extract_complete'
$ffmpegWindowsHasPayload = $false
if (Test-Path -LiteralPath $ffmpegWindowsExtractRoot) {
    $ffmpegWindowsHasPayload = @(
        Get-ChildItem -LiteralPath $ffmpegWindowsExtractRoot -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne '.extract_complete' }
    ).Count -gt 0
}
if (-not $ffmpegWindowsHasPayload) {
    if (Test-Path -LiteralPath $ffmpegWindowsExtractRoot) {
        Remove-Item -LiteralPath $ffmpegWindowsExtractRoot -Recurse -Force
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($ffmpegWindowsZip, $ffmpegWindowsExtractRoot)
    New-Item -ItemType File -Force -Path $ffmpegWindowsMarker | Out-Null
    Write-Host "Extracted $ffmpegWindowsName into the hook cache"
}
else {
    if (-not (Test-Path -LiteralPath $ffmpegWindowsMarker)) {
        New-Item -ItemType File -Force -Path $ffmpegWindowsMarker | Out-Null
    }
    Write-Host "Reused the extracted $ffmpegWindowsName payload"
}
