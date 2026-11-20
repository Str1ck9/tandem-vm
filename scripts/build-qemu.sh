#!/bin/sh
# Builds QEMU 11.1.3 with this project's patches and installs it where the app looks first.
# - hvf-unknown-smc: Windows 11 22H2 guests hang at boot on stock QEMU, which faults an SMC call their boot loader makes.
# - parallels-readonly-migration: lets a VM whose disk is an overlay on a read-only Parallels image be suspended.
# - usb-cdc-acm: a USB modem-class serial port with configurable ids, so a Mac serial device (a Flipper Zero) reaches
#   the guest under its own identity and Windows binds its inbox usbser.sys instead of needing FTDI's driver.
# usb-redir: USB devices are handed to guests through the root helper (usbredir), because macOS only lets root detach its own drivers.
# Homebrew's QEMU is not touched. Needs Homebrew's qemu dependencies (brew install qemu pulls them in).
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
version=11.1.3
sha256=5a8289c7940dc77d3873c81a6c29ba3afe1446fc9d36e77fa1658cdbecb84b22
prefix="${1:-$HOME/Library/Application Support/Tandem/qemu}"
work="$root/.cache/qemu-src"
tools="$root/.cache/buildtools"
mkdir -p "$work"
cd "$work"
[ -f "qemu-$version.tar.xz" ] || curl -fsSL -o "qemu-$version.tar.xz" "https://download.qemu.org/qemu-$version.tar.xz"
echo "$sha256  qemu-$version.tar.xz" | shasum -a 256 -c -
if [ ! -d "qemu-$version" ]; then
  tar xf "qemu-$version.tar.xz"
  (cd "qemu-$version" && for p in "$root"/patches/qemu-$version-*.patch; do patch -p1 < "$p"; done)
fi
[ -x "$tools/bin/ninja" ] || { python3 -m venv "$tools" && "$tools/bin/pip" -q install ninja; }
export PATH="$tools/bin:$PATH"
builddir="build${QEMU_PROFILE:+-$QEMU_PROFILE}"
mkdir -p "qemu-$version/$builddir"
cd "qemu-$version/$builddir"
# --disable-pvg: the apple-gfx device does not link against the current SDK and is not used here.
# QEMU_PROFILE=package (scripts/package-app.sh): leave out every optional library the app does not use, so the
# copy carried inside Tandem.app needs as few Homebrew libraries as possible (no GTK, SDL, X11, FUSE, libssh).
extra=""
if [ "${QEMU_PROFILE:-}" = package ]; then
  extra="--disable-gtk --disable-sdl --disable-fuse --disable-libssh --disable-capstone --disable-gnutls --disable-curses \
    --disable-vte --disable-opengl --disable-virglrenderer --disable-spice --disable-smartcard --disable-libiscsi --disable-libnfs --disable-sdl-image --disable-jack --disable-pa --disable-pipewire --disable-dbus-display --disable-libdw \
    --disable-curl --disable-rbd --disable-bzip2 --disable-lzfse --disable-snappy --disable-lzo"
fi
../configure --prefix="$prefix" --target-list=aarch64-softmmu --enable-hvf --enable-cocoa --enable-slirp --enable-tpm \
  --enable-tools --disable-docs --disable-werror --disable-guest-agent --disable-pvg --enable-usb-redir $extra
ninja
ninja install
"$prefix/bin/qemu-system-aarch64" --version | head -1
echo "Installed to $prefix"
