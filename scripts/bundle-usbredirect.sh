#!/bin/bash
# Bundles usbredir's `usbredirect` tool for the root helper (see bundle-tool.sh). Needs: brew install usbredir.
#
#   scripts/bundle-usbredirect.sh <folder>      -> <folder>/usbredirect, <folder>/lib/*.dylib
set -euo pipefail
dest=${1:?usage: bundle-usbredirect.sh <folder>}
source_tool=$(command -v usbredirect || true)
[ -n "$source_tool" ] || { echo "usbredirect is not installed. Run: brew install usbredir" >&2; exit 1; }
exec "$(dirname "$0")/bundle-tool.sh" "$source_tool" "$dest" --help
