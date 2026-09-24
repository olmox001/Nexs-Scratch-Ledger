[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][Alias('V')][ValidatePattern('^\d+\.\d+\.\d+\.\d+$')][string]$Version,
    [ValidateSet('windows-x86_64','windows-arm64')][string[]]$Target,
    [string]$Source = '',
    [switch]$HostOnly,
    [switch]$NoPublish,
    [string]$ArtifactOut = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'
$env:PYTHONDONTWRITEBYTECODE='1'
$env:PYTHONHASHSEED='0'
$env:PYTHONNOUSERSITE='1'
$env:PYTHONSAFEPATH='1'
$env:PYTHONHOME=$null; $env:PYTHONPATH=$null; $env:PYTHONSTARTUP=$null; $env:PYTHONUSERBASE=$null; $env:PYTHONINSPECT=$null; $env:PYTHONBREAKPOINT=$null; $env:PYTHONOPTIMIZE=$null; $env:PYTHONDEBUG=$null; $env:PYTHONWARNINGS='error'; $env:CC=$null; $env:CXX=$null; $env:CFLAGS=$null; $env:CXXFLAGS=$null; $env:CPPFLAGS=$null; $env:LDFLAGS=$null; $env:AR=$null; $env:AS=$null; $env:LD=$null; $env:RANLIB=$null; $env:STRIP=$null; $env:SDKROOT=$null; $env:MACOSX_DEPLOYMENT_TARGET=$null
$env:SOURCE_DATE_EPOCH=if($env:NEXS_SOURCE_DATE_EPOCH){$env:NEXS_SOURCE_DATE_EPOCH}else{'0'}
if($env:SOURCE_DATE_EPOCH -notmatch '^\d+$'){Fail 'NEXS_SOURCE_DATE_EPOCH must be a non-negative integer.'}
$env:PIP_CONFIG_FILE='NUL'; $env:PIP_EXTRA_INDEX_URL=''; $env:PIP_FIND_LINKS=''; $env:PIP_NO_INDEX='0'; $env:PIP_TRUSTED_HOST=$null; $env:PIP_CERT=$null; $env:PIP_CLIENT_CERT=$null; $env:PIP_CLIENT_KEY=$null; $env:PIP_USER=$null; $env:PIP_GLOBAL_OPTION=$null; $env:PIP_PRE=$null; $env:PIP_ONLY_BINARY=$null; $env:PIP_NO_BINARY=$null; $env:PIP_PREFER_BINARY=$null; $env:PIP_USE_PEP517=$null; $env:PIP_REQUIRE_HASHES=$null
$env:PIP_DISABLE_PIP_VERSION_CHECK='1'
$env:PIP_NO_CACHE_DIR='1'
$env:PIP_REQUIRE_VIRTUALENV='1'
$env:PIP_INDEX_URL=if($env:NEXS_PIP_INDEX_URL){$env:NEXS_PIP_INDEX_URL}else{'https://pypi.org/simple'}
if(-not $env:PIP_INDEX_URL.StartsWith('https://',[StringComparison]::OrdinalIgnoreCase)){throw 'PIP_INDEX_URL must use HTTPS.'}
if($env:PIP_INDEX_URL -ne 'https://pypi.org/simple' -and $env:NEXS_ALLOW_CUSTOM_PIP_INDEX -ne '1'){throw 'Custom PIP index is disabled by default; set NEXS_ALLOW_CUSTOM_PIP_INDEX=1 only for an explicitly trusted mirror.'}

$ScriptDir = (Resolve-Path -LiteralPath (Split-Path -Parent $MyInvocation.MyCommand.Path)).Path
$RootDir = if ($env:NEXS_ROOT_DIR) { (Resolve-Path -LiteralPath $env:NEXS_ROOT_DIR).Path } else { (Resolve-Path -LiteralPath (Join-Path $ScriptDir '..')).Path }
$SourceFile = if ($Source) { (Resolve-Path -LiteralPath $Source).Path } else { Join-Path $RootDir 'main.py' }
$TestFile = Join-Path $RootDir 'test.py'
$BuildDir = Join-Path $RootDir 'build'
$env:TEMP=Join-Path $BuildDir '.tmp'; $env:TMP=$env:TEMP
$ReleaseDir = Join-Path $RootDir 'release'
$ReqFile = Join-Path $ScriptDir 'requirements-build.txt'
$Core = Join-Path $ScriptDir 'nexs_build_core.py'
$Checksums = Join-Path $ScriptDir 'BUILD_TOOLS_SHA256SUMS'
$KitChecksums = Join-Path $RootDir 'BUILD_KIT_SHA256SUMS'
$AutoSystem = ($env:NEXS_AUTO_ACCEPT_SYSTEM -eq '1')
$AutoPip = ($env:NEXS_AUTO_ACCEPT_PIP -eq '1')
$NuitkaVersion='4.2.2'; $CryptoVersion='48.0.1'; $CffiVersion='2.1.1'; $PycparserVersion='2.23'; $OrderedSetVersion='4.1.0'; $SetuptoolsVersion='83.0.0'; $Argon2Version='23.1.0'; $Argon2BindingsVersion='21.2.0'

