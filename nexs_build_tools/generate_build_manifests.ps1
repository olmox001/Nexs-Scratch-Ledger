<#
Nexs Ledger build-manifest generator.

REQUIRED LOCATION:
    <project-root>/nexs_build_tools/generate_build_manifests.ps1

GENERATED FILES:
    <project-root>/nexs_build_tools/BUILD_TOOLS_SHA256SUMS
    <project-root>/BUILD_KIT_SHA256SUMS

HASHING:
    sha256sum ONLY.
    No Get-FileHash, .NET hashing, shasum, openssl, Python, or alternate
    hash implementation is used.

TREE RULES:
    audit_tools(): complete nexs_build_tools tree, except
                   BUILD_TOOLS_SHA256SUMS and __pycache__ directories.
    audit_kit():   complete project tree, except BUILD_KIT_SHA256SUMS,
                   top-level build/, release/, .git/, .venv/, and __pycache__.

DYNAMIC EXCLUSIONS:
    <project-root>/.gitignore is read at runtime (when present) and its
    non-comment, non-negated patterns are merged with the project invariants
    (build/, release/, .git/, .venv/, __pycache__). The two anchors
    BUILD_KIT_SHA256SUMS and BUILD_TOOLS_SHA256SUMS are never excluded, so
    the kit manifest always binds the tool manifest.

Existing manifests are verified and kept unchanged by default.
Use -Update to deliberately regenerate them after source/tool changes.
#>

[CmdletBinding()]
param(
    [switch]$Update
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Fail {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Error "[nexs-manifest][ERROR] $Message"
    exit 1
}

function Log {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[nexs-manifest] $Message"
}

$scriptPath = $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($scriptPath)) {
    Fail 'Unable to determine script path.'
}

$scriptDirectory = Split-Path -Parent $scriptPath
if ([string]::IsNullOrWhiteSpace($scriptDirectory)) {
    Fail 'Unable to determine script directory.'
}

try {
    $scriptDirectory = (Resolve-Path -LiteralPath $scriptDirectory -ErrorAction Stop).Path
}
catch {
    Fail "Unable to resolve script directory: $scriptDirectory"
}

if ((Split-Path -Leaf $scriptDirectory) -ne 'nexs_build_tools') {
    Fail 'generate_build_manifests.ps1 must reside in nexs_build_tools/.'
}

$rootDirectory = Split-Path -Parent $scriptDirectory
try {
    $rootDirectory = (Resolve-Path -LiteralPath $rootDirectory -ErrorAction Stop).Path
}
catch {
    Fail "Unable to resolve project root: $rootDirectory"
}

$toolsDirectory = $scriptDirectory
$toolManifest = Join-Path $toolsDirectory 'BUILD_TOOLS_SHA256SUMS'
$kitManifest = Join-Path $rootDirectory 'BUILD_KIT_SHA256SUMS'
$gitignorePath = Join-Path $rootDirectory '.gitignore'

if (-not (Test-Path -LiteralPath $rootDirectory -PathType Container)) {
    Fail "Project root is not a directory: $rootDirectory"
}

if (-not (Test-Path -LiteralPath $toolsDirectory -PathType Container)) {
    Fail "Build-tools directory is missing: $toolsDirectory"
}

$sha256Command = Get-Command sha256sum -CommandType Application -ErrorAction SilentlyContinue
if ($null -eq $sha256Command) {
    Fail 'sha256sum is required; no alternate hash implementation is permitted.'
}

$sha256Path = $sha256Command.Source
if ([string]::IsNullOrWhiteSpace($sha256Path)) {
    Fail 'Unable to resolve sha256sum executable.'
}

# ---------------------------------------------------------------------------
# Dynamic .gitignore pattern loading
# ---------------------------------------------------------------------------
# The parsing is intentionally minimal and matches the POSIX generator:
#   - comments ('#' prefix) and blank lines are skipped
#   - negation patterns ('!' prefix) are skipped
#   - trailing whitespace is removed
#   - leading '/' is preserved as an anchoring hint for the matcher
$script:GitIgnorePatterns = @()

