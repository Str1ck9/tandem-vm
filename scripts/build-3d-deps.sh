#!/bin/sh
# Builds the libraries behind Tandem's 3D QEMU from public source, so nothing is copied out of another app:
#
#   ANGLE (EGL + GLESv2 on Metal, BSD-3-Clause)      from WebKit's copy of ANGLE, as UTM builds it
#   libepoxy (MIT)                                   GL/EGL dispatch
#   Vulkan-Loader (Apache-2.0)                       linked by virglrenderer's Venus path
#   virglrenderer (MIT) + virgl_render_server        Linux 3D (virgl) and Windows 3D (Neptune)
#   LLVM 15 libraries (Apache-2.0 with LLVM exception)  only to build DXMT's shader converter
#   DXMT native (LGPL-2.1-or-later)                  Direct3D 11 on Metal, loaded by Neptune
#
# The commits are the ones UTM's own build pins (github.com/utmapp/UTM, scripts/build_dependencies.sh and
# patches/sources, Apache-2.0); the build steps follow that script. Apple's D3DMetal is never built or used.
#
# Output: $TANDEM_3D_DEPS (default .cache/3d-src/prefix) with Frameworks/{EGL,GLESv2,epoxy.0,
# virglrenderer.1,vulkan.1,dxmt-native}.framework (the layout libepoxy and the QEMU build expect) and
# libexec/virgl_render_server. scripts/build-qemu-3d.sh links QEMU against it.
#
#   scripts/build-3d-deps.sh            everything (first run about 1 hour on an M2 Pro, mostly LLVM and ANGLE)
#   STEPS="epoxy virgl" scripts/build-3d-deps.sh   only some steps (fetch angle llvm dxmt epoxy vulkan virgl frameworks)
#
# Needs: Xcode, Homebrew cmake meson ninja pkg-config python3.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
. "$root/scripts/identity.sh"
work="${TANDEM_3D_WORK:-$root/.cache/3d-src}"
src="$work/src"
stage="$work/stage"            # plain install prefix (dylibs, headers, pkg-config)
prefix="${TANDEM_3D_DEPS:-$work/prefix}"   # packaged output
steps="${STEPS:-fetch angle llvm dxmt epoxy vulkan virgl frameworks}"
ncpu=$(sysctl -n hw.ncpu)
export MACOSX_DEPLOYMENT_TARGET=13.0
want() { case " $steps " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
say() { echo "== $(date +%H:%M:%S) $*"; }
for tool in cmake meson ninja pkg-config python3 xcodebuild; do
  command -v $tool >/dev/null || { echo "missing: $tool" >&2; exit 1; }
done
mkdir -p "$src" "$stage/lib/pkgconfig" "$stage/include"
# virglrenderer's generators need PyYAML and Mako; keep them in a private Python environment.
if [ ! -x "$work/venv/bin/python3" ]; then
  python3 -m venv "$work/venv" && "$work/venv/bin/pip" install -q pyyaml mako
fi
export PATH="$work/venv/bin:$PATH"

# Pinned sources (owner/repo, commit, SHA-256 of GitHub's tarball of that commit).
EPOXY="utmapp/libepoxy bf98587477fe68d07b93319ece7b40a7d0e2eabe ea784095dae75234f30a90ddd7f7acb13e8779474d64b6f3aac8d6b0e9a052e8"
VIRGL="utmapp/virglrenderer dd0652b13e589c4c124ea79123a3adcd85173f4f 9019a8461f12c0e2c6d33d83e16cc47da759ea66175bb1e01232e84044b42231"
VULKAN="osy/Vulkan-Loader 6df86907be582927507637f3f6003ea58bc34517 4802ba9b7e28bea1bae993cfc986d37c6d9717f0eac8edf3ab14e41e56164487"
DXMT="utmapp/dxmt 1fe2e752c98207518a99c9322482f63ebb9f0232 7b33595e04c918d6a3713ffaa8eb05ddad3b56fa94332e567de721300ef33db0"
# DXMT's submodule include/native/directx and its meson subproject directx-native, at the pinned commits.
DXHEADERS="misyltoad/mingw-directx-headers 9df86f2341616ef1888ae59919feaa6d4fad693d 9c1b8bbfd2d6c758fac4d93c2808a46bc1eee429fe656b4f21b29e02615aa8aa"
DXNATIVE="osy/directx-native 7258be1c56cdbf1e55c56b1bc4a866169c8ca0da da4517d5c31465a5ec03d4c679371da178ef010cb38655dac5e1d7e71d201630"
LLVM15_URL=https://github.com/llvm/llvm-project/releases/download/llvmorg-15.0.7/llvm-project-15.0.7.src.tar.xz
LLVM15_SHA=8b5fcb24b4128cf04df1b0b9410ce8b1a729cb3c544e6da885d234280dedeac6
WEBKIT_REPO=https://github.com/utmapp/WebKit.git
WEBKIT_COMMIT=ed78ab6e1a37f4f11583a0bd038f22ec91f3ff10

fetch_tar() { # name "owner/repo commit sha"
  name=$1; set -- $2
  file="$src/$name.tar.gz"
  [ -f "$file" ] || curl -sfL -o "$file" "https://codeload.github.com/$1/tar.gz/$2"
  echo "$3  $file" | shasum -a 256 -c - >/dev/null || { echo "checksum mismatch: $file" >&2; rm -f "$file"; exit 1; }
  rm -rf "$src/$name"; mkdir "$src/$name"; tar xzf "$file" -C "$src/$name" --strip-components 1
}

if want fetch; then
  say "fetching sources"
  fetch_tar epoxy "$EPOXY"; fetch_tar virglrenderer "$VIRGL"; fetch_tar vulkanloader "$VULKAN"; fetch_tar dxmt "$DXMT"
  fetch_tar dxheaders "$DXHEADERS"; fetch_tar directx-native "$DXNATIVE"
  rm -rf "$src/dxmt/include/native/directx" "$src/dxmt/subprojects/directx-native"
  cp -R "$src/dxheaders" "$src/dxmt/include/native/directx"
  cp -R "$src/directx-native" "$src/dxmt/subprojects/directx-native"
  if [ ! -d "$src/llvm-project-15.0.7.src" ]; then
    [ -f "$src/llvm15.tar.xz" ] || curl -sfL -o "$src/llvm15.tar.xz" "$LLVM15_URL"
    echo "$LLVM15_SHA  $src/llvm15.tar.xz" | shasum -a 256 -c - >/dev/null || { echo "checksum mismatch: LLVM 15" >&2; exit 1; }
    tar xJf "$src/llvm15.tar.xz" -C "$src"
  fi
  if [ ! -d "$src/WebKit/Source/ThirdParty/ANGLE" ]; then
    # Only ANGLE and the build configuration it needs, at the pinned commit.
    rm -rf "$src/WebKit"; mkdir -p "$src/WebKit"
    ( cd "$src/WebKit" && git init -q && git remote add origin "$WEBKIT_REPO" \
      && git sparse-checkout set --no-cone Source/ThirdParty/ANGLE Configurations Tools/ccache \
      && git fetch -q --depth 1 --filter=blob:none origin "$WEBKIT_COMMIT" && git checkout -q FETCH_HEAD )
  fi
fi

if want angle; then
  say "ANGLE (xcodebuild)"
  ( cd "$src/WebKit/Source/ThirdParty/ANGLE"
    env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$(command -v python3)")" HOME="$HOME" \
      xcodebuild archive -archivePath "$work/angle-build/ANGLE" -scheme ANGLE -sdk macosx -arch arm64 \
        -configuration Release -derivedDataPath "$work/angle-build/dd" \
        WEBCORE_LIBRARY_DIR=/usr/local/lib NORMAL_UMBRELLA_FRAMEWORKS_DIR= CODE_SIGNING_ALLOWED=NO \
        GCC_TREAT_WARNINGS_AS_ERRORS=NO MACOSX_DEPLOYMENT_TARGET=13.0 >"$work/angle-build.log" 2>&1 \
      || { tail -30 "$work/angle-build.log" >&2; exit 1; }
    rsync -a "$work/angle-build/ANGLE.xcarchive/Products/usr/local/lib/" "$stage/lib/"
    rsync -a include/ "$stage/include/" )
fi

if want llvm; then
  say "LLVM 15 libraries (for DXMT's shader converter)"
  cmake -S "$src/llvm-project-15.0.7.src/llvm" -B "$work/llvm-build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$work/llvm15" -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DLLVM_ENABLE_ZSTD=Off -DLLVM_TARGETS_TO_BUILD="" -DLLVM_BUILD_TOOLS=Off -DLLVM_INCLUDE_TESTS=Off \
    -DLLVM_INCLUDE_EXAMPLES=Off -DLLVM_INCLUDE_BENCHMARKS=Off -DLLVM_VERSION_PRINTER_SHOW_HOST_TARGET_INFO=Off \
    -DLLVM_ENABLE_TERMINFO=Off -DLLVM_ENABLE_LIBXML2=Off >"$work/llvm-build.log" 2>&1
  ninja -C "$work/llvm-build" install >>"$work/llvm-build.log" 2>&1 || { tail -30 "$work/llvm-build.log" >&2; exit 1; }
  # LLVM 15's tablegen is not installed with LLVM_BUILD_TOOLS=Off but DXMT does not need it.
fi

if want dxmt; then
  say "DXMT native"
  rm -rf "$work/dxmt-build"
  ( cd "$src/dxmt" && meson setup "$work/dxmt-build" --buildtype=release --prefix="$stage" \
      -Dnative_llvm_path="$work/llvm15" >"$work/dxmt-build.log" 2>&1 \
    && ninja -C "$work/dxmt-build" >>"$work/dxmt-build.log" 2>&1 \
    && ninja -C "$work/dxmt-build" install >>"$work/dxmt-build.log" 2>&1 ) || { tail -40 "$work/dxmt-build.log" >&2; exit 1; }
fi

if want epoxy; then
  say "libepoxy"
  rm -rf "$work/epoxy-build"
  ( cd "$src/epoxy" && meson setup "$work/epoxy-build" --buildtype=release --prefix="$stage" \
      -Dtests=false -Dglx=no -Degl=yes -Dx11=false \
      -Dc_args="-I$stage/include" >"$work/epoxy-build.log" 2>&1 \
    && ninja -C "$work/epoxy-build" install >>"$work/epoxy-build.log" 2>&1 ) || { tail -30 "$work/epoxy-build.log" >&2; exit 1; }
fi

if want vulkan; then
  say "Vulkan loader"
  cmake -S "$src/vulkanloader" -B "$work/vulkan-build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$stage" -DCMAKE_OSX_ARCHITECTURES=arm64 -DUPDATE_DEPS=On \
    -DBUILD_TESTS=Off >"$work/vulkan-build.log" 2>&1
  ninja -C "$work/vulkan-build" install >>"$work/vulkan-build.log" 2>&1 || { tail -30 "$work/vulkan-build.log" >&2; exit 1; }
  # As UTM does: one real file named libvulkan.1.dylib, without the minor-version symlinks.
  real=$(readlink "$stage/lib/libvulkan.1.dylib" || true)
  [ -n "$real" ] && mv -f "$stage/lib/$real" "$stage/lib/libvulkan.1.dylib"
fi

if want virgl; then
  say "virglrenderer"
  rm -rf "$work/virgl-build"
  ( cd "$src/virglrenderer" && PKG_CONFIG_PATH="$stage/lib/pkgconfig:$stage/share/pkgconfig" \
      meson setup "$work/virgl-build" --buildtype=release --prefix="$stage" \
      -Dtests=false -Dcheck-gl-errors=false -Dvenus=true -Dneptune=true -Dvulkan-dload=false \
      -Drender-server-mode=process -Dc_args="-I$stage/include" -Dcpp_args="-I$stage/include" \
      >"$work/virgl-build.log" 2>&1 \
    && ninja -C "$work/virgl-build" install >>"$work/virgl-build.log" 2>&1 ) || { tail -40 "$work/virgl-build.log" >&2; exit 1; }
fi

if want frameworks; then
  say "packaging as frameworks"
  rm -rf "$prefix"; mkdir -p "$prefix/Frameworks" "$prefix/libexec" "$prefix/include" "$prefix/lib/pkgconfig"
  # dylib in $stage/lib -> framework name (the names libepoxy dlopens and UTM's QEMU links).
  make_fw() { # dylib name
    lib=$(cd "$stage/lib" && ls $1 2>/dev/null | head -1)
    [ -n "$lib" ] || { echo "not built: $1" >&2; exit 1; }
    fw="$prefix/Frameworks/$2.framework"
    mkdir -p "$fw/Versions/A/Resources"
    cp -L "$stage/lib/$lib" "$fw/Versions/A/$2"
    ln -sfh A "$fw/Versions/Current"; ln -sfh "Versions/Current/$2" "$fw/$2"; ln -sfh Versions/Current/Resources "$fw/Resources"
    cat > "$fw/Versions/A/Resources/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$2</string>
<key>CFBundleIdentifier</key><string>$TANDEM_BUNDLE_PREFIX.3d.$(echo $2 | tr -cd 'A-Za-z0-9')</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>
EOF
    install_name_tool -id "@rpath/$2.framework/Versions/A/$2" "$fw/Versions/A/$2" 2>/dev/null
  }
  make_fw "libEGL.dylib" EGL
  make_fw "libGLESv2.dylib" GLESv2
  make_fw "libepoxy.0.dylib" epoxy.0
  make_fw "libvulkan.1.dylib" vulkan.1
  make_fw "libvirglrenderer.1.dylib" virglrenderer.1
  make_fw "libdxmt-native*.dylib" dxmt-native
  cp "$stage/libexec/virgl_render_server" "$prefix/libexec/virgl_render_server"
  # Point every reference at the frameworks.
  for f in "$prefix"/Frameworks/*.framework/Versions/A/* "$prefix/libexec/virgl_render_server"; do
    [ -f "$f" ] && file "$f" | grep -q Mach-O || continue
    for dep in $(otool -L "$f" | tail -n +2 | awk '{print $1}'); do
      case "$dep" in
        *libEGL*) new=@rpath/EGL.framework/Versions/A/EGL ;;
        *libGLESv2*) new=@rpath/GLESv2.framework/Versions/A/GLESv2 ;;
        *libepoxy*) new=@rpath/epoxy.0.framework/Versions/A/epoxy.0 ;;
        *libvulkan*) new=@rpath/vulkan.1.framework/Versions/A/vulkan.1 ;;
        *libvirglrenderer*) new=@rpath/virglrenderer.1.framework/Versions/A/virglrenderer.1 ;;
        *) continue ;;
      esac
      install_name_tool -change "$dep" "$new" "$f" 2>/dev/null
    done
  done
  install_name_tool -add_rpath @executable_path/../Frameworks "$prefix/libexec/virgl_render_server" 2>/dev/null || true
  for f in "$prefix"/Frameworks/*.framework/Versions/A/*; do
    [ -f "$f" ] && file "$f" | grep -q Mach-O && codesign --force --sign - "$f" >/dev/null 2>&1
  done
  codesign --force --sign - "$prefix/libexec/virgl_render_server" >/dev/null 2>&1
  # Headers, link names and pkg-config for the QEMU build.
  rsync -a "$stage/include/" "$prefix/include/"
  ln -sf ../Frameworks/epoxy.0.framework/Versions/A/epoxy.0 "$prefix/lib/libepoxy.dylib"
  ln -sf ../Frameworks/virglrenderer.1.framework/Versions/A/virglrenderer.1 "$prefix/lib/libvirglrenderer.dylib"
  cat > "$prefix/lib/pkgconfig/epoxy.pc" <<EOF
prefix=$prefix
Name: epoxy
Description: GL dispatch (built from source)
Version: 1.5.9
Cflags: -I\${prefix}/include
Libs: -L\${prefix}/lib -lepoxy
epoxy_has_glx=0
epoxy_has_egl=1
epoxy_has_wgl=0
EOF
  cat > "$prefix/lib/pkgconfig/virglrenderer.pc" <<EOF
prefix=$prefix
Name: virglrenderer
Description: virgl renderer (built from source)
Version: 1.3.0
Cflags: -I\${prefix}/include/virgl
Libs: -L\${prefix}/lib -lvirglrenderer
EOF
  du -sh "$prefix"/Frameworks/* "$prefix/libexec/virgl_render_server"
fi
say "done: $prefix"
