#!/bin/sh
#
# Nexs Ledger build-manifest cleaner.
#
# MUST reside in: <project-root>/nexs_build_tools/
#
# Removes the two generated checksum manifests so they can be regenerated
# from scratch with generate_build_manifests.sh:
#   <project-root>/nexs_build_tools/BUILD_TOOLS_SHA256SUMS
#   <project-root>/BUILD_KIT_SHA256SUMS
#
# Refuses to touch anything that is not a plain regular file at exactly
# those two locations (no symlinks, no directories).
#

set -eu

die() {
    printf '%s\n' "[nexs-clean][ERROR] $*" >&2
    exit 1
}

log() {
    printf '%s\n' "[nexs-clean] $*"
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P) ||
    die "Unable to resolve script directory."

TOOLS_BASENAME=$(basename -- "$SCRIPT_DIR")
[ "$TOOLS_BASENAME" = nexs_build_tools ] ||
    die "clean_manifest.sh must reside in nexs_build_tools/."

ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P) ||
    die "Unable to resolve project root."

TOOL_MANIFEST="$SCRIPT_DIR/BUILD_TOOLS_SHA256SUMS"
KIT_MANIFEST="$ROOT_DIR/BUILD_KIT_SHA256SUMS"

remove_manifest() {
    path=$1
    label=$2

    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
        log "$label already absent: $path"
        return 0
    fi

    [ ! -L "$path" ] || die "$label is a symlink, refusing to remove: $path"
    [ -f "$path" ] || die "$label is not a regular file, refusing to remove: $path"

    rm -f -- "$path" || die "Unable to remove $label: $path"
    log "Removed $label: $path"
}

remove_manifest "$TOOL_MANIFEST" "BUILD_TOOLS_SHA256SUMS"
remove_manifest "$KIT_MANIFEST" "BUILD_KIT_SHA256SUMS"

log "Done. Run generate_build_manifests.sh to regenerate."
