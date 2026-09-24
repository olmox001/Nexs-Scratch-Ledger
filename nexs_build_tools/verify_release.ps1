[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][Alias('V')][ValidatePattern('^\d+\.\d+\.\d+\.\d+$')][string]$Version,
    [string]$Release = '',
    [switch]$RequireAll,
    [string]$Python = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$env:PYTHONDONTWRITEBYTECODE='1'; $env:PYTHONNOUSERSITE='1'; $env:PYTHONSAFEPATH='1'; $env:PYTHONHASHSEED='0'
$env:PYTHONHOME=$null; $env:PYTHONPATH=$null; $env:PYTHONSTARTUP=$null; $env:PYTHONUSERBASE=$null; $env:PYTHONINSPECT=$null; $env:PYTHONBREAKPOINT=$null
$ScriptDir = (Resolve-Path -LiteralPath (Split-Path -Parent $MyInvocation.MyCommand.Path)).Path
$RootDir = (Resolve-Path -LiteralPath (Join-Path $ScriptDir '..')).Path
$Core = Join-Path $ScriptDir 'nexs_build_core.py'
if (-not $Release) { $Release = Join-Path $RootDir 'release' }
$KitChecksums = Join-Path $RootDir 'BUILD_KIT_SHA256SUMS'
function Verify-ChecksumManifest([string]$Manifest,[string]$Base) {
    if(-not(Test-Path -LiteralPath $Manifest -PathType Leaf)){throw "Checksum manifest missing: $Manifest"}; $seen=@{}
    foreach($line in [IO.File]::ReadAllLines($Manifest)){
        if([string]::IsNullOrEmpty($line)){continue}; if($line.Contains("`t") -or $line.StartsWith(' ') -or $line.EndsWith(' ')){throw 'Invalid checksum manifest whitespace.'}
        $idx=$line.IndexOf('  ',[StringComparison]::Ordinal); if($idx -lt 0){throw 'Invalid checksum manifest entry.'}; $digest=$line.Substring(0,$idx); $rel=$line.Substring($idx+2);
        if($digest -notmatch '^[0-9A-Fa-f]{64}$' -or [IO.Path]::IsPathRooted($rel) -or $rel.Contains('\') -or $rel.Split('/') -contains '..' -or $rel.Split('/') -contains '.'){throw "Unsafe checksum path: $rel"}
        $full=[IO.Path]::GetFullPath((Join-Path $Base ($rel -replace '/','\'))); Assert-File $full 'checksum member'; if($seen.ContainsKey($rel)){throw "Duplicate checksum entry: $rel"}; if((Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant() -ne $digest.ToLowerInvariant()){throw "Checksum verification failed: $rel"}; $seen[$rel]=$true
    }; if($seen.Count -eq 0){throw 'Checksum manifest is empty.'}
}
function Assert-File([string]$Path,[string]$Label) { if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){throw "$Label is missing: $Path"}; $item=Get-Item -LiteralPath $Path -Force; if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw "$Label is a reparse point: $Path"} }
Verify-ChecksumManifest $KitChecksums $RootDir
if (-not $Python) {
    $pyCmd = Get-Command py -ErrorAction SilentlyContinue
    if ($pyCmd) { $Python = 'py'; $PyArgs = @('-3.12') }
    else { $Python = 'python'; $PyArgs = @() }
} else { $PyArgs = @() }
if (-not (Test-Path -LiteralPath $Core -PathType Leaf)) { throw 'Build core is missing.' }
& $Python @PyArgs -c 'import sys; raise SystemExit(0 if sys.implementation.name=="cpython" and sys.version_info[:2]==(3,12) else 1)'
if ($LASTEXITCODE -ne 0) { throw 'CPython 3.12 is required for release verification.' }
& $Python @PyArgs $Core audit-kit --root $RootDir --checksums $KitChecksums; if ($LASTEXITCODE -ne 0) { throw 'Build-kit integrity verification failed.' }
& $Python @PyArgs $Core audit-tools --tools-dir $ScriptDir --checksums (Join-Path $ScriptDir 'BUILD_TOOLS_SHA256SUMS')
if ($LASTEXITCODE -ne 0) { throw 'Build-tool integrity verification failed.' }
$Args = @($Core, 'verify-release', '--release', $Release, '--version', $Version)
if ($RequireAll) { $Args += '--require-all' }
& $Python @PyArgs @Args
if ($LASTEXITCODE -ne 0) { throw "Release verification failed with exit code $LASTEXITCODE." }
