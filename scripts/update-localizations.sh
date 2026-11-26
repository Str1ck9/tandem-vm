#!/bin/sh
# Refreshes resources/Localizable.xcstrings with the strings in the app's source (host/Sources/TandemApp).
# New strings are added in English; translations already in the catalog stay. Strings that exist only at
# run time (titles that come from the downloading providers) carry "extractionState": "manual" and are kept.
# After it: open the catalog in Xcode (or edit the JSON), add a language, then build and try it:
#   scripts/build-app.sh && TANDEM_LANG=es build/Tandem.app/Contents/MacOS/Tandem
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
catalog="$root/resources/Localizable.xcstrings"
out="$root/.cache/l10n"
rm -rf "$out"; mkdir -p "$out"
[ -f "$catalog" ] || printf '{"sourceLanguage":"en","strings":{},"version":"1.0"}\n' > "$catalog"
# The compiler writes what it finds in each file while it compiles, so every file is compiled again.
touch "$root"/host/Sources/TandemApp/*.swift
swift build --package-path "$root/host" --product TandemApp -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$out"
set --
for f in "$root"/host/Sources/TandemApp/*.swift; do
  b="$(basename "$f" .swift)"
  case "$b" in SelfTest*) continue ;; esac
  [ -f "$out/$b.stringsdata" ] && set -- "$@" "$out/$b.stringsdata"
done
xcrun xcstringstool sync "$catalog" --stringsdata "$@"
echo "Catalog updated: $catalog"
