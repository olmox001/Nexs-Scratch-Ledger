#!/usr/bin/env bash
# Nexs Scratch Ledger - development environment manager (macOS/Linux).
#
# Verifies/creates the project's own development virtualenv (NOT the
# disposable, hash-pinned venv the release build creates under ./build/*/venv)
# and installs the runtime dependencies declared in requirements.txt.
#
# Usage:
#   ./setup_env.sh            Create the venv if missing, verify/install deps,
#                              then just exit 0. Safe to run every time; if the
#                              venv already exists and is healthy, it does
#                              nothing but a quick check.
#   ./setup_env.sh --clean     Remove ONLY this development venv and exit.
#   ./setup_env.sh --help      Show this help.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

# ---------------------------------------------------------------------------
# BEGIN: environment sanitisation (added fix)
#
# This script can be run from *any* working directory, including one that
# happens to contain a CPython 3.12 runtime shipped inside a compiled Nuitka
# --standalone release bundle (e.g. an extracted "release/<target-version>/"
# directory, or a copy of one that has since been moved into ~/.Trash). Such
# a directory contains _posixsubprocess.so, _blake2.so, _hashlib.so,
# libpython3.12.dylib / libpython3.12.so, python312.dll, and similar native
# modules, all compiled against the exact CPython minor version used at
# build time.
#
# CPython prepends the current working directory to sys.path when a process
# is started with -m (as setup_env.sh itself starts "python -m venv"), and
# it also honours any inherited PYTHONPATH. Either mechanism can make a
# differently-versioned interpreter (e.g. Homebrew 3.13, or any other
# system python3) load the bundle's CPython 3.12 native extension modules
# in place of its own stdlib. The failure occurs during interpreter
# bootstrap, before this script's own checks can run: on macOS it surfaces
# as "symbol not found in flat namespace '__PyLong_AsInt'", on Linux as an
# undefined-symbol dlopen error, on Windows as a missing-export error from
# pythonXY.dll. In the specific case of "python -m venv" the failing import
# is subprocess -> _posixsubprocess, which aborts virtualenv creation
# before a single line of this script's logic has executed.
#
# Clearing the environment here, before any Python invocation, is therefore
# the only place this can be fixed from inside setup_env.sh.
#
# PYTHONSAFEPATH=1 is honoured by CPython 3.11+ on every platform and is
# equivalent to the -P command-line flag: it stops CPython from prepending
# a potentially unsafe path (CWD for -m/-c, the script's directory for a
# file argument) to sys.path. On older interpreters it is silently ignored
# (the variable does not exist there and neither does -P), but clearing
# PYTHONPATH and PYTHONHOME still eliminates the other two ways a stray
# directory can end up on sys.path first. PYTHONNOUSERSITE=1 additionally
# prevents ~/.local/lib/pythonX.Y/site-packages (and any .pth file dropped
# there) from participating in sys.path resolution for this script's own
# interpreter - the venv created below has its own site-packages and does
# not need the user-site tree.
# ---------------------------------------------------------------------------
export PYTHONDONTWRITEBYTECODE=1
export PYTHONHASHSEED=0
export PYTHONNOUSERSITE=1
export PYTHONSAFEPATH=1
unset PYTHONPATH PYTHONHOME PYTHONSTARTUP PYTHONUSERBASE \
      PYTHONINSPECT PYTHONBREAKPOINT PYTHONOPTIMIZE PYTHONDEBUG || true
# ---------------------------------------------------------------------------
# END: environment sanitisation
# ---------------------------------------------------------------------------

