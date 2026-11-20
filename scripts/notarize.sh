#!/bin/bash
# Notarises a packaged Tandem.app with Apple and staples the ticket, so other Macs open it without warnings.
# Run scripts/package-app.sh with TANDEM_SIGN_TIMESTAMP=1 first: notarisation needs Apple's secure timestamp.
#
#   scripts/notarize.sh [<Tandem.app>]        default: build/package/Tandem.app
#
# One-time setup (the developer does this, with their own Apple ID):
#   1. appleid.apple.com > Sign-In and Security > App-Specific Passwords: create one named "notarytool".
#   2. In Terminal:
#        xcrun notarytool store-credentials tandem-notary \
#          --apple-id <your Apple ID e-mail> --team-id <your team id, e.g. from: security find-identity -v -p codesigning> \
#          --password <the app-specific password>
#      This stores the credentials in the login keychain under the profile name "tandem-notary".
# TANDEM_NOTARY_PROFILE chooses another profile name.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
app=${1:-$root/build/package/Tandem.app}
profile=${TANDEM_NOTARY_PROFILE:-tandem-notary}
[ -d "$app" ] || { echo "no app at $app; run scripts/package-app.sh first" >&2; exit 1; }
codesign --verify --deep --strict "$app"
if codesign -dvvv "$app" 2>&1 | grep -q "Timestamp=none\|^Signed Time="; then
  echo "The app is signed without Apple's secure timestamp. Package it again with: TANDEM_SIGN_TIMESTAMP=1 scripts/package-app.sh" >&2
  exit 1
fi
zip="$(mktemp -d)/Tandem.zip"
/usr/bin/ditto -c -k --keepParent "$app" "$zip"
xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait
xcrun stapler staple "$app"
spctl -a -vv "$app"
rm -f "$zip"
