#!/bin/sh
#
# Nexs Ledger build-manifest generator.
#
# MUST reside in: <project-root>/nexs_build_tools/
#
# Generates and verifies:
#   <project-root>/nexs_build_tools/BUILD_TOOLS_SHA256SUMS
#   <project-root>/BUILD_KIT_SHA256SUMS
#
# SHA-256 calculation and verification use ONLY sha256sum.
# No shasum, openssl, Python, Get-FileHash, or alternate implementation.
#
# The file sets intentionally follow the build-core audit rules:
#   audit_tools():
#       entire nexs_build_tools tree, except BUILD_TOOLS_SHA256SUMS
#       and __pycache__ directories.
#   audit_kit():
#       entire project tree, except BUILD_KIT_SHA256SUMS itself,
#       top-level build/, release/, .git/, .venv/, and any __pycache__ directories.
#
# Dynamic exclusions:
#   <project-root>/.gitignore is read at runtime (when present) and its
#   non-comment, non-negated patterns are merged with the project invariants
#   (build/, release/, .git/, .venv/, __pycache__/). The two anchors
#   BUILD_KIT_SHA256SUMS and BUILD_TOOLS_SHA256SUMS are never excluded, so
#   the kit manifest can always bind the tool manifest.
#
# Existing manifests are verified first. They are replaced only with
# --update, or when the manifest does not yet exist.
#

set -eu

umask 077
LC_ALL=C
export LC_ALL

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P) || {
    printf '%s\n' '[nexs-manifest][ERROR] Unable to resolve script directory.' >&2
    exit 1
}

TOOLS_BASENAME=$(basename -- "$SCRIPT_DIR")
[ "$TOOLS_BASENAME" = nexs_build_tools ] || {
    printf '%s\n' '[nexs-manifest][ERROR] generate_build_manifests.sh must reside in nexs_build_tools/.' >&2
    exit 1
}

ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P) || {
    printf '%s\n' '[nexs-manifest][ERROR] Unable to resolve project root.' >&2
    exit 1
}

TOOLS_DIR="$SCRIPT_DIR"
TOOL_MANIFEST="$TOOLS_DIR/BUILD_TOOLS_SHA256SUMS"
KIT_MANIFEST="$ROOT_DIR/BUILD_KIT_SHA256SUMS"

GITIGNORE_PATH="$ROOT_DIR/.gitignore"
GITIGNORE_PATTERNS=""

UPDATE=0

usage() {
    cat <<USAGE
Usage: generate_build_manifests.sh [--update] [-h|--help]

Generate/verify the two Nexs Ledger checksum manifests.

  default       generate a missing manifest; otherwise verify that it is current
  --update      explicitly replace an existing stale manifest
  -h, --help    show this help

The script must be located at:
  <project-root>/nexs_build_tools/generate_build_manifests.sh

SHA-256 implementation:
  sha256sum only

Exclusion source:
  <project-root>/.gitignore (when present) plus the project invariants
  build/, release/, .git/, .venv/, __pycache__/.
  The two anchors BUILD_KIT_SHA256SUMS and BUILD_TOOLS_SHA256SUMS are
  never excluded.
USAGE
}

die() {
    printf '%s\n' "[nexs-manifest][ERROR] $*" >&2
    exit 1
}

log() {
    printf '%s\n' "[nexs-manifest] $*"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --update)
            UPDATE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

[ -d "$ROOT_DIR" ] || die "Project root is not a directory: $ROOT_DIR"
[ -d "$TOOLS_DIR" ] || die "Build-tools directory is missing: $TOOLS_DIR"
[ ! -L "$TOOLS_DIR" ] || die "Build-tools directory is a symlink: $TOOLS_DIR"

SHA256SUMS=$(command -v sha256sum 2>/dev/null || true)
[ -n "$SHA256SUMS" ] || die "sha256sum is required; no alternate hash implementation is permitted."
[ -x "$SHA256SUMS" ] || die "sha256sum is not executable: $SHA256SUMS"

