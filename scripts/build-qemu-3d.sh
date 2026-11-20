#!/bin/sh
# Builds Tandem's 3D-capable QEMU (virtio-gpu-gl + virglrenderer on Apple's OpenGL or ANGLE on Metal, and the
# Windows Direct3D path: Neptune + DXMT in virglrenderer's render server) and stages it in
# ~/Library/Application Support/Tandem/qemu-3d.staged (TANDEM_QEMU_3D_OUT overrides). The normal QEMU is not touched.
#
# This follows UTM's approach (github.com/utmapp/UTM, Apache-2.0, scripts/build_dependencies.sh): UTM's QEMU
# release with UTM's patch, plus Tandem's own patches. Every library it links or loads (ANGLE, libepoxy,
# Vulkan loader, virglrenderer and its render server, DXMT) is built from public source by
# scripts/build-3d-deps.sh; nothing is copied from another app. Apple's D3DMetal is never used.
#
# Needs: Xcode with the Metal toolchain (xcodebuild -downloadComponent MetalToolchain), Homebrew meson ninja
# pkg-config cmake spice-server spice-protocol glib pixman libslirp.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
build="$root/.cache/3d-build"
src="$build/src"
deps="${TANDEM_3D_DEPS:-$root/.cache/3d-src/prefix}"
out="${TANDEM_QEMU_3D_OUT:-$HOME/Library/Application Support/Tandem/qemu-3d.staged}"
gh=https://github.com
raw=https://raw.githubusercontent.com
# QEMU sources: UTM's QEMU 10.0.12 release and UTM's patch for it (UTM commit d1a889ad, the patch UTM ships
# since 11 Nov 2026), each checked against its SHA-256.
QEMU_SHA=7c9605290b34152debb842e965a55d2e4fbba4793e536ab677b4027e5dc0ba1a
UTM_COMMIT=d1a889ad582d6fc6f2214fef952286c93d47449c
PATCH_SHA=b3d9931d6099a034031a81bdd9de09d711b18525d648201f348306516acb6002

for tool in meson ninja pkg-config; do command -v $tool >/dev/null || { echo "missing: $tool (brew install meson ninja pkg-config)" >&2; exit 1; }; done
pkg-config --exists spice-server spice-protocol || { echo "missing: brew install spice-server spice-protocol" >&2; exit 1; }
[ -f "$deps/Frameworks/virglrenderer.1.framework/virglrenderer.1" ] || TANDEM_3D_DEPS="$deps" "$root/scripts/build-3d-deps.sh"

mkdir -p "$src"
cd "$src"
[ -f qemu-10.0.12-utm.tar.xz ] || curl -sfL -o qemu-10.0.12-utm.tar.xz "$gh/utmapp/qemu/releases/download/v10.0.12-utm/qemu-10.0.12-utm.tar.xz"
[ -f qemu-10.0.12-utm.patch ] || curl -sfL -o qemu-10.0.12-utm.patch "$raw/utmapp/UTM/$UTM_COMMIT/patches/qemu-10.0.12-utm.patch"
echo "$QEMU_SHA  qemu-10.0.12-utm.tar.xz" | shasum -a 256 -c - >/dev/null || { echo "checksum mismatch: QEMU tarball" >&2; rm -f qemu-10.0.12-utm.tar.xz; exit 1; }
echo "$PATCH_SHA  qemu-10.0.12-utm.patch" | shasum -a 256 -c - >/dev/null || { echo "checksum mismatch: UTM's QEMU patch" >&2; rm -f qemu-10.0.12-utm.patch; exit 1; }
if [ ! -d qemu-10.0.12-utm ]; then
  tar xJf qemu-10.0.12-utm.tar.xz
  (cd qemu-10.0.12-utm && patch -p1 -s < ../qemu-10.0.12-utm.patch)
  # Tandem's own changes on top (GPL like QEMU): egl-headless on macOS so the 3D picture reaches Tandem's
  # window through VNC, and the Windows driver's shared-memory scanout shown as a 2D surface.
  for p in "$root"/patches/qemu-10.0.12-utm-*.patch; do
    [ -f "$p" ] && (cd qemu-10.0.12-utm && patch -p1 -s < "$p")
  done
fi

cd qemu-10.0.12-utm
rm -rf build && mkdir -p build && cd build
PKG_CONFIG_PATH="$deps/lib/pkgconfig:/opt/homebrew/lib/pkgconfig" ../configure --prefix="$out" --target-list=aarch64-softmmu \
  --enable-hvf --enable-opengl --enable-virglrenderer --enable-spice --enable-slirp --enable-tpm \
  --disable-cocoa --disable-sdl --disable-gtk --disable-docs --disable-werror --disable-fuse --disable-fuse-lseek \
  --extra-cflags="-I$deps/include" --extra-ldflags="-L$deps/lib -Wl,-rpath,@executable_path/../Frameworks"
ninja
rm -rf "$out"
ninja install
mkdir -p "$out/Frameworks" "$out/libexec"
cp -R "$deps"/Frameworks/*.framework "$out/Frameworks/"
# virglrenderer's render server (MIT), built from the same virglrenderer: the Windows Direct3D path
# (Neptune, DXMT) runs in this separate process. Linux 3D does not use it.
cp "$deps/libexec/virgl_render_server" "$out/libexec/virgl_render_server"
codesign --force --sign - "$out/libexec/virgl_render_server" >/dev/null 2>&1
echo "Staged: $out"
