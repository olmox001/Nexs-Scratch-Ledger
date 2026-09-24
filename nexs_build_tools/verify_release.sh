#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077
export LC_ALL=C
export LANG=C
export PYTHONDONTWRITEBYTECODE=1
export PYTHONHASHSEED=0
export PYTHONNOUSERSITE=1
export PYTHONSAFEPATH=1
unset PYTHONHOME PYTHONPATH PYTHONSTARTUP PYTHONUSERBASE PYTHONINSPECT PYTHONBREAKPOINT PYTHONOPTIMIZE PYTHONDEBUG \
  CC CXX CFLAGS CXXFLAGS CPPFLAGS LDFLAGS AR AS LD RANLIB STRIP OBJC SDKROOT MACOSX_DEPLOYMENT_TARGET \
  PIP_FIND_LINKS PIP_EXTRA_INDEX_URL PIP_NO_INDEX PIP_TRUSTED_HOST PIP_CERT PIP_CLIENT_CERT PIP_CLIENT_KEY \
  PIP_USER PIP_GLOBAL_OPTION PIP_PRE PIP_ONLY_BINARY PIP_NO_BINARY PIP_PREFER_BINARY PIP_USE_PEP517 \
  PIP_REQUIRE_HASHES || true
log() { printf '[nexs-build] %s\n' "$*"; }
die() { printf '[nexs-build][ERROR] %s\n' "$*" >&2; exit 1; }
warn() { printf '[nexs-build][WARN] %s\n' "$*" >&2; }

