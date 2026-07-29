#!/bin/bash
# Tools/LayoutLab/run.sh
# Builds and runs LayoutLab in one step. No Xcode project, no simulator:
# Sources/Engine/**/*.swift is platform-pure (Foundation/CoreGraphics only)
# and links directly against this tool's own sources via plain `swiftc`,
# the same recipe the Project Build Guide already uses for Tests/SmokeTest.swift.
#
# Usage: Tools/LayoutLab/run.sh <photo-folder> [setSize=4] [outputDir]
#
# NOTE: `timeout` is not installed on macOS - do not add it to this script,
# it fails in a way indistinguishable from the command itself hanging (see
# the Build Guide's own trap list).
set -euo pipefail

if [ -z "${1:-}" ]; then
  echo "Usage: $0 <photo-folder> [setSize=4] [outputDir]" >&2
  echo "  <photo-folder>  Folder of JPEG/HEIC/PNG photos to test." >&2
  echo "  [setSize]       2-4, default 4." >&2
  echo "  [outputDir]     Default: \$TMPDIR/LayoutLab-output (never inside the repo -" >&2
  echo "                  this repo is PUBLIC and test photos must never land in it)." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PHOTO_DIR="$1"
SET_SIZE="${2:-4}"
OUTPUT_DIR="${3:-${TMPDIR:-/tmp}LayoutLab-output}"

# Safety net (see the tool's file-ownership rules): output must never resolve
# inside this repo's working tree, since a rendered sheet embeds the actual
# personal test photos and the repo is public. mkdir first so realpath can
# resolve a not-yet-existing directory.
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR_REAL="$(cd "$OUTPUT_DIR" && pwd)"
case "$OUTPUT_DIR_REAL" in
  "$REPO_ROOT"|"$REPO_ROOT"/*)
    echo "Refusing to write output inside the repo ($REPO_ROOT) - this repo is public." >&2
    echo "Pass an outputDir outside the repo (the default, \$TMPDIR/LayoutLab-output, already is one)." >&2
    exit 1
    ;;
esac

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

# xattr -cr avoids a quarantine-flag build failure on Engine sources copied
# in from elsewhere (same guard the Build Guide's own smoke-test recipe uses).
xattr -cr "$REPO_ROOT/Sources/Engine" 2>/dev/null || true

echo "Building LayoutLab..."
swiftc -O \
  "$REPO_ROOT/Sources/Engine"/*.swift \
  "$SCRIPT_DIR/Sources"/*.swift \
  -o "$BUILD_DIR/layoutlab"

echo "Running LayoutLab..."
"$BUILD_DIR/layoutlab" "$PHOTO_DIR" "$OUTPUT_DIR" "$SET_SIZE"