# ---------------------------------------------------------------------------
# Dynamic .gitignore support
# ---------------------------------------------------------------------------
# load_gitignore_patterns() materialises every active .gitignore pattern into
# a temporary file, then appends the project invariants. Negated patterns
# ('!...') and comments are skipped: the manifest generator is deliberately
# conservative — it includes a file that .gitignore would exclude rather than
# risk hashing something the audit function will not see.
#
# The parsing is intentionally minimal:
#   - comments ('#' prefix) and blank lines are skipped
#   - negation patterns ('!' prefix) are skipped
#   - trailing whitespace is removed
#   - a leading '/' (anchored) is preserved as a hint that the pattern is
#     rooted; path_matches_gitignore() interprets it accordingly.
load_gitignore_patterns() {
    if [ ! -e "$GITIGNORE_PATH" ]; then
        GITIGNORE_PATTERNS=$(mktemp "${TMPDIR:-/tmp}/nexs-gitignore.XXXXXX") ||
            die "Unable to create temporary gitignore pattern list."
        chmod 0600 "$GITIGNORE_PATTERNS" ||
            die "Unable to restrict temporary gitignore pattern list."
        cat > "$GITIGNORE_PATTERNS" <<'EOF'
build
release
.git
.venv
__pycache__
EOF
        return 0
    fi

    [ ! -L "$GITIGNORE_PATH" ] || die "Project .gitignore is a symlink: $GITIGNORE_PATH"
    [ -f "$GITIGNORE_PATH" ] || die "Project .gitignore is not a regular file: $GITIGNORE_PATH"

    GITIGNORE_PATTERNS=$(mktemp "${TMPDIR:-/tmp}/nexs-gitignore.XXXXXX") ||
        die "Unable to create temporary gitignore pattern list."
    chmod 0600 "$GITIGNORE_PATTERNS" ||
        die "Unable to restrict temporary gitignore pattern list."

    while IFS= read -r raw_line || [ -n "$raw_line" ]; do
        # Strip trailing whitespace; .gitignore treats trailing spaces as
        # insignificant unless backslash-escaped, which we do not support.
        line=$(printf '%s' "$raw_line" | sed 's/[[:space:]]*$//')
        case "$line" in
            ''|'#'*) continue ;;
            '!'*) continue ;;
        esac
        printf '%s\n' "$line" >> "$GITIGNORE_PATTERNS"
    done < "$GITIGNORE_PATH"

    # Project invariants are always appended, so a user removing them from
    # .gitignore cannot accidentally hash build artifacts or virtualenvs.
    cat >> "$GITIGNORE_PATTERNS" <<'EOF'
build
release
.git
.venv
__pycache__
EOF
}

