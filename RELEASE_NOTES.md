# Tandem 0.7.0

Windows, Linux and macOS virtual machines on Apple silicon Macs. This is the first public release: **early software**.
Expect rough edges, and do not keep the only copy of anything important in a VM yet.

## What is in it

- **Create New** downloads and installs systems unattended: Windows 11 ARM (Microsoft's own media), macOS (Apple's restore
  images), Ubuntu 24.04 and 26.04 (MATE, Xfce or GNOME desktop, or Server), Debian, Fedora and Kali.
- **Two engines.** macOS guests use Apple's Virtualization framework; Windows and Linux use QEMU with Apple's Hypervisor
  framework.
- **Guest tools** for Windows and Linux (and, newer and lightly tested, macOS): shared clipboard, shared Mac folders,
  drag and drop, resolution that follows the window, clean shutdown, time sync.
- **Seamless mode** for Windows: Windows programs in Mac windows, launchable from Finder and the Dock.
- **Snapshots, instant clones, templates, suspend and resume.**
- **USB** drives and serial adapters can be given to a VM.
- **Automation:** a `tandem` command-line tool and an MCP server (off by default; per-VM permissions).
- **Parallels import:** read VMs you own, without modifying the originals.
- **Self-contained app:** its own QEMU, an uninstaller, a built-in updater (needs an update feed, see below) and crash-report
  prompts that send nothing without your say.

## Known limits

- **Not notarised.** macOS blocks the first launch (see "First open").
- **USB:** only drives and serial adapters. Full USB pass-through of arbitrary devices needs Apple's
  `com.apple.vm.device-access` entitlement, which this project does not have yet.
- **3D acceleration is experimental.** Windows 3D cannot resize the display while running and has no hardware video decoding.
- **macOS guest tools** are new and lightly tested.
- **No update feed yet.** This build's updater has no signing key, so it will not offer or install updates; download new
  releases from this page.
- Linux Seamless mode, printers, camera and other importers are not started (see `ROADMAP.md`).
- Apple silicon Macs only, macOS 15 or later (developed on macOS 26).

## First open

This build is signed ad hoc, not notarised by Apple. Either:

1. Open the `.dmg`, drag **Tandem** to **Applications**.
2. Right-click (Control-click) **Tandem** in Applications, choose **Open**, then **Open** again.

or open it once, then go to System Settings > Privacy & Security and click **Open Anyway**.

Features that need the helper (bridged networking, USB drives, Windows shared folders) ask you to install it from the
Welcome window or Settings > Network, to allow it in System Settings > General > Login Items, and to give **Tandem** Full Disk
Access (for USB drives). Because the app is signed ad hoc, macOS may refuse to register the helper; the README
explains the `sudo scripts/install-net-helper.sh` route.

## Verify the download

The SHA-256 checksum is in the release description and in the `.sha256` file next to the image:

```sh
shasum -a 256 -c Tandem-0.7.0-arm64.dmg.sha256
```

## Build it yourself

See the README: [Build from source](README.md#build-from-source) and
[Packaged app](README.md#packaged-app-self-contained-signed). Licence: Apache-2.0; third-party licences are in
`THIRD_PARTY_NOTICES.md`.