log()  { printf '[nexs-env] %s\n' "$*"; }
warn() { printf '[nexs-env][WARN] %s\n' "$*" >&2; }
die()  { printf '[nexs-env][ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: setup_env.sh [-clean|--clean] [-h|--help]

  (no flags)      Create the development virtualenv if it does not exist yet,
                  verify/install runtime dependencies, then exit. Safe to run
                  on every invocation (including from build_release.sh).
  -clean/--clean  Remove ONLY the development virtualenv (./.venv) and exit.
                  Never touches the build system's own disposable venvs
                  under ./build/*/venv - those are cleaned by the build
                  scripts themselves.
  -h/--help       Show this help.
EOF
}

# Resolve paths relative to THIS file, not the caller's CWD, so the script
# behaves the same no matter where it is invoked from.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$SCRIPT_DIR"
VENV_DIR="${NEXS_DEV_VENV_DIR:-$ROOT_DIR/.venv}"
REQ_FILE="$ROOT_DIR/requirements.txt"

# Minimum Python the source actually needs; 3.12.x is only the release-build
# baseline (see nexs_build_tools/BUILD.md), not a hard requirement to run
# main.py from source, so accept any modern 3.x here and just recommend 3.12.
MIN_MAJOR=3
MIN_MINOR=9
RECOMMENDED_MINOR=12
AUTO_ACCEPT_PIP="${NEXS_AUTO_ACCEPT_PIP:-0}"

CLEAN=0
for arg in "$@"; do
  case "$arg" in
    -clean|--clean) CLEAN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $arg (see --help)" ;;
  esac
done

# Refuse to ever resolve VENV_DIR to something outside the project root or to
# the build tree, however NEXS_DEV_VENV_DIR is overridden.
case "$VENV_DIR" in
  "$ROOT_DIR"/build|"$ROOT_DIR"/build/*) die "NEXS_DEV_VENV_DIR must not point inside ./build (that tree belongs to the release build)." ;;
esac
resolved_parent="$(cd -- "$(dirname -- "$VENV_DIR")" 2>/dev/null && pwd -P || true)"
if [[ -n "$resolved_parent" ]]; then
  case "$resolved_parent" in
    "$ROOT_DIR"|"$ROOT_DIR"/*) : ;;
    *) die "NEXS_DEV_VENV_DIR must resolve inside the project root: $VENV_DIR" ;;
  esac
fi

if [[ "$CLEAN" == "1" ]]; then
  if [[ -d "$VENV_DIR" ]]; then
    [[ -L "$VENV_DIR" ]] && die "Refusing to remove a symlink: $VENV_DIR"
    rm -rf -- "$VENV_DIR"
    log "Removed development virtualenv: $VENV_DIR"
  else
    log "No development virtualenv found at $VENV_DIR; nothing to clean."
  fi
  exit 0
fi

find_python() {
  local candidate
  for candidate in python3.13 python3.12 python3.11 python3.10 python3.9 python3 python; do
    if command -v "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

SYSTEM_PYTHON="$(find_python)" || die "No Python ${MIN_MAJOR}.${MIN_MINOR}+ interpreter found on PATH. Install Python (${MIN_MAJOR}.${RECOMMENDED_MINOR}.x recommended) first."

"$SYSTEM_PYTHON" - "$MIN_MAJOR" "$MIN_MINOR" <<'PY' || die "$("$SYSTEM_PYTHON" --version 2>&1) is too old; ${MIN_MAJOR}.${MIN_MINOR}+ is required (${MIN_MAJOR}.${RECOMMENDED_MINOR}.x recommended, matching the release build baseline)."
import sys
min_major, min_minor = int(sys.argv[1]), int(sys.argv[2])
sys.exit(0 if sys.version_info[:2] >= (min_major, min_minor) else 1)
PY

VENV_PY="$VENV_DIR/bin/python"

if [[ ! -x "$VENV_PY" ]]; then
  log "Creating development virtualenv at $VENV_DIR with $("$SYSTEM_PYTHON" --version 2>&1) ..."
  rm -rf -- "$VENV_DIR"
  "$SYSTEM_PYTHON" -m venv "$VENV_DIR" || die "Virtual environment creation failed."
  [[ -x "$VENV_PY" ]] || die "Virtual environment python missing after creation: $VENV_PY"
else
  log "Using existing development virtualenv at $VENV_DIR."
fi

deps_ok() {
  if [[ -f "$REQ_FILE" ]]; then
    "$VENV_PY" - "$REQ_FILE" <<'PY' >/dev/null 2>&1
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
PY
  else
    "$VENV_PY" -c "import cryptography, argon2" >/dev/null 2>&1
  fi
}

if deps_ok; then
  log "Runtime dependencies already satisfied."
else
  if [[ "$AUTO_ACCEPT_PIP" != "1" ]]; then
    printf '[nexs-env] Runtime dependencies are missing from the development virtualenv; install them now? [y/N] '
    IFS= read -r answer
    case "$answer" in y|Y|yes|YES) ;; *) die "Operation declined: install runtime dependencies." ;; esac
  fi
  export PIP_DISABLE_PIP_VERSION_CHECK=1
  "$VENV_PY" -m pip install --disable-pip-version-check --no-input --upgrade pip >/dev/null 2>&1 \
    || warn "Could not upgrade pip inside the virtual environment (continuing)."
  if [[ -f "$REQ_FILE" ]]; then
    log "Installing runtime dependencies from $(basename -- "$REQ_FILE") ..."
    "$VENV_PY" -m pip install --disable-pip-version-check --no-input -r "$REQ_FILE" || die "Dependency installation failed."
  else
    warn "No requirements.txt found at project root; installing known runtime dependencies directly."
    "$VENV_PY" -m pip install --disable-pip-version-check --no-input "cryptography>=41" "argon2-cffi>=23" || die "Dependency installation failed."
  fi
  deps_ok || die "Dependencies were installed but are still not importable; check for a broken virtualenv."
fi

log "Environment ready."
log "  Path:   $VENV_DIR"
log "  Python: $("$VENV_PY" --version 2>&1)"
log "Activate it with: source \"$VENV_DIR/bin/activate\""