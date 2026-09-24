<#
Nexs Ledger build-manifest cleaner.

REQUIRED LOCATION:
    <project-root>/nexs_build_tools/clean_manifest.ps1

Removes the two generated checksum manifests so they can be regenerated
from scratch with generate_build_manifests.ps1:
    <project-root>/nexs_build_tools/BUILD_TOOLS_SHA256SUMS
    <project-root>/BUILD_KIT_SHA256SUMS

Refuses to touch anything that is not a plain regular file at exactly
those two locations (no symlinks/reparse points, no directories).
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Fail([string]$Message) { throw "[nexs-clean][ERROR] $Message" }
function Log([string]$Message) { Write-Host "[nexs-clean] $Message" }

$ScriptDir = (Resolve-Path -LiteralPath (Split-Path -Parent $MyInvocation.MyCommand.Path)).Path
$ToolsBasename = Split-Path -Leaf $ScriptDir
if ($ToolsBasename -ne 'nexs_build_tools') { Fail 'clean_manifest.ps1 must reside in nexs_build_tools/.' }

$RootDir = (Resolve-Path -LiteralPath (Join-Path $ScriptDir '..')).Path
$ToolManifest = Join-Path $ScriptDir 'BUILD_TOOLS_SHA256SUMS'
$KitManifest = Join-Path $RootDir 'BUILD_KIT_SHA256SUMS'

function Remove-Manifest {
    param([string]$Path, [string]$Label)

    if (-not (Test-Path -LiteralPath $Path)) {
        Log "$Label already absent: $Path"
        return
    }

    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        Fail "$Label is a symlink/reparse point, refusing to remove: $Path"
    }
    if ($item.PSIsContainer) {
        Fail "$Label is a directory, refusing to remove: $Path"
    }

    Remove-Item -LiteralPath $Path -Force
    Log "Removed $Label`: $Path"
}

Remove-Manifest -Path $ToolManifest -Label 'BUILD_TOOLS_SHA256SUMS'
Remove-Manifest -Path $KitManifest -Label 'BUILD_KIT_SHA256SUMS'

Log 'Done. Run generate_build_manifests.ps1 to regenerate.'