SOURCE_DATE_EPOCH="${NEXS_SOURCE_DATE_EPOCH:-0}"
[[ "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]] || die "NEXS_SOURCE_DATE_EPOCH must be a non-negative integer."
export SOURCE_DATE_EPOCH

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="${NEXS_ROOT_DIR:-$(cd -- "$SCRIPT_DIR/.." && pwd -P)}"
ROOT_DIR="$(cd -- "$ROOT_DIR" && pwd -P)"
SOURCE_FILE="${NEXS_SOURCE_FILE:-$ROOT_DIR/main.py}"
TEST_FILE="${NEXS_TEST_FILE:-$ROOT_DIR/test.py}"
BUILD_DIR="${NEXS_BUILD_DIR:-$ROOT_DIR/build}"
RELEASE_DIR="${NEXS_RELEASE_DIR:-$ROOT_DIR/release}"
REQ_FILE="$SCRIPT_DIR/requirements-build.txt"
CORE="$SCRIPT_DIR/nexs_build_core.py"
TOOL_CHECKSUMS="$SCRIPT_DIR/BUILD_TOOLS_SHA256SUMS"
KIT_CHECKSUMS="$ROOT_DIR/BUILD_KIT_SHA256SUMS"

PYTHON_MAJOR=3
PYTHON_MINOR=12
NUITKA_VERSION="4.2.2"
CRYPTOGRAPHY_VERSION="48.0.1"
CFFI_VERSION="2.1.1"
PYCPARSER_VERSION="2.23"
ORDERED_SET_VERSION="4.1.0"
SETUPTOOLS_VERSION="83.0.0"
ARGON2_CFFI_VERSION="23.1.0"
ARGON2_CFFI_BINDINGS_VERSION="21.2.0"

ALL_TARGETS=(
  "macos-x86_64" "macos-arm64"
  "linux-x86_64" "linux-aarch64"
  "linux-musl-x86_64" "linux-musl-aarch64"
  "windows-x86_64" "windows-arm64"
)

VERSION=""
TARGETS=()
SOURCE_OVERRIDE=""
AUTO_ACCEPT_SYSTEM="${NEXS_AUTO_ACCEPT_SYSTEM:-0}"
AUTO_ACCEPT_PIP="${NEXS_AUTO_ACCEPT_PIP:-0}"
AUTO_ACCEPT_CONTAINER="${NEXS_AUTO_ACCEPT_CONTAINER:-0}"
AUTO_ACCEPT_OVERWRITE="${NEXS_AUTO_ACCEPT_OVERWRITE:-0}"
REQUIRE_PINNED_IMAGE="${NEXS_REQUIRE_PINNED_IMAGE:-1}"
KEEP_BUILD="${NEXS_KEEP_BUILD:-0}"
NO_PUBLISH="${NEXS_NO_PUBLISH:-0}"
IN_CONTAINER="${NEXS_CONTAINER_TARGET_ONLY:-0}"
ALLOW_RELEASE_OVERWRITE="${NEXS_ALLOW_RELEASE_OVERWRITE:-0}"

for value_name in AUTO_ACCEPT_SYSTEM AUTO_ACCEPT_PIP AUTO_ACCEPT_CONTAINER AUTO_ACCEPT_OVERWRITE REQUIRE_PINNED_IMAGE KEEP_BUILD NO_PUBLISH IN_CONTAINER ALLOW_RELEASE_OVERWRITE; do
  value="${!value_name:-0}"
  [[ "$value" == 0 || "$value" == 1 ]] || die "$value_name must be 0 or 1."
done

usage() {
  cat <<'EOF'
Usage:
  build_release.sh -V 0.0.1.0 -t linux-x86_64
  build_release.sh -V 0.0.1.0 --host-only

Targets:
  macos-x86_64       macOS Intel 64-bit
  macos-arm64        macOS Apple Silicon 64-bit
  linux-x86_64       Linux glibc x86-64
  linux-aarch64      Linux glibc ARM64
  linux-musl-x86_64  Linux musl x86-64
  linux-musl-aarch64 Linux musl ARM64
  windows-x86_64     Windows x86-64 (PowerShell builder)
  windows-arm64      Windows ARM64 (PowerShell builder)

Options:
  -V, --version VERSION   Required N.N.N.N release version.
  -t, --target TARGET     Build one target; repeatable.
  --host-only             Build the host's matching native target.
  -s, --source FILE       Source override.
  --allow-overwrite       Deliberately replace an already-published release
                          of the same VERSION instead of refusing. Off by
                          default; asks for interactive confirmation unless
                          NEXS_AUTO_ACCEPT_OVERWRITE=1 is also set.
  -h, --help              Show help.

A POSIX host never fabricates a Windows executable. Linux cross-architecture
and musl builds use isolated Docker/Podman target environments.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -V|--version) [[ $# -ge 2 ]] || die "$1 requires a value."; VERSION="$2"; shift 2 ;;
    -t|--target) [[ $# -ge 2 ]] || die "$1 requires a value."; TARGETS+=("$2"); shift 2 ;;
    --host-only) TARGETS=("__HOST_ONLY__"); shift ;;
    -s|--source) [[ $# -ge 2 ]] || die "$1 requires a value."; SOURCE_OVERRIDE="$2"; shift 2 ;;
    --allow-overwrite) ALLOW_RELEASE_OVERWRITE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done
[[ -n "$VERSION" ]] || die "Release version is required (-V N.N.N.N)."
[[ -z "$SOURCE_OVERRIDE" ]] || SOURCE_FILE="$SOURCE_OVERRIDE"

require_regular() {
  local path="$1" label="$2"
  [[ -f "$path" && ! -L "$path" ]] || die "$label is missing, not regular, or a symlink: $path"
}
require_directory() {
  local path="$1" label="$2"
  [[ ! -L "$path" ]] || die "$label is a symlink: $path"
  [[ -d "$path" ]] || die "$label is missing or not a directory: $path"
}

# A venv's bin/python is *expected* to be a symlink (or symlink chain) by
# design across every Python distribution ("python -m venv" never copies the
# interpreter unless --copies is passed). require_regular() would reject that
# unconditionally and break on every stock macOS/Linux venv. What actually
# matters for supply-chain safety here is not "is this a plain file" but:
#   1. the venv directory itself is not a symlink (checked separately by the
#      caller via VENV_DIR handling in setup_env.sh),
#   2. the symlink chain terminates (no dangling/broken link, no loop),
#   3. it resolves to a real, executable regular file,
#   4. that real file lives under a plausible Python installation prefix
#      (the venv itself, or a system/Homebrew/pyenv-style location) rather
#      than somewhere arbitrary an attacker dropped a payload (e.g. /tmp,
#      a world-writable dir, or inside the project's own working tree
#      outside the venv).
require_venv_python() {
  local path="$1" label="$2" resolved
  [[ -e "$path" || -L "$path" ]] || die "$label is missing: $path"
  resolved="$(readlink -f -- "$path" 2>/dev/null || true)"
  if [[ -z "$resolved" ]]; then
    # readlink -f is a GNU extension; macOS/BSD readlink lacks -f in some
    # versions, so fall back to Python's os.path.realpath for portability.
    resolved="$(command -v python3 || command -v python || true)"
    [[ -n "$resolved" ]] || die "No Python interpreter available to resolve symlinks for: $path"
    resolved="$("$resolved" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$path")"
  fi
  [[ -n "$resolved" ]] || die "$label symlink is broken or unresolvable: $path"
  [[ -e "$resolved" ]] || die "$label resolves to a nonexistent target: $path -> $resolved"
  [[ -f "$resolved" && ! -d "$resolved" ]] || die "$label does not resolve to a regular file: $path -> $resolved"
  [[ -x "$resolved" ]] || die "$label resolves to a non-executable file: $path -> $resolved"
  # Reject resolution into obviously unsafe/world-writable shared locations.
  case "$resolved" in
    /tmp/*|/var/tmp/*|/dev/shm/*|/tmp|/var/tmp|/dev/shm)
      die "$label resolves into an unsafe shared temp location: $path -> $resolved" ;;
  esac
  printf '%s\n' "$resolved"
}

path_is_under_or_equal() {
  local child="$1" parent="$2"
  [[ "$child" == "$parent" || "$child" == "$parent"/* ]]
}

assert_safe_external_output() {
  local path="$1" parent base current
  parent="$(dirname -- "$path")"
  base="$(basename -- "$path")"
  current="$parent"
  while [[ ! -e "$current" ]]; do
    local next
    next="$(dirname -- "$current")"
    [[ "$next" != "$current" ]] || break
    current="$next"
  done
  while :; do
    [[ ! -L "$current" ]] || die "External output ancestor is a symlink: $current"
    [[ -d "$current" ]] || die "External output ancestor is not a directory: $current"
    [[ "$current" == "/" ]] && break
    current="$(dirname -- "$current")"
  done
  path="$(cd -- "$parent" && pwd -P)/$base"
  case "$path" in
    /|/usr|/usr/*|/etc|/etc/*|/var|/var/*|/bin|/bin/*|/sbin|/sbin/*|/lib|/lib/*|/lib64|/lib64/*|/opt|/opt/*|/tmp|/tmp/*|/home|/home/*) die "Unsafe external output path: $path" ;;
  esac
  path_is_under_or_equal "$path" "$ROOT_DIR" && die "External output must not be inside the build project root: $path"
  [[ -L "$path" ]] && die "External output is a symlink: $path"
}

verify_checksum_manifest_independent() {
  local manifest="$1" base="$2" line digest rel count=0 resolved expected
  require_regular "$manifest" "checksum manifest"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    [[ "$line" != *$'\t'* && "$line" != " "* && "$line" != *" " ]] || die "Invalid checksum manifest whitespace: $manifest"
    digest="${line%%  *}"
    rel="${line#*  }"
    [[ "$digest" =~ ^[0-9a-fA-F]{64}$ ]] || die "Invalid SHA-256 in checksum manifest: $manifest"
    [[ "$rel" != "$line" && -n "$rel" ]] || die "Invalid checksum manifest entry: $manifest"
    [[ "$rel" != /* && "$rel" != *\* && "$rel" != *"\x00"* ]] || die "Unsafe checksum manifest path: $rel"
    case "/$rel/" in */../*|*/./*|*//*) die "Non-canonical checksum manifest path: $rel" ;; esac
    resolved="$base/$rel"
    require_regular "$resolved" "checksum manifest member"
    if command -v sha256sum >/dev/null 2>&1; then expected="$(sha256sum -- "$resolved" | awk '{print tolower($1)}')"
    else expected="$(shasum -a 256 -- "$resolved" | awk '{print tolower($1)}')"; fi
    [[ "$expected" == "${digest,,}" ]] || die "Checksum verification failed: $rel"
    count=$((count+1))
  done < "$manifest"
  (( count > 0 )) || die "Checksum manifest is empty: $manifest"
}

# Refuse destructive cleanup on paths that can only be an operator/configuration mistake.
case "$ROOT_DIR" in /|/usr|/usr/*|/etc|/etc/*|/var|/var/*|/bin|/bin/*|/sbin|/sbin/*|/lib|/lib/*|/lib64|/lib64/*|/opt|/opt/*|/tmp|/tmp/*|/home|/home/*) die "Unsafe project root for destructive build cleanup: $ROOT_DIR" ;; esac
[[ "$BUILD_DIR" == "$ROOT_DIR/build" ]] || die "BUILD_DIR must remain inside the project root at ./build."
[[ "$RELEASE_DIR" == "$ROOT_DIR/release" ]] || die "RELEASE_DIR must remain inside the project root at ./release."
require_regular "$SOURCE_FILE" "source"
require_regular "$TEST_FILE" "test source"
require_regular "$CORE" "build core"
require_regular "$REQ_FILE" "build requirements"
require_regular "$TOOL_CHECKSUMS" "build-tool checksum catalogue"
require_regular "$KIT_CHECKSUMS" "build-kit checksum catalogue"
[[ "$ROOT_DIR" != "$BUILD_DIR" && "$ROOT_DIR" != "$RELEASE_DIR" ]] || die "Build/release paths cannot equal project root."
SOURCE_FILE="$(cd -- "$(dirname -- "$SOURCE_FILE")" && pwd -P)/$(basename -- "$SOURCE_FILE")"
TEST_FILE="$(cd -- "$(dirname -- "$TEST_FILE")" && pwd -P)/$(basename -- "$TEST_FILE")"
[[ ! -L "$BUILD_DIR" && ! -L "$RELEASE_DIR" ]] || die "Build/release roots must not be symlinks."
path_is_under_or_equal "$SOURCE_FILE" "$BUILD_DIR" && die "Source cannot reside inside ./build."
path_is_under_or_equal "$SOURCE_FILE" "$RELEASE_DIR" && die "Source cannot reside inside ./release."
path_is_under_or_equal "$TEST_FILE" "$BUILD_DIR" && die "Test source cannot reside inside ./build."
path_is_under_or_equal "$TEST_FILE" "$RELEASE_DIR" && die "Test source cannot reside inside ./release."
verify_checksum_manifest_independent "$KIT_CHECKSUMS" "$ROOT_DIR"

python_core="$(command -v python3 || command -v python || true)"
[[ -n "$python_core" ]] || die "A Python interpreter is required for the build core."

# The self-test below imports main.py directly. Rather than trusting whatever
# interpreter happens to be first on PATH, delegate to the project's own
# development-environment manager: it creates/reuses a dedicated venv at
# ./.venv (fully separate from the disposable, hash-pinned venv create_venv()
# builds later for the Nuitka compile step) and makes sure the runtime
# dependencies are importable there.
DEV_ENV_SCRIPT="$ROOT_DIR/setup_env.sh"
require_regular "$DEV_ENV_SCRIPT" "development environment script"
[[ -x "$DEV_ENV_SCRIPT" ]] || die "setup_env.sh is not executable: $DEV_ENV_SCRIPT"
"$DEV_ENV_SCRIPT" || die "Development environment setup failed."
DEV_VENV_DIR="${NEXS_DEV_VENV_DIR:-$ROOT_DIR/.venv}"
[[ ! -L "$DEV_VENV_DIR" ]] || die "Development virtualenv directory must not itself be a symlink: $DEV_VENV_DIR"
python_core="$DEV_VENV_DIR/bin/python"
require_venv_python "$python_core" "development virtualenv python" >/dev/null

"$python_core" "$CORE" audit-kit --root "$ROOT_DIR" --checksums "$KIT_CHECKSUMS" || die "Build-kit integrity check failed."
"$python_core" "$CORE" audit-tools --tools-dir "$SCRIPT_DIR" --checksums "$TOOL_CHECKSUMS" || die "Build-tool integrity check failed."
"$python_core" "$CORE" validate-source --source "$SOURCE_FILE" >/dev/null || die "Source validation failed."
"$python_core" "$TEST_FILE" || die "Build/test source verification failed."

confirm() {
  local message="$1" auto="$2" answer
  [[ "$auto" == "1" ]] && return 0
  printf '[nexs-build] %s [y/N] ' "$message"
  IFS= read -r answer
  case "$answer" in y|Y|yes|YES) ;; *) die "Operation declined: $message" ;; esac
}

run_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then "$@"; return; fi
  command -v sudo >/dev/null 2>&1 || die "sudo is required for system package installation."
  sudo "$@"
}

host_os="$(uname -s)"
host_machine="$(uname -m | tr '[:upper:]' '[:lower:]')"
case "$host_machine" in x86_64|amd64) host_arch="x86_64" ;; arm64|aarch64) host_arch="arm64" ;; *) die "Unsupported host architecture: $host_machine" ;; esac

# Nuitka/Scons compile parallelism: (available cores - 2), but never below 1,
# and never parallel at all on machines with fewer than 4 cores.
host_build_jobs() {
  local cores=""
  if command -v nproc >/dev/null 2>&1; then
    cores="$(nproc 2>/dev/null || true)"
  fi
  if [[ -z "$cores" ]] && command -v getconf >/dev/null 2>&1; then
    cores="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  fi
  if [[ -z "$cores" ]] && command -v sysctl >/dev/null 2>&1; then
    cores="$(sysctl -n hw.ncpu 2>/dev/null || true)"
  fi
  [[ "$cores" =~ ^[0-9]+$ ]] && (( cores >= 1 )) || cores=1
  local jobs
  if (( cores < 4 )); then
    jobs=1
  else
    jobs=$(( cores - 2 ))
  fi
  (( jobs < 1 )) && jobs=1
  printf '%s\n' "$jobs"
}
build_jobs="$(host_build_jobs)"
[[ "$build_jobs" =~ ^[0-9]+$ ]] && (( build_jobs >= 1 )) || die "Failed to determine a valid compile job count."

normalize_target() {
  case "$1" in __HOST_ONLY__)
    case "$host_os/$host_arch" in Darwin/x86_64) printf 'macos-x86_64\n' ;; Darwin/arm64) printf 'macos-arm64\n' ;; Linux/x86_64) printf 'linux-x86_64\n' ;; Linux/arm64) printf 'linux-aarch64\n' ;; *) die "No native release target for $host_os/$host_arch" ;; esac ;;
    *) printf '%s\n' "$1" ;;
  esac
}
if ((${#TARGETS[@]} == 0)); then TARGETS=("__HOST_ONLY__"); fi
normalized_targets=()
for requested in "${TARGETS[@]}"; do
  target="$(normalize_target "$requested")"
  printf '%s\n' "${ALL_TARGETS[@]}" | grep -Fxq "$target" || die "Unsupported target: $target"
  normalized_targets+=("$target")
done
TARGETS=("${normalized_targets[@]}")
if [[ -n "$SOURCE_OVERRIDE" ]]; then
  for target in "${TARGETS[@]}"; do
    case "$target" in
      linux-aarch64|linux-x86_64|linux-musl-x86_64|linux-musl-aarch64)
        [[ "$SOURCE_FILE" == "$ROOT_DIR/main.py" ]] || die "Source override is forbidden for Linux container/cross targets; use the trusted ./main.py source." ;;
    esac
  done
fi

find_python312() {
  local candidate
  for candidate in python3.12 python3 python; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    if "$candidate" - <<'PY' >/dev/null 2>&1
import sys
raise SystemExit(0 if sys.version_info[:2] == (3, 12) and sys.implementation.name == 'cpython' else 1)
PY
    then command -v "$candidate"; return 0; fi
  done
  return 1
}

linux_distribution() {
  [[ -r /etc/os-release ]] || die "Linux /etc/os-release is unavailable; refusing to guess the distribution."
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ -n "${ID:-}" ]] || die "Linux distribution ID is unavailable."
  printf '%s\n' "${ID,,}"
}

linux_manager() {
  local id like token
  id="$(linux_distribution)"
  case "$id" in
    alpine) command -v apk >/dev/null 2>&1 && { printf 'apk\n'; return; } ;;
    ubuntu|debian|linuxmint|elementary|pop) command -v apt-get >/dev/null 2>&1 && { printf 'apt\n'; return; } ;;
    fedora|rhel|centos|rocky|almalinux|ol) command -v dnf >/dev/null 2>&1 && { printf 'dnf\n'; return; } ;;
    arch|manjaro|endeavouros) command -v pacman >/dev/null 2>&1 && { printf 'pacman\n'; return; } ;;
    opensuse*|sles) command -v zypper >/dev/null 2>&1 && { printf 'zypper\n'; return; } ;;
  esac
  if [[ -r /etc/os-release ]]; then
    # ID_LIKE is a compatibility fallback, but only after the concrete ID failed.
    # shellcheck disable=SC1091
    . /etc/os-release
    for like in ${ID_LIKE:-}; do
      case "$like" in
        alpine) command -v apk >/dev/null 2>&1 && { printf 'apk\n'; return; } ;;
        debian|ubuntu) command -v apt-get >/dev/null 2>&1 && { printf 'apt\n'; return; } ;;
        fedora|rhel) command -v dnf >/dev/null 2>&1 && { printf 'dnf\n'; return; } ;;
        arch) command -v pacman >/dev/null 2>&1 && { printf 'pacman\n'; return; } ;;
        suse|opensuse) command -v zypper >/dev/null 2>&1 && { printf 'zypper\n'; return; } ;;
      esac
    done
  fi
  return 1
}

verify_python_target_arch() {
  local py="$1" expected="$2" actual
  actual="$($py - <<'PY'
import platform
print(platform.machine().lower())
PY
)" || die "Unable to determine Python target architecture: $py"
  case "$actual" in
    amd64|x86_64) actual=x86_64 ;;
    arm64|aarch64) actual=arm64 ;;
  esac
  [[ "$actual" == "$expected" ]] || die "Python interpreter architecture mismatch: expected=$expected actual=$actual"
}

install_system_deps() {
  if [[ "$host_os" == Darwin ]]; then
    command -v brew >/dev/null 2>&1 || die "Homebrew is required on macOS."
    local missing=()
    command -v file >/dev/null 2>&1 || missing+=(file)
    command -v xcrun >/dev/null 2>&1 || die "Xcode Command Line Tools are required."
    if ((${#missing[@]})); then
      confirm "Install Homebrew packages: ${missing[*]}" "$AUTO_ACCEPT_SYSTEM"
      brew install "${missing[@]}"
    fi
    return
  fi
  local manager; manager="$(linux_manager)" || die "No supported Linux package manager found."
  local packages=()
  case "$manager" in
    apk) packages=(python3 py3-pip bash build-base patchelf file) ;;
    apt) packages=(build-essential patchelf file) ;;
    dnf) packages=(gcc gcc-c++ make patchelf file) ;;
    pacman) packages=(base-devel patchelf file) ;;
    zypper) packages=(gcc gcc-c++ make patchelf file) ;;
  esac
  local missing=() pkg
  for pkg in "${packages[@]}"; do
    case "$manager" in
      apk) apk info -e "$pkg" >/dev/null 2>&1 || missing+=("$pkg") ;;
      apt) dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' || missing+=("$pkg") ;;
      dnf|zypper) rpm -q "$pkg" >/dev/null 2>&1 || missing+=("$pkg") ;;
      pacman) pacman -Q "$pkg" >/dev/null 2>&1 || missing+=("$pkg") ;;
    esac
  done
  if ((${#missing[@]})); then
    confirm "Install system packages (${manager}): ${missing[*]}" "$AUTO_ACCEPT_SYSTEM"
    case "$manager" in
      apk) run_root apk add --no-cache "${missing[@]}" ;;
      apt) run_root apt-get update; run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}" ;;
      dnf) run_root dnf install -y "${missing[@]}" ;;
      pacman) run_root pacman -S --needed --noconfirm "${missing[@]}" ;;
      zypper) run_root zypper --non-interactive install "${missing[@]}" ;;
    esac
  fi
}

ensure_host_python() {
  local python312
  if python312="$(find_python312)"; then printf '%s\n' "$python312"; return 0; fi
  if [[ "$host_os" == Darwin ]]; then
    confirm "Install Homebrew CPython 3.12" "$AUTO_ACCEPT_SYSTEM"
    brew install python@3.12
    python312="$(find_python312)" || die "Homebrew installation did not provide CPython 3.12."
    printf '%s\n' "$python312"; return
  fi
  local manager; manager="$(linux_manager)" || die "No Linux package manager for CPython 3.12."
  case "$manager" in
    apk) confirm "Install Alpine CPython 3.12 package" "$AUTO_ACCEPT_SYSTEM"; run_root apk add --no-cache python3 py3-pip; ;;
    apt) apt-cache show python3.12 >/dev/null 2>&1 || die "This APT configuration does not provide CPython 3.12. Refusing to add an untrusted third-party repository automatically."; confirm "Install CPython 3.12 packages" "$AUTO_ACCEPT_SYSTEM"; run_root apt-get update; run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3.12 python3.12-venv; ;;
    dnf) dnf info python3.12 >/dev/null 2>&1 || die "DNF does not expose CPython 3.12 in the configured repositories."; confirm "Install CPython 3.12 packages" "$AUTO_ACCEPT_SYSTEM"; run_root dnf install -y python3.12 python3.12-devel; ;;
    zypper) zypper --non-interactive info python312 >/dev/null 2>&1 || die "Zypper does not expose CPython 3.12 in the configured repositories."; confirm "Install CPython 3.12 packages" "$AUTO_ACCEPT_SYSTEM"; run_root zypper --non-interactive install python312 python312-devel; ;;
    pacman) warn "Arch Linux tracks one current Python. The local build requires exactly 3.12.x; use the supplied CI/container builder if your host Python differs."; die "No exact CPython 3.12 package guarantee on this rolling host." ;;
  esac
  python312="$(find_python312)" || die "CPython 3.12 remains unavailable after installation."
  printf '%s\n' "$python312"
}

ensure_rosetta_macos() {
  if [[ "$host_os" != Darwin || "$host_arch" != arm64 ]]; then return 0; fi
  if arch -x86_64 true >/dev/null 2>&1; then return 0; fi
  confirm "Install Rosetta 2 for macOS x86_64 build" "$AUTO_ACCEPT_SYSTEM"
  command -v softwareupdate >/dev/null 2>&1 || die "softwareupdate is required to install Rosetta 2."
  run_root softwareupdate --install-rosetta --agree-to-license
  arch -x86_64 true >/dev/null 2>&1 || die "Rosetta 2 remains unavailable."
}

find_intel_python_macos() {
  local candidate
  for candidate in /usr/local/bin/python3.12 /usr/local/opt/python@3.12/bin/python3.12; do
    [[ -x "$candidate" ]] || continue
    if arch -x86_64 "$candidate" - <<'PY' >/dev/null 2>&1
import platform,sys
raise SystemExit(0 if platform.machine() == 'x86_64' and sys.version_info[:2] == (3,12) and sys.implementation.name == 'cpython' else 1)
PY
    then printf '%s\n' "$candidate"; return 0; fi
  done
  return 1
}

resolve_target_python() {
  local target="$1"
  case "$target" in
    macos-x86_64)
      if [[ "$host_os" == Darwin && "$host_arch" == arm64 ]]; then
        ensure_rosetta_macos
        command -v /usr/local/bin/brew >/dev/null 2>&1 || true
        if ! find_intel_python_macos; then
          [[ -x /usr/local/bin/brew ]] || die "Intel Homebrew is required for macOS x86_64 cross-build on Apple Silicon."
          confirm "Install Intel Homebrew CPython 3.12 under Rosetta 2" "$AUTO_ACCEPT_SYSTEM"
          arch -x86_64 /usr/local/bin/brew install python@3.12
        fi
        find_intel_python_macos || die "Intel CPython 3.12 is unavailable."
        local py; py="$(find_intel_python_macos)"; verify_python_target_arch "$py" x86_64; printf '%s\n' "$py"
      else
        [[ "$host_os" == Darwin && "$host_arch" == x86_64 ]] || die "macOS x86_64 must build on Intel macOS or Apple Silicon with Rosetta Python."
        local py; py="$(ensure_host_python)"; verify_python_target_arch "$py" x86_64; printf '%s\n' "$py"
      fi ;;
    macos-arm64) [[ "$host_os" == Darwin && "$host_arch" == arm64 ]] || die "macOS ARM64 must build on an Apple Silicon host."; local py; py="$(ensure_host_python)"; verify_python_target_arch "$py" arm64; printf '%s\n' "$py" ;;
    linux-x86_64) [[ "$host_os" == Linux && "$host_arch" == x86_64 ]] || return 1; local py; py="$(ensure_host_python)"; verify_python_target_arch "$py" x86_64; printf '%s\n' "$py" ;;
    linux-aarch64) [[ "$host_os" == Linux && "$host_arch" == arm64 ]] || return 1; [[ "$(host_libc)" == glibc ]] || return 1; local py; py="$(ensure_host_python)"; verify_python_target_arch "$py" arm64; printf '%s\n' "$py" ;;
    linux-musl-x86_64) [[ "$host_os" == Linux && "$host_arch" == x86_64 ]] || return 1; [[ "$(host_libc)" == musl ]] || return 1; local py; py="$(ensure_host_python)"; verify_python_target_arch "$py" x86_64; printf '%s\n' "$py" ;;
    linux-musl-aarch64) [[ "$host_os" == Linux && "$host_arch" == arm64 ]] || return 1; [[ "$(host_libc)" == musl ]] || return 1; local py; py="$(ensure_host_python)"; verify_python_target_arch "$py" arm64; printf '%s\n' "$py" ;;
    *) die "POSIX builder cannot build target $target" ;;
  esac
}

host_libc() {
  if [[ "$host_os" != Linux ]]; then printf 'apple\n'; return; fi
  if command -v getconf >/dev/null 2>&1 && getconf GNU_LIBC_VERSION >/dev/null 2>&1; then printf 'glibc\n'; return; fi
  if command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | head -n1 | grep -qi musl; then printf 'musl\n'; return; fi
  printf 'unknown\n'
}

container_engine() {
  if command -v docker >/dev/null 2>&1; then printf 'docker\n'; return; fi
  if command -v podman >/dev/null 2>&1; then printf 'podman\n'; return; fi
  return 1
}

container_image_for() {
  case "$1" in
    linux-musl-x86_64|linux-musl-aarch64) printf '%s\n' "${NEXS_MUSL_IMAGE:-python:3.12.14-alpine3.24@sha256:b64631e04e4920160c50fbe8d8df828f7f35f06f425cb44aa09bca53e708a35a}" ;;
    linux-x86_64|linux-aarch64) printf '%s\n' "${NEXS_GLIBC_IMAGE:-python:3.12.14-slim-bookworm@sha256:782412e85d0f0984994c290652577d4018aff08145c85b262bb63dc0c7522254}" ;;
    *) die "No container image for $1" ;;
  esac
}

build_in_linux_container() {
  local target="$1" engine image platform target_context
  [[ "$SOURCE_FILE" == "$ROOT_DIR/main.py" ]] || die "Container targets require the trusted build-kit source at ./main.py; source override is not permitted for cross/musl builds."
  engine="$(container_engine)" || die "Docker or Podman is required for Linux cross/musl builds."
  image="$(container_image_for "$target")"
  if [[ "$image" != *@sha256:* ]]; then
    if [[ "$REQUIRE_PINNED_IMAGE" == 1 ]]; then die "Pinned container image digest required for $target; set the image variable to name@sha256:digest."; fi
    warn "Using a mutable container tag for $target: $image. Set NEXS_REQUIRE_PINNED_IMAGE=1 with an immutable digest for strict supply-chain pinning."
  fi
  case "$target" in
    linux-x86_64|linux-musl-x86_64) platform="linux/amd64" ;;
    linux-aarch64|linux-musl-aarch64) platform="linux/arm64" ;;
    *) die "Invalid container target: $target" ;;
  esac
  confirm "Pull and use isolated target container $image for $target" "$AUTO_ACCEPT_CONTAINER"
  "$engine" pull "$image" >/dev/null
  local image_digest image_id
  image_digest="$($engine image inspect --format '{{index .RepoDigests 0}}' "$image" 2>/dev/null || true)"
  image_id="$($engine image inspect --format '{{.Id}}' "$image" 2>/dev/null || true)"
  [[ -n "$image_digest" && -n "$image_id" ]] || die "Unable to obtain the container image digest/id for provenance."
  if [[ "$image" == *@sha256:* ]]; then
    [[ "$image_digest" == "$image" ]] || die "Pulled container digest does not match the pinned reference: expected=$image actual=$image_digest"
  fi
  local expected_machine expected_loader
  expected_machine="$([[ "$platform" == linux/amd64 ]] && printf x86_64 || printf aarch64)"
  expected_loader=""
  case "$target" in
    linux-x86_64) expected_loader="/lib64/ld-linux-x86-64.so.2" ;;
    linux-aarch64) expected_loader="/lib/ld-linux-aarch64.so.1" ;;
    linux-musl-x86_64) expected_loader="/lib/ld-musl-x86_64.so.1" ;;
    linux-musl-aarch64) expected_loader="/lib/ld-musl-aarch64.so.1" ;;
  esac
  "$engine" run --rm --platform "$platform" "$image" sh -c "python -c 'import platform; raise SystemExit(0 if platform.machine() == \"$expected_machine\" else 1)'; test -e '$expected_loader'" || die "Target container architecture/libc validation failed."

  target_context="$BUILD_DIR/.container-$target"
  rm -rf -- "$target_context"
  mkdir -m 700 -p -- "$target_context"
  cp -p -- "$ROOT_DIR/main.py" "$target_context/main.py"
  cp -p -- "$KIT_CHECKSUMS" "$target_context/BUILD_KIT_SHA256SUMS"
  cp -a -- "$SCRIPT_DIR" "$target_context/nexs_build_tools"
  # The trust set has already rejected links; fail instead of silently deleting one.
  if find "$target_context" -type l -print -quit | grep -q .; then die "Container build context contains a symlink."; fi

  local host_uid host_gid
  host_uid="$(id -u)"; host_gid="$(id -g)"
  "$engine" run --rm --platform "$platform" --cap-drop=ALL --security-opt=no-new-privileges \
    -v "$target_context:/workspace:rw" -w /workspace \
    -e NEXS_ROOT_DIR=/workspace \
    -e NEXS_SOURCE_FILE=/workspace/main.py \
    -e NEXS_AUTO_ACCEPT_SYSTEM=1 -e NEXS_AUTO_ACCEPT_PIP=1 \
    -e NEXS_REQUIRE_PINNED_IMAGE="$REQUIRE_PINNED_IMAGE" -e NEXS_SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
    -e NEXS_CONTAINER_TARGET_ONLY=1 -e NEXS_KEEP_BUILD=1 -e NEXS_NO_PUBLISH=1 \
    -e NEXS_HOST_UID="$host_uid" -e NEXS_HOST_GID="$host_gid" \
    -e NEXS_PIP_INDEX_URL="${NEXS_PIP_INDEX_URL:-https://pypi.org/simple}" \
    -e NEXS_ALLOW_CUSTOM_PIP_INDEX="${NEXS_ALLOW_CUSTOM_PIP_INDEX:-0}" \
    -e NEXS_BUILD_VERSION="$VERSION" -e NEXS_BUILD_TARGET="$target" \
    "$image" /bin/sh -c \
    'set -eu; if command -v apk >/dev/null 2>&1; then apk add --no-cache bash build-base patchelf file; elif command -v apt-get >/dev/null 2>&1; then apt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends bash build-essential patchelf file; elif command -v dnf >/dev/null 2>&1; then dnf install -y bash gcc gcc-c++ make patchelf file; else echo "No supported container package manager." >&2; exit 1; fi; exec /bin/bash /workspace/nexs_build_tools/build_release.sh -V "$NEXS_BUILD_VERSION" -t "$NEXS_BUILD_TARGET";'

  local child_package="$target_context/build/$target/package"
  [[ -d "$child_package" ]] || die "Container build did not produce $target package."
  rm -rf -- "$BUILD_DIR/$target"
  mkdir -m 700 -p -- "$BUILD_DIR/$target"
  cp -a -- "$child_package" "$BUILD_DIR/$target/package"
  cp -p -- "$target_context/build/$target/internal_identity.json" "$BUILD_DIR/$target/internal_identity.json"
  cp -p -- "$target_context/build/$target/BUILD_PROVENANCE.json" "$BUILD_DIR/$target/BUILD_PROVENANCE.json"
  "$python_core" "$CORE" catalogue-package --package "$BUILD_DIR/$target/package" --target "$target" --version "$VERSION" --source "$SOURCE_FILE" --identity "$BUILD_DIR/$target/internal_identity.json" --provenance "$BUILD_DIR/$target/package/BUILD_PROVENANCE.json" >/dev/null
  "$python_core" "$CORE" archive-package --package "$BUILD_DIR/$target/package" --target "$target" --version "$VERSION" --output-dir "$BUILD_DIR/$target" >/dev/null
  "$python_core" "$CORE" verify-archive --archive "$BUILD_DIR/$target/$target-$VERSION.tar.gz" --target "$target" --version "$VERSION" >/dev/null
  rm -rf -- "$target_context"
  log "$target container build verified by child and parent builders; parent provenance image=$image_digest"
}

prepare_provenance() {
  local target="$1" py="$2" package_dir="$3" image_ref="${4:-}" image_digest="${5:-}" image_id="${6:-}" dependency_catalogue="${7:-}"
  local compiler="unknown"
  case "$host_os" in
    Darwin) compiler="$(xcrun --find clang)" ;;
    Linux) compiler="$(command -v cc || command -v gcc || true)" ;;
  esac
  "$py" - "$target" "$VERSION" "$py" "$host_os" "$host_arch" "$(host_libc)" "$compiler" "$image_ref" "$image_digest" "$image_id" "$dependency_catalogue" "$package_dir" <<'PY'
import hashlib,json,os,platform,shutil,sys
from pathlib import Path

def shasum(p):
    h=hashlib.sha256()
    with Path(p).open('rb') as f:
        for c in iter(lambda:f.read(1024*1024),b''): h.update(c)
    return h.hexdigest()

target,version,py,host_os,host_arch,host_libc,compiler,image_ref,image_digest,image_id,dependency_catalogue,package=sys.argv[1:]
host_arch = platform.machine().lower() if host_arch else host_arch
host_arch = {'amd64':'x86_64','x86_64':'x86_64','arm64':'arm64','aarch64':'arm64'}.get(host_arch, host_arch)
# uname -s reports "Darwin"/"Linux"; nexs_build_core.py's TARGETS table (and
# therefore validate_provenance) expects the lowercase "macos"/"linux" spelling.
host_os = {'darwin':'macos','linux':'linux'}.get(host_os.lower(), host_os.lower())
compiler_version=None
if compiler and Path(compiler).exists():
    import subprocess
    try:
        probe=subprocess.run([compiler,'--version'],check=True,capture_output=True,text=True,timeout=10)
        compiler_version=probe.stdout.splitlines()[0] if probe.stdout else (probe.stderr.splitlines()[0] if probe.stderr else None)
    except Exception:
        compiler_version=None
prov={
  'schema':1,
  'builder':'nexs_build_release.sh',
  'target':target,
  'release_version':version,
  'source_date_epoch':int(os.environ.get('SOURCE_DATE_EPOCH','0')),
  'python':{'version':platform.python_version(),'implementation':platform.python_implementation(),'executable_sha256':shasum(py)},
  'host':{'os':host_os,'arch':host_arch,'libc':host_libc},
  'compiler':{'path':compiler,'version':compiler_version},
  'container':({'image':image_ref,'digest':image_digest,'image_id':image_id} if image_ref else None),
  'dependency_catalogue':({'path':Path(dependency_catalogue).name,'sha256':shasum(dependency_catalogue)} if dependency_catalogue else None),
}
if compiler and Path(compiler).exists():
    prov['compiler']['sha256']=shasum(compiler)
Path(package,'BUILD_PROVENANCE.json').write_bytes(json.dumps(prov,sort_keys=True,separators=(',',':')).encode()+b'\n')
PY
}

create_venv() {
  local py="$1" venv="$2" target_dir="$3" target="$4"
  confirm "Create temporary CPython 3.12 virtualenv and install pinned build dependencies" "$AUTO_ACCEPT_PIP"
  rm -rf -- "$venv"
  "$py" -m venv "$venv"
  export PIP_CONFIG_FILE=/dev/null PIP_EXTRA_INDEX_URL= PIP_FIND_LINKS= PIP_NO_INDEX=0 PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_CACHE_DIR=1 PIP_REQUIRE_VIRTUALENV=1 PYTHONHASHSEED=0
  unset PIP_TRUSTED_HOST PIP_CERT PIP_CLIENT_CERT PIP_CLIENT_KEY || true
  export PIP_INDEX_URL="${NEXS_PIP_INDEX_URL:-https://pypi.org/simple}"
  [[ "$PIP_INDEX_URL" == https://* ]] || die "PIP_INDEX_URL must use HTTPS."
  if [[ "$PIP_INDEX_URL" != "https://pypi.org/simple" && "${NEXS_ALLOW_CUSTOM_PIP_INDEX:-0}" != 1 ]]; then
    die "Custom PIP index is disabled by default; set NEXS_ALLOW_CUSTOM_PIP_INDEX=1 only for an explicitly trusted mirror."
  fi
  local wheelhouse="$venv/wheelhouse"
  local requirements_hash_before requirements_hash_after
  requirements_hash_before="$("$venv/bin/python" - "$REQ_FILE" <<'PY'
import hashlib,sys
from pathlib import Path
h=hashlib.sha256(); p=Path(sys.argv[1])
with p.open('rb') as f:
    for chunk in iter(lambda:f.read(1024*1024), b''): h.update(chunk)
print(h.hexdigest())
PY
)"
  rm -rf -- "$wheelhouse"
  mkdir -m 700 -p -- "$wheelhouse"
  local wheel_requirements="$venv/wheel-requirements.txt"
  "$venv/bin/python" - "$REQ_FILE" "$wheel_requirements" <<'PY'
from pathlib import Path
import sys
src=Path(sys.argv[1]); dst=Path(sys.argv[2])
rows=[]
for raw in src.read_text(encoding="utf-8").splitlines():
    line=raw.split("#",1)[0].strip()
    if line and not line.lower().startswith("nuitka=="):
        rows.append(line)
dst.write_text("\n".join(rows)+"\n", encoding="utf-8")
PY
  "$venv/bin/python" -m pip download --disable-pip-version-check --no-input --no-cache-dir --only-binary=:all: --no-deps --dest "$wheelhouse" -r "$wheel_requirements"
  "$venv/bin/python" -m pip download --disable-pip-version-check --no-input --no-cache-dir --no-binary=:all: --no-deps --dest "$wheelhouse" "Nuitka==$NUITKA_VERSION"
  "$venv/bin/python" "$CORE" catalogue-dependencies --wheelhouse "$wheelhouse" --requirements "$REQ_FILE" --output "$target_dir/BUILD_DEPENDENCY_CATALOGUE.json" --target "$target"
  local lock_file="$target_dir/BUILD_DEPENDENCY_LOCK.txt"
  "$venv/bin/python" "$CORE" emit-hashed-requirements --catalogue "$target_dir/BUILD_DEPENDENCY_CATALOGUE.json" --requirements "$REQ_FILE" --output "$lock_file" --target "$target"
  requirements_hash_after="$("$venv/bin/python" - "$REQ_FILE" <<'PY'
import hashlib,sys
from pathlib import Path
h=hashlib.sha256(); p=Path(sys.argv[1])
with p.open('rb') as f:
    for chunk in iter(lambda:f.read(1024*1024), b''): h.update(chunk)
print(h.hexdigest())
PY
)"
  [[ "$requirements_hash_before" == "$requirements_hash_after" ]] || die "Build requirements changed during wheel acquisition."
  local setuptools_hash
  setuptools_hash="$("$venv/bin/python" - "$target_dir/BUILD_DEPENDENCY_CATALOGUE.json" <<'PY'
import json,sys
from pathlib import Path
data=json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
rows=[a for a in data["artifacts"] if a["normalized_package"]=="setuptools"]
if len(rows)!=1: raise SystemExit("setuptools artifact missing from dependency catalogue")
print(rows[0]["sha256"])
PY
)"
  printf '%s==%s --hash=sha256:%s\n' setuptools "$SETUPTOOLS_VERSION" "$setuptools_hash" > "$target_dir/SETUPTOOLS_LOCK.txt"
  "$venv/bin/python" -m pip install --disable-pip-version-check --no-input --no-index --find-links "$wheelhouse" --require-hashes --no-deps -r "$target_dir/SETUPTOOLS_LOCK.txt"
  "$venv/bin/python" -m pip install --disable-pip-version-check --no-input --no-index --find-links "$wheelhouse" --no-build-isolation --no-deps --require-hashes -r "$lock_file"
  rm -rf -- "$wheelhouse" "$wheel_requirements" "$lock_file" "$target_dir/SETUPTOOLS_LOCK.txt"
  "$venv/bin/python" -m pip check
  "$venv/bin/python" - <<PY
import cffi, cryptography, nuitka.Version, ordered_set, pycparser, setuptools, sys
from importlib.metadata import version as _pkg_version
argon2_version = _pkg_version('argon2-cffi')
expected=((${PYTHON_MAJOR},${PYTHON_MINOR}), '${NUITKA_VERSION}','${CRYPTOGRAPHY_VERSION}','${CFFI_VERSION}','${PYCPARSER_VERSION}','${ORDERED_SET_VERSION}','${SETUPTOOLS_VERSION}','${ARGON2_CFFI_VERSION}')
actual=(sys.version_info[:2], nuitka.Version.getNuitkaVersion(), cryptography.__version__, cffi.__version__, pycparser.__version__, ordered_set.__version__, setuptools.__version__, argon2_version)
if actual != expected: raise SystemExit(f'build dependency mismatch: expected={expected} actual={actual}')
print('Build Python/dependencies verified:', actual)
PY
}

build_local_target() {
  local target="$1" target_dir="$BUILD_DIR/$1" srcdir="$BUILD_DIR/$1/source" outdir="$BUILD_DIR/$1/nuitka" package="$BUILD_DIR/$1/package" venv="$BUILD_DIR/$1/venv" py
  local image_ref="${NEXS_CONTAINER_IMAGE:-}" image_digest="${NEXS_CONTAINER_IMAGE_DIGEST:-}" image_id="${NEXS_CONTAINER_IMAGE_ID:-}"
  mkdir -m 700 -p -- "$srcdir" "$outdir"
  py="$(resolve_target_python "$target")" || die "No local interpreter for $target."
  [[ -x "$py" ]] || die "Target Python is not executable: $py"
  "$py" "$CORE" validate-source --source "$SOURCE_FILE" >/dev/null
  "$py" "$CORE" prepare-source --source "$SOURCE_FILE" --output "$srcdir/main.py"
  cp -p -- "$SOURCE_FILE" "$srcdir/original_main.py"
  cp -p -- "$TEST_FILE" "$srcdir/original_test.py"
  create_venv "$py" "$venv" "$target_dir" "$target"
  local vpy="$venv/bin/python"
  "$vpy" "$srcdir/main.py" --self-test

  local -a args=(
    --mode=standalone
    "--output-dir=$outdir"
    --output-filename=nexs_ledger
    "--jobs=$build_jobs"
    --python-flag=isolated
    --follow-imports
    "--product-name=Nexs-Scratch-System"
    "--file-description=Nexs-Scratch-System signed ledger"
    "--file-version=$VERSION"
    "--product-version=$VERSION"
    "--report=$outdir/compilation-report.xml"
    "--include-data-files=$srcdir/original_main.py=main.py"
    "--include-data-files=$srcdir/original_test.py=test.py"
    "$srcdir/main.py"
  )
  case "$target" in
    macos-x86_64) [[ "$host_os" == Darwin ]] || die "macOS build executed on non-macOS host."; if [[ "$host_arch" == arm64 ]]; then args+=(--target-arch=x86_64); fi ;;
    macos-arm64) [[ "$host_os" == Darwin && "$host_arch" == arm64 ]] || die "macOS ARM64 requires native ARM64 macOS." ;;
    linux-x86_64) [[ "$host_os" == Linux && "$host_arch" == x86_64 ]] || die "Linux x86_64 local target mismatch."; [[ "$(host_libc)" == glibc ]] || die "glibc target requires a glibc host; use the glibc container on musl hosts." ;;
    linux-aarch64) [[ "$host_os" == Linux && "$host_arch" == arm64 ]] || die "Linux ARM64 local target mismatch."; [[ "$(host_libc)" == glibc ]] || die "glibc target requires a glibc host; use the glibc container on musl hosts." ;;
    linux-musl-x86_64) [[ "$host_os" == Linux && "$host_arch" == x86_64 && "$(host_libc)" == musl ]] || die "Linux musl x86_64 requires a musl x86_64 builder." ;;
    linux-musl-aarch64) [[ "$host_os" == Linux && "$host_arch" == arm64 && "$(host_libc)" == musl ]] || die "Linux musl ARM64 requires a musl ARM64 builder." ;;
    *) die "Invalid local POSIX target: $target" ;;
  esac

  log "Compiling $target with $build_jobs parallel job(s)."
  "$vpy" -m nuitka "${args[@]}"
  local dist="$outdir/main.dist"
  [[ -d "$dist" ]] || die "Nuitka did not produce the expected .dist directory: $dist"
  rm -rf -- "$package"
  mv -- "$dist" "$package"
  local main="$package/nexs_ledger"
  require_regular "$main" "nexs_ledger"
  chmod 0755 "$main"
  require_regular "$package/test.py" "packaged test.py"
  mkdir -m 700 -p -- "$package/external" "$package/extensions"
  cp -p -- "$target_dir/BUILD_DEPENDENCY_CATALOGUE.json" "$package/BUILD_DEPENDENCY_CATALOGUE.json"
  # A single compiled binary is produced and verified once; there used to be
  # a second "test_ledger" file that was nothing but a byte-for-byte copy of
  # this same binary, run through --self-test a second time for no benefit
  # (the two files were, by construction, identical). test.py is packaged
  # alongside the binary (as plain, uncompiled data -- see the
  # --include-data-files entry above; it is never fed to Nuitka together
  # with main.py) and, in its --binary mode, drives the compiled artifact's
  # own --self-test/--build-identity entry points out-of-process. This keeps
  # exactly one compiled self-test per target (via test.py's --binary mode
  # below) instead of three redundant runs (source self-test, duplicate-
  # binary self-test, main self-test).
  "$vpy" "$srcdir/original_test.py" --binary "$main" --source "$srcdir/original_main.py"
  local identity="$target_dir/internal_identity.json"
  "$main" --build-identity > "$identity"
  "$vpy" "$CORE" validate-source --source "$srcdir/original_main.py" >/dev/null
  "$vpy" - "$identity" "$srcdir/original_main.py" <<'PY'
import hashlib,json,sys
from pathlib import Path
identity=json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
source_hash=hashlib.sha256(Path(sys.argv[2]).read_bytes()).hexdigest()
if identity.get('program_hash') != source_hash: raise SystemExit('compiled internal program hash does not equal original source hash')
if len(identity.get('runtime_fingerprint','')) != 64: raise SystemExit('runtime fingerprint missing or malformed')
print('runtime identity == original source identity')
PY
  prepare_provenance "$target" "$vpy" "$package" "${image_ref:-}" "${image_digest:-}" "${image_id:-}" "$target_dir/BUILD_DEPENDENCY_CATALOGUE.json"
  "$vpy" "$CORE" catalogue-package --package "$package" --target "$target" --version "$VERSION" --source "$srcdir/original_main.py" --identity "$identity" --provenance "$package/BUILD_PROVENANCE.json"
  local archive="$target_dir/$target-$VERSION.tar.gz"
  "$vpy" "$CORE" archive-package --package "$package" --target "$target" --version "$VERSION" --output-dir "$target_dir" >/dev/null
  if [[ "$target" == windows-* ]]; then archive="$target_dir/$target-$VERSION.zip"; fi
  "$vpy" "$CORE" verify-archive --archive "$archive" --target "$target" --version "$VERSION" >/dev/null
  if [[ -n "${NEXS_ARTIFACT_DIR:-}" ]]; then
    assert_safe_external_output "$NEXS_ARTIFACT_DIR"
    mkdir -m 700 -p -- "$NEXS_ARTIFACT_DIR"
    cp -p -- "$archive" "$NEXS_ARTIFACT_DIR/"
  fi
  log "$target built and internally verified."
}

publish_release() {
  local stage="$BUILD_DIR/release-stage"
  rm -rf -- "$stage"
  mkdir -m 700 -p -- "$stage"
  local target package
  for target in "${TARGETS[@]}"; do
    package="$BUILD_DIR/$target/package"
    [[ -d "$package" ]] || die "Target package missing before release assembly: $target"
    cp -a -- "$package" "$stage/$target"
  done
  # NOTE: assemble-release writes the staging catalogue files WITHOUT the
  # version suffix (RELEASE_CATALOGUE.json, not RELEASE_CATALOGUE-$VERSION.json);
  # the version suffix is only added below, once the files are moved into
  # $RELEASE_DIR. verify-release always expects the *versioned* filenames, so
  # it must never be called against the pre-move staging directory -- doing
  # so is a guaranteed, unconditional failure regardless of how many targets
  # were built (this used to happen here and broke every single build,
  # including fully successful ones). The one and only verification pass
  # against real, final filenames happens after the mv below.
  "$python_core" "$CORE" assemble-release --stage "$stage" --version "$VERSION" >/dev/null
  mkdir -m 700 -p -- "$RELEASE_DIR"

  # Refuse-by-default: an already-published release of the same VERSION is
  # left untouched unless the operator explicitly opts in with
  # --allow-overwrite/NEXS_ALLOW_RELEASE_OVERWRITE=1. This only decides
  # whether pre-existing artifacts for THIS version are removed first; it
  # never weakens the "never publish a partial target matrix" guarantee
  # enforced earlier for the current run.
  local existing=() candidate
  for candidate in "$RELEASE_DIR/RELEASE_CATALOGUE-$VERSION.json" "$RELEASE_DIR/BINARY_HASH_CATALOGUE-$VERSION.json" "$RELEASE_DIR/SHA256SUMS-$VERSION"; do
    [[ -e "$candidate" || -L "$candidate" ]] && existing+=("$candidate")
  done
  local file
  for file in "$stage"/*.zip "$stage"/*.tar.gz; do
    [[ -f "$file" ]] || continue
    candidate="$RELEASE_DIR/$(basename -- "$file")"
    [[ -e "$candidate" || -L "$candidate" ]] && existing+=("$candidate")
  done

  if ((${#existing[@]} > 0)); then
    if [[ "$ALLOW_RELEASE_OVERWRITE" != 1 ]]; then
      die "Release version already exists. Refusing overwrite. Pass --allow-overwrite (or set NEXS_ALLOW_RELEASE_OVERWRITE=1) to replace it deliberately: ${existing[*]}"
    fi
    warn "Release $VERSION already has published artifacts; --allow-overwrite was given, so they will be deleted and replaced."
    local victim
    for victim in "${existing[@]}"; do
      warn "  will remove: $victim"
    done
    confirm "Delete and replace the existing $VERSION release artifacts listed above" "$AUTO_ACCEPT_OVERWRITE"
    for victim in "${existing[@]}"; do
      [[ ! -L "$victim" ]] || die "Refusing to remove a symlinked release artifact: $victim"
      [[ -f "$victim" ]] || die "Refusing to remove a non-regular release artifact: $victim"
      rm -f -- "$victim"
    done
  fi

  local destination
  for file in "$stage"/*.zip "$stage"/*.tar.gz; do
    [[ -f "$file" ]] || continue
    destination="$RELEASE_DIR/$(basename -- "$file")"
    [[ ! -e "$destination" && ! -L "$destination" ]] || die "Release archive already exists. Refusing overwrite: $(basename -- "$file")"
    mv -- "$file" "$RELEASE_DIR/"
  done
  mv -- "$stage/RELEASE_CATALOGUE.json" "$RELEASE_DIR/RELEASE_CATALOGUE-$VERSION.json"
  mv -- "$stage/BINARY_HASH_CATALOGUE.json" "$RELEASE_DIR/BINARY_HASH_CATALOGUE-$VERSION.json"
  mv -- "$stage/SHA256SUMS" "$RELEASE_DIR/SHA256SUMS-$VERSION"
  "$python_core" "$CORE" verify-release --release "$RELEASE_DIR" --version "$VERSION" >/dev/null
  rm -rf -- "$stage"
  log "Release $VERSION published and verified in $RELEASE_DIR."
}

cleanup() {
  local rc=$?
  if [[ "$rc" == 0 ]]; then
    if [[ "$KEEP_BUILD" != 1 ]]; then
      rm -rf -- "$BUILD_DIR" || rc=1
      [[ ! -e "$BUILD_DIR" && ! -L "$BUILD_DIR" ]] || rc=1
    fi
  else
    warn "Build did not complete successfully; preserving $BUILD_DIR (already-built targets, logs, and reports are not deleted). Remove it manually once you are done inspecting it, or set NEXS_KEEP_BUILD=1/0 to control this on future successful runs."
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM HUP

rm -rf -- "$BUILD_DIR"
mkdir -m 700 -p -- "$BUILD_DIR/.tmp"
export TMPDIR="$BUILD_DIR/.tmp"
export TMP="$BUILD_DIR/.tmp"
export TEMP="$BUILD_DIR/.tmp"
export NUITKA_CACHE_DIR="$BUILD_DIR/.tmp/nuitka-cache"
export NUITKA_CACHE_DIR_DOWNLOADS="$BUILD_DIR/.tmp/nuitka-downloads"
export NUITKA_CACHE_DIR_CCACHE="$BUILD_DIR/.tmp/nuitka-ccache"
export NUITKA_CACHE_DIR_CLCACHE="$BUILD_DIR/.tmp/nuitka-clcache"
export NUITKA_CACHE_DIR_BYTECODE="$BUILD_DIR/.tmp/nuitka-bytecode"
export NUITKA_CACHE_DIR_DLL_DEPENDENCIES="$BUILD_DIR/.tmp/nuitka-dll-dependencies"

need_native_deps=0
for target in "${TARGETS[@]}"; do
  case "$target" in
    macos-x86_64|macos-arm64) need_native_deps=1 ;;
    linux-x86_64) [[ "$host_os" == Linux && "$host_arch" == x86_64 && "$(host_libc)" == glibc ]] && need_native_deps=1 ;;
    linux-aarch64) [[ "$host_os" == Linux && "$host_arch" == arm64 && "$(host_libc)" == glibc ]] && need_native_deps=1 ;;
  esac
done
if [[ "$need_native_deps" == 1 ]]; then
  install_system_deps
fi

# Each target is built in its own subshell so that a failure (die/exit) in
# one target only ends that target's subshell, not the whole script: the
# remaining requested targets are still attempted. `trap - ...` inside the
# subshell is required because subshells inherit the parent's EXIT trap, and
# without resetting it here a *successful* target would trigger cleanup()
# and delete $BUILD_DIR (with every other target's work) before the loop
# even continues.
SUCCEEDED_TARGETS=()
FAILED_TARGETS=()
for target in "${TARGETS[@]}"; do
  target_ok=1
  case "$target" in
    linux-musl-x86_64|linux-musl-aarch64)
      if [[ "$IN_CONTAINER" == 1 ]]; then
        ( trap - EXIT INT TERM HUP; build_local_target "$target" ) || target_ok=0
      else
        ( trap - EXIT INT TERM HUP; build_in_linux_container "$target" ) || target_ok=0
      fi ;;
    linux-aarch64|linux-x86_64)
      if resolve_target_python "$target" >/dev/null 2>&1 && [[ "$(host_libc)" == glibc ]]; then
        ( trap - EXIT INT TERM HUP; build_local_target "$target" ) || target_ok=0
      else
        ( trap - EXIT INT TERM HUP; build_in_linux_container "$target" ) || target_ok=0
      fi ;;
    macos-x86_64|macos-arm64)
      ( trap - EXIT INT TERM HUP; build_local_target "$target" ) || target_ok=0 ;;
    windows-*)
      warn "$target: Windows targets are built by build_release.ps1 or GitHub Actions, not this script."
      target_ok=0 ;;
  esac
  if [[ "$target_ok" == 1 ]]; then
    SUCCEEDED_TARGETS+=("$target")
  else
    FAILED_TARGETS+=("$target")
    warn "$target: build FAILED; continuing with the remaining requested targets."
  fi
done

log "Target build summary: ${#SUCCEEDED_TARGETS[@]}/${#TARGETS[@]} succeeded."
((${#SUCCEEDED_TARGETS[@]} == 0)) || log "Succeeded: ${SUCCEEDED_TARGETS[*]}"
if ((${#FAILED_TARGETS[@]} > 0)); then
  warn "Failed: ${FAILED_TARGETS[*]}"
  warn "No release was published: a release bundle requires every requested target to succeed, so a partial one is never assembled or marked complete."
  warn "Already-built target packages are preserved under $BUILD_DIR for inspection (see above)."
  if [[ -n "${NEXS_ARTIFACT_DIR:-}" ]]; then
    warn "Per-target archives for the targets that did succeed were already copied to $NEXS_ARTIFACT_DIR as each one finished."
  fi
  die "One or more targets failed: ${FAILED_TARGETS[*]}"
fi

"$python_core" "$CORE" audit-kit --root "$ROOT_DIR" --checksums "$KIT_CHECKSUMS" || die "Build-kit integrity changed during the build."
"$python_core" "$CORE" audit-tools --tools-dir "$SCRIPT_DIR" --checksums "$TOOL_CHECKSUMS" || die "Build-tool integrity changed during the build."

if [[ "$NO_PUBLISH" == 1 ]]; then
  log "Target build(s) completed and verified; release publication disabled by NEXS_NO_PUBLISH=1."
  exit 0
fi
publish_release