function Initialize-GitIgnorePatterns {
    param([Parameter(Mandatory = $true)][string]$Root)

    $patterns = New-Object 'System.Collections.Generic.List[string]'
    $gi = Join-Path $Root '.gitignore'

    if (Test-Path -LiteralPath $gi -PathType Leaf) {
        try {
            $item = Get-Item -LiteralPath $gi -Force -ErrorAction Stop
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                Fail "Project .gitignore is a symlink/reparse point: $gi"
            }
        }
        catch {
            Fail "Unable to inspect .gitignore: $gi"
        }

        $lines = [System.IO.File]::ReadAllLines($gi, [System.Text.UTF8Encoding]::new($false))
        foreach ($raw in $lines) {
            $line = $raw.TrimEnd()
            if ([string]::IsNullOrEmpty($line)) { continue }
            if ($line.StartsWith('#')) { continue }
            if ($line.StartsWith('!')) { continue }
            $patterns.Add($line)
        }
    }

    # Project invariants are always merged.
    foreach ($invariant in @('build', 'release', '.git', '.venv', '__pycache__')) {
        if (-not $patterns.Contains($invariant)) {
            $patterns.Add($invariant)
        }
    }

    $script:GitIgnorePatterns = $patterns.ToArray()
}

# Returns $true when the relative path (POSIX separators) should be excluded.
function Test-PathMatchesGitIgnore {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    if ($null -eq $script:GitIgnorePatterns -or $script:GitIgnorePatterns.Count -eq 0) {
        return $false
    }

    $ignored = $false
    foreach ($rawPattern in $script:GitIgnorePatterns) {
        if ([string]::IsNullOrEmpty($rawPattern)) { continue }

        $pattern = $rawPattern
        if ($pattern.StartsWith('/')) { $pattern = $pattern.Substring(1) }
        if ($pattern.EndsWith('/'))   { $pattern = $pattern.Substring(0, $pattern.Length - 1) }
        if ([string]::IsNullOrEmpty($pattern)) { continue }

        $matched = $false

        if ($pattern.Contains('/')) {
            # Path pattern: match against the full relative path or any suffix.
            if ([System.Management.Automation.WildcardPattern]::Get(
                    $pattern,
                    [System.Management.Automation.WildcardOptions]::IgnoreCase
                ).IsMatch($RelativePath)) {
                $matched = $true
            }
            elseif ([System.Management.Automation.WildcardPattern]::Get(
                        "$pattern/*",
                        [System.Management.Automation.WildcardOptions]::IgnoreCase
                    ).IsMatch($RelativePath)) {
                $matched = $true
            }
            elseif ([System.Management.Automation.WildcardPattern]::Get(
                        "*/$pattern",
                        [System.Management.Automation.WildcardOptions]::IgnoreCase
                    ).IsMatch($RelativePath)) {
                $matched = $true
            }
            elseif ([System.Management.Automation.WildcardPattern]::Get(
                        "*/$pattern/*",
                        [System.Management.Automation.WildcardOptions]::IgnoreCase
                    ).IsMatch($RelativePath)) {
                $matched = $true
            }
        }
        else {
            # Basename pattern: match any path component.
            $components = $RelativePath.Split('/')
            $wp = [System.Management.Automation.WildcardPattern]::Get(
                $pattern,
                [System.Management.Automation.WildcardOptions]::IgnoreCase
            )
            foreach ($component in $components) {
                if ($wp.IsMatch($component)) {
                    $matched = $true
                    break
                }
            }
        }

        if ($matched) {
            $ignored = $true
        }
    }

    return $ignored
}

# ---------------------------------------------------------------------------
# Low-level helpers
# ---------------------------------------------------------------------------

function Test-RegularFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail "$Description is missing or is not a regular file: $Path"
    }

    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    }
    catch {
        Fail "Unable to inspect $Description`: $Path"
    }

    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail "$Description is a symbolic/reparse point: $Path"
    }
}

function Get-Sha256File {
    param([Parameter(Mandatory = $true)][string]$Path)

    Test-RegularFile -Path $Path -Description 'file to hash'

    try {
        $rawOutput = @(& $sha256Path -- $Path 2>&1)
    }
    catch {
        Fail "Unable to execute sha256sum for '$Path': $($_.Exception.Message)"
    }

    if ($LASTEXITCODE -ne 0) {
        Fail "sha256sum failed: $Path"
    }

    if ($rawOutput.Count -lt 1) {
        Fail "sha256sum returned no digest: $Path"
    }

    $line = [string]$rawOutput[0]
    if ($line.Length -lt 64) {
        Fail "sha256sum returned malformed output: $Path"
    }

    $digest = $line.Substring(0, 64).ToLowerInvariant()
    if ($digest -notmatch '^[0-9a-f]{64}$') {
        Fail "sha256sum returned an invalid digest: $Path"
    }

    return $digest
}

