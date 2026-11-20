#!/bin/sh
# Builds Tandem.app into build/ and signs it ad hoc with the virtualization entitlement (local use only).
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
. "$root/scripts/identity.sh"
config="${1:-release}"
swift build --package-path "$root/host" -c "$config" --product TandemApp
swift build --package-path "$root/host" -c "$config" --product TandemNetHelper
swift build --package-path "$root/host" -c "$config" --product TandemGuestApp
swift build --package-path "$root/host" -c "$config" --product tandem
# TANDEM_APP_OUT: build somewhere else (scripts/package-app.sh builds the packaged copy in build/package/).
app="${TANDEM_APP_OUT:-$root/build/Tandem.app}"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Helpers"
cp "$root/resources/Tandem.icns" "$app/Contents/Resources/Tandem.icns"
cp "$root/host/.build/$config/TandemApp" "$app/Contents/MacOS/Tandem"
# The command-line tool lives inside the app, so it finds the app it belongs to. Not in MacOS/: on a
# case-insensitive disk "tandem" and "Tandem" are the same file.
cp "$root/host/.build/$config/tandem" "$app/Contents/Helpers/tandem"
# Version from the newest tag (v0.3.0 -> 0.3.0), build number from the commit count.
# TANDEM_VERSION / TANDEM_BUILD_NUMBER override both (release tests build two versions from one tree).
version="${TANDEM_VERSION:-$(git -C "$root" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')}"; version="${version:-0.0.0}"
buildnum="${TANDEM_BUILD_NUMBER:-$(git -C "$root" rev-list --count HEAD 2>/dev/null || echo 1)}"
# The key updates must be signed with (scripts/release.sh; tandem-release keygen), and where to look for
# them. TANDEM_UPDATE_PUBLIC_KEY and TANDEM_UPDATE_FEED_URL override (tests use a key and feed of their own).
updatekey="${TANDEM_UPDATE_PUBLIC_KEY:-$(cat "$root/resources/update-public-key.txt" 2>/dev/null || true)}"
updatefeed="${TANDEM_UPDATE_FEED_URL:-}"   # empty: the app uses its built-in default (TandemIdentity.projectRepository)
commit="$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo unknown)"
builddate="$(date '+%-d %b %Y, %-I:%M %p')"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Tandem</string>
    <key>CFBundleIdentifier</key><string>@APPID@</string>
    <key>TandemBundlePrefix</key><string>@PREFIX@</string>
    <key>TandemAppID</key><string>@APPID@</string>
    <key>CFBundleIconFile</key><string>Tandem.icns</string>
    <key>CFBundleName</key><string>Tandem</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>@VERSION@</string>
    <key>CFBundleVersion</key><string>@BUILD@</string>
    <key>TandemCommit</key><string>@COMMIT@</string>
    <key>TandemBuildDate</key><string>@BUILDDATE@</string>
    <key>TandemUpdatePublicKey</key><string>@UPDATEKEY@</string>
    <key>TandemUpdateFeedURL</key><string>@UPDATEFEED@</string>
    <key>NSHumanReadableCopyright</key><string>Developer: The Tandem contributors</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSMicrophoneUsageDescription</key><string>Virtual machines can use the microphone.</string>
    <!-- A virtual machine bundle is one item in Finder; double-clicking it opens it in Tandem. -->
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>@PREFIX@.vm</string>
            <key>UTTypeDescription</key><string>Tandem Virtual Machine</string>
            <key>UTTypeConformsTo</key><array><string>com.apple.package</string><string>public.composite-content</string></array>
            <key>UTTypeIconFile</key><string>Tandem.icns</string>
            <key>UTTypeTagSpecification</key>
            <dict><key>public.filename-extension</key><array><string>tandemvm</string></array></dict>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Tandem Virtual Machine</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Owner</string>
            <key>LSTypeIsPackage</key><true/>
            <key>CFBundleTypeIconFile</key><string>Tandem.icns</string>
            <key>LSItemContentTypes</key><array><string>@PREFIX@.vm</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST
sed -i "" -e "s/@VERSION@/$version/" -e "s/@BUILD@/$buildnum/" -e "s/@COMMIT@/$commit/" -e "s/@BUILDDATE@/$builddate/" \
  -e "s|@PREFIX@|$TANDEM_BUNDLE_PREFIX|g" -e "s|@APPID@|$TANDEM_APP_ID|g" \
  -e "s|@UPDATEKEY@|$updatekey|" -e "s|@UPDATEFEED@|$updatefeed|" "$app/Contents/Info.plist"
# Ship the Windows guest agent inside the app when it has been built (scripts/build-agent.sh).
agent="$root/guest/target/aarch64-pc-windows-gnullvm/release/tandem-agent.exe"
if [ -f "$agent" ]; then
  cp "$agent" "$app/Contents/Resources/tandem-agent.exe"
fi
# The network helper and its installer, for Configure > Hardware > Network > Install Network Helper.
cp "$root/host/.build/$config/TandemNetHelper" "$app/Contents/Resources/TandemNetHelper"
cp "$root/scripts/install-net-helper.sh" "$app/Contents/Resources/install-net-helper.sh"
# usbredir's usbredirect, which the helper runs as root to hand USB devices to VMs (brew install usbredir).
if command -v usbredirect >/dev/null 2>&1; then
  "$root/scripts/bundle-usbredirect.sh" "$app/Contents/Resources/usbredirect" >/dev/null
else
  echo "note: usbredir is not installed (brew install usbredir); this build's helper cannot take USB devices from macOS" >&2
fi
# QEMU's qemu-nbd, which the helper runs as root to serve USB drives to VMs.
if ! "$root/scripts/bundle-qemu-nbd.sh" "$app/Contents/Resources/qemu-nbd" >/dev/null; then
  echo "note: Tandem's QEMU build has no qemu-nbd (scripts/build-qemu.sh); this build's helper cannot serve USB drives" >&2
fi
# The stand-in that gives each Windows program its own Dock tile in Seamless Mode.
cp "$root/host/.build/$config/TandemGuestApp" "$app/Contents/Resources/TandemGuestApp"
linux_agent="$root/guest/target/aarch64-unknown-linux-musl/release/tandem-agent"
if [ -f "$linux_agent" ]; then
  cp "$linux_agent" "$app/Contents/Resources/tandem-agent-linux"
fi
# The macOS guest agent (signed by scripts/build-agent.sh); Tandem builds the "Tandem Tools" disc from it.
mac_agent="$root/guest/target/aarch64-apple-darwin/release/tandem-agent"
if [ -f "$mac_agent" ]; then
  cp "$mac_agent" "$app/Contents/Resources/tandem-agent-macos"
fi
codesign --force --sign - "$app/Contents/Helpers/tandem"
codesign --force --sign - --entitlements "$root/scripts/vmctl.entitlements" "$app"
echo "$app"
