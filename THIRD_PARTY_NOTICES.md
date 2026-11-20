# Third-party components

Tandem runs or downloads the open-source components below. Each keeps its own licence; the full licence texts
come with the components themselves (in their source releases, and for the Windows 3D driver on the driver
disc Tandem builds). This file lists what is used and where it comes from.

| Component | Used for | Licence | Source |
|---|---|---|---|
| QEMU 11.1.3 (with Tandem's patches in `patches/`) | Windows and Linux VMs on the QEMU engine | GPL-2.0 | qemu.org; patches in this repository |
| UTM's QEMU 10.0.12 release (`qemu-10.0.12-utm`) with UTM's patch `patches/qemu-10.0.12-utm.patch` and Tandem's patches `patches/qemu-10.0.12-utm-egl-headless-darwin.patch` and `patches/qemu-10.0.12-utm-virtio-gpu-shm-scanout.patch` | The 3D QEMU (`Contents/Helpers/qemu-3d`): Linux and Windows 3D acceleration | GPL-2.0 | github.com/utmapp/qemu release v10.0.12-utm; UTM's patch from github.com/utmapp/UTM `patches/`; Tandem's patches in this repository. Built by `scripts/build-qemu-3d.sh` |
| virglrenderer (UTM's fork, commit `dd0652b1`) and its render server `virgl_render_server` | 3D acceleration: OpenGL in Linux guests (virgl), Direct3D for the Windows driver (Neptune, in the render server) | MIT | github.com/utmapp/virglrenderer |
| ANGLE (from WebKit, UTM's fork, commit `ed78ab6e`) | EGL and OpenGL ES on Metal, used by libepoxy and virglrenderer | BSD-3-Clause | github.com/utmapp/WebKit `Source/ThirdParty/ANGLE` (upstream: chromium.googlesource.com/angle) |
| libepoxy (UTM's fork, commit `bf985874`) | OpenGL and EGL function loading for QEMU and virglrenderer | MIT | github.com/utmapp/libepoxy |
| Vulkan-Loader (commit `6df86907`) | Linked by virglrenderer's Venus path | Apache-2.0 | github.com/osy/Vulkan-Loader (upstream: KhronosGroup/Vulkan-Loader) |
| DXMT (UTM's fork, commit `1fe2e752`), native macOS build | Direct3D 11 on Metal for Windows 3D, loaded by virglrenderer's render server | LGPL-2.1-or-later | github.com/utmapp/dxmt (upstream: github.com/3Shain/dxmt). Its LGPL obligations are met by this source link and the build script; the library is a separate, replaceable framework |
| LLVM 15.0.7 libraries (linked statically into DXMT) | DXMT's shader converter (DXBC to Metal AIR) | Apache-2.0 WITH LLVM-exception | github.com/llvm/llvm-project release llvmorg-15.0.7 |
| directx-native (commit `7258be1c`) and mingw-directx-headers (commit `9df86f23`) | Headers and small helpers DXMT is compiled with | Apache-2.0; MinGW-w64 headers (public domain / ZPL-2.1) | github.com/osy/directx-native, github.com/misyltoad/mingw-directx-headers |
| Libraries the 3D QEMU links, from Homebrew: GLib, pixman, spice-server, libslirp, gnutls (with nettle, gmp, libtasn1, p11-kit, libidn2, libunistring), libssh, libusb, usbredir (parser), capstone, libpng, libjpeg-turbo, zstd, and their dependencies | Bundled in `Contents/Helpers/qemu-3d/lib` | LGPL-2.1-or-later (GLib, spice-server, gnutls, libssh, libusb, usbredir parser), MIT (pixman), BSD-3-Clause (libslirp, capstone), libpng and IJG/BSD (libpng, libjpeg-turbo), BSD-3-Clause or GPL-2.0 (zstd), GPL/LGPL family for the GnuTLS dependencies | Homebrew's formula sources (formulae.brew.sh); each project's own site |
| viogpu3d (Windows ARM64 display driver, from UTM's guest tools 0.1.274) | Windows 3D acceleration; downloaded by Tandem from UTM's official release and installed in the guest | BSD-style virtio-win licence (`virtio-win_license.txt`, copied onto the driver disc) | UTM guest tools release on utmapp/qemu |
| virtio-win drivers | Windows network, storage and display drivers | BSD-style virtio-win licence | fedorapeople.org virtio-win releases |
| swtpm and libtpms | Virtual TPM for Windows 11 | BSD-3-Clause | github.com/stefanberger |
| usbredir (usbredirect) | USB devices without a Mac driver | LGPL-2.1-or-later (library), GPL-2.0-or-later (tool) | spice-space.org |
| wimlib | Building Windows install discs from Microsoft's images | LGPL-3.0-or-later (library), GPL-3.0-or-later (tool) | wimlib.net |
| zstd | Compressing suspended VM state | BSD-3-Clause or GPL-2.0 | facebook/zstd |

Every 3D library above is built from the public source at the pinned commit (SHA-256 checked) by
`scripts/build-3d-deps.sh`, following UTM's build script (github.com/utmapp/UTM `scripts/build_dependencies.sh`,
Apache-2.0); nothing is copied from an installed UTM.app. The commits are the ones UTM's own build pins (`patches/sources`).

Apple's D3DMetal is not used. No code from Parallels Desktop is used.

## Downloaded at run time, not bundled

Tandem downloads these when you ask for them; their own licences and terms apply, and Tandem does not redistribute them:

- Windows 11 installation media, from Microsoft's servers (Microsoft's licence terms; Windows needs its own licence)
- macOS restore images, from Apple's servers (Apple's software licence agreement)
- Linux cloud images and installers (Ubuntu, Debian, Fedora, Kali), from their projects' official servers, each under its own licences
- The virtio-win driver ISO (Fedora project; BSD-style licence, with some GPL components) and UTM's guest tools (Windows 3D driver)
- For development: a small Alpine Linux cloud image for the agent test

## Source code of GPL and LGPL components

Builds of Tandem that carry QEMU, usbredir, wimlib, swtpm/libtpms, GLib, spice-server and the other libraries above
include them as separate programs and libraries, unmodified except for the patches in `patches/`. They are not linked into
Tandem's own code. The corresponding source for the exact versions shipped is available from the upstream
addresses in the table, from the patches and build scripts in this repository (`scripts/build-qemu.sh`, `scripts/build-qemu-3d.sh`,
`scripts/build-3d-deps.sh`, `scripts/bundle-tool.sh`), and on request from the maintainers for three years after a release.
The licence texts accompany each component's source.

## Swift and Rust dependencies

Tandem's Swift code uses only Apple's system frameworks. The guest agent uses the Rust crates `libc`, `serde`, `serde_json`
and `windows-sys` (and their small dependencies; see `guest/Cargo.lock`), all under MIT or Apache-2.0.

## Trademarks

Parallels, Apple, macOS, Windows, Microsoft, Ubuntu, Debian, Fedora, Kali and other names are trademarks of their owners and are
used only to say what Tandem runs or imports. Tandem is not affiliated with or endorsed by them.
