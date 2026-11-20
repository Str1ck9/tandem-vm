# Development and release guide

[Back to the Tandem README](../README.md)

This guide covers source builds, repository layout, packaging, signing, notarisation and project identity.
For installing a published release and creating a VM, start with the README.

## Build from source

Requires an Apple silicon Mac running macOS 15 or later, Xcode with Swift 6, Rust, and Homebrew.
Install Xcode and Rust before running these commands:

```sh
git clone https://github.com/Str1ck9/tandem-vm.git
cd tandem-vm
brew install qemu swtpm
scripts/build.sh
scripts/build-app.sh
open build/Tandem.app
```

The app is signed ad hoc for local development. Read [Maintainers](#maintainers) before changing signing identities
or installing the privileged helper. The standalone `vmctl` executable is at `host/.build/debug/vmctl`; it is not
installed on your PATH by the build scripts. Guest agents are copied into the app only when they have been built;
see [Build and test](#build-and-test) for the agent script and its cross-compilation requirements. The app's installable `tandem` command is described in the
[command-line guide](../README.md#command-line-and-ai-tools-mcp).

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
Before running the app from a build of your own, read [Maintainers](#maintainers). All commands in this guide run from the repository root.


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
xcrun notarytool store-credentials tandem-notary --apple-id "you@example.com" --team-id "YOUR_TEAM_ID"
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


## UI snapshots for development

To check the UI without operating it, the app can render its own windows to PNG files:

```sh
TANDEM_SNAPSHOT_DIR=/tmp/snap TANDEM_SNAPSHOT_START="Windows 11" build/Tandem.app/Contents/MacOS/Tandem
```

`vmctl start <vm> --embedded`, `vmctl screenshot <vm> out.png` and `vmctl input <vm> key:0x37 click:700,400 "type:hello"`
do the same from the command line.


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

