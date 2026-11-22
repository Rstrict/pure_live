[CmdletBinding()]
param(
    # Rewrite the derived files instead of only reporting drift.
    [switch] $Apply,

    # Environment file holding the owner/repository variables.
    [string] $EnvFile = '.env.prod'
)

$ErrorActionPreference = 'Stop'

# Owner and repository names live in one place: the .env file this project
# already uses for its update feed. Everything that embeds a GitHub URL is
# derived from those variables, so renaming an owner is one edit plus this
# script - not a search-and-replace across pubspec, native bundle manifests,
# workflows and assets.
#
# Roles, and who owns which URL:
#
#   PURELIVE_UPDATE_OWNER / PURELIVE_UPDATE_REPOSITORY
#       this project's own releases: assets/version.json, assets/releases.json
#       and the release workflows
#   PURELIVE_NATIVE_OWNER / PURELIVE_NATIVE_REPOSITORY
#       the native bundles (FFmpeg, libmpv) the build downloads: pubspec.yaml's
#       ffmpeg_kit_extended_config, media_kit's native_bundles.json and the
#       Android prefetch script
#   PURELIVE_TV_REPOSITORY
#       the TV companion repository named in release notes
#
# Third-party URLs (Predidit's libmpv builds, akashskypatel's ffmpeg-kit
# builders) are deliberately left alone: they are upstream projects, not this
# repository's mirrors. Documentation under docs/ is historical record and is
# never rewritten.

$repoRoot = Split-Path -Parent $PSScriptRoot
$envPath = Join-Path $repoRoot $EnvFile
if (-not (Test-Path -LiteralPath $envPath)) {
    throw "Environment file not found: $EnvFile"
}

$settings = @{}
foreach ($line in Get-Content -LiteralPath $envPath) {
    if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
    $name, $value = $line.Split('=', 2)
    $settings[$name.Trim()] = $value.Trim()
}

function Get-Setting([string] $name) {
    if (-not $settings.ContainsKey($name) -or [string]::IsNullOrWhiteSpace($settings[$name])) {
        throw "Missing $name in $EnvFile. Add it before running this script."
    }
    return $settings[$name]
}

$selfOwner = Get-Setting 'PURELIVE_UPDATE_OWNER'
$selfRepo = Get-Setting 'PURELIVE_UPDATE_REPOSITORY'
$nativeOwner = Get-Setting 'PURELIVE_NATIVE_OWNER'
$nativeRepo = Get-Setting 'PURELIVE_NATIVE_REPOSITORY'
$tvRepo = Get-Setting 'PURELIVE_TV_REPOSITORY'

# `media_kit` is a git dependency (see pubspec.lock), so its bundle manifest
# resolves into the Pub cache rather than a repository-local `third_party/`
# directory. Resolve it the way the build does instead of assuming a checkout
# layout; a hard-coded path here reported "missing" and blocked the gate on a file
# that moved, not on a stale owner reference.
function Resolve-NativeBundleManifest {
    $configPath = Join-Path $repoRoot '.dart_tool/package_config.json'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { return $null }
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $package = @($config.packages | Where-Object { $_.name -eq 'media_kit' })
    if ($package.Count -ne 1) { return $null }
    $rootUri = [Uri]::new([Uri]::new($configPath), [string]$package[0].rootUri)
    $manifest = Join-Path $rootUri.LocalPath 'hook/native_bundles.json'
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { return $null }
    return $manifest
}

$nativeBundleManifest = Resolve-NativeBundleManifest

