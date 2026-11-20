#!/bin/bash
# Bundles QEMU's `qemu-nbd` for the root helper (see bundle-tool.sh): the helper runs it as root on a USB
# drive's raw disk, and QEMU reads the disk from it over a unix socket only the user can open.
#
#   scripts/bundle-qemu-nbd.sh <folder> [<qemu-nbd>]   -> <folder>/qemu-nbd, <folder>/lib/*.dylib
# Without <qemu-nbd>: Tandem's own QEMU build in ~/Library/Application Support/Tandem/qemu.
set -euo pipefail
dest=${1:?usage: bundle-qemu-nbd.sh <folder> [<qemu-nbd>]}
source_tool=${2:-"$HOME/Library/Application Support/Tandem/qemu/bin/qemu-nbd"}
[ -x "$source_tool" ] || { echo "qemu-nbd not found at $source_tool. Build QEMU with scripts/build-qemu.sh." >&2; exit 1; }
exec "$(dirname "$0")/bundle-tool.sh" "$source_tool" "$dest" --version
