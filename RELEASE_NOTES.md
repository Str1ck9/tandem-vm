# Tandem 0.8.0

Windows, Linux and macOS virtual machines on Apple silicon Macs. Still **early software**: expect rough edges, and do not keep
the only copy of anything important in a VM yet.

## New in 0.8.0

- **AI tools get a permission level for each VM**: Off, Observe, Operate or Full (Configure > Options > Sharing > AI tools).
  Reverting a snapshot, cloning, powering off and sharing writable folders need Full; deleting a snapshot is never offered. A VM can
  mark one snapshot as its **baseline**, and AI tools may then revert only to that one. Every call an AI tool makes, allowed or refused,
  is listed in Settings > Advanced > AI activity. The app enforces all of this itself, not just through the tool list.
  *Upgrading:* existing VMs read as Operate, so revert, clone, power off and writable shares now need Full.
- **Linux guests**: a program list with icons, Mac-side launchers, files dropped onto the VM window, files sent back to the Mac
  from the file manager, any screen size, and an experimental Seamless mode for X11 desktops (Settings > Advanced, off by default).
- **Ubuntu Desktop with MATE, Xfce or GNOME**: pick the desktop when you create the VM (MATE is the default and Xfce the lightest).
- **macOS guest tools** (clipboard, clean shutdown and restart, clock after resume), delivered on a "Tandem Tools" disc.
- **Windows on a Retina screen**: the guest's display scale follows your screen, and an option gives Windows the screen's full pixel
  resolution. (The 3D display driver only offers a fixed list of sizes.)
- **Network changes while a QEMU VM runs**: port forwards, the virtual cable, shared or bridged networking.
- **Safer by design**: a security review fixed ten problems in the helper, file sharing and guest channel; shared folders no longer
  follow links out of the share; a failed overwrite or snapshot restore no longer loses the old data; one program at a time can own a
  VM; every outside program now has a time limit.
- **Accessibility and translations**: names for controls and rows for VoiceOver, keyboard access in the snapshot list, a first
  Spanish translation (main window, New VM flow, menus) and a catalogue to add more.
- A VM made from the command line, or copied into the library, now appears without restarting the app.

## Known limits

- **USB:** only drives and serial adapters. Full USB pass-through of arbitrary devices needs Apple's
  `com.apple.vm.device-access` entitlement, which has been requested.
- **3D acceleration is experimental.** Windows 3D offers a fixed list of screen sizes and has no hardware video decoding.
- **macOS guest tools** and **Linux Seamless mode** are new and lightly tested.
- **No update feed yet.** The updater has no signing key published, so install new releases from this page.
- Printers, camera and other importers are not started (see `ROADMAP.md`).
- Apple silicon Macs only, macOS 15 or later (developed on macOS 26).

## First open

This build is signed with a Developer ID and notarised by Apple. Open the `.dmg`, drag **Tandem** to **Applications** and
open it. macOS asks once whether you want to open an app downloaded from the Internet: click **Open**. If you are upgrading
from 0.7.0, replace the app, open it, and use Settings > Network > Restart Helper.

Features that need the helper (bridged networking, USB drives, Windows shared folders) ask you to install it from the
Welcome window or Settings > Network, to allow it in System Settings > General > Login Items, and to give **Tandem** Full Disk
Access (for USB drives).

## Verify the download

The SHA-256 checksum is in the release description and in the `.sha256` file next to the image:

```sh
shasum -a 256 -c Tandem-0.8.0-arm64.dmg.sha256
```

## Build it yourself

See the README and [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md). Licence: Apache-2.0; third-party licences are in
`THIRD_PARTY_NOTICES.md`.
