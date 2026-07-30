#!/bin/bash
# Tools/WeightSweep/run.sh
# Builds and runs WeightSweep in one step - the framingCost weight-tuning
# decision aid, sibling to Tools/LayoutLab. No Xcode project, no simulator:
# Sources/Engine/**/*.swift is platform-pure (Foundation/CoreGraphics only)
# and links directly against this tool's own main.swift PLUS three files
# reused unchanged from Tools/LayoutLab/Sources (PhotoLoading.swift,
# VisionDetect.swift, Render.swift - Vision detection and rendering do not
# depend on framingCost's weights, so there is no reason to duplicate them)
# via one `swiftc` invocation, the same recipe the Project Build Guide
# already uses for Tests/SmokeTest.swift and Tools/LayoutLab itself.
#
# IMPORTANT: do NOT add Tools/LayoutLab/Sources/main.swift to this build -
# swiftc treats a file literally named `main.swift` as THE top-level-code
# file for the whole compilation, and two of them in one invocation is a
# build error (and would run the wrong tool's logic besides).
#
# Usage: Tools/WeightSweep/run.sh <photo-folder> [setSize=4] [outputDir]
#
# NOTE: `timeout` is not installed on macOS - do not add it to this script,
# it fails in a way indistinguishable from the command itself hanging (see
# the Build Guide's own trap list).
set -euo pipefail

if [ -z "${1:-}" ]; then
  echo "Usage: $0 <photo-folder> [setSize=4] [outputDir]" >&2
  echo "  <photo-folder>  Folder of JPEG/HEIC/PNG photos to test." >&2
  echo "  [setSize]       2-4, default 4." >&2
  echo "  [outputDir]     Default: \$TMPDIR/WeightSweep-output (never inside the repo -" >&2
  echo "                  this repo is PUBLIC and test photos must never land in it)." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LAYOUTLAB_SRC="$REPO_ROOT/Tools/LayoutLab/Sources"

PHOTO_DIR="$1"
SET_SIZE="${2:-4}"
OUTPUT_DIR="${3:-${TMPDIR:-/tmp}WeightSweep-output}"

# Safety net (see the tool's file-ownership rules): output must never resolve
# inside this repo's working tree, since a rendered sheet embeds the actual
# personal test photos and the repo is public. mkdir first so realpath can
# resolve a not-yet-existing directory. Same guard LayoutLab's run.sh has.
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR_REAL="$(cd "$OUTPUT_DIR" && pwd)"
case "$OUTPUT_DIR_REAL" in
  "$REPO_ROOT"|"$REPO_ROOT"/*)
    echo "Refusing to write output inside the repo ($REPO_ROOT) - this repo is public." >&2
    echo "Pass an outputDir outside the repo (the default, \$TMPDIR/WeightSweep-output, already is one)." >&2
    exit 1
    ;;
esac

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

# xattr -cr avoids a quarantine-flag build failure on sources copied in from
# elsewhere (same guard the Build Guide's own smoke-test recipe uses).
xattr -cr "$REPO_ROOT/Sources/Engine" 2>/dev/null || true
xattr -cr "$LAYOUTLAB_SRC" 2>/dev/null || true

echo "Building WeightSweep..."
swiftc -O \
  "$REPO_ROOT/Sources/Engine"/*.swift \
  "$LAYOUTLAB_SRC/PhotoLoading.swift" \
  "$LAYOUTLAB_SRC/VisionDetect.swift" \
  "$LAYOUTLAB_SRC/Render.swift" \
  "$SCRIPT_DIR/Sources/main.swift" \
  -o "$BUILD_DIR/weightsweep"

echo "Running WeightSweep..."
"$BUILD_DIR/weightsweep" "$PHOTO_DIR" "$OUTPUT_DIR" "$SET_SIZE"