# One entry per file: the repository whose URLs belong to which role. A URL is
# rewritten when its repository name matches, whatever owner it currently
# carries - that is what makes the owner rename work.
#
# `AbsolutePath` targets are resolved packages, not repository files, so they are
# checked for owner drift but never treated as missing repository content.
$targets = @(
    @{ Path = 'pubspec.yaml'; Repo = $nativeRepo; Owner = $nativeOwner; Note = 'native bundles (ffmpeg_kit_extended_config)' },
    @{ Path = 'tool/prefetch_android_native.ps1'; Repo = $nativeRepo; Owner = $nativeOwner; Note = 'native bundles (Android prefetch)' },
    @{ Path = 'assets/version.json'; Repo = $selfRepo; Owner = $selfOwner; Note = 'download link' },
    @{ Path = 'assets/releases.json'; Repo = $selfRepo; Owner = $selfOwner; Note = 'release history' },
    @{ Path = '.github/workflows/build_pure_live_release.yml'; Repo = $selfRepo; Owner = $selfOwner; Note = 'release notes and asset links' },
    @{ Path = '.github/workflows/feature-build.yml'; Repo = $selfRepo; Owner = $selfOwner; Note = 'release notes and asset links' },
    @{ Path = '.github/workflows/audit-upstream.yml'; Repo = $selfRepo; Owner = $selfOwner; Note = 'upstream comparison remote' },
    @{ Path = '.github/workflows/stage-hosted-artifacts.yml'; Repo = $selfRepo; Owner = $selfOwner; Note = 'staged asset links' },
    @{ Path = '.github/workflows/publish-staged-release.yml'; Repo = $selfRepo; Owner = $selfOwner; Note = 'staged asset links' },
    @{ Path = '.github/workflows/build_pure_live_release.yml'; Repo = $tvRepo; Owner = $selfOwner; Note = 'TV repository link' },
    @{ Path = '.github/workflows/feature-build.yml'; Repo = $tvRepo; Owner = $selfOwner; Note = 'TV repository link' }
)
if ($nativeBundleManifest) {
    $targets += @{
        Path = $nativeBundleManifest
        AbsolutePath = $true
        Repo = $nativeRepo
        Owner = $nativeOwner
        Note = 'native bundles (libmpv)'
    }
}

$problems = New-Object System.Collections.Generic.List[string]
$changes = New-Object System.Collections.Generic.List[string]

foreach ($target in $targets) {
    $full = if ($target.AbsolutePath) { $target.Path } else { Join-Path $repoRoot $target.Path }
    if (-not (Test-Path -LiteralPath $full)) {
        $problems.Add("$($target.Path): missing (referenced by this script)")
        continue
    }

    $text = Get-Content -LiteralPath $full -Raw
    # github.com/<any owner>/<repo>/... - the owner is replaced, the repository
    # name has to stay as configured (typos in the repository are drift too).
    $pattern = [regex]::Escape('github.com') + '/[^/''"\s]+/' + [regex]::Escape($target.Repo) + '/'
    $matches = [regex]::Matches($text, $pattern)
    if ($matches.Count -eq 0) {
        continue
    }

    $wrong = @($matches | Where-Object { $_.Value -ne "github.com/$($target.Owner)/$($target.Repo)/" })
    if ($wrong.Count -eq 0) {
        continue
    }

    $found = @($wrong | ForEach-Object { $_.Value } | Sort-Object -Unique)
    if ($Apply) {
        if ($target.AbsolutePath) {
            # This file belongs to a resolved git dependency, not to this
            # repository: rewriting it would edit another project's checkout and
            # the next `pub get` would silently undo it. Report instead.
            $problems.Add("$($target.Path): owner drift inside a resolved dependency ($($found -join ', ')) - update the dependency, not this file")
            continue
        }
        $updated = [regex]::Replace($text, $pattern, "github.com/$($target.Owner)/$($target.Repo)/")
        # Write exactly the bytes git expects: UTF-8 without BOM, LF endings.
        $updated = $updated -replace "`r`n", "`n"
        [System.IO.File]::WriteAllText($full, $updated, (New-Object System.Text.UTF8Encoding($false)))
        $changes.Add("$($target.Path): $($found -join ', ') -> github.com/$($target.Owner)/$($target.Repo)/")
    } else {
        $problems.Add("$($target.Path) ($($target.Note)): $($found -join ', ') should be github.com/$($target.Owner)/$($target.Repo)/")
    }
}

if ($Apply) {
    if ($changes.Count -eq 0) {
        Write-Host 'Owner references already match the environment file.'
    } else {
        foreach ($change in $changes) { Write-Host "updated $change" }
    }
    exit 0
}

if ($problems.Count -gt 0) {
    Write-Host "Owner references do not match $EnvFile (github.com/$selfOwner/$selfRepo, native github.com/$nativeOwner/$nativeRepo):"
    foreach ($problem in $problems) { Write-Host "  - $problem" }
    Write-Host 'Run tool/sync_owner_refs.ps1 -Apply to rewrite them.'
    exit 1
}

Write-Host "Owner references match $EnvFile."
