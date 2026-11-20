#!/bin/bash
# Makes a release that installed copies of Tandem can update to: the packaged, signed app, its disk image,
# and the update feed entry with the image's Ed25519 signature. Publishes nothing.
#
#   scripts/release.sh [--notes FILE] [--out DIR] [--skip-package] [--notarize]
#
#   --notes FILE     release notes shown in Tandem's update window (plain text)
#   --out DIR        where the image and feed go (default build/release); an existing
#                    DIR/tandem-update.json is kept and the new release added to it
#   --skip-package   use build/package/Tandem.app as it is (already built and signed)
#   --notarize       sign with Apple's secure timestamp and notarise (needs `tandem-notary`, scripts/notarize.sh)
#
# Needs the release key, made once with:  host/.build/release/tandem-release keygen
# (written to ~/.config/tandem/update-signing.key, readable only by you; back it up: without it, no
# installed copy of Tandem will accept another update). Its public half is resources/update-public-key.txt,
# which build-app.sh puts into every build. TANDEM_RELEASE_KEY chooses another key file.
#
# To publish on GitHub (later, by hand): attach both files to one release, for example
#   gh release create v<version> build/release/Tandem-<version>.dmg build/release/tandem-update.json
# Tandem's default feed is …/releases/latest/download/tandem-update.json, and the feed names the image
# relative to itself, so both must be on the same (latest) release.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
notes="" out="$root/build/release" package=1 notarize=0
while [ $# -gt 0 ]; do
  case "$1" in
    --notes) notes="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --skip-package) package=0; shift ;;
    --notarize) notarize=1; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
key="${TANDEM_RELEASE_KEY:-$HOME/.config/tandem/update-signing.key}"
[ -f "$key" ] || { echo "no release key at $key; make one with: host/.build/release/tandem-release keygen" >&2; exit 1; }

swift build --package-path "$root/host" -c release --product tandem-release >/dev/null
tool="$root/host/.build/release/tandem-release"

# The key the build will trust must be the one we sign with.
want="$("$tool" public-key --key "$key")"
have="${TANDEM_UPDATE_PUBLIC_KEY:-$(cat "$root/resources/update-public-key.txt" 2>/dev/null || true)}"
[ "$want" = "$have" ] || { echo "the release key does not match resources/update-public-key.txt (or TANDEM_UPDATE_PUBLIC_KEY)" >&2; exit 1; }

app="${TANDEM_APP_OUT:-$root/build/package/Tandem.app}"
if [ "$package" = 1 ]; then
  if [ "$notarize" = 1 ]; then TANDEM_SIGN_TIMESTAMP=1 "$root/scripts/package-app.sh"; else "$root/scripts/package-app.sh"; fi
fi
[ -d "$app" ] || { echo "no app at $app" >&2; exit 1; }
codesign --verify --deep --strict "$app"
plist="$app/Contents/Info.plist"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")
inkey=$(/usr/libexec/PlistBuddy -c 'Print :TandemUpdatePublicKey' "$plist" 2>/dev/null || true)
[ "$inkey" = "$want" ] || { echo "$app does not carry the release key (TandemUpdatePublicKey); package it again" >&2; exit 1; }
if [ "$notarize" = 1 ]; then "$root/scripts/notarize.sh" "$app"; fi

mkdir -p "$out"
dmg="$out/Tandem-$version.dmg"
TANDEM_DMG_OUT="$dmg" "$root/scripts/make-dmg.sh" "$app"
args=("$dmg" --version "$version" --build "$build" --feed "$out/tandem-update.json" --key "$key")
[ -n "$notes" ] && args+=(--notes "$notes")
"$tool" sign "${args[@]}"
"$tool" verify --feed "$out/tandem-update.json" --public-key "$want" --current 0.0.0 --build 0
echo "Release ready in $out (nothing published)."
