#!/bin/bash
# Signs a packaged Tandem.app inside out: every library, every program with the hardened runtime and its
# own entitlements, then the app. Uses the first "Developer ID Application" identity in the login keychain
# (TANDEM_SIGN_IDENTITY overrides; "-" signs ad hoc, which runs on this Mac but cannot install the helper
# with SMAppService or be notarised).
#
#   scripts/sign-app.sh <Tandem.app>
#   TANDEM_SIGN_TIMESTAMP=1 adds Apple's secure timestamp (needs the network; required for notarisation).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
. "$root/scripts/identity.sh"
app=${1:?usage: sign-app.sh <Tandem.app>}
identity=${TANDEM_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $2; exit}')}
identity=${identity:--}
# The hardened runtime (which also turns on library validation) goes with a real identity: an ad hoc signature has
# no team, so the system would refuse the app's own libraries. Ad hoc builds are for the Mac that made them.
if [ "$identity" = - ]; then rt=; else rt="--options runtime"; fi
if [ "${TANDEM_SIGN_TIMESTAMP:-0}" = 1 ]; then ts=--timestamp; else ts=--timestamp=none; fi
ents="$root/scripts/entitlements"
sign() { codesign --force --sign "$identity" "$ts" "$@"; }

# 1. Libraries.
find "$app/Contents" -name '*.dylib' -type f -print0 | while IFS= read -r -d '' lib; do sign "$lib"; done

H="$app/Contents/Helpers"
# The 3D QEMU's frameworks (ANGLE, libepoxy, virglrenderer, Vulkan loader, DXMT), as bundles. Signed with the
# same identity as the programs, so library validation under the hardened runtime accepts them.
for fw in "$H"/qemu-3d/Frameworks/*.framework; do [ -d "$fw" ] && sign "$fw"; done

# 2. Programs, with the hardened runtime. QEMU itself needs the hypervisor; the rest need no entitlement.
#    The 3D QEMU gets the same entitlements as the normal one. virglrenderer's render server (where DXMT
#    runs Direct3D on Metal) needs none: no hypervisor, and Metal compiles shaders without JIT memory.
if [ -x "$H/qemu-3d/bin/qemu-system-aarch64" ]; then
  sign $rt --identifier $TANDEM_BUNDLE_PREFIX.qemu-3d --entitlements "$ents/qemu.plist" "$H/qemu-3d/bin/qemu-system-aarch64"
fi
if [ -x "$H/qemu-3d/libexec/virgl_render_server" ]; then
  sign $rt --identifier $TANDEM_BUNDLE_PREFIX.virgl-render-server "$H/qemu-3d/libexec/virgl_render_server"
fi
for f in "$H"/qemu/bin/* "$H"/tools/*; do
  [ -f "$f" ] && [ -x "$f" ] || continue
  if [ "$(basename "$f")" = qemu-system-aarch64 ]; then
    sign $rt --identifier $TANDEM_BUNDLE_PREFIX.qemu --entitlements "$ents/qemu.plist" "$f"
  else
    sign $rt --identifier "$TANDEM_BUNDLE_PREFIX.$(basename "$f")" "$f"
  fi
done
if [ -x "$H/TandemNetHelper" ]; then sign $rt --identifier $TANDEM_BUNDLE_PREFIX.helper "$H/TandemNetHelper"; fi
if [ -x "$H/tandem" ]; then sign $rt --identifier $TANDEM_BUNDLE_PREFIX.cli "$H/tandem"; fi
# The Dock-tile stand-in is copied and re-signed ad hoc for every Windows program, so no runtime here.
if [ -x "$app/Contents/Resources/TandemGuestApp" ]; then sign --identifier $TANDEM_BUNDLE_PREFIX.guestapp "$app/Contents/Resources/TandemGuestApp"; fi
# The macOS guest agent: it runs inside macOS VMs (as a LaunchDaemon), never on this Mac.
if [ -f "$app/Contents/Resources/tandem-agent-macos" ]; then
  sign $rt --identifier $TANDEM_BUNDLE_PREFIX.agent "$app/Contents/Resources/tandem-agent-macos"
fi

# 3. The app itself.
sign $rt --entitlements "$ents/app.plist" "$app"
codesign --verify --deep --strict "$app"
echo "Signed $app with: $identity"
