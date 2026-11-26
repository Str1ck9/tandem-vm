<h1 align="center">Tandem</h1>

<p align="center">
  Windows, Linux and macOS virtual machines on Apple silicon Macs, in a native app.<br>
  Free and open source (Apache-2.0).
</p>

<p align="center">
  <a href="https://github.com/Str1ck9/tandem-vm/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/Str1ck9/tandem-vm?include_prereleases&label=release"></a>
  <a href="LICENSE"><img alt="License: Apache-2.0" src="https://img.shields.io/badge/license-Apache--2.0-blue"></a>
  <img alt="Platform: macOS 15 or later, Apple silicon" src="https://img.shields.io/badge/platform-macOS%2015%2B%20%C2%B7%20Apple%20silicon-lightgrey">
  <img alt="Status: early" src="https://img.shields.io/badge/status-early-orange">
</p>

<p align="center">
  <img src="screenshots/01-control-center.png" alt="Tandem Control Center with Windows, macOS and Linux virtual machines" width="760">
</p>

Tandem runs Windows 11 (ARM), Linux and macOS in virtual machines on your Mac. **Create New** downloads Microsoft's, Apple's and the
distributions' own installation media and sets up supported guests unattended: you pick a system, give it a name and an account, and Tandem handles
the installation. It brings a shared clipboard, shared folders, drag and drop, snapshots, instant clones and a command line with an MCP server.