function Validate-RelativePath {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    if ([string]::IsNullOrEmpty($RelativePath)) {
        Fail 'Empty relative manifest path.'
    }

    if ($RelativePath.StartsWith('/') -or
        $RelativePath.StartsWith('\') -or
        $RelativePath -match '(^|[\/])\.\.([\/]|$)' -or
        $RelativePath -match '(^|[\/])\.([\/]|$)' -or
        $RelativePath.Contains('//') -or
        $RelativePath.Contains("`t") -or
        $RelativePath.Contains("`r") -or
        $RelativePath.Contains("`n")) {
        Fail "Unsafe/non-canonical relative manifest path: $RelativePath"
    }

    if ($RelativePath.StartsWith(' ') -or $RelativePath.EndsWith(' ')) {
        Fail "Manifest path has leading/trailing whitespace: $RelativePath"
    }

    if ($RelativePath.Contains('\')) {
        Fail "Manifest path uses a Windows separator; use '/': $RelativePath"
    }
}

function Get-TreeFiles {
    param(
        [Parameter(Mandatory = $true)][string]$BaseDirectory,
        [Parameter(Mandatory = $true)][ValidateSet('tools','kit')][string]$Mode
    )

    $base = (Resolve-Path -LiteralPath $BaseDirectory -ErrorAction Stop).Path
    $queue = New-Object 'System.Collections.Generic.Queue[string]'
    $queue.Enqueue($base)
    $files = New-Object 'System.Collections.Generic.List[string]'

    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        $children = @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop |
            Sort-Object -Property Name, FullName)

        foreach ($item in $children) {
            $full = $item.FullName

            if ($item.PSIsContainer) {
                if ($item.Name -eq '__pycache__') {
                    continue
                }

                $isTopLevel = [System.StringComparer]::OrdinalIgnoreCase.Equals(
                    [System.IO.Path]::GetFullPath((Split-Path -Parent $full)),
                    [System.IO.Path]::GetFullPath($base)
                )

                if ($Mode -eq 'kit' -and $isTopLevel -and
                    ($item.Name -eq 'build' -or
                     $item.Name -eq 'release' -or
                     $item.Name -eq '.git' -or
                     $item.Name -eq '.venv')) {
                    continue
                }

                if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    Fail "Build tree contains a symbolic/reparse directory: $full"
                }

                $queue.Enqueue($full)
                continue
            }

            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                Fail "Build tree contains a symbolic/reparse file: $full"
            }

            $files.Add($full)
        }
    }

    return @($files | Sort-Object)
}