function Fail([string]$Message) { throw "[nexs-build][ERROR] $Message" }
function Log([string]$Message) { Write-Host "[nexs-build] $Message" }
function Get-BuildJobs {
    # Nuitka/Scons compile parallelism: (available cores - 2), but never below 1,
    # and never parallel at all on machines with fewer than 4 cores.
    $cores = [Environment]::ProcessorCount
    if ($cores -lt 1) { $cores = 1 }
    if ($cores -lt 4) { return 1 }
    $jobs = $cores - 2
    if ($jobs -lt 1) { $jobs = 1 }
    return $jobs
}
$BuildJobs = Get-BuildJobs
function Confirm-Action([string]$Message,[bool]$Auto) { if($Auto){return}; $answer=Read-Host "$Message [y/N]"; if($answer -notin @('y','Y','yes','YES')){Fail "Operation declined: $Message"} }
function Assert-File([string]$Path,[string]$Label) { if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){Fail "$Label is missing: $Path"}; $item=Get-Item -LiteralPath $Path -Force; if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){Fail "$Label is a reparse point: $Path"} }
function Assert-Dir([string]$Path,[string]$Label) { if(Test-Path -LiteralPath $Path){$item=Get-Item -LiteralPath $Path -Force; if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){Fail "$Label is a reparse point: $Path"}; if(-not $item.PSIsContainer){Fail "$Label is not a directory: $Path"}} }
function Assert-RootSafe {
    $full=[IO.Path]::GetFullPath($RootDir).TrimEnd('\'); $drive=[IO.Path]::GetPathRoot($full).TrimEnd('\'); if($full -eq $drive){Fail 'Refusing destructive cleanup at filesystem root.'}
    foreach($blocked in @($env:WINDIR,$env:ProgramFiles,${env:ProgramFiles(x86)},$env:ProgramData)){
        if($blocked){$resolved=(Resolve-Path -LiteralPath $blocked -ErrorAction SilentlyContinue); if($resolved){$b=$resolved.Path.TrimEnd('\'); if($full -eq $b -or $full.StartsWith($b+'\',[StringComparison]::OrdinalIgnoreCase)){Fail "Project root is under a protected system path: $full"}}}
    }
    if([IO.Path]::GetFullPath($BuildDir) -ne [IO.Path]::GetFullPath((Join-Path $RootDir 'build')) -or [IO.Path]::GetFullPath($ReleaseDir) -ne [IO.Path]::GetFullPath((Join-Path $RootDir 'release'))){Fail 'Build/release path contract violated.'}
}
function Assert-NoReparseAncestors([string]$Path,[string]$Label) {
    $full=[IO.Path]::GetFullPath($Path)
    $current=New-Object IO.DirectoryInfo $full
    while($true){
        if(Test-Path -LiteralPath $current.FullName){
            $item=Get-Item -LiteralPath $current.FullName -Force
            if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){Fail "$Label contains a reparse-point ancestor: $($current.FullName)"}
        }
        $parent=$current.Parent
        if($null -eq $parent){break}
        $current=$parent
    }
}
function Test-PathUnder([string]$Child,[string]$Parent) {
    $c=[IO.Path]::GetFullPath($Child).TrimEnd('\'); $p=[IO.Path]::GetFullPath($Parent).TrimEnd('\')
    return $c -eq $p -or $c.StartsWith($p+'\',[StringComparison]::OrdinalIgnoreCase)
}
function Assert-ExternalOutput([string]$Path) {
    $full=[IO.Path]::GetFullPath($Path)
    Assert-NoReparseAncestors $full 'External artifact output'
    $root=[IO.Path]::GetPathRoot($full).TrimEnd('\')
    if($full.TrimEnd('\') -eq $root){Fail 'External artifact output may not be a filesystem root.'}
    foreach($blocked in @($env:WINDIR,$env:ProgramFiles,${env:ProgramFiles(x86)},$env:ProgramData)){
        if($blocked){$b=[IO.Path]::GetFullPath($blocked).TrimEnd('\'); if(Test-PathUnder $full $b){Fail "External artifact output is under protected system path: $full"}}
    }
    if(Test-PathUnder $full $RootDir){Fail "External artifact output must be outside the build project root: $full"}
    if(Test-Path -LiteralPath $full){$item=Get-Item -LiteralPath $full -Force; if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){Fail 'External artifact output is a reparse point.'}; if(-not $item.PSIsContainer){Fail 'External artifact output is not a directory.'}}
    return $full
}

function Verify-ChecksumManifest([string]$Manifest,[string]$Base) {
    Assert-File $Manifest 'checksum manifest'; $seen=@{}
    foreach($line in [IO.File]::ReadAllLines($Manifest)){
        if([string]::IsNullOrEmpty($line)){continue}; if($line.Contains("`t") -or $line.StartsWith(' ') -or $line.EndsWith(' ')){Fail "Invalid checksum manifest whitespace: $Manifest"}
        $idx=$line.IndexOf('  ',[StringComparison]::Ordinal); if($idx -lt 0){Fail "Invalid checksum manifest entry: $Manifest"}
        $digest=$line.Substring(0,$idx); $rel=$line.Substring($idx+2);
        if($digest -notmatch '^[0-9A-Fa-f]{64}$'){Fail "Invalid checksum digest: $rel"}; if([string]::IsNullOrWhiteSpace($rel) -or [IO.Path]::IsPathRooted($rel) -or $rel.Contains('\') -or $rel.Split('/') -contains '..' -or $rel.Split('/') -contains '.'){Fail "Unsafe checksum path: $rel"}
        $full=[IO.Path]::GetFullPath((Join-Path $Base ($rel -replace '/','\'))); $baseFull=([IO.Path]::GetFullPath($Base)).TrimEnd('\')+'\'; if(-not $full.StartsWith($baseFull,[StringComparison]::OrdinalIgnoreCase)){Fail "Checksum path escapes base: $rel"}; if($seen.ContainsKey($rel)){Fail "Duplicate checksum entry: $rel"}; Assert-File $full 'checksum member'; $actual=(Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant(); if($actual -ne $digest.ToLowerInvariant()){Fail "Checksum verification failed: $rel"}; $seen[$rel]=$true
    }
    if($seen.Count -eq 0){Fail "Checksum manifest is empty: $Manifest"}
}
function Get-HostArch {
    if($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64'){return 'arm64'}
    if($env:PROCESSOR_ARCHITECTURE -eq 'AMD64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'AMD64'){return 'x86_64'}
    Fail 'Unsupported Windows host architecture.'
}
function Test-PythonArchitecture([pscustomobject]$PythonInfo,[string]$Expected) {
    $actual=& $PythonInfo.Exe @($PythonInfo.Args) -c 'import platform; print(platform.machine().lower())'
    if($LASTEXITCODE -ne 0){Fail 'Unable to determine CPython architecture.'}
    $actual=($actual | Select-Object -First 1).Trim().ToLowerInvariant()
    if($actual -eq 'amd64'){$actual='x86_64'} elseif($actual -eq 'aarch64'){$actual='arm64'}
    if($actual -ne $Expected){Fail "CPython architecture mismatch: expected=$Expected actual=$actual"}
}
function Resolve-Python312 {
    $expected=Get-HostArch
    $py=Get-Command py -ErrorAction SilentlyContinue
    if($py){& $py.Source -3.12 -c 'import sys; raise SystemExit(0 if sys.implementation.name=="cpython" and sys.version_info[:2]==(3,12) else 1)' 2>$null; if($LASTEXITCODE -eq 0){$info=[pscustomobject]@{Exe=$py.Source;Args=@("-3.12")}; Test-PythonArchitecture $info $expected; return $info}}
    $python=Get-Command python -ErrorAction SilentlyContinue
    if($python){& $python.Source -c 'import sys; raise SystemExit(0 if sys.implementation.name=="cpython" and sys.version_info[:2]==(3,12) else 1)' 2>$null; if($LASTEXITCODE -eq 0){$info=[pscustomobject]@{Exe=$python.Source;Args=@()}; Test-PythonArchitecture $info $expected; return $info}}
    return $null
}


function Is-Administrator { $id=[Security.Principal.WindowsIdentity]::GetCurrent(); $p=New-Object Security.Principal.WindowsPrincipal($id); return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Find-Msvc([string]$Arch) {
    $vswherePaths=@()
    if(${env:ProgramFiles(x86)}){$vswherePaths += Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'}
    if($env:ProgramFiles){$vswherePaths += Join-Path $env:ProgramFiles 'Microsoft Visual Studio\Installer\vswhere.exe'}
    foreach($vswhere in $vswherePaths){
        if(-not(Test-Path $vswhere)){continue}
        $installs=& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.CoreBuildTools -property installationPath 2>$null
        foreach($install in @($installs)){
            if(-not $install){continue}
            $base=Join-Path $install 'VC\Tools\MSVC'
            if(-not(Test-Path $base)){continue}
            $wanted=if($Arch -eq 'x86_64'){@('Hostx64\x64\cl.exe')}else{@('Hostarm64\arm64\cl.exe','Hostx64\arm64\cl.exe')}
            foreach($suffix in $wanted){$found=Get-ChildItem -LiteralPath $base -Filter cl.exe -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.FullName.EndsWith('\'+$suffix,[StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1; if($found){return $found.FullName}}
        }
    }
    return ''
}
function Ensure-Msvc([string]$Arch) {
    $cl=Find-Msvc $Arch; if($cl){return $cl}
    Confirm-Action "MSVC C++ Build Tools are missing for Windows $Arch. Install with winget?" $AutoSystem
    if(-not(Is-Administrator)){Fail 'Administrator elevation is required for Visual Studio Build Tools installation.'}
    $winget=Get-Command winget -ErrorAction SilentlyContinue; if(-not $winget){Fail 'winget is required for automatic MSVC installation.'}
    & $winget.Source install --id Microsoft.VisualStudio.2022.BuildTools --exact --accept-source-agreements --accept-package-agreements --override '--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'
    if($LASTEXITCODE -notin @(0,3010)){Fail "winget failed with exit code $LASTEXITCODE."}
    $cl=Find-Msvc $Arch; if(-not $cl){Fail "MSVC toolchain for $Arch remains unavailable."}; return $cl
}
function Create-Venv([pscustomobject]$PythonInfo,[string]$Venv,[string]$TargetDir,[string]$Target) {
    Confirm-Action 'Create temporary CPython 3.12 virtualenv and install pinned build dependencies?' $AutoPip
    if(Test-Path $Venv){Remove-Item -LiteralPath $Venv -Recurse -Force}
    & $PythonInfo.Exe @($PythonInfo.Args) -m venv $Venv
    if($LASTEXITCODE -ne 0){Fail 'CPython venv creation failed.'}
    $vpy=Join-Path $Venv 'Scripts\python.exe'; Assert-File $vpy 'venv Python'
    $env:PIP_CONFIG_FILE='NUL'; $env:PIP_EXTRA_INDEX_URL=''; $env:PIP_FIND_LINKS=''; $env:PIP_NO_INDEX='0'; $env:PIP_TRUSTED_HOST=$null; $env:PIP_CERT=$null; $env:PIP_CLIENT_CERT=$null; $env:PIP_CLIENT_KEY=$null; $env:PIP_USER=$null; $env:PIP_GLOBAL_OPTION=$null; $env:PIP_PRE=$null; $env:PIP_ONLY_BINARY=$null; $env:PIP_NO_BINARY=$null; $env:PIP_PREFER_BINARY=$null; $env:PIP_USE_PEP517=$null; $env:PIP_REQUIRE_HASHES=$null; $env:PIP_DISABLE_PIP_VERSION_CHECK='1'; $env:PIP_NO_CACHE_DIR='1'; $env:PIP_REQUIRE_VIRTUALENV='1'
$env:PIP_INDEX_URL=if($env:NEXS_PIP_INDEX_URL){$env:NEXS_PIP_INDEX_URL}else{'https://pypi.org/simple'}; $env:PYTHONHASHSEED='0'; $env:PYTHONDONTWRITEBYTECODE='1'
    if(-not $env:PIP_INDEX_URL.StartsWith('https://',[StringComparison]::OrdinalIgnoreCase)){Fail 'PIP_INDEX_URL must use HTTPS.'}
    if($env:PIP_INDEX_URL -ne 'https://pypi.org/simple' -and $env:NEXS_ALLOW_CUSTOM_PIP_INDEX -ne '1'){Fail 'Custom PIP index is disabled by default; set NEXS_ALLOW_CUSTOM_PIP_INDEX=1 only for an explicitly trusted mirror.'}
    $wheelhouse=Join-Path $Venv 'wheelhouse'; if(Test-Path $wheelhouse){Remove-Item $wheelhouse -Recurse -Force}; New-Item -ItemType Directory -Force -Path $wheelhouse|Out-Null
    $requirementsHashBefore=(Get-FileHash -LiteralPath $ReqFile -Algorithm SHA256).Hash.ToLowerInvariant()
    $wheelReq=Join-Path $Venv 'wheel-requirements.txt'
    $rows=Get-Content -LiteralPath $ReqFile | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') -and $_.Trim() -notmatch '^Nuitka=='}
    [IO.File]::WriteAllLines($wheelReq,$rows,[Text.UTF8Encoding]::new($false))
    & $vpy -m pip download --disable-pip-version-check --no-input --no-cache-dir --only-binary=:all: --no-deps --dest $wheelhouse -r $wheelReq; if($LASTEXITCODE -ne 0){Fail 'Pinned dependency wheel download failed.'}
    & $vpy -m pip download --disable-pip-version-check --no-input --no-cache-dir --no-binary=:all: --no-deps --dest $wheelhouse "Nuitka==$NuitkaVersion"; if($LASTEXITCODE -ne 0){Fail 'Trusted Nuitka source download failed.'}
    & $vpy $Core catalogue-dependencies --wheelhouse $wheelhouse --requirements $ReqFile --output (Join-Path $TargetDir 'BUILD_DEPENDENCY_CATALOGUE.json') --target $Target; if($LASTEXITCODE -ne 0){Fail 'Dependency artifact catalogue verification failed.'}
    $lockFile=Join-Path $TargetDir 'BUILD_DEPENDENCY_LOCK.txt'
    & $vpy $Core emit-hashed-requirements --catalogue (Join-Path $TargetDir 'BUILD_DEPENDENCY_CATALOGUE.json') --requirements $ReqFile --output $lockFile --target $Target; if($LASTEXITCODE -ne 0){Fail 'Hash-locked requirement generation failed.'}
    $requirementsHashAfter=(Get-FileHash -LiteralPath $ReqFile -Algorithm SHA256).Hash.ToLowerInvariant(); if($requirementsHashBefore -ne $requirementsHashAfter){Fail 'Build requirements changed during wheel acquisition.'}
    $depcat=Get-Content -LiteralPath (Join-Path $TargetDir 'BUILD_DEPENDENCY_CATALOGUE.json') -Raw | ConvertFrom-Json
    $setuptoolsArtifact=@($depcat.artifacts | Where-Object normalized_package -eq 'setuptools'); if($setuptoolsArtifact.Count -ne 1){Fail 'Setuptools artifact missing from dependency catalogue.'}
    $setuptoolsLock=Join-Path $TargetDir 'SETUPTOOLS_LOCK.txt'; [IO.File]::WriteAllText($setuptoolsLock,"setuptools==$SetuptoolsVersion --hash=sha256:$($setuptoolsArtifact[0].sha256)`n",[Text.UTF8Encoding]::new($false))
    & $vpy -m pip install --disable-pip-version-check --no-input --no-index --find-links $wheelhouse --require-hashes --no-deps -r $setuptoolsLock; if($LASTEXITCODE -ne 0){Fail 'Pinned setuptools bootstrap installation failed.'}
    & $vpy -m pip install --disable-pip-version-check --no-input --no-index --find-links $wheelhouse --no-build-isolation --no-deps --require-hashes -r $lockFile; if($LASTEXITCODE -ne 0){Fail 'Pinned dependency installation from verified artifacts failed.'}
    Remove-Item $wheelhouse,$wheelReq,$lockFile,$setuptoolsLock -Recurse -Force
    if($LASTEXITCODE -ne 0){Fail 'Pinned dependency installation failed.'}
    & $vpy -m pip check; if($LASTEXITCODE -ne 0){Fail 'pip check failed.'}
    $check="import cffi,cryptography,nuitka.Version,ordered_set,pycparser,setuptools,sys; from importlib.metadata import version as _pkg_version; argon2_version=_pkg_version('argon2-cffi'); e=((3,12),'$NuitkaVersion','$CryptoVersion','$CffiVersion','$PycparserVersion','$OrderedSetVersion','$SetuptoolsVersion','$Argon2Version'); a=(sys.version_info[:2],nuitka.Version.getNuitkaVersion(),cryptography.__version__,cffi.__version__,pycparser.__version__,ordered_set.__version__,setuptools.__version__,argon2_version); raise SystemExit(0 if a==e else 'dependency mismatch: expected=%r actual=%r'%(e,a))"
    & $vpy -c $check; if($LASTEXITCODE -ne 0){Fail 'Dependency version verification failed.'}; return $vpy
}
function New-Provenance([string]$Target,[string]$Vpy,[string]$Package,[string]$Cl,[string]$DependencyCatalogue) {
    $prov=[ordered]@{
        schema=1; builder='nexs_build_release.ps1'; target=$Target; release_version=$Version; source_date_epoch=[Int64]$env:SOURCE_DATE_EPOCH
        python=[ordered]@{version=(& $Vpy -c 'import platform; print(platform.python_version())'); implementation='CPython'; executable_sha256=(Get-FileHash -LiteralPath $Vpy -Algorithm SHA256).Hash.ToLowerInvariant()}
        host=[ordered]@{os='windows'; arch=if($Target -eq 'windows-arm64'){'arm64'}else{'x86_64'}; libc='ucrt-msvc'}
        compiler=[ordered]@{path=$Cl; version=((& $Cl '--version' 2>$null | Select-Object -First 1).ToString().Trim()); sha256=(Get-FileHash -LiteralPath $Cl -Algorithm SHA256).Hash.ToLowerInvariant()}
        dependency_catalogue=[ordered]@{path=(Split-Path -Leaf $DependencyCatalogue); sha256=(Get-FileHash -LiteralPath $DependencyCatalogue -Algorithm SHA256).Hash.ToLowerInvariant()}
        container=$null
    }
    $path=Join-Path $Package 'BUILD_PROVENANCE.json'; [IO.File]::WriteAllText($path, ($prov|ConvertTo-Json -Depth 10 -Compress), [Text.UTF8Encoding]::new($false)); return $path
}
function Build-Target([string]$T,[pscustomobject]$PythonInfo) {
    $arch=if($T -eq 'windows-arm64'){'arm64'}else{'x86_64'}; $cl=Ensure-Msvc $arch
    $hostArch=Get-HostArch; if($hostArch -ne $arch){Fail "Target $T requires matching native Windows architecture; host=$hostArch."}
    Test-PythonArchitecture $PythonInfo $arch
    $targetDir=Join-Path $BuildDir $T; $srcDir=Join-Path $targetDir 'source'; $outDir=Join-Path $targetDir 'nuitka'; $venv=Join-Path $targetDir 'venv'; $package=Join-Path $targetDir 'package'; New-Item -ItemType Directory -Force -Path $srcDir,$outDir|Out-Null
    & $PythonInfo.Exe @($PythonInfo.Args) $Core prepare-source --source $SourceFile --output (Join-Path $srcDir 'main.py'); if($LASTEXITCODE -ne 0){Fail 'Source preparation failed.'}
    Copy-Item -LiteralPath $SourceFile -Destination (Join-Path $srcDir 'original_main.py') -Force
    Copy-Item -LiteralPath $TestFile -Destination (Join-Path $srcDir 'original_test.py') -Force
    $vpy=Create-Venv $PythonInfo $venv $targetDir $T
    & $vpy (Join-Path $srcDir 'main.py') --self-test; if($LASTEXITCODE -ne 0){Fail "$T pre-build self-test failed."}
    Log "Compiling $T with $BuildJobs parallel job(s)."
    & $vpy -m nuitka --mode=standalone --output-dir=$outDir --output-filename=nexs_ledger "--jobs=$BuildJobs" --python-flag=isolated --follow-imports --product-name=Nexs-Scratch-System --file-description='Nexs-Scratch-System signed ledger' --file-version=$Version --product-version=$Version --report=(Join-Path $outDir 'compilation-report.xml') --include-data-files="$(Join-Path $srcDir 'original_main.py')=main.py" --include-data-files="$(Join-Path $srcDir 'original_test.py')=test.py" (Join-Path $srcDir 'main.py'); if($LASTEXITCODE -ne 0){Fail "$T Nuitka build failed."}
    $dist=Join-Path $outDir 'main.dist'; if(-not(Test-Path $dist -PathType Container)){Fail 'Nuitka .dist directory missing.'}; if(Test-Path $package){Remove-Item $package -Recurse -Force}; Move-Item -LiteralPath $dist -Destination $package
    $exe=Join-Path $package 'nexs_ledger.exe'; Assert-File $exe 'nexs_ledger.exe'; Assert-File (Join-Path $package 'test.py') 'packaged test.py'; New-Item -ItemType Directory -Force -Path (Join-Path $package 'external'),(Join-Path $package 'extensions')|Out-Null; Copy-Item -LiteralPath (Join-Path $targetDir 'BUILD_DEPENDENCY_CATALOGUE.json') -Destination (Join-Path $package 'BUILD_DEPENDENCY_CATALOGUE.json') -Force
    # A single compiled binary is produced and verified once; there used to be a
    # second "test_ledger.exe" that was nothing but a byte-for-byte copy of this
    # same binary, run through --self-test a second time for no benefit. test.py
    # is packaged alongside the binary as plain, uncompiled data (see the
    # --include-data-files entry above; it is never fed to Nuitka together with
    # main.py) and, in its --binary mode, drives the compiled artifact's own
    # --self-test/--build-identity entry points out-of-process.
    & $vpy (Join-Path $srcDir 'original_test.py') --binary $exe --source (Join-Path $srcDir 'original_main.py'); if($LASTEXITCODE -ne 0){Fail 'Compiled-binary verification failed.'}
    # -------------------------------------------------------------------
    # BEGIN: portable safe-path wrapper (added fix)
    #
    # The extracted release directory is a Nuitka --standalone drop: it
    # contains a full CPython 3.12 runtime next to test.py and the
    # compiled nexs_ledger.exe launcher. CPython prepends the script's
    # own directory to sys.path[0], so a user who cd's into the
    # extracted directory and runs the system python (a different minor
    # version, e.g. a separately-installed 3.13) would dlopen the
    # bundle's CPython 3.12 native extension modules against a
    # mismatched interpreter and crash with missing-symbol errors.
    # test.py now refuses to run in that state (see its top-of-file
    # guard); this generated wrapper performs the correct invocation
    # for the user, so the released artifact is self-serviceable
    # without needing to read this script's source.
    #
    # run-test.cmd (not .ps1) is generated deliberately: it runs from
    # cmd.exe, Windows PowerShell 5.1, PowerShell 7+ and any other
    # Windows shell without hitting the default "Restricted" /
    # "RemoteSigned" execution-policy wall that would block a .ps1
    # wrapper on a freshly extracted archive. The file is written with
    # CRLF line endings and no BOM, which is what every Windows shell
    # expects from a .cmd file. The env var name used is
    # PYTHONSAFEPATH, honoured by CPython 3.11+ on every platform; the
    # wrapper does not fall back to invoking python without it, since
    # that would defeat the entire point of the guard.
    # -------------------------------------------------------------------
    $runTestLines = @(
        '@echo off',
        'setlocal',
        'cd /d "%~dp0"',
        'if not defined PYTHON set "PYTHON=python"',
        'set "PYTHONSAFEPATH=1"',
        '"%PYTHON%" .\test.py --binary .\nexs_ledger.exe --source .\main.py %*',
        'exit /b %ERRORLEVEL%'
    )
    $runTestCmdPath = Join-Path $package 'run-test.cmd'
    [IO.File]::WriteAllText($runTestCmdPath, (($runTestLines -join "`r`n") + "`r`n"), [Text.UTF8Encoding]::new($false))
    # -------------------------------------------------------------------
    # END: portable safe-path wrapper
    # -------------------------------------------------------------------
    $identity=Join-Path $targetDir 'internal_identity.json'; [IO.File]::WriteAllText($identity, (& $exe --build-identity | Out-String).TrimEnd(), [Text.UTF8Encoding]::new($false)); if($LASTEXITCODE -ne 0){Fail 'Unable to obtain compiled runtime identity.'}
    $sourceHash=(Get-FileHash -LiteralPath (Join-Path $srcDir 'original_main.py') -Algorithm SHA256).Hash.ToLowerInvariant(); $internal=Get-Content -LiteralPath $identity -Raw|ConvertFrom-Json; if($internal.program_hash.ToLowerInvariant() -ne $sourceHash){Fail 'Compiled program identity does not match source hash.'}
    $prov=New-Provenance $T $vpy $package $cl (Join-Path $targetDir 'BUILD_DEPENDENCY_CATALOGUE.json')
    & $vpy $Core catalogue-package --package $package --target $T --version $Version --source (Join-Path $srcDir 'original_main.py') --identity $identity --provenance $prov; if($LASTEXITCODE -ne 0){Fail 'Binary catalogue generation failed.'}
    & $vpy $Core archive-package --package $package --target $T --version $Version --output-dir $targetDir|Out-Null; if($LASTEXITCODE -ne 0){Fail 'Archive generation failed.'}
    $archive=Join-Path $targetDir "$T-$Version.zip"; Assert-File $archive 'target archive'; & $vpy $Core verify-archive --archive $archive --target $T --version $Version; if($LASTEXITCODE -ne 0){Fail 'Target archive verification failed.'}
}
function Main {
    Assert-RootSafe; $script:SourceFile=(Resolve-Path -LiteralPath $SourceFile).Path; Assert-File $SourceFile 'source'; Assert-File $TestFile 'test source'; Assert-File $ReqFile 'requirements'; Assert-File $Core 'build core'; Assert-File $Checksums 'build-tool checksum catalogue'; Assert-File $KitChecksums 'build-kit checksum catalogue'
    if((Test-Path -LiteralPath $BuildDir) -and ((Get-Item -LiteralPath $BuildDir -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){Fail 'Build directory is a reparse point.'}
    if((Test-Path -LiteralPath $ReleaseDir) -and ((Get-Item -LiteralPath $ReleaseDir -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){Fail 'Release directory is a reparse point.'}
    if(Test-PathUnder $SourceFile $BuildDir -or Test-PathUnder $SourceFile $ReleaseDir){Fail 'Source may not reside under ./build or ./release.'}; if(Test-PathUnder $TestFile $BuildDir -or Test-PathUnder $TestFile $ReleaseDir){Fail 'Test source may not reside under ./build or ./release.'}
    Verify-ChecksumManifest $KitChecksums $RootDir
    $global:PythonInfo=Resolve-Python312; if(-not $PythonInfo){Fail 'CPython 3.12 is required on Windows.'}
    & $PythonInfo.Exe @($PythonInfo.Args) $Core audit-kit --root $RootDir --checksums $KitChecksums; if($LASTEXITCODE -ne 0){Fail 'Build-kit integrity check failed.'}
    & $PythonInfo.Exe @($PythonInfo.Args) $Core audit-tools --tools-dir $ScriptDir --checksums $Checksums; if($LASTEXITCODE -ne 0){Fail 'Build-tool integrity check failed.'}
    # test.py below imports main.py directly. Rather than trusting whatever
    # interpreter Resolve-Python312 found, delegate to the project's own
    # development-environment manager: it creates/reuses a dedicated venv at
    # .\.venv (fully separate from the disposable venv Create-Venv builds
    # later for the Nuitka compile step) and makes sure the runtime
    # dependencies are importable there.
    $devEnvScript = Join-Path $RootDir 'setup_env.ps1'
    Assert-File $devEnvScript 'development environment script'
    & $devEnvScript; if($LASTEXITCODE -ne 0){Fail 'Development environment setup failed.'}
    $devVenvDir = if($env:NEXS_DEV_VENV_DIR){$env:NEXS_DEV_VENV_DIR}else{Join-Path $RootDir '.venv'}
    $devVenvPy = Join-Path $devVenvDir 'Scripts\python.exe'
    Assert-File $devVenvPy 'development virtualenv python'
    $testPythonInfo = [pscustomobject]@{ Exe = $devVenvPy; Args = @() }
    & $testPythonInfo.Exe @($testPythonInfo.Args) $TestFile; if($LASTEXITCODE -ne 0){Fail 'Build/test source verification failed.'}
    if(Test-Path -LiteralPath $BuildDir){Remove-Item -LiteralPath $BuildDir -Recurse -Force -ErrorAction Stop}; New-Item -ItemType Directory -Force -Path $BuildDir,(Join-Path $BuildDir '.tmp')|Out-Null; $env:NUITKA_CACHE_DIR=Join-Path $BuildDir '.tmp\nuitka-cache'; $env:NUITKA_CACHE_DIR_DOWNLOADS=Join-Path $BuildDir '.tmp\nuitka-downloads'; $env:NUITKA_CACHE_DIR_CCACHE=Join-Path $BuildDir '.tmp\nuitka-ccache'; $env:NUITKA_CACHE_DIR_CLCACHE=Join-Path $BuildDir '.tmp\nuitka-clcache'; $env:NUITKA_CACHE_DIR_BYTECODE=Join-Path $BuildDir '.tmp\nuitka-bytecode'; $env:NUITKA_CACHE_DIR_DLL_DEPENDENCIES=Join-Path $BuildDir '.tmp\nuitka-dll-dependencies'
    try {
        foreach($t in $Targets){Build-Target $t $PythonInfo}
        & $PythonInfo.Exe @($PythonInfo.Args) $Core audit-kit --root $RootDir --checksums $KitChecksums; if($LASTEXITCODE -ne 0){Fail 'Build-kit integrity changed during the build.'}
        & $PythonInfo.Exe @($PythonInfo.Args) $Core audit-tools --tools-dir $ScriptDir --checksums $Checksums; if($LASTEXITCODE -ne 0){Fail 'Build-tool integrity changed during the build.'}
        if($ArtifactOut){
            $ArtifactOut=Assert-ExternalOutput $ArtifactOut
            if(Test-Path -LiteralPath $ArtifactOut){Remove-Item -LiteralPath $ArtifactOut -Recurse -Force}; New-Item -ItemType Directory -Force -Path $ArtifactOut|Out-Null
            foreach($t in $Targets){Copy-Item -LiteralPath (Join-Path $BuildDir "$t\$t-$Version.zip") -Destination $ArtifactOut -Force}
            return
        }
        if($NoPublish){return}
        $stage=Join-Path $BuildDir 'release-stage'; New-Item -ItemType Directory -Force -Path $stage|Out-Null
        foreach($t in $Targets){Copy-Item -LiteralPath (Join-Path $BuildDir "$t\package") -Destination (Join-Path $stage $t) -Recurse -Force}
        # assemble-release writes UNVERSIONED catalogue filenames into $stage
        # (RELEASE_CATALOGUE.json, not RELEASE_CATALOGUE-$Version.json). The
        # version suffix only appears after the Move-Item calls below, into
        # $ReleaseDir. verify-release always expects the versioned filenames,
        # so calling it against $stage here is a guaranteed failure -- it
        # would abort even a fully successful, fully verified build. There is
        # exactly one verification pass, below, against the final filenames.
        & $PythonInfo.Exe @($PythonInfo.Args) $Core assemble-release --stage $stage --version $Version|Out-Null; if($LASTEXITCODE -ne 0){Fail 'Release assembly failed.'}
        New-Item -ItemType Directory -Force -Path $ReleaseDir|Out-Null
        $names=@("RELEASE_CATALOGUE-$Version.json","BINARY_HASH_CATALOGUE-$Version.json","SHA256SUMS-$Version"); foreach($n in $names){if(Test-Path (Join-Path $ReleaseDir $n)){Fail "Release already exists: $n"}}
        Get-ChildItem -LiteralPath $stage -File|Where-Object{$_.Name -like "*$Version.zip"}|ForEach-Object{$dst=Join-Path $ReleaseDir $_.Name; if(Test-Path -LiteralPath $dst){Fail "Release archive already exists: $($_.Name)"}; Move-Item -LiteralPath $_.FullName -Destination $dst}
        Move-Item (Join-Path $stage 'RELEASE_CATALOGUE.json') (Join-Path $ReleaseDir "RELEASE_CATALOGUE-$Version.json"); Move-Item (Join-Path $stage 'BINARY_HASH_CATALOGUE.json') (Join-Path $ReleaseDir "BINARY_HASH_CATALOGUE-$Version.json"); Move-Item (Join-Path $stage 'SHA256SUMS') (Join-Path $ReleaseDir "SHA256SUMS-$Version")
        # --require-all is deliberately NOT passed here: this script only
        # ever builds Windows targets (windows-x86_64/windows-arm64), and a
        # local publish covers only the target(s) actually requested/built,
        # exactly like build_release.sh. --require-all is reserved for the
        # CI "assemble" job, which gathers verified archives from every OS
        # runner in the matrix (see nexs_build_core.py assemble-archives).
        # Passing it here would make even a perfect single-target Windows
        # build fail, because it demands macOS/Linux archives this script
        # never produces.
        & $PythonInfo.Exe @($PythonInfo.Args) $Core verify-release --release $ReleaseDir --version $Version; if($LASTEXITCODE -ne 0){Fail 'Published release verification failed.'}
        Log "Release $Version published and verified."
    } finally { if(-not $env:NEXS_KEEP_BUILD -or $env:NEXS_KEEP_BUILD -ne '1'){ if(Test-Path -LiteralPath $BuildDir){Remove-Item -LiteralPath $BuildDir -Recurse -Force -ErrorAction Stop}; if(Test-Path -LiteralPath $BuildDir){Fail 'Build directory cleanup did not complete.'} } }
}
$Targets=if($HostOnly -or -not $Target){if($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64'){@('windows-arm64')}else{@('windows-x86_64')}}else{@($Target)}
Main