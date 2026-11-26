<h1 align="center">Tandem</h1>

<p align="center">
  Windows, Linux and macOS virtual machines on Apple silicon Macs, in a native app.<br>
  Free and open source (Apache-2.0).
</p>

<p align="center">
  <a href="https://github.com/Str1ck9/tandem-vm/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/Str1ck9/tandem-vm?include_prereleases&label=release"></a>
  <a href="LICENSE"><img alt="License: Apache-2.0" src="https://img.shields.io/badge/license-Apache--2.0-blue"></a>
  <img alt="Platform: macOS 26, Apple silicon" src="https://img.shields.io/badge/platform-macOS%2026%20%C2%B7%20Apple%20silicon-lightgrey">
  <img alt="Status: early" src="https://img.shields.io/badge/status-early-orange">
</p>

<p align="center">
  <img src="screenshots/01-control-center.png" alt="Tandem Control Center with Windows, macOS and Linux virtual machines" width="760">
</p>

Tandem runs Windows 11 (ARM), Linux and macOS in virtual machines on your Mac. **Create New** downloads Microsoft's, Apple's and the
distributions' own images and installs them unattended: you pick a system, give it a name and an account, and Tandem does the
rest. It brings a shared clipboard, shared folders, drag and drop, snapshots, instant clones and a command line with an MCP server.

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

