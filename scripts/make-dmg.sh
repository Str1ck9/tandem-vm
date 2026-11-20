#!/bin/bash
# Makes the disk image people download: Tandem.app next to a link to /Applications, so installing is one
# drag. The image is signed with the same Developer ID as the app; notarise the app before packing it for
# other Macs (scripts/notarize.sh), and the image afterwards if you like (notarytool accepts .dmg too).
#
#   scripts/make-dmg.sh [<Tandem.app>]     default: build/package/Tandem.app
#   -> build/package/Tandem-<version>.dmg  (TANDEM_DMG_OUT overrides)
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
app=${1:-$root/build/package/Tandem.app}
[ -d "$app" ] || { echo "no app at $app; run scripts/package-app.sh first" >&2; exit 1; }
codesign --verify --deep --strict "$app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
out="${TANDEM_DMG_OUT:-$(dirname "$app")/Tandem-$version.dmg}"
identity=${TANDEM_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $2; exit}')}

stage=$(mktemp -d /tmp/tandem-dmg.XXXXXX)
trap 'rm -rf "$stage"' EXIT
/usr/bin/ditto "$app" "$stage/Tandem.app"
ln -s /Applications "$stage/Applications"
rm -f "$out"
# ULFO: LZFSE-compressed, read-only; opens on macOS 10.11 and later.
hdiutil create -quiet -volname "Tandem $version" -srcfolder "$stage" -fs APFS -format ULFO -ov "$out"
if [ -n "$identity" ] && [ "$identity" != "-" ]; then
  codesign --force --sign "$identity" --timestamp=none "$out"
  codesign --verify "$out"
  echo "Signed with: $identity"
else
  echo "Note: no Developer ID identity found; the image is not signed." >&2
fi
du -h "$out" | awk '{print "Disk image: " $2 " (" $1 ")"}'
