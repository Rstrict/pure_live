# Strips dev-only plugins from the generated Android plugin registrant.
#
# `flutter build apk --release` writes every Android plugin into
# `GeneratedPluginRegistrant.java`, including `integration_test`, which is a
# `dev_dependencies` SDK package. The release variant does not put that plugin on
# the Java classpath, so the generated file fails to compile:
#
#   GeneratedPluginRegistrant.java:119: error: package
#   dev.flutter.plugins.integration_test does not exist
#
# The file itself is git-ignored and regenerated on every `pub get`, so the fix
# cannot live in the file — it has to run after generation and before javac.
#
# Usage:
#   ./tool/strip_dev_plugin_registrant.ps1 [-Check]
#
# `-Check` reports what would change without writing, so a CI gate can assert the
# release tree has no dev-only registrations.

[CmdletBinding()]
param(
    [switch] $Check
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$registrant = Join-Path $repoRoot 'android\app\src\main\java\io\flutter\plugins\GeneratedPluginRegistrant.java'

# Plugins that are declared under `dev_dependencies` (or only pulled in by a
# test-only dependency) and therefore never exist on a release classpath.
$devOnlyPlugins = @('integration_test')

function Remove-PluginBlock {
    param(
        [string] $Text,
        [string] $Plugin
    )

    # Each registration is a `try { ... } catch (Exception e) { ... }` block. Walk
    # the lines and cut exactly that block, so the surrounding registrations stay
    # intact — deleting only the add() line would leave an empty try and a
    # dangling catch.
    #
    # Line-based rather than one regex: the block is three statements with a
    # quoted log message in the middle, and a single pattern over that had to
    # encode both the quoting and the newline flavour. Matching "a try that
    # mentions the plugin, through the next closing brace at the same indent" is
    # the actual shape and does not depend on either.
    $lines = $Text -split "\r?\n"
    $output = New-Object System.Collections.Generic.List[string]
    $removed = $false

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if (-not $removed -and $line -match '^[ \t]*try \{[ \t]*$') {
            # Look ahead for the add() line of this block only: the next line.
            $next = if ($i + 1 -lt $lines.Count) { $lines[$i + 1] } else { '' }
            if ($next -match [regex]::Escape($Plugin) -and $next -match 'getPlugins\(\)\.add\(') {
                # Consume through the closing brace of the catch block.
                $j = $i + 1
                while ($j -lt $lines.Count -and $lines[$j] -notmatch '^[ \t]*\}[ \t]*$') { $j++ }
                if ($j -ge $lines.Count) {
                    throw "Unterminated try/catch block for '$Plugin' at line $($i + 1)."
                }
                $i = $j
                $removed = $true
                continue
            }
        }
        $output.Add($line)
    }

    return @{ Text = ($output -join "`n"); Removed = $removed }
}

if (-not (Test-Path -LiteralPath $registrant -PathType Leaf)) {
    throw "Generated plugin registrant was not found: $registrant. Run 'flutter pub get' first."
}

$original = [System.IO.File]::ReadAllText($registrant)
$updated = $original
$removed = @()

foreach ($plugin in $devOnlyPlugins) {
    if ($updated -notmatch [regex]::Escape($plugin)) { continue }
    $result = Remove-PluginBlock -Text $updated -Plugin $plugin
    if (-not $result.Removed) {
        # The name is present but not in the shape this script knows how to cut.
        # Failing loudly beats shipping a registrant that will not compile.
        throw "Found '$plugin' in $registrant but could not remove its try/catch block. The generated layout changed; update this script."
    }
    $updated = $result.Text
    $removed += $plugin
}

if ($removed.Count -eq 0) {
    Write-Host "Generated plugin registrant already has no dev-only plugins."
    exit 0
}

if ($Check) {
    Write-Host "Dev-only plugins present in the release registrant: $($removed -join ', ')"
    exit 1
}

[System.IO.File]::WriteAllText($registrant, $updated, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Removed dev-only plugins from the release registrant: $($removed -join ', ')"