Prefer to build it yourself? See [Build from source](#build-from-source) and [Packaged app](#packaged-app-self-contained-signed).

## Screenshots

<table>
  <tr>
    <td align="center" width="33%"><a href="screenshots/03-create-new.png"><img src="screenshots/03-create-new.png" alt="Create New"></a><br><sub><b>New VM:</b> install from an image, import, or download a free system</sub></td>
    <td align="center" width="33%"><a href="screenshots/04-download-windows-11.png"><img src="screenshots/04-download-windows-11.png" alt="Windows 11 download list"></a><br><sub><b>Windows 11</b> from Microsoft: every edition and language for ARM</sub></td>
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
    <td align="center"><a href="screenshots/18-settings-general.png"><img src="screenshots/18-settings-general.png" alt="Settings"></a><br><sub><b>Settings:</b> including automatic updates</sub></td>
    <td align="center"><a href="screenshots/21-running-ubuntu-mate.png"><img src="screenshots/21-running-ubuntu-mate.png" alt="Ubuntu MATE running in Tandem"></a><br><sub><b>A running</b> Ubuntu MATE VM, signed in automatically</sub></td>
  </tr>
</table>

All pictures, with captions and how they were made, are in [`screenshots/`](screenshots/).

## What it does

- **Install a system without hunting for ISOs.** Create New offers free systems to download and install unattended:
  Windows 11 ARM (Microsoft's own media), macOS (Apple's restore images), Ubuntu (MATE, Xfce or GNOME desktop, or Server),
  Debian, Fedora and Kali. You answer one page (name, account); Tandem does the rest.
- **Two engines.** macOS guests run on Apple's Virtualization framework. Windows runs on QEMU with Apple's Hypervisor
  framework; Linux can use either (QEMU for a TPM, USB redirection or 3D).
- **Guest tools**: shared clipboard, shared Mac folders, drag and drop, resolution that follows the window, clean
  shutdown, time sync, and **Seamless mode** (Windows programs in Mac windows, launchable from Finder and the Dock).
  Not every feature exists on every guest; see [Status](#status).
- **Snapshots, instant clones, suspend and resume.**
- **Sharing profiles and restrictions** for VMs you do not fully trust.
- **USB**: drives and serial adapters can be given to a VM. Full USB pass-through of arbitrary devices needs an Apple
  entitlement that this project does not have yet (see [Status](#status)).
- **3D acceleration (experimental)** for Linux and Windows guests, built from UTM's open-source graphics stack.
- **Automation**: a `tandem` command-line tool and an MCP server, so scripts and AI tools can start, snapshot and run commands
  in VMs, with switches and per-VM permissions that you control.
- **Import** existing Parallels Desktop VMs that you own.
- **Self-contained app** with its own QEMU, signed updates, uninstaller and crash-report prompts that send nothing without your say.

## Status

| Area | State |
|---|---|
| Linux, Windows 11 ARM, macOS guests: install, run, snapshots, clone | Working |
| Guest tools: Windows and Linux | Working; macOS guest tools are new and lightly tested |
| Seamless mode (Windows) | Working; some drag-out cases unfinished |
| 3D acceleration | Experimental; Windows 3D cannot resize while running |
| USB pass-through | Drives and serial devices only; full pass-through needs Apple's `com.apple.vm.device-access` entitlement |
| Notarised releases | Yes, from 0.7.0 |
| Automatic updates | Built; needs an update feed and signing key, so releases are installed by hand for now |
| Linux Seamless mode, printers, camera, other importers | Not started (see `ROADMAP.md`) |

Requirements: Apple silicon Mac, **macOS 15 or later** (macOS 26 recommended; development happens on 26).

## Install

Download the `.dmg` from the [Releases page](https://github.com/Str1ck9/tandem-vm/releases/latest) and drag Tandem to Applications
(see [Download](#download) for the first-open steps), or build from source (below).

The first time you use bridged networking, USB drives or Windows shared folders, Tandem asks you to install its helper
(Settings > Network > Install…, then allow it under System Settings > General > Login Items) and to give **Tandem** Full
Disk Access for USB drives. The Welcome window walks you through it.

## Build from source

Requires Xcode (Swift 6), Rust, and for development builds `brew install qemu swtpm`.

## Layout

| Path | Content |
|---|---|
| `host/` | Swift package: `VMCore`, `EngineVZ`, `EngineQEMU`, `GuestLink`, `Provisioning`, `Sharing`, `Updater`, `vmctl`, `tandem`, `TandemApp` |
| `guest/` | Rust workspace: `link-proto` (codec, transports, client), `tandem-agent` |
| `protocol/` | `PROTOCOL.md`, the reference encoder and shared test vectors |
| `patches/` | Patches to QEMU (QEMU's licence applies to them) |
| `scripts/` | Build, signing, packaging, release scripts and the agent end-to-end test |
| `screenshots/` | Pictures of the app |

### Build and test

```sh
scripts/build.sh                 # host package + signed vmctl (prints its path)
scripts/build-app.sh             # build/Tandem.app, signed ad hoc for local use
(cd host && swift test)          # Swift tests (some need local sockets or disk images)
(cd guest && cargo test)         # Rust tests
scripts/build-agent.sh           # guest agent for Linux arm64 and, with llvm-mingw, Windows arm64
scripts/agent-test/run.sh        # boots a guest on both engines and checks the agent end to end
```

`scripts/agent-test/run.sh` needs an Alpine arm64 cloud image at `.cache/images/alpine-arm64.qcow2`
(for example `generic_alpine-3.24.1-aarch64-uefi-cloudinit-r0.qcow2` from alpinelinux.org).

Set `TANDEM_HOME` to keep test VMs out of the real library (`~/Library/Application Support/Tandem`).
Before running the app from a build of your own, read [Maintainers](#maintainers).

## Packaged app (self-contained, signed)

`scripts/build-app.sh` makes a development app that uses QEMU and the other tools where they are installed
(Tandem's own QEMU build in `~/Library/Application Support/Tandem/qemu`, then Homebrew).
`scripts/package-app.sh` makes one that carries everything it runs and is signed with your Developer ID:

```sh
scripts/package-app.sh           # build/package/Tandem.app (about 210 MB)
```

- Inside: a lean QEMU build (`QEMU_PROFILE=package scripts/build-qemu.sh`, no GTK/SDL/FUSE) in
  `Contents/Helpers/qemu`, its firmware in `Contents/Resources/qemu` (passed with `-L`), swtpm, zstd,
  wimlib and usbredirect in `Contents/Helpers/tools`, the helper, the `tandem` tool and the guest agents.
  Every library is copied in and rewired (`scripts/bundle-tool.sh`); nothing links to Homebrew afterwards.
  The VirtIO driver disc (837 MB) is not included; Tandem finds or downloads it as before.
- Signing (`scripts/sign-app.sh`): the first "Developer ID Application" identity in your keychain
  (`TANDEM_SIGN_IDENTITY` overrides; without one the app is signed ad hoc, which runs on your Mac but cannot register its helper
  with macOS's service manager, so use `sudo scripts/install-net-helper.sh` there), hardened runtime, entitlements in
  `scripts/entitlements/`.
- The helper: a packaged app installs it itself (Settings > Network > Install…) with macOS's service manager;
  approve it once in System Settings > General > Login Items. It runs from inside the app with `--from-bundle`,
  serves the user who owns the app, and only runs tools signed by the same developer team.
  `scripts/install-net-helper.sh` remains for development builds; remove its daemon first
  (`sudo scripts/install-net-helper.sh --uninstall`), because both serve the same socket.

### Maintainers: release

A release is built, signed, notarised and stapled on your own Mac with your own Apple Developer account. Set these first
(placeholders; use your own values):

```sh
export TANDEM_BUNDLE_PREFIX=com.example.tandem TANDEM_APP_ID=com.example.tandem   # your registered identifiers
export TANDEM_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"        # or leave unset: the first one in your keychain
export TANDEM_SIGN_TIMESTAMP=1                                                    # Apple's secure timestamp, needed to notarise
```

One-time: create an app-specific password at account.apple.com > Sign-In and Security, then store it in your keychain under the
profile name the scripts expect (`tandem-notary`, or set `TANDEM_NOTARY_PROFILE`). The command asks for the password, so it
never appears in your shell history:

```sh
xcrun notarytool store-credentials tandem-notary --apple-id <your Apple ID> --team-id <your team id>
```

Each release:

1. `scripts/package-app.sh`: builds and signs `build/package/Tandem.app` with the hardened runtime. It also removes the
   build machine's folder names from the bundled programs (`scripts/neutralize-paths.py`); add more folders with
   `TANDEM_NEUTRALIZE_PATHS=/path/one:/path/two`.
2. `scripts/notarize.sh`: submits the app to Apple, waits, staples the ticket and checks it with `spctl`.
3. `scripts/make-dmg.sh`: makes `build/package/Tandem-<version>.dmg` from the stapled app and signs it.
4. `xcrun notarytool submit <dmg> --keychain-profile tandem-notary --wait`, then `xcrun stapler staple <dmg>`.
5. Check: `spctl -a -vvv -t install <dmg>` must say `Notarized Developer ID`. Name the file `Tandem-<version>-arm64.dmg`,
   add `shasum -a 256` of it to the release, and upload it with `gh release create` or `gh release upload`.

If Apple answers 403 "a required agreement is missing or has expired", sign in at developer.apple.com/account and accept
the updated Program License Agreement. If notarisation says Invalid, `xcrun notarytool log <submission id> --keychain-profile tandem-notary`
lists the files at fault (usually a program without the hardened runtime or the secure timestamp).

## Importing existing virtual machines (Parallels Desktop)

Tandem can read a Parallels Desktop VM bundle (`.pvm`, `.macvm`) that you own and run it, without modifying the original. Tandem is not
associated with Parallels; the import reads the files of your own VMs.

```sh
vmctl inspect-parallels ~/Parallels/*.pvm ~/Parallels/*.macvm   # read-only report
vmctl import-parallels "~/Parallels/Kali Linux.pvm"             # no disk copy
vmctl start "Kali Linux"
```

The Parallels bundle is never written. A `.pvm` import is an overlay on the original disk, so the original must stay
where it is and must not be started in Parallels again; pass `--copy` for an independent VM. A `.macvm` import is an
APFS clone and is independent from the start.

Windows needs a repair pass to boot on QEMU, which `import-parallels` runs when given a Windows 11 ARM64 installer ISO:

```sh
vmctl import-parallels ~/Parallels/"Windows 11.pvm" \
  --windows-iso ~/ISOs/Windows11_Client_arm64.iso --virtio-iso .cache/images/virtio-win-0.1.302.iso
```

Windows 11 25H2 boots after that on stock QEMU. Windows 11 22H2 additionally needs this project's patched QEMU build,
because stock QEMU faults a firmware call its boot loader makes (`patches/`):

```sh
scripts/build-qemu.sh        # one time, about five minutes; installs to ~/Library/Application Support/Tandem/qemu
```

`vmctl` and the app use that build automatically when it exists (or the one named by `TANDEM_QEMU_PREFIX`).

## Using the app

`scripts/build-app.sh` builds `build/Tandem.app`. **Import from Parallels…** (toolbar, or File menu) brings in a `.pvm` or
`.macvm`; for Windows it asks once for a Windows 11 ARM64 installer ISO and the virtio-win driver ISO. A VM's screen opens
in its own window: Command is the Windows key, Option is Alt, Control-click is a right click.

To check the UI without operating it, the app can render its own windows to PNG files:

```sh
TANDEM_SNAPSHOT_DIR=/tmp/snap TANDEM_SNAPSHOT_START="Windows 11" build/Tandem.app/Contents/MacOS/Tandem
```

`vmctl start <vm> --embedded`, `vmctl screenshot <vm> out.png` and `vmctl input <vm> key:0x37 click:700,400 "type:hello"`
do the same from the command line.

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

Existing VMs keep what AI tools could do before, except the destructive operations: they read as **Operate**, so revert,
clone, power off and writable shares now need the Full level.

(off by default). `guest_exec` also needs the VM's own permission, Configure > Options > Sharing > Commands from the
Mac ("The command-line tool and AI tools"); by default only the command-line tool may run commands, and restricted VMs
allow none. The app decides all of this; the tool only says whether it is the command line or an AI tool. Both talk to
the app over `control.sock` in the library folder (owner-only).

## Translations

The app's text lives in one string catalog, `resources/Localizable.xcstrings`; English is the source language
and Spanish is there as the first proof (the main window, the New VM flow and the menus). The build compiles
the catalog into `<language>.lproj/Localizable.strings` inside the app and lists the languages in its
`Info.plist`.

To add a language:

1. `scripts/update-localizations.sh` brings the catalog up to date with the source (new strings arrive in English).
2. Open `resources/Localizable.xcstrings` in Xcode (or edit the JSON) and add the language: one value per string.
   Keep the placeholders (`%@`, `%lld`) as they are; `LocalizationCatalogTests` checks that.
3. `scripts/build-app.sh`, then try it without changing the Mac's language:
   `TANDEM_LANG=es build/Tandem.app/Contents/MacOS/Tandem`. With `TANDEM_LANG_SHOW_MISSING=1` every string
   that has no translation appears in capitals, which shows what is still missing.

Text written in code as a plain `String` (a status line made from several parts, for example) is not found
automatically: use `String(localized:)` or a `LocalizedStringKey`, then run the script again. Dates, numbers and
sizes use the Mac's formats (`formatted(date:time:)`, `ByteCountFormatter`).

## Accessibility

Controls that show only a picture carry an `.accessibilityLabel`, a VM row is one element for VoiceOver (name, system,
state, with its buttons inside), and every progress bar says its value. To check a window, run the app with
`TANDEM_SNAPSHOT_A11Y=1` and a snapshot folder (see `SelfTest.swift`): it walks each visible window's accessibility
tree and prints the controls VoiceOver would read without a name (rules in `VMCore/AccessibilityAudit.swift`).

## Maintainers

Things a fork or a release build has to set once:

- **Repository name.** `host/Sources/IdentityCore/TandemIdentity.swift` has `projectRepository` (`owner/repo`). Issue
  reports and the default update feed are derived from it. If you fork, set it, and the repository address in
  `.github/ISSUE_TEMPLATE/config.yml`, before publishing builds.
- **Bundle identifiers.** Every identifier (the app's, the helper's launchd label, the signing identifiers of the bundled tools, the
  guest agent, the document type) derives from two build settings, read by every script in `scripts/` through
  `scripts/identity.sh`:

  | Variable | Default | Names |
  |---|---|---|
  | `TANDEM_BUNDLE_PREFIX` | `local.tandem` | helper (`<prefix>.helper`), tools (`<prefix>.qemu-nbd`, …), agent, document type |
  | `TANDEM_APP_ID` | `<prefix>.app` | the app's own bundle identifier |

  The defaults are right for building and running Tandem yourself. For builds you ship under your own name, export both before
  running any script, for example `export TANDEM_BUNDLE_PREFIX=com.example.tandem TANDEM_APP_ID=com.example.tandem`, and register
  the identifier under your own Apple developer account. `scripts/build-app.sh` writes them into the app's `Info.plist`
  (`TandemBundlePrefix`, `TandemAppID`); the app, its helper and its command-line tool read them from there, so one build stays
  consistent. With `sudo`, pass them on explicitly: `sudo TANDEM_BUNDLE_PREFIX=… TANDEM_APP_ID=… scripts/install-net-helper.sh`.
- **Signing.** `TANDEM_SIGN_IDENTITY` names your Developer ID Application certificate; without one, builds are signed ad hoc.
- **Update key.** Updates are signed with an Ed25519 key you create: `tandem-release keygen` writes the private key
  (keep it out of git, and back it up: without it no installed copy accepts another update) and prints the public key, which goes in
  `resources/update-public-key.txt` (or `TANDEM_UPDATE_PUBLIC_KEY`). `scripts/release.sh` builds, signs and writes the feed.
  `TANDEM_UPDATE_FEED_URL` overrides the feed address compiled into a build.
- **USB entitlement.** Capturing arbitrary USB devices needs `com.apple.vm.device-access`, which Apple grants on request to a
  developer account for a registered App ID. Until a build has it, Tandem lends only drives and serial devices.

## Licence

Tandem is licensed under the [Apache License 2.0](LICENSE). It runs and downloads other open-source software that keeps its own
licences: see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The QEMU patches in `patches/` are under QEMU's licence.
Parallels is a trademark of its owner; Tandem is an independent project.