# path_matches_gitignore() returns 0 when the relative path should be excluded.
# It supports:
#   - basename globs    : "*.nxsl", "__pycache__", ".DS_Store"
#   - path globs        : "docs/*.tmp", "src/**/cache"
#   - anchored patterns : "/build" (matched relative to the enumeration root)
#   - directory markers : "build/" (trailing slash stripped)
#
# Any pattern is matched against the full relative path (with leading slash
# stripped). Basename patterns additionally match any path component.
path_matches_gitignore() {
    _pmg_rel="$1"
    [ -n "$GITIGNORE_PATTERNS" ] || return 1
    [ -s "$GITIGNORE_PATTERNS" ] || return 1

    _pmg_ignored=1
    while IFS= read -r _pmg_pat || [ -n "$_pmg_pat" ]; do
        [ -n "$_pmg_pat" ] || continue

        # Strip leading slash (anchoring is implicit: our paths are already
        # relative to the enumeration root).
        case "$_pmg_pat" in
            /*) _pmg_pat="${_pmg_pat#/}" ;;
        esac
        # Strip trailing slash (directory-only marker is irrelevant for us
        # because we only ever test regular files).
        case "$_pmg_pat" in
            */) _pmg_pat="${_pmg_pat%/}" ;;
        esac
        [ -n "$_pmg_pat" ] || continue

        _pmg_match=0
        case "$_pmg_pat" in
            */*)
                # Path pattern (contains a slash): match against the full
                # relative path at any depth.
                case "$_pmg_rel" in
                    $_pmg_pat) _pmg_match=1 ;;
                    $_pmg_pat/*) _pmg_match=1 ;;
                    */$_pmg_pat) _pmg_match=1 ;;
                    */$_pmg_pat/*) _pmg_match=1 ;;
                esac
                ;;
            *)
                # Basename pattern: match any path component.
                _pmg_old_ifs=$IFS
                IFS=/
                for _pmg_comp in $_pmg_rel; do
                    case "$_pmg_comp" in
                        $_pmg_pat) _pmg_match=1; break ;;
                    esac
                done
                IFS=$_pmg_old_ifs
                ;;
        esac

        if [ "$_pmg_match" = 1 ]; then
            _pmg_ignored=0
        fi
    done < "$GITIGNORE_PATTERNS"

    return $_pmg_ignored
}

validate_rel_path() {
    rel=$1

    [ -n "$rel" ] || die "Empty relative manifest path."

    case "$rel" in
        /*|../*|*/../*|./*|*/./*|*//*|*"$(printf '\t')"*)
            die "Unsafe/non-canonical relative manifest path: $rel"
            ;;
    esac

    case "$rel" in
        " "*|*" ")
            die "Manifest path has leading/trailing whitespace: $rel"
            ;;
    esac
}

hash_file() {
    file=$1
    [ -f "$file" ] || die "Cannot hash non-regular file: $file"
    [ ! -L "$file" ] || die "Cannot hash symlink: $file"

    digest=$(sha256sum -- "$file" | awk 'NR == 1 { print tolower($1); exit }') ||
        die "sha256sum failed: $file"

    case "$digest" in
        "") die "sha256sum returned no digest: $file" ;;
        *[!0123456789abcdef]*) die "sha256sum returned an invalid digest for: $file" ;;
    esac

    [ "$(printf '%s' "$digest" | wc -c | tr -d '[:space:]')" = 64 ] ||
        die "sha256sum did not return a 256-bit digest: $file"

    printf '%s\n' "$digest"
}

# Build a stable list of paths without placing helper files inside the tree.
# GNU/macOS find differences are avoided by using only POSIX find primitives.
collect_paths() {
    cp_base=$1
    cp_mode=$2
    cp_output=$3
    cp_skip_manifest=$4
    cp_skip_temporary=$5

    : > "$cp_output" || die "Unable to create path list: $cp_output"

    (
        cd -- "$cp_base" || exit 1

        case "$cp_mode" in
            tools)
                find . \
                    \( -type d -name '__pycache__' -prune \) -o \
                    -print
                ;;
            kit)
                find . \
                    \( -type d -name '__pycache__' -prune \) -o \
                    \( -type d \
                       \( -path './build' -o -path './release' -o -path './.git' -o -path './.venv' \) \
                       -prune \) -o \
                    -print
                ;;
            *)
                exit 2
                ;;
        esac
    ) | LC_ALL=C sort > "$cp_output" || die "Unable to enumerate $cp_mode tree."
}

build_manifest_candidate() {
    bmc_base=$1
    bmc_mode=$2
    bmc_output=$3
    bmc_skip_manifest=$4
    bmc_skip_temporary=$5
    bmc_path_list=$6

    : > "$bmc_output" || die "Unable to create manifest candidate: $bmc_output"

    collect_paths "$bmc_base" "$bmc_mode" "$bmc_path_list" \
        "$bmc_skip_manifest" "$bmc_skip_temporary"

    bmc_count=0

    while IFS= read -r bmc_relative_or_path || [ -n "$bmc_relative_or_path" ]; do
        [ -n "$bmc_relative_or_path" ] || continue

        case "$bmc_relative_or_path" in
            .)
                continue
                ;;
        esac

        bmc_path="$bmc_base/${bmc_relative_or_path#./}"

        # Always exclude the manifest itself and the in-progress candidate.
        if [ "$bmc_path" = "$bmc_skip_manifest" ] || [ "$bmc_path" = "$bmc_skip_temporary" ]; then
            continue
        fi

        if [ -L "$bmc_path" ]; then
            die "Symlink/reparse-like path found in $bmc_mode tree: $bmc_path"
        fi

        if [ -d "$bmc_path" ]; then
            continue
        fi

        [ -f "$bmc_path" ] || die "Non-regular entry found in $bmc_mode tree: $bmc_path"

        bmc_rel=${bmc_relative_or_path#./}
        validate_rel_path "$bmc_rel"

        # Dynamic .gitignore-driven exclusion. Anchors are never excluded.
        case "$bmc_rel" in
            BUILD_KIT_SHA256SUMS|BUILD_TOOLS_SHA256SUMS|nexs_build_tools/BUILD_TOOLS_SHA256SUMS)
                ;;
            *)
                if path_matches_gitignore "$bmc_rel"; then
                    continue
                fi
                ;;
        esac

        bmc_digest=$(hash_file "$bmc_path")
        printf '%s  %s\n' "$bmc_digest" "$bmc_rel" >> "$bmc_output" ||
            die "Unable to write checksum entry: $bmc_rel"

        bmc_count=$((bmc_count + 1))
    done < "$bmc_path_list"

    [ "$bmc_count" -gt 0 ] || die "Generated checksum manifest is empty: $bmc_output"

    # Keep generation deterministic and compatible with sha256sum --check.
    sort -o "$bmc_output" "$bmc_output" || die "Unable to sort generated manifest: $bmc_output"

    # Validate every generated line once before publication.
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || die "Empty line in generated manifest: $bmc_output"
        bmc_line_digest=${line%%  *}
        bmc_line_rel=${line#*  }
        case "$bmc_line_digest" in
            ""|*[!0123456789abcdef]*) die "Invalid generated digest: $bmc_output" ;;
        esac
        [ "$(printf '%s' "$bmc_line_digest" | wc -c | tr -d '[:space:]')" = 64 ] ||
            die "Invalid generated SHA-256 length: $bmc_output"
        validate_rel_path "$bmc_line_rel"
    done < "$bmc_output"
}

verify_manifest_with_sha256sum() {
    manifest=$1
    directory=$2

    [ -f "$manifest" ] || die "Manifest is missing: $manifest"
    [ ! -L "$manifest" ] || die "Manifest is a symlink: $manifest"

    (
        cd -- "$directory" || exit 1
        sha256sum --strict --check "$(basename -- "$manifest")" >/dev/null
    ) || die "sha256sum verification failed: $manifest"
}

manifest_equal() {
    left=$1
    right=$2
    cmp -s -- "$left" "$right"
}

publish_candidate() {
    candidate=$1
    destination=$2

    [ -f "$candidate" ] || die "Candidate manifest is missing: $candidate"
    [ ! -L "$candidate" ] || die "Candidate manifest is a symlink: $candidate"

    chmod 0600 "$candidate" || die "Unable to restrict candidate permissions: $candidate"

    mv -f -- "$candidate" "$destination" || die "Unable to publish manifest: $destination"
}

TMP_TOOL=""
TMP_KIT=""
TMP_TOOL_PATHS=""
TMP_KIT_PATHS=""

cleanup() {
    rc=$?
    [ -z "$TMP_TOOL" ] || rm -f -- "$TMP_TOOL" 2>/dev/null || true
    [ -z "$TMP_KIT" ] || rm -f -- "$TMP_KIT" 2>/dev/null || true
    [ -z "$TMP_TOOL_PATHS" ] || rm -f -- "$TMP_TOOL_PATHS" 2>/dev/null || true
    [ -z "$TMP_KIT_PATHS" ] || rm -f -- "$TMP_KIT_PATHS" 2>/dev/null || true
    [ -z "$GITIGNORE_PATTERNS" ] || rm -f -- "$GITIGNORE_PATTERNS" 2>/dev/null || true
    exit "$rc"
}
trap cleanup EXIT HUP INT TERM

# Load dynamic exclusions up front so the tool and kit manifest see the same
# pattern set for the whole run.
load_gitignore_patterns

# ---------------------------------------------------------------------------
# TOOL MANIFEST
# ---------------------------------------------------------------------------
# Candidate is created beside the final manifest so publication is same-filesystem.
TMP_TOOL=$(mktemp "$TOOLS_DIR/.BUILD_TOOLS_SHA256SUMS.tmp.XXXXXX") ||
    die "Unable to create temporary tool manifest."
TMP_TOOL_PATHS=$(mktemp "${TMPDIR:-/tmp}/nexs-build-tools-paths.XXXXXX") ||
    die "Unable to create temporary tool path list."

chmod 0600 "$TMP_TOOL" "$TMP_TOOL_PATHS" ||
    die "Unable to restrict temporary tool files."

build_manifest_candidate \
    "$TOOLS_DIR" \
    tools \
    "$TMP_TOOL" \
    "$TOOL_MANIFEST" \
    "$TMP_TOOL" \
    "$TMP_TOOL_PATHS"

if [ -f "$TOOL_MANIFEST" ]; then
    if [ "$UPDATE" -eq 0 ]; then
        verify_manifest_with_sha256sum "$TOOL_MANIFEST" "$TOOLS_DIR"
        manifest_equal "$TOOL_MANIFEST" "$TMP_TOOL" ||
            die "BUILD_TOOLS_SHA256SUMS is stale; rerun with --update after reviewing changes."
        rm -f -- "$TMP_TOOL"
        TMP_TOOL=""
        log "BUILD_TOOLS_SHA256SUMS is current."
    else
        publish_candidate "$TMP_TOOL" "$TOOL_MANIFEST"
        TMP_TOOL=""
        verify_manifest_with_sha256sum "$TOOL_MANIFEST" "$TOOLS_DIR"
        log "BUILD_TOOLS_SHA256SUMS regenerated."
    fi
else
    publish_candidate "$TMP_TOOL" "$TOOL_MANIFEST"
    TMP_TOOL=""
    verify_manifest_with_sha256sum "$TOOL_MANIFEST" "$TOOLS_DIR"
    log "BUILD_TOOLS_SHA256SUMS generated."
fi

# ---------------------------------------------------------------------------
# ROOT BUILD-KIT MANIFEST
# ---------------------------------------------------------------------------
TMP_KIT=$(mktemp "$ROOT_DIR/.BUILD_KIT_SHA256SUMS.tmp.XXXXXX") ||
    die "Unable to create temporary build-kit manifest."
TMP_KIT_PATHS=$(mktemp "${TMPDIR:-/tmp}/nexs-build-kit-paths.XXXXXX") ||
    die "Unable to create temporary build-kit path list."

chmod 0600 "$TMP_KIT" "$TMP_KIT_PATHS" ||
    die "Unable to restrict temporary build-kit files."

build_manifest_candidate \
    "$ROOT_DIR" \
    kit \
    "$TMP_KIT" \
    "$KIT_MANIFEST" \
    "$TMP_KIT" \
    "$TMP_KIT_PATHS"

if [ -f "$KIT_MANIFEST" ]; then
    if [ "$UPDATE" -eq 0 ]; then
        verify_manifest_with_sha256sum "$KIT_MANIFEST" "$ROOT_DIR"
        manifest_equal "$KIT_MANIFEST" "$TMP_KIT" ||
            die "BUILD_KIT_SHA256SUMS is stale; rerun with --update after reviewing changes."
        rm -f -- "$TMP_KIT"
        TMP_KIT=""
        log "BUILD_KIT_SHA256SUMS is current."
    else
        publish_candidate "$TMP_KIT" "$KIT_MANIFEST"
        TMP_KIT=""
        verify_manifest_with_sha256sum "$KIT_MANIFEST" "$ROOT_DIR"
        log "BUILD_KIT_SHA256SUMS regenerated."
    fi
else
    publish_candidate "$TMP_KIT" "$KIT_MANIFEST"
    TMP_KIT=""
    verify_manifest_with_sha256sum "$KIT_MANIFEST" "$ROOT_DIR"
    log "BUILD_KIT_SHA256SUMS generated."
fi

# The root trust manifest MUST bind the tool manifest.
grep -Eq '^[0-9A-Fa-f]{64}  nexs_build_tools/BUILD_TOOLS_SHA256SUMS$' "$KIT_MANIFEST" ||
    die "BUILD_KIT_SHA256SUMS does not bind nexs_build_tools/BUILD_TOOLS_SHA256SUMS."

# Final verification with sha256sum only.
verify_manifest_with_sha256sum "$TOOL_MANIFEST" "$TOOLS_DIR"
verify_manifest_with_sha256sum "$KIT_MANIFEST" "$ROOT_DIR"

log "Manifest generation/verification completed successfully."
printf '%s\n' "[nexs-manifest] Tool manifest: $TOOL_MANIFEST"
printf '%s\n' "[nexs-manifest] Kit manifest:  $KIT_MANIFEST"
printf '%s\n' "[nexs-manifest] Hash implementation: $SHA256SUMS"
