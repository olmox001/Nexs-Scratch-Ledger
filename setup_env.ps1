# Nexs Scratch Ledger - development environment manager (Windows).
#
# Verifies/creates the project's own development virtualenv (NOT the
# disposable, hash-pinned venv the release build creates under .\build\*\venv)
# and installs the runtime dependencies declared in requirements.txt.
#
# Usage:
#   .\setup_env.ps1            Create the venv if missing, verify/install
#                               deps, then exit. Safe to run every time; if
#                               the venv already exists and is healthy, it
#                               does nothing but a quick check.
#   .\setup_env.ps1 -clean     Remove ONLY this development venv and exit.
#   .\setup_env.ps1 -help      Show this help.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

function Log([string]$Message)  { Write-Host "[nexs-env] $Message" }
function Warn([string]$Message) { Write-Warning "[nexs-env] $Message" }
function Fail([string]$Message) { throw "[nexs-env][ERROR] $Message" }

function Show-Usage {
    @'
Usage: setup_env.ps1 [-clean|--clean] [-h|-help|--help]

  (no flags)      Create the development virtualenv if it does not exist yet,
                  verify/install runtime dependencies, then exit. Safe to run
                  on every invocation (including from build_release.ps1).
  -clean/--clean  Remove ONLY the development virtualenv (.\.venv) and exit.
                  Never touches the build system's own disposable venvs
                  under .\build\*\venv - those are cleaned by the build
                  scripts themselves.
  -h/-help/--help Show this help.
'@ | Write-Host
}

# Resolve paths relative to THIS file, not the caller's working directory.
$RootDir = $PSScriptRoot
$VenvDir = if ($env:NEXS_DEV_VENV_DIR) { $env:NEXS_DEV_VENV_DIR } else { Join-Path $RootDir '.venv' }
$ReqFile = Join-Path $RootDir 'requirements.txt'

# Minimum Python the source actually needs; 3.12.x is only the release-build
# baseline (see nexs_build_tools\BUILD.md), not a hard requirement to run
# main.py from source, so accept any modern 3.x here and just recommend 3.12.
$MinMajor = 3
$MinMinor = 9
$RecommendedMinor = 12
$AutoPip = ($env:NEXS_AUTO_ACCEPT_PIP -eq '1')

$Clean = $false
foreach ($a in $args) {
    switch -Regex ($a) {
        '^(-clean|--clean)$' { $Clean = $true }
        '^(-h|-help|--help)$' { Show-Usage; exit 0 }
        default { Fail "Unknown argument: $a (see -help)" }
    }
}