function Get-RelativeManifestPath {
    param(
        [Parameter(Mandatory = $true)][string]$BaseDirectory,
        [Parameter(Mandatory = $true)][string]$FullPath
    )

    $base = [System.IO.Path]::GetFullPath($BaseDirectory).TrimEnd('\','/')
    $full = [System.IO.Path]::GetFullPath($FullPath)
    $separator = [System.IO.Path]::DirectorySeparatorChar

    if (-not $full.StartsWith($base + $separator, [System.StringComparison]::OrdinalIgnoreCase)) {
        Fail "Path escapes manifest base directory: $FullPath"
    }

    $relative = $full.Substring($base.Length + 1).Replace('\','/')
    Validate-RelativePath -RelativePath $relative
    return $relative
}

function Build-ManifestCandidate {
    param(
        [Parameter(Mandatory = $true)][string]$BaseDirectory,
        [Parameter(Mandatory = $true)][ValidateSet('tools','kit')][string]$Mode,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][string]$SkipManifest,
        [Parameter(Mandatory = $true)][string]$SkipTemporary
    )

    $files = Get-TreeFiles -BaseDirectory $BaseDirectory -Mode $Mode
    $rows = New-Object 'System.Collections.Generic.List[string]'
    $skipA = [System.IO.Path]::GetFullPath($SkipManifest)
    $skipB = [System.IO.Path]::GetFullPath($SkipTemporary)

    foreach ($file in $files) {
        $full = [System.IO.Path]::GetFullPath($file)

        if ([System.StringComparer]::OrdinalIgnoreCase.Equals($full, $skipA) -or
            [System.StringComparer]::OrdinalIgnoreCase.Equals($full, $skipB)) {
            continue
        }

        $relative = Get-RelativeManifestPath -BaseDirectory $BaseDirectory -FullPath $file

        # The two anchors are never excluded.
        if ($relative -eq 'BUILD_KIT_SHA256SUMS' -or $relative -eq 'BUILD_TOOLS_SHA256SUMS' -or $relative -eq 'nexs_build_tools/BUILD_TOOLS_SHA256SUMS') {
            # fall through to hashing
        }
        else {
            if (Test-PathMatchesGitIgnore -RelativePath $relative) {
                continue
            }
        }

        $digest = Get-Sha256File -Path $file
        $rows.Add(('{0}  {1}' -f $digest, $relative))
    }

    if ($rows.Count -eq 0) {
        Fail "Generated checksum manifest is empty: $OutputPath"
    }

    $sortedRows = @($rows | Sort-Object)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    try {
        [System.IO.File]::WriteAllLines($OutputPath, $sortedRows, $utf8NoBom)
    }
    catch {
        Fail "Unable to write generated checksum manifest: $OutputPath"
    }

    Test-RegularFile -Path $OutputPath -Description 'generated checksum manifest'

    foreach ($line in [System.IO.File]::ReadAllLines($OutputPath, $utf8NoBom)) {
        if ($line -notmatch '^[0-9a-f]{64}  .+$') {
            Fail "Generated checksum manifest contains malformed data: $OutputPath"
        }
    }
}

function Verify-ManifestWithSha256sum {
    param(
        [Parameter(Mandatory = $true)][string]$Manifest,
        [Parameter(Mandatory = $true)][string]$Directory
    )

    Test-RegularFile -Path $Manifest -Description 'checksum manifest'

    $manifestName = Split-Path -Leaf $Manifest
    $workingDirectory = (Resolve-Path -LiteralPath $Directory -ErrorAction Stop).Path

    Push-Location $workingDirectory
    try {
        & $sha256Path --strict --check $manifestName *> $null
        if ($LASTEXITCODE -ne 0) {
            Fail "sha256sum verification failed: $Manifest"
        }
    }
    finally {
        Pop-Location
    }
}

function Manifest-Equal {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    $a = [System.IO.File]::ReadAllBytes($Left)
    $b = [System.IO.File]::ReadAllBytes($Right)

    if ($a.Length -ne $b.Length) {
        return $false
    }

    for ($i = 0; $i -lt $a.Length; $i++) {
        if ($a[$i] -ne $b[$i]) {
            return $false
        }
    }

    return $true
}

function Publish-Candidate {
    param(
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    Test-RegularFile -Path $Candidate -Description 'candidate manifest'

    try {
        Move-Item -LiteralPath $Candidate -Destination $Destination -Force -ErrorAction Stop
    }
    catch {
        Fail "Unable to publish manifest '$Destination': $($_.Exception.Message)"
    }

    Test-RegularFile -Path $Destination -Description 'published checksum manifest'
}

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------

Initialize-GitIgnorePatterns -Root $rootDirectory

$toolCandidate = Join-Path $toolsDirectory ('.BUILD_TOOLS_SHA256SUMS.tmp.' + [Guid]::NewGuid().ToString('N'))
$kitCandidate = Join-Path $rootDirectory ('.BUILD_KIT_SHA256SUMS.tmp.' + [Guid]::NewGuid().ToString('N'))

try {
    # -----------------------------------------------------------------------
    # BUILD_TOOLS_SHA256SUMS
    # -----------------------------------------------------------------------
    Build-ManifestCandidate `
        -BaseDirectory $toolsDirectory `
        -Mode tools `
        -OutputPath $toolCandidate `
        -SkipManifest $toolManifest `
        -SkipTemporary $toolCandidate

    if (Test-Path -LiteralPath $toolManifest -PathType Leaf) {
        if (-not $Update) {
            Verify-ManifestWithSha256sum -Manifest $toolManifest -Directory $toolsDirectory

            if (-not (Manifest-Equal -Left $toolManifest -Right $toolCandidate)) {
                Fail 'BUILD_TOOLS_SHA256SUMS is stale; rerun with -Update after reviewing changes.'
            }

            Remove-Item -LiteralPath $toolCandidate -Force -ErrorAction Stop
            $toolCandidate = ''
            Log 'BUILD_TOOLS_SHA256SUMS is current.'
        }
        else {
            Publish-Candidate -Candidate $toolCandidate -Destination $toolManifest
            $toolCandidate = ''
            Verify-ManifestWithSha256sum -Manifest $toolManifest -Directory $toolsDirectory
            Log 'BUILD_TOOLS_SHA256SUMS regenerated.'
        }
    }
    else {
        Publish-Candidate -Candidate $toolCandidate -Destination $toolManifest
        $toolCandidate = ''
        Verify-ManifestWithSha256sum -Manifest $toolManifest -Directory $toolsDirectory
        Log 'BUILD_TOOLS_SHA256SUMS generated.'
    }

    # -----------------------------------------------------------------------
    # BUILD_KIT_SHA256SUMS
    # -----------------------------------------------------------------------
    Build-ManifestCandidate `
        -BaseDirectory $rootDirectory `
        -Mode kit `
        -OutputPath $kitCandidate `
        -SkipManifest $kitManifest `
        -SkipTemporary $kitCandidate

    if (Test-Path -LiteralPath $kitManifest -PathType Leaf) {
        if (-not $Update) {
            Verify-ManifestWithSha256sum -Manifest $kitManifest -Directory $rootDirectory

            if (-not (Manifest-Equal -Left $kitManifest -Right $kitCandidate)) {
                Fail 'BUILD_KIT_SHA256SUMS is stale; rerun with -Update after reviewing changes.'
            }

            Remove-Item -LiteralPath $kitCandidate -Force -ErrorAction Stop
            $kitCandidate = ''
            Log 'BUILD_KIT_SHA256SUMS is current.'
        }
        else {
            Publish-Candidate -Candidate $kitCandidate -Destination $kitManifest
            $kitCandidate = ''
            Verify-ManifestWithSha256sum -Manifest $kitManifest -Directory $rootDirectory
            Log 'BUILD_KIT_SHA256SUMS regenerated.'
        }
    }
    else {
        Publish-Candidate -Candidate $kitCandidate -Destination $kitManifest
        $kitCandidate = ''
        Verify-ManifestWithSha256sum -Manifest $kitManifest -Directory $rootDirectory
        Log 'BUILD_KIT_SHA256SUMS generated.'
    }

    # The root manifest MUST explicitly bind the tool manifest.
    $kitEncoding = New-Object System.Text.UTF8Encoding($false)
    $kitLines = [System.IO.File]::ReadAllLines($kitManifest, $kitEncoding)
    $bindingFound = $false

    foreach ($line in $kitLines) {
        if ($line -match '^[0-9A-Fa-f]{64}  nexs_build_tools/BUILD_TOOLS_SHA256SUMS$') {
            $bindingFound = $true
            break
        }
    }

    if (-not $bindingFound) {
        Fail 'BUILD_KIT_SHA256SUMS does not bind nexs_build_tools/BUILD_TOOLS_SHA256SUMS.'
    }

    Verify-ManifestWithSha256sum -Manifest $toolManifest -Directory $toolsDirectory
    Verify-ManifestWithSha256sum -Manifest $kitManifest -Directory $rootDirectory

    Log 'Manifest generation/verification completed successfully.'
    Write-Host "[nexs-manifest] Tool manifest: $toolManifest"
    Write-Host "[nexs-manifest] Kit manifest:  $kitManifest"
    Write-Host "[nexs-manifest] Hash implementation: $sha256Path"
}
catch {
    if ($_.Exception.Message) {
        Write-Error "[nexs-manifest][ERROR] $($_.Exception.Message)"
    }
    else {
        Write-Error '[nexs-manifest][ERROR] Manifest generation failed.'
    }
    exit 1
}
finally {
    if (-not [string]::IsNullOrWhiteSpace($toolCandidate) -and
        (Test-Path -LiteralPath $toolCandidate -PathType Leaf)) {
        Remove-Item -LiteralPath $toolCandidate -Force -ErrorAction SilentlyContinue
    }

    if (-not [string]::IsNullOrWhiteSpace($kitCandidate) -and
        (Test-Path -LiteralPath $kitCandidate -PathType Leaf)) {
        Remove-Item -LiteralPath $kitCandidate -Force -ErrorAction SilentlyContinue
    }
}
