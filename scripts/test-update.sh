#!/bin/bash
# End-to-end test of Tandem's updates, with a key and feed of its own in a temporary folder. Never touches
# /Applications, the installed Tandem, its helper or its settings.
#
#   scripts/test-update.sh [WORKDIR]       default: .cache/tandem-test-upd
#
# Builds two versions (0.6.900 and 0.6.901, development builds signed with the Developer ID), puts the
# newer one in a signed disk image with a feed entry, then:
#   A  tandem-release try-update: older -> newer in a temporary Applications folder
#   B  an archive signed with another key is refused
#   C  an update signed ad hoc (no developer team) is refused
#   D  a downgrade is not offered, and an archive holding an older app than it claims is refused
#   E  the app itself: Check for Updates, download, Install and Restart; the relaunched copy reports its version
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
T="${1:-$root/.cache/tandem-test-upd}"
rm -rf "$T"; mkdir -p "$T"
swift build --package-path "$root/host" -c release --product tandem-release >/dev/null
tool="$root/host/.build/release/tandem-release"
pass=0 fail=0
ok() { echo "PASS $*"; pass=$((pass+1)); }
bad() { echo "FAIL $*"; fail=$((fail+1)); }
ver() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist"; }

"$tool" keygen --key "$T/keys/release.key" >/dev/null
"$tool" keygen --key "$T/keys/other.key" >/dev/null
pub=$("$tool" public-key --key "$T/keys/release.key")
mkdir -p "$T/feed"
feed="$T/feed/tandem-update.json"

build() { # version build out
  TANDEM_VERSION=$1 TANDEM_BUILD_NUMBER=$2 TANDEM_APP_OUT="$3" TANDEM_UPDATE_PUBLIC_KEY="$pub" \
    TANDEM_UPDATE_FEED_URL="file://$feed" "$root/scripts/build-app.sh" release >/dev/null
  "$root/scripts/sign-app.sh" "$3" >/dev/null 2>&1
}
echo "building 0.6.900 and 0.6.901…"
build 0.6.900 900 "$T/old/Tandem.app"
build 0.6.901 901 "$T/new/Tandem.app"
TANDEM_DMG_OUT="$T/feed/Tandem-0.6.901.dmg" "$root/scripts/make-dmg.sh" "$T/new/Tandem.app" >/dev/null
echo "Release notes for the test." > "$T/notes.txt"
"$tool" sign "$T/feed/Tandem-0.6.901.dmg" --version 0.6.901 --build 901 --feed "$feed" --key "$T/keys/release.key" --notes "$T/notes.txt" >/dev/null

# A: older -> newer.
mkdir -p "$T/A"; ditto "$T/old/Tandem.app" "$T/A/Tandem.app"
if "$tool" try-update --feed "$feed" --app "$T/A/Tandem.app" --downloads "$T/A-dl" > "$T/A.log" 2>&1 && [ "$(ver "$T/A/Tandem.app")" = 0.6.901 ] \
   && codesign --verify --deep --strict "$T/A/Tandem.app" && [ "$(ls -A "$T/A")" = Tandem.app ]; then ok "A installs 0.6.900 -> 0.6.901"; else bad "A"; cat "$T/A.log"; fi

# B: signed with another key.
mkdir -p "$T/B/feed" "$T/B/apps"; cp "$T/feed/Tandem-0.6.901.dmg" "$T/B/feed/"
"$tool" sign "$T/B/feed/Tandem-0.6.901.dmg" --version 0.6.901 --build 901 --feed "$T/B/feed/tandem-update.json" --key "$T/keys/other.key" >/dev/null
ditto "$T/old/Tandem.app" "$T/B/apps/Tandem.app"
if ! "$tool" try-update --feed "$T/B/feed/tandem-update.json" --app "$T/B/apps/Tandem.app" --public-key "$pub" --downloads "$T/B-dl" > "$T/B.log" 2>&1 \
   && grep -q "signature" "$T/B.log" && [ "$(ver "$T/B/apps/Tandem.app")" = 0.6.900 ]; then ok "B other key refused: $(grep error: "$T/B.log")"; else bad "B"; cat "$T/B.log"; fi

