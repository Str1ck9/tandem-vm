#!/bin/bash
# Installs (or removes) the Tandem helper, the root daemon that provides bridged networking and hands
# USB devices to VMs (macOS only lets root take a device away from its own drivers).
#
#   sudo scripts/install-net-helper.sh              install for the user who ran sudo
#   sudo scripts/install-net-helper.sh --uid 501    install for another user id
#   sudo scripts/install-net-helper.sh --uninstall  remove it
#   --binary <file>   install this already built helper instead of building one (the app does this)
#   --usbredirect <folder>   install this usbredirect bundle (made by scripts/bundle-usbredirect.sh;
#                     the app carries one); without it, one is made from Homebrew's usbredir if installed
#   --qemu-nbd <folder>      install this qemu-nbd bundle (made by scripts/bundle-qemu-nbd.sh); without it,
#                     one is made from Tandem's QEMU build. The helper runs it as root to serve USB drives.
#
# What it does: copies the helper and the tool bundles to /Library/PrivilegedHelperTools (owned
# by root, so nobody else can change what root runs), writes one LaunchDaemon plist, and starts it. The
# daemon only accepts connections from the one user id given here.
set -euo pipefail
# The names come from TANDEM_BUNDLE_PREFIX (default local.tandem; see scripts/identity.sh). sudo does not pass
# environment variables on by itself: sudo TANDEM_BUNDLE_PREFIX=... TANDEM_APP_ID=... scripts/install-net-helper.sh
. "$(cd "$(dirname "$0")" && pwd)/identity.sh"

LABEL=$TANDEM_BUNDLE_PREFIX.nethelper
BINARY=/Library/PrivilegedHelperTools/$LABEL
USBREDIR_DIR=/Library/PrivilegedHelperTools/$TANDEM_BUNDLE_PREFIX.usbredirect
NBD_DIR=/Library/PrivilegedHelperTools/$TANDEM_BUNDLE_PREFIX.qemu-nbd
PLIST=/Library/LaunchDaemons/$LABEL.plist
SOCKET=/var/run/tandem-net.sock
LOG=/var/log/tandem-nethelper.log
ROOT=$(cd "$(dirname "$0")/.." && pwd)

ACTION=install
ALLOW_UID=${SUDO_UID:-}
PREBUILT=
USBREDIR_SOURCE=
NBD_SOURCE=
while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall) ACTION=uninstall ;;
    --uid) shift; ALLOW_UID=${1:-} ;;
    --binary) shift; PREBUILT=${1:-} ;;
    --usbredirect) shift; USBREDIR_SOURCE=${1:-} ;;
    --qemu-nbd) shift; NBD_SOURCE=${1:-} ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ "$(id -u)" -ne 0 ]; then
  echo "This must run as root. Run it again with sudo in front." >&2
  exit 1
fi

launchctl bootout system "$PLIST" 2>/dev/null || true

if [ "$ACTION" = uninstall ]; then
  rm -f "$BINARY" "$PLIST" "$SOCKET"
  rm -rf "$USBREDIR_DIR" "$NBD_DIR"
  echo "Tandem helper removed."
  exit 0
fi

case "$ALLOW_UID" in
  ''|*[!0-9]*) echo "Cannot tell which user to serve. Pass --uid <number> (see: id -u)." >&2; exit 1 ;;
esac
if [ "$ALLOW_UID" -eq 0 ]; then
  echo "Refusing to install for root. Pass --uid <your user id> (see: id -u)." >&2
  exit 1
fi

if [ -n "$PREBUILT" ]; then
  BUILT=$PREBUILT
else
  # Build as the invoking user, not as root, so the build folder keeps its owner.
  BUILD_USER=$(id -un "$ALLOW_UID")
  BUILT="$ROOT/host/.build/release/TandemNetHelper"
  sudo -u "$BUILD_USER" swift build --package-path "$ROOT/host" -c release --product TandemNetHelper
fi
[ -x "$BUILT" ] || { echo "The helper program is missing: $BUILT" >&2; exit 1; }