# Refuse to ever resolve VenvDir to something outside the project root or
# inside the build tree, however NEXS_DEV_VENV_DIR is overridden.
$buildDir = Join-Path $RootDir 'build'
$resolvedVenvParent = Split-Path -Parent ([IO.Path]::GetFullPath($VenvDir))
$fullRoot = [IO.Path]::GetFullPath($RootDir).TrimEnd('\')
$fullBuild = [IO.Path]::GetFullPath($buildDir).TrimEnd('\')
$fullVenv = [IO.Path]::GetFullPath($VenvDir).TrimEnd('\')
if ($fullVenv -eq $fullBuild -or $fullVenv.StartsWith("$fullBuild\")) {
    Fail 'NEXS_DEV_VENV_DIR must not point inside .\build (that tree belongs to the release build).'
}
if (-not ($resolvedVenvParent -eq $fullRoot -or $resolvedVenvParent.StartsWith("$fullRoot\"))) {
    Fail "NEXS_DEV_VENV_DIR must resolve inside the project root: $VenvDir"
}

if ($Clean) {
    if (Test-Path -LiteralPath $VenvDir) {
        $item = Get-Item -LiteralPath $VenvDir -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { Fail "Refusing to remove a reparse point: $VenvDir" }
        Remove-Item -LiteralPath $VenvDir -Recurse -Force
        Log "Removed development virtualenv: $VenvDir"
    } else {
        Log "No development virtualenv found at $VenvDir; nothing to clean."
    }
    exit 0
}

function Find-Python {
    foreach ($cmd in @('py','python3.13','python3.12','python3.11','python3.10','python3.9','python3','python')) {
        $found = Get-Command $cmd -ErrorAction SilentlyContinue
        if ($found) {
            if ($cmd -eq 'py') { return [pscustomobject]@{ Exe = $found.Source; Args = @('-3') } }
            return [pscustomobject]@{ Exe = $found.Source; Args = @() }
        }
    }
    return $null
}

$SystemPython = Find-Python
if (-not $SystemPython) { Fail "No Python $MinMajor.$MinMinor+ interpreter found on PATH. Install Python ($MinMajor.$RecommendedMinor.x recommended) first." }

& $SystemPython.Exe @($SystemPython.Args) -c "import sys; sys.exit(0 if sys.version_info[:2] >= ($MinMajor, $MinMinor) else 1)"
if ($LASTEXITCODE -ne 0) {
    $verText = (& $SystemPython.Exe @($SystemPython.Args) --version 2>&1)
    Fail "$verText is too old; $MinMajor.$MinMinor+ is required ($MinMajor.$RecommendedMinor.x recommended, matching the release build baseline)."
}

$VenvPy = Join-Path $VenvDir 'Scripts\python.exe'

if (-not (Test-Path -LiteralPath $VenvPy)) {
    $verText = (& $SystemPython.Exe @($SystemPython.Args) --version 2>&1)
    Log "Creating development virtualenv at $VenvDir with $verText ..."
    if (Test-Path -LiteralPath $VenvDir) { Remove-Item -LiteralPath $VenvDir -Recurse -Force }
    & $SystemPython.Exe @($SystemPython.Args) -m venv $VenvDir
    if ($LASTEXITCODE -ne 0) { Fail 'Virtual environment creation failed.' }
    if (-not (Test-Path -LiteralPath $VenvPy)) { Fail "Virtual environment python missing after creation: $VenvPy" }
} else {
    Log "Using existing development virtualenv at $VenvDir."
}

function Test-Deps {
    if (Test-Path -LiteralPath $ReqFile) {
        $checkScript = @'
import re, sys, importlib
req_file = sys.argv[1]
mod_names = {"argon2-cffi": "argon2"}
with open(req_file, encoding="utf-8") as f:
    for raw in f:
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        name = re.split(r"[<>=!~\[]", line, 1)[0].strip()
        importlib.import_module(mod_names.get(name.lower(), name.replace("-", "_")))
'@
        & $VenvPy -c $checkScript $ReqFile 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    } else {
        & $VenvPy -c "import cryptography, argon2" 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    }
}

if (Test-Deps) {
    Log 'Runtime dependencies already satisfied.'
} else {
    if (-not $AutoPip) {
        $answer = Read-Host '[nexs-env] Runtime dependencies are missing from the development virtualenv; install them now? [y/N]'
        if ($answer -notin @('y','Y','yes','YES')) { Fail 'Operation declined: install runtime dependencies.' }
    }
    & $VenvPy -m pip install --disable-pip-version-check --no-input --upgrade pip 2>$null | Out-Null
    if (Test-Path -LiteralPath $ReqFile) {
        Log "Installing runtime dependencies from $(Split-Path -Leaf $ReqFile) ..."
        & $VenvPy -m pip install --disable-pip-version-check --no-input -r $ReqFile
        if ($LASTEXITCODE -ne 0) { Fail 'Dependency installation failed.' }
    } else {
        Warn 'No requirements.txt found at project root; installing known runtime dependencies directly.'
        & $VenvPy -m pip install --disable-pip-version-check --no-input "cryptography>=41" "argon2-cffi>=23"
        if ($LASTEXITCODE -ne 0) { Fail 'Dependency installation failed.' }
    }
    if (-not (Test-Deps)) { Fail 'Dependencies were installed but are still not importable; check for a broken virtualenv.' }
}

$verText = (& $VenvPy --version 2>&1)
Log 'Environment ready.'
Log "  Path:   $VenvDir"
Log "  Python: $verText"
Log "Activate it with: . `"$VenvDir\Scripts\Activate.ps1`""
