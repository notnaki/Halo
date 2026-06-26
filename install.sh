#!/bin/sh
# Build halo (release) and copy the binaries onto PATH so `halo` works from
# anywhere — independent of the build directory.
# Usage: ./install.sh [DEST_DIR]   (default /usr/local/bin)
set -e
cd "$(dirname "$0")"
swift build -c release
SRC="$(pwd)/.build/release"
DEST="${1:-/usr/local/bin}"
# Copy all three so `halo` finds its halod/halo-attach siblings next to it
# (a symlink into .build breaks if the build dir is cleaned or moved).
cp -f "$SRC/halo" "$SRC/halod" "$SRC/halo-attach" "$DEST/"
echo "installed halo, halod, halo-attach -> $DEST"
echo "try: halo help"
