#!/bin/bash
# Builds a self-contained Tandem.app: everything it runs is inside it, so it needs neither Homebrew nor
# this source folder nor files in ~/Library/Application Support/Tandem, and it is signed with the
# Developer ID (scripts/sign-app.sh) so macOS permissions given to it stay put across updates.
#
#   scripts/package-app.sh            -> build/package/Tandem.app
#
# Inside the app:
#   Contents/Helpers/qemu/{bin,lib}               Tandem's QEMU (lean build: QEMU_PROFILE=package)
#   Contents/Resources/qemu                       its firmware, ROMs and keymaps (code may not sit with data)
#   Contents/Helpers/qemu-3d/{bin,lib,Frameworks,libexec}   the 3D QEMU and its libraries (built from source)
#   Contents/Helpers/tools/{swtpm,zstd,wimlib-imagex,usbredirect,lib}
#   Contents/Helpers/TandemNetHelper              the helper, installed by the app with SMAppService
#   Contents/Library/LaunchDaemons/<prefix>.helper.plist
#   Contents/Helpers/tandem                       the command-line tool
#   Contents/Resources/tandem-agent.exe, tandem-agent-linux, tandem-agent-macos, TandemGuestApp
# Not inside: the VirtIO driver disc (837 MB); Tandem finds or downloads it as before.
# Build-time needs: Homebrew's swtpm, zstd, wimlib and usbredir, and QEMU's build dependencies.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
. "$root/scripts/identity.sh"
out="${TANDEM_APP_OUT:-$root/build/package/Tandem.app}"
qprefix="${TANDEM_QEMU_PACKAGE_PREFIX:-$root/.cache/qemu-package}"
bundle="$root/scripts/bundle-tool.sh"

# 1. QEMU, lean build.
if [ ! -x "$qprefix/bin/qemu-system-aarch64" ]; then
  QEMU_PROFILE=package "$root/scripts/build-qemu.sh" "$qprefix"
fi

# 2. The app as for development, into the package folder.
mkdir -p "$(dirname "$out")"
TANDEM_APP_OUT="$out" "$root/scripts/build-app.sh" release >/dev/null
H="$out/Contents/Helpers"
R="$out/Contents/Resources"

# 3. QEMU: its programs share qemu/lib; firmware for ARM guests only.
rm -rf "$H/qemu"
# Data stays out of Contents/Helpers, which may hold code only; Tandem passes it to QEMU with -L.
rm -rf "$R/qemu"
mkdir -p "$H/qemu/bin" "$R/qemu"
for b in qemu-system-aarch64 qemu-img qemu-nbd; do
  BUNDLE_KEEP=1 BUNDLE_LIBDIR="$H/qemu/lib" BUNDLE_LIBREF=@executable_path/../lib "$bundle" "$qprefix/bin/$b" "$H/qemu/bin" --version >/dev/null
done
share="$qprefix/share/qemu"
cp "$share/edk2-aarch64-code.fd" "$share/edk2-arm-vars.fd" "$R/qemu/"
cp "$share"/efi-*.rom "$R/qemu/" 2>/dev/null || true
if [ -d "$share/keymaps" ]; then cp -R "$share/keymaps" "$R/qemu/"; fi
if [ -d "$share/firmware" ]; then cp -R "$share/firmware" "$R/qemu/"; fi

# 3b. The 3D QEMU (Linux and Windows 3D), built from public source by scripts/build-qemu-3d.sh and
#     scripts/build-3d-deps.sh: qemu-3d/bin/qemu-system-aarch64 with its Homebrew libraries in qemu-3d/lib,
#     ANGLE, libepoxy, virglrenderer, the Vulkan loader and DXMT in qemu-3d/Frameworks, and virglrenderer's
#     render server in qemu-3d/libexec. It shares the firmware in Resources/qemu (Tandem passes -L) and takes
#     qemu-img and swtpm from the normal set. TANDEM_PACKAGE_3D=0 leaves it out.
rm -rf "$H/qemu-3d"
if [ "${TANDEM_PACKAGE_3D:-1}" = 1 ]; then
  q3d="${TANDEM_QEMU_3D_PACKAGE_PREFIX:-$root/.cache/qemu-3d-package}"
  if [ ! -x "$q3d/bin/qemu-system-aarch64" ]; then
    TANDEM_QEMU_3D_OUT="$q3d" "$root/scripts/build-qemu-3d.sh"
  fi
  mkdir -p "$H/qemu-3d/bin" "$H/qemu-3d/libexec"
  BUNDLE_LIBDIR="$H/qemu-3d/lib" BUNDLE_LIBREF=@executable_path/../lib BUNDLE_CHECK=0 \
    "$bundle" "$q3d/bin/qemu-system-aarch64" "$H/qemu-3d/bin" >/dev/null
  cp -R "$q3d/Frameworks" "$H/qemu-3d/Frameworks"
  cp "$q3d/libexec/virgl_render_server" "$H/qemu-3d/libexec/"
  # Checked with the frameworks in place (the program loads them through @executable_path/../Frameworks).
  "$H/qemu-3d/bin/qemu-system-aarch64" -device help | grep -q virtio-gpu-gl \
    || { echo "the bundled 3D QEMU does not run" >&2; exit 1; }
fi

# 4. Tools, sharing tools/lib.
rm -rf "$H/tools"
for spec in "swtpm --version" "zstd --version" "wimlib-imagex --version" "usbredirect --help"; do
  set -- $spec
  path=$(command -v "$1" || true)
  [ -n "$path" ] || { echo "missing build-time tool: $1 (brew install ${1%-imagex})" >&2; exit 1; }
  BUNDLE_KEEP=1 "$bundle" "$path" "$H/tools" "$2" >/dev/null