Tandem is **early software**: the day-to-day flows work for its author, but expect rough edges, and read
[Status](#status) before trusting it with VMs you cannot recreate. It is not affiliated with Parallels, Apple or Microsoft.

## Download

**[Download the latest release](https://github.com/Str1ck9/tandem-vm/releases/latest)** (`Tandem-<version>-arm64.dmg`), open the
image and drag **Tandem** to **Applications**.

Requirements: an Apple silicon Mac and macOS 15 or later (macOS 26 is what Tandem is developed on).

**First open.** Releases are signed with a Developer ID and notarised by Apple. Because the app comes from the Internet,
macOS asks once whether you want to open it: click **Open**.

**Verify the download** (the checksum is on the release page):

```sh
shasum -a 256 ~/Downloads/Tandem-*-arm64.dmg
```

Prefer to build it yourself? See [Build from source](#build-from-source) and the [development and release guide](docs/DEVELOPMENT.md).

## Create your first VM

1. Open **Tandem** from Applications and choose **Create New**.
2. Choose a system to download. Select an edition, language or Linux desktop when those options are offered.
3. Give the VM a name, create its account, and start the installation. Keep your Mac awake and connected to the
   Internet while Tandem downloads the media and finishes setup.
4. When installation finishes, use the VM's desktop. Unattended Windows and Linux installations include Tandem's
   guest tools for integration with your Mac; macOS guest tools are newer and lightly tested. Check the VM's
   configuration for guest-tools status and installation controls.

The Welcome window explains helper installation for features that need it. You can start with a basic VM and
set up the helper when you need bridged networking, USB drives or Windows shared folders. See [Install](#install).

In a Windows VM, Command is the Windows key, Option is Alt, and Control-click is a right click.

**Tandem is free; guest operating systems retain their own licensing and activation requirements.** Downloading
Windows installation media through Tandem does not provide a Windows licence.

**Updates:** automatic updating is built but not switched on in these releases (it needs an update feed and signing key).
Download and install newer releases from [Releases](https://github.com/Str1ck9/tandem-vm/releases).

## Screenshots

<table>
  <tr>
    <td align="center" width="33%"><a href="screenshots/03-create-new.png"><img src="screenshots/03-create-new.png" alt="Create New"></a><br><sub><b>New VM:</b> install from an image, import, or download official installation media</sub></td>
    <td align="center" width="33%"><a href="screenshots/04-download-windows-11.png"><img src="screenshots/04-download-windows-11.png" alt="Windows 11 download list"></a><br><sub><b>Windows 11</b> from Microsoft: choose an available ARM edition and language</sub></td>
    <td align="center" width="33%"><a href="screenshots/05-download-macos.png"><img src="screenshots/05-download-macos.png" alt="macOS download"></a><br><sub><b>macOS</b> from Apple's restore images</sub></td>
  </tr>
  <tr>
    <td align="center"><a href="screenshots/06-download-linux.png"><img src="screenshots/06-download-linux.png" alt="Linux download list"></a><br><sub><b>Linux:</b> Ubuntu (MATE, Xfce or GNOME), Debian, Fedora, Kali</sub></td>
    <td align="center"><a href="screenshots/01-control-center.png"><img src="screenshots/01-control-center.png" alt="Control Center, light"></a><br><sub><b>Control Center</b> with Windows, macOS and Linux VMs</sub></td>
    <td align="center"><a href="screenshots/02-control-center-dark.png"><img src="screenshots/02-control-center-dark.png" alt="Control Center, dark"></a><br><sub>The same in dark appearance</sub></td>
  </tr>
  <tr>
    <td align="center"><a href="screenshots/09-config-general.png"><img src="screenshots/09-config-general.png" alt="VM configuration, General"></a><br><sub><b>Configuration:</b> general settings, engine and guest tools</sub></td>
    <td align="center"><a href="screenshots/11-config-graphics.png"><img src="screenshots/11-config-graphics.png" alt="Graphics configuration"></a><br><sub><b>Graphics:</b> resolution and experimental 3D acceleration</sub></td>
    <td align="center"><a href="screenshots/13-config-sharing.png"><img src="screenshots/13-config-sharing.png" alt="Sharing configuration"></a><br><sub><b>Sharing:</b> Mac folders, clipboard and restrictions</sub></td>
  </tr>
  <tr>
    <td align="center"><a href="screenshots/14-snapshot-manager.png"><img src="screenshots/14-snapshot-manager.png" alt="Snapshot Manager"></a><br><sub><b>Snapshots:</b> take, revert and delete</sub></td>
    <td align="center"><a href="screenshots/18-settings-general.png"><img src="screenshots/18-settings-general.png" alt="Settings"></a><br><sub><b>Settings:</b> update preferences.0</sub></td>
    <td align="center"><a href="screenshots/21-running-ubuntu-mate.png"><img src="screenshots/21-running-ubuntu-mate.png" alt="Ubuntu MATE running in Tandem"></a><br><sub><b>A running</b> Ubuntu MATE VM, signed in automatically</sub></td>
  </tr>
  <tr>
    <td align="center"><a href="screenshots/22-ai-level.png"><img src="screenshots/22-ai-level.png" alt="AI tools permission level"></a><br><sub><b>AI tools:</b> a permission level for each VM (Off, Observe, Operate, Full)</sub></td>
    <td align="center"><a href="screenshots/23-snapshot-baseline.png"><img src="screenshots/23-snapshot-baseline.png" alt="Snapshot baseline"></a><br><sub><b>Baseline snapshot:</b> the only one an AI tool may revert to</sub></td>
    <td align="center"><a href="screenshots/24-ai-switch.png"><img src="screenshots/24-ai-switch.png" alt="Settings, Advanced"></a><br><sub><b>AI switch:</b> the master switch, and the log of every call an AI tool made</sub></td>
  </tr>
</table>

All pictures, with captions and how they were made, are in [`screenshots/`](screenshots/).

## What it does

- **Install a system without hunting for ISOs.** Create New offers official installation media for supported systems and sets them up unattended:
  Windows 11 ARM (Microsoft's own media), macOS (Apple's restore images), Ubuntu (MATE, Xfce or GNOME desktop, or Server),
  Debian, Fedora and Kali. You answer one page (name, account); Tandem does the rest.
- **Two engines.** macOS guests run on Apple's Virtualization framework. Windows runs on QEMU with Apple's Hypervisor
  framework; Linux can use either (QEMU for a TPM, USB redirection or 3D).
- **Guest tools** for Windows, Linux and macOS guests: shared clipboard, shared Mac folders, drag and drop, resolution that follows the
  window, clean shutdown and restart, and time sync after a resume. **Seamless mode** shows Windows programs in Mac windows, launchable from
  Finder and the Dock; Linux guests list their programs, get Mac-side launchers and take dropped files, with an experimental Seamless mode
  for X11 desktops. Not every feature exists on every guest; see [Status](#status).
- **Snapshots, instant clones, suspend and resume.** A VM can mark one snapshot as its **baseline**.
- **AI tools under your control.** `tandem mcp` lets AI tools start, snapshot and run commands in your VMs, with a
  permission level for each VM (Off, Observe, Operate, Full), a baseline snapshot as the only revert target, and a
  log of every call. See [Command line and AI tools](#command-line-and-ai-tools-mcp).
- **Sharing profiles and restrictions** for VMs you do not fully trust.
- **Windows on a Retina screen.** The guest's display scale follows your screen, and an option gives Windows the screen's full pixel resolution.
- **Network changes while a QEMU VM runs:** port forwards, the virtual cable and shared or bridged networking.
- **USB**: drives and serial adapters can be given to a VM. Full USB pass-through of arbitrary devices needs an Apple
  entitlement that this project does not have yet (see [Status](#status)).
- **3D acceleration (experimental)** for Linux and Windows guests, built from UTM's open-source graphics stack.
- **Import** existing Parallels Desktop VMs that you own.
- **Self-contained, notarised app** with its own QEMU, an uninstaller, signed-update support (not yet switched on), VoiceOver names for its controls,
  a first Spanish translation, and crash-report prompts that send nothing without your say.

## Status

| Area | State |
|---|---|
| Linux, Windows 11 ARM, macOS guests: install, run, snapshots, clone | Working |
| Guest tools: Windows and Linux | Working |
| Guest tools: macOS | New (clipboard, restart, clock, activity); lightly tested |
| Seamless mode (Windows) | Working; some drag-out cases unfinished |
| Linux programs, launchers, drag and drop | Working (X11 desktops, NAT networking for drops); drag-out from file managers only |
| Linux Seamless mode | Experimental, off by default |
| AI tools (MCP): permission levels, baseline snapshot, activity log | Working |
| Network changes while a VM runs | Working on QEMU VMs; macOS guests apply them at the next start |
| 3D acceleration | Experimental; Windows 3D offers a fixed list of screen sizes and cannot follow the window freely while running; no hardware video decoding |
| Windows display scale / Retina resolution | Working; the Retina option on the 3D display gets the closest size the driver offers |
| USB pass-through | Drives and serial devices only; full pass-through needs Apple's `com.apple.vm.device-access` entitlement (requested) |
| Accessibility (VoiceOver, keyboard) | First pass: names and keyboard access added; a full audit with VoiceOver is still to do |
| Translations | Spanish proof of concept (main window, New VM flow, menus); most text is English only |
| Notarised releases | Yes |
| Automatic updates | Built; needs an update feed and signing key, so releases are installed by hand for now |
| Printers, camera, other importers | Not started (see [Roadmap](ROADMAP.md)) |

Requirements: Apple silicon Mac, **macOS 15 or later** (macOS 26 recommended; development happens on 26).

## Install

Download the `.dmg` from the [Releases page](https://github.com/Str1ck9/tandem-vm/releases/latest) and drag Tandem to Applications
(see [Download](#download) for the first-open steps), or build from source (below).

The first time you use bridged networking, USB drives or Windows shared folders, Tandem asks you to install its helper
(Settings > Network > Install…, then allow it under System Settings > General > Login Items) and to give **Tandem** Full
Disk Access for USB drives. The Welcome window walks you through it.

## Build from source

Requires Xcode with Swift 6, Rust, and Homebrew on an Apple silicon Mac running macOS 15 or later.
Install Xcode and Rust first, then:

```sh
git clone https://github.com/Str1ck9/tandem-vm.git
cd tandem-vm
brew install qemu swtpm
scripts/build-app.sh
open build/Tandem.app
```

This makes a development app signed ad hoc for local use. Guest integration also requires the corresponding
[guest-agent builds](docs/DEVELOPMENT.md#build-and-test). See the [development and release guide](docs/DEVELOPMENT.md)
for repository layout, tests, guest-agent builds, self-contained packaging, helper setup, signing and notarisation.

## Importing existing virtual machines (Parallels Desktop)

Tandem can read a Parallels Desktop VM bundle (`.pvm`, `.macvm`) that you own and run it, without modifying the original. Tandem is not
associated with Parallels; the import reads the files of your own VMs. You can import through **File → Import from Parallels…**
or use `vmctl` after a [source build](#build-from-source). Run these commands from the cloned repository directory:

```sh
VMCTL="$PWD/host/.build/debug/vmctl"
"$VMCTL" inspect-parallels "$HOME/Parallels/Kali Linux.pvm"   # read-only report
"$VMCTL" import-parallels "$HOME/Parallels/Kali Linux.pvm"    # no disk copy
"$VMCTL" start "Kali Linux"
```

The Parallels bundle is never written. A `.pvm` import is an overlay on the original disk, so the original must stay
where it is and must not be started in Parallels again; pass `--copy` for an independent VM. A `.macvm` import is an
APFS clone and is independent from the start.

Windows needs a repair pass to boot on QEMU, which `import-parallels` runs when given a Windows 11 ARM64 installer ISO:

```sh
"$VMCTL" import-parallels "$HOME/Parallels/Windows 11.pvm" \
  --windows-iso ~/ISOs/Windows11_Client_arm64.iso --virtio-iso .cache/images/virtio-win-0.1.302.iso
```

Windows 11 25H2 boots after that on stock QEMU. Windows 11 22H2 additionally needs this project's patched QEMU build,
because stock QEMU faults a firmware call its boot loader makes (`patches/`):

```sh
scripts/build-qemu.sh        # one time, about five minutes; installs to ~/Library/Application Support/Tandem/qemu
```

`vmctl` and the app use that build automatically when it exists (or the one named by `TANDEM_QEMU_PREFIX`).

## Command line and AI tools (MCP)

`tandem` controls the virtual machines of the running Tandem app (it starts the app hidden when it is not running).
Install it from Tandem > Settings > Advanced > **Install Command-Line Tool**, which links
`Tandem.app/Contents/Helpers/tandem` into `/opt/homebrew/bin` (when writable) or `~/.local/bin`. `tandem help` lists
the commands; `--json` gives machine-readable answers.

```sh
tandem list
tandem start Debian --wait-tools
tandem exec Debian -- uname -a
tandem share Debian ~/Projects --read-only
tandem snapshot take Debian "Before upgrade"
tandem stop Debian
```

`tandem mcp` serves the Model Context Protocol on stdin/stdout. To add it to Claude Code:

```sh
claude mcp add tandem -- ~/.local/bin/tandem mcp     # or /opt/homebrew/bin/tandem
```

Nothing works through it until **Allow AI tools (MCP) to control Tandem** is turned on in Tandem > Settings > Advanced
(off by default). That is the master switch. Below it, each VM has an **AI level**, set in Configure > Options >
Sharing > AI tools (or `tandem sharing <vm> --ai-tier observe|operate|full|off`):

| Level | What AI tools may do with the VM |
|---|---|
| Off | Nothing, not even look at it |
| Observe | List and inspect it, read its snapshots, take screenshots |
| **Operate** (the default) | Also start, shut down gracefully, suspend, resume and restart it, take snapshots, share folders read-only, run commands (if the VM's *Commands from the Mac* allows AI tools) |
| Full | Also revert to a snapshot, clone, power off or reset, share folders the guest can change. Work can be lost, so it is never the default |

Deleting a snapshot is never offered to AI tools, and an AI tool cannot change a VM's level, its baseline or who may run
commands. **Baseline:** mark one snapshot as a VM's baseline (Snapshot Manager > Set as Baseline, or `tandem snapshot
baseline <vm> <snapshot>`). An AI tool may then revert only to that snapshot, so a bad run cannot roll back past its safety
net. `guest_exec` also needs the VM's own permission, Configure > Options > Sharing > Commands from the Mac ("The
command-line tool and AI tools"); by default only the command-line tool may run commands, and restricted VMs allow none.
The app decides all of this on every request, whatever the client claims to be; the `tandem` command is the Mac user's
own tool and is not limited by the AI level. Every call an AI tool makes, allowed or refused, is listed in Tandem >
Settings > Advanced > AI activity (`ai-activity.log` in the library folder). Both clients talk to the app over
`control.sock` in the library folder (owner-only).

Upgrading from 0.7.0: existing VMs read as **Operate**, so revert, clone, power off and writable shares now need the Full level.


<a id="packaged-app-self-contained-signed"></a>

## Maintainers

See the [development and release guide](docs/DEVELOPMENT.md) for bundle identifiers, repository settings,
helper installation, signing and update keys, packaging, and [release steps](docs/DEVELOPMENT.md#maintainers-release).

## Licence

Tandem is licensed under the [Apache License 2.0](LICENSE). It runs and downloads other open-source software that keeps its own
licences: see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The QEMU patches in `patches/` are under QEMU's licence.
Parallels is a trademark of its owner; Tandem is an independent project.