# C: ad hoc signed update (no team).
mkdir -p "$T/C/feed" "$T/C/apps"; ditto "$T/new/Tandem.app" "$T/C/adhoc/Tandem.app"
codesign --force --deep --sign - "$T/C/adhoc/Tandem.app" 2>/dev/null
TANDEM_SIGN_IDENTITY=- TANDEM_DMG_OUT="$T/C/feed/Tandem-0.6.901.dmg" "$root/scripts/make-dmg.sh" "$T/C/adhoc/Tandem.app" >/dev/null 2>&1
"$tool" sign "$T/C/feed/Tandem-0.6.901.dmg" --version 0.6.901 --build 901 --feed "$T/C/feed/tandem-update.json" --key "$T/keys/release.key" >/dev/null
ditto "$T/old/Tandem.app" "$T/C/apps/Tandem.app"
if ! "$tool" try-update --feed "$T/C/feed/tandem-update.json" --app "$T/C/apps/Tandem.app" --downloads "$T/C-dl" > "$T/C.log" 2>&1 \
   && grep -q "not signed by the developer" "$T/C.log" && [ "$(ver "$T/C/apps/Tandem.app")" = 0.6.900 ] && [ "$(ls -A "$T/C/apps")" = Tandem.app ]; then
  ok "C wrong team refused: $(grep error: "$T/C.log")"; else bad "C"; cat "$T/C.log"; fi

# D: downgrade. 0.6.901 installed, feed offers 0.6.900; then an image of 0.6.900 claiming to be 0.6.902.
mkdir -p "$T/D/feed" "$T/D/apps"; ditto "$T/new/Tandem.app" "$T/D/apps/Tandem.app"
TANDEM_DMG_OUT="$T/D/feed/Tandem-0.6.900.dmg" "$root/scripts/make-dmg.sh" "$T/old/Tandem.app" >/dev/null
"$tool" sign "$T/D/feed/Tandem-0.6.900.dmg" --version 0.6.900 --build 900 --feed "$T/D/feed/tandem-update.json" --key "$T/keys/release.key" >/dev/null
if "$tool" try-update --feed "$T/D/feed/tandem-update.json" --app "$T/D/apps/Tandem.app" --downloads "$T/D-dl" > "$T/D.log" 2>&1 \
   && grep -q "Up to date" "$T/D.log" && [ "$(ver "$T/D/apps/Tandem.app")" = 0.6.901 ]; then ok "D1 older version not offered"; else bad "D1"; cat "$T/D.log"; fi
mkdir -p "$T/D2/feed"; cp "$T/D/feed/Tandem-0.6.900.dmg" "$T/D2/feed/Tandem-0.6.902.dmg"
"$tool" sign "$T/D2/feed/Tandem-0.6.902.dmg" --version 0.6.902 --build 902 --feed "$T/D2/feed/tandem-update.json" --key "$T/keys/release.key" >/dev/null
if ! "$tool" try-update --feed "$T/D2/feed/tandem-update.json" --app "$T/D/apps/Tandem.app" --downloads "$T/D2-dl" > "$T/D2.log" 2>&1 \
   && grep -q "not 0.6.902" "$T/D2.log" && [ "$(ver "$T/D/apps/Tandem.app")" = 0.6.901 ]; then ok "D2 mislabelled older app refused: $(grep error: "$T/D2.log")"; else bad "D2"; cat "$T/D2.log"; fi

# E: the app's own updater, from the window to the relaunch.
# A short library path: the control socket's path must fit in 104 bytes.
home=$(mktemp -d /tmp/tandem-upd.XXXX)
mkdir -p "$T/E/apps" "$T/E/snap"; ditto "$T/old/Tandem.app" "$T/E/apps/Tandem.app"
TANDEM_HOME="$home" TANDEM_SNAPSHOT_DIR="$T/E/snap" TANDEM_UPDATE_FEED="$feed" TANDEM_SNAPSHOT_PREFS_TAB=general \
  TANDEM_SNAPSHOT_UPDATE="settings;check;download;install" TANDEM_UPDATE_TEST_PROBE="$T/E/probe.txt" \
  perl -e 'alarm 600; exec @ARGV' "$T/E/apps/Tandem.app/Contents/MacOS/Tandem" > "$T/E.log" 2>&1 || true
for _ in $(seq 1 60); do [ -s "$T/E/probe.txt" ] && break; sleep 1; done
grep "selftest: update" "$T/E.log" || true
if [ "$(ver "$T/E/apps/Tandem.app")" = 0.6.901 ] && grep -q "^0.6.901 901 $T/E/apps/Tandem.app" "$T/E/probe.txt" 2>/dev/null \
   && [ "$(ls -A "$T/E/apps")" = Tandem.app ]; then
  ok "E app updated itself and relaunched: $(cat "$T/E/probe.txt")"; else bad "E"; tail -20 "$T/E.log"; fi

rm -rf "$home"
echo "$pass passed, $fail failed (work folder $T; snapshots in $T/E/snap)"
[ "$fail" = 0 ]