done

# 5. The helper, where SMAppService starts it, and its launch file. The development build's copies for
#    the script installer (Resources/usbredirect, Resources/qemu-nbd) are not needed here.
mv "$R/TandemNetHelper" "$H/TandemNetHelper"
rm -rf "$R/usbredirect" "$R/qemu-nbd"
mkdir -p "$out/Contents/Library/LaunchDaemons"
cat > "$out/Contents/Library/LaunchDaemons/$TANDEM_BUNDLE_PREFIX.helper.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$TANDEM_BUNDLE_PREFIX.helper</string>
  <key>BundleProgram</key><string>Contents/Helpers/TandemNetHelper</string>
  <key>ProgramArguments</key>
  <array>
    <string>TandemNetHelper</string>
    <string>--from-bundle</string>
    <string>--socket</string><string>/var/run/tandem-net.sock</string>
  </array>
  <key>AssociatedBundleIdentifiers</key><array><string>$TANDEM_APP_ID</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>/var/log/tandem-nethelper.log</string>
</dict>
</plist>
PLIST

# 5b. Build-machine details out of the shipped programs, where that is safe (signing follows, so the edits
#     cost nothing): run paths that do not exist, or that point into Xcode's or the Metal toolchain when the
#     program loads nothing through a run path (the Swift programs use the system's Swift runtime), and the
#     debug map (`strip -S`: object file and source paths; the symbol table stays, so crash logs keep names).
while IFS= read -r -d '' f; do
  file -b "$f" | grep -q Mach-O || continue
  uses_rpath=$(otool -L "$f" 2>/dev/null | grep -c '@rpath/' || true)
  for rp in $(otool -l "$f" | awk '/LC_RPATH/ {getline; getline; print $2}'); do
    case "$rp" in @*|/usr/lib/swift) continue ;; esac
    drop=0
    [ -e "$rp" ] || drop=1
    if [ "$uses_rpath" = 0 ]; then case "$rp" in *.xctoolchain/*) drop=1 ;; esac; fi
    if [ $drop = 1 ]; then install_name_tool -delete_rpath "$rp" "$f" 2>/dev/null || true; fi
  done
  strip -S "$f" 2>/dev/null || true
done < <(find "$out/Contents" -type f -print0)
# What is left is reported, not fatal: QEMU and some libraries keep source paths in assertion messages
# (compiled in as text). Rebuilding them with -ffile-prefix-map would remove those.
built=$(find "$out/Contents" -type f -print0 | while IFS= read -r -d '' f; do
  file -b "$f" | grep -q Mach-O || continue
  n=$(strings -a "$f" 2>/dev/null | grep -cE "$root|$HOME|^/Users/|/private/tmp/|/opt/homebrew/Cellar/" || true)
  [ "$n" = 0 ] || echo "  $n	${f#$out/}"
done)
if [ -n "$built" ]; then
  echo "warning: absolute build paths are still inside these programs (text in the code, harmless at run time):" >&2
  echo "$built" >&2
fi

# 6. Nothing may point outside the app any more.
leaks=$(find "$out/Contents" -type f \( -name '*.dylib' -o -perm -u+x \) -print0 \
  | xargs -0 otool -L 2>/dev/null | grep -E '^\s+(/opt/homebrew|/usr/local|/Applications/UTM|'"$HOME"')' || true)
if [ -n "$leaks" ]; then echo "the package still links outside itself:" >&2; echo "$leaks" >&2; exit 1; fi
# Nor may any program look for libraries there (run paths). Swift's own run path into Xcode's toolchain is
# harmless (the system's Swift runtime is used) and is not counted.
rpaths=$(find "$out/Contents" -type f \( -name '*.dylib' -o -perm -u+x \) -print0 | xargs -0 otool -l 2>/dev/null \
  | awk '/LC_RPATH/ {getline; getline; print $2}' | grep -E '^(/opt/homebrew|/usr/local|/Applications/UTM|'"$HOME"')' || true)
if [ -n "$rpaths" ]; then echo "the package still searches outside itself:" >&2; echo "$rpaths" >&2; exit 1; fi

# 6b. The folders this build was made in (and the home folder of whoever builds) are compiled into QEMU and
#     some libraries as text, and listed in QEMU's firmware descriptions. Replace them with a neutral string
#     of the same length before signing, so a release does not publish the builder's folder names. Does
#     nothing when nothing matches. TANDEM_NEUTRALIZE_PATHS adds more folders (separated by ":").
python3 "$root/scripts/neutralize-paths.py" "$out" "$root" "$qprefix" "${TANDEM_QEMU_3D_PACKAGE_PREFIX:-$root/.cache/qemu-3d-package}"

# 7. Sign.
"$root/scripts/sign-app.sh" "$out"
# 8. The signed programs still start (the edits in 5b happen before signing, so check after it).
"$H/qemu/bin/qemu-system-aarch64" --version >/dev/null
"$H/qemu/bin/qemu-img" --version >/dev/null
"$H/tools/swtpm" --version >/dev/null
"$H/tandem" help >/dev/null
usage=$("$H/TandemNetHelper" --check 2>&1 || true)
case "$usage" in *Usage*) ;; *) echo "the signed helper does not start: $usage" >&2; exit 1 ;; esac
if [ -x "$H/qemu-3d/bin/qemu-system-aarch64" ]; then
  "$H/qemu-3d/bin/qemu-system-aarch64" -device help | grep -q virtio-gpu-gl || { echo "the signed 3D QEMU does not run" >&2; exit 1; }
fi
du -sh "$out" | awk '{print "Packaged: " $2 " (" $1 ")"}'