# Sign with a stable identity when one is available, so macOS permissions given to the helper (Full Disk
# Access for USB drives) survive reinstalls. An ad hoc signature is tied to one exact build, so every
# rebuild would lose them. The identity is looked up in the invoking user's keychain; set
# TANDEM_SIGN_IDENTITY to choose one, or to "-" for ad hoc.
SIGN_USER=$(id -un "$ALLOW_UID")
IDENTITY=${TANDEM_SIGN_IDENTITY:-$(sudo -u "$SIGN_USER" security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Developer ID Application/ {print $2; exit}')}
if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ]; then
  SIGNED=$(sudo -u "$SIGN_USER" mktemp /tmp/tandem-nethelper.XXXXXX)
  cp "$BUILT" "$SIGNED"; chown "$SIGN_USER" "$SIGNED"
  if sudo -u "$SIGN_USER" codesign --force --identifier "$LABEL" --sign "$IDENTITY" "$SIGNED" 2>/dev/null; then
    BUILT=$SIGNED
    echo "Signed the helper with: $IDENTITY"
  else
    echo "Note: signing with \"$IDENTITY\" failed; installing it unsigned (Full Disk Access must be given again after each reinstall)." >&2
  fi
else
  echo "Note: no Developer ID certificate found; Full Disk Access must be given again after each reinstall." >&2
fi

mkdir -p /Library/PrivilegedHelperTools
install -o root -g wheel -m 0755 "$BUILT" "$BINARY"
[ -n "${SIGNED:-}" ] && rm -f "$SIGNED"

# USB: usbredir's usbredirect, with its libraries, in a root-owned folder.
USB_ARGS=
if [ -z "$USBREDIR_SOURCE" ] && [ -x "$ROOT/scripts/bundle-usbredirect.sh" ]; then
  BUILD_USER=$(id -un "$ALLOW_UID")
  STAGE=$(sudo -u "$BUILD_USER" mktemp -d /tmp/tandem-usbredirect.XXXXXX)
  if sudo -u "$BUILD_USER" PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" "$ROOT/scripts/bundle-usbredirect.sh" "$STAGE/usbredirect" >/dev/null; then
    USBREDIR_SOURCE=$STAGE/usbredirect
  else
    echo "Note: USB devices will not work; Homebrew's usbredir is missing (brew install usbredir), then run this again." >&2
  fi
fi
rm -rf "$USBREDIR_DIR"
if [ -n "$USBREDIR_SOURCE" ] && [ -x "$USBREDIR_SOURCE/usbredirect" ]; then
  mkdir -p "$USBREDIR_DIR/lib"
  install -o root -g wheel -m 0755 "$USBREDIR_SOURCE/usbredirect" "$USBREDIR_DIR/usbredirect"
  for lib in "$USBREDIR_SOURCE"/lib/*.dylib; do install -o root -g wheel -m 0644 "$lib" "$USBREDIR_DIR/lib/"; done
  chown -R root:wheel "$USBREDIR_DIR"; chmod 0755 "$USBREDIR_DIR" "$USBREDIR_DIR/lib"
  USB_ARGS="<string>--usbredirect</string><string>$USBREDIR_DIR/usbredirect</string>"
fi
[ -n "${STAGE:-}" ] && rm -rf "$STAGE"

# USB drives: QEMU's qemu-nbd, with its libraries, in a root-owned folder. The helper runs it as root on
# the drive's raw disk; QEMU reads the disk from it over a socket only the user can open.
if [ -z "$NBD_SOURCE" ] && [ -x "$ROOT/scripts/bundle-qemu-nbd.sh" ]; then
  BUILD_USER=$(id -un "$ALLOW_UID")
  USER_HOME=$(dscl . -read "/Users/$BUILD_USER" NFSHomeDirectory | awk '{print $2}')
  NBD_STAGE=$(sudo -u "$BUILD_USER" mktemp -d /tmp/tandem-qemu-nbd.XXXXXX)
  if sudo -u "$BUILD_USER" PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" "$ROOT/scripts/bundle-qemu-nbd.sh" "$NBD_STAGE/qemu-nbd" \
       "$USER_HOME/Library/Application Support/Tandem/qemu/bin/qemu-nbd" >/dev/null; then
    NBD_SOURCE=$NBD_STAGE/qemu-nbd
  else
    echo "Note: USB drives will not work; Tandem's QEMU build has no qemu-nbd (run scripts/build-qemu.sh), then run this again." >&2
  fi
fi
rm -rf "$NBD_DIR"
NBD_ARGS=
if [ -n "$NBD_SOURCE" ] && [ -x "$NBD_SOURCE/qemu-nbd" ]; then
  mkdir -p "$NBD_DIR/lib"
  install -o root -g wheel -m 0755 "$NBD_SOURCE/qemu-nbd" "$NBD_DIR/qemu-nbd"
  for lib in "$NBD_SOURCE"/lib/*.dylib; do install -o root -g wheel -m 0644 "$lib" "$NBD_DIR/lib/"; done
  chown -R root:wheel "$NBD_DIR"; chmod 0755 "$NBD_DIR" "$NBD_DIR/lib"
  NBD_ARGS="<string>--qemu-nbd</string><string>$NBD_DIR/qemu-nbd</string>"
fi
[ -n "${NBD_STAGE:-}" ] && rm -rf "$NBD_STAGE"

cat > "$PLIST" <<PLIST_END
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BINARY</string>
    <string>--socket</string><string>$SOCKET</string>
    <string>--allow-uid</string><string>$ALLOW_UID</string>
    $USB_ARGS
    $NBD_ARGS
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>TANDEM_BUNDLE_PREFIX</key><string>$TANDEM_BUNDLE_PREFIX</string>
    <key>TANDEM_APP_ID</key><string>$TANDEM_APP_ID</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST_END
chown root:wheel "$PLIST"
chmod 0644 "$PLIST"

launchctl bootstrap system "$PLIST"

for _ in $(seq 1 50); do
  if [ -S "$SOCKET" ]; then
    parts="network bridging"
    [ -n "$NBD_ARGS" ] && parts="$parts, USB drives"
    [ -n "$USB_ARGS" ] && parts="$parts, USB devices"
    echo "Tandem helper installed for user id $ALLOW_UID ($parts)."
    if [ -n "$NBD_ARGS" ]; then
      echo "If a USB drive then fails with \"Operation not permitted\": allow Full Disk Access for '$LABEL'"
      echo "in System Settings > Privacy & Security > Full Disk Access (+, then add $BINARY)."
    fi
    exit 0
  fi
  sleep 0.1
done
echo "The helper was installed but did not start. See $LOG" >&2
exit 1
