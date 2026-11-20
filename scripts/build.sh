#!/bin/sh
# Builds the host package and signs vmctl with the virtualization entitlement (ad hoc, local use only).
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
config="${1:-debug}"
swift build --package-path "$root/host" -c "$config"
bin="$root/host/.build/$config/vmctl"
codesign --force --sign - --entitlements "$root/scripts/vmctl.entitlements" "$bin"
echo "$bin"
