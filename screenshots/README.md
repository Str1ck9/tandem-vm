# Tandem screenshots

Taken in Nov 2026 from Tandem 0.7.0 and 0.8.0 on macOS 26 (pictures 01 to 21 from 0.7.0, 22 to 24 from 0.8.0), light appearance unless noted. They
are made from a demo library with generic VM names and the account name `demo`, so no personal
details appear.

| File | What it shows |
|---|---|
| `01-control-center.png` | Control Center: the library with Windows, macOS and Linux VMs |
| `02-control-center-dark.png` | The same in dark appearance |
| `03-create-new.png` | Create New: install from an image, import from Parallels, or download a free system |
| `04-download-windows-11.png` | Get Windows 11 from Microsoft: every edition and language Microsoft offers for ARM |
| `05-download-macos.png` | Download macOS: the newest restore image Apple offers for this Mac |
| `06-download-linux.png` | Download a Linux system: Ubuntu Desktop (MATE, Xfce or GNOME) and Server, Debian, Fedora, Kali |
| `07-new-linux-vm.png` | Name and Location for Ubuntu Desktop: account, optional password, automatic sign-in, resources |
| `08-new-windows-vm.png` | Name and Location for Windows 11: unattended install with an account |
| `09-config-general.png` | VM configuration, General: name, colour, engine, space used, location, guest tools |
| `10-config-cpu-memory.png` | Hardware > CPU & Memory |
| `11-config-graphics.png` | Hardware > Graphics: resolution and experimental 3D acceleration for Windows |
| `12-config-network.png` | Hardware > Network: shared or bridged network, port forwarding, published services |
| `13-config-sharing.png` | Options > Sharing: Mac folders, clipboard, restrictions |
| `14-snapshot-manager.png` | Snapshot Manager with a chain of snapshots |
| `15-clone.png` | Clone: instant APFS copy with a new hardware and guest identity |
| `16-welcome.png` | Welcome window: one-time checks for tools, helper and Full Disk Access |
| `17-about.png` | About Tandem |
| `18-settings-general.png` | Settings > General, including automatic updates |
| `19-settings-network.png` | Settings > Network: helper status, Full Disk Access, restart |
| `20-settings-advanced.png` | Settings > Advanced: command-line tool, AI tools (MCP), templates, crash reports |
| `21-running-ubuntu-mate.png` | A running Ubuntu Desktop VM with the MATE desktop, signed in automatically |
| `22-ai-level.png` | Configuration > Options > Sharing: the AI tools level for a VM (here Full, with its warning); cropped to the last two groups |
| `23-snapshot-baseline.png` | Snapshot Manager with a baseline snapshot, the only one an AI tool may revert to |
| `24-ai-switch.png` | Settings > Advanced: the master switch for AI tools (MCP) and the AI activity log |

## How they were made

The app renders its own windows to PNG files when `TANDEM_SNAPSHOT_DIR` is set (see
`host/Sources/TandemApp/SelfTest.swift`), so no screen recording is needed. The run used:

1. A copy of the packaged app with its own bundle ID (for example `local.tandem.screenshots`,
   re-signed ad hoc), so it never touches the installed Tandem's settings.
2. A separate library: `TANDEM_HOME="/Users/Shared/Tandem Demo"`, with VMs made by
   `vmctl create "<name>" --os windows11arm|linux|macos` (they never need to boot) and snapshots taken
   with `tandem snapshot take`. The running VM came from a Linux template (`vmctl create … --download
   linux:ubuntu-desktop-mate-24.04 --user demo --password ""`).
3. One launch per picture, for example:

```sh
export TANDEM_HOME="/Users/Shared/Tandem Demo"
TANDEM_SNAPSHOT_DIR=/tmp/shots TANDEM_SNAPSHOT_ASSISTANT_DOWNLOAD=linux TANDEM_SNAPSHOT_OPEN=assistant \
  TANDEM_SNAPSHOT_OPEN_WAIT=25 TANDEM_SNAPSHOT_ASSISTANT_HEIGHT=880 \
  Tandem.app/Contents/MacOS/Tandem -NSRequiresAquaSystemAppearance YES
```

Useful switches: `TANDEM_SNAPSHOT_OPEN` (`assistant`, `snapshots`, `clone`, `resources`, `about`,
`welcome`, `preferences`) with `TANDEM_SNAPSHOT_SELECT=<VM>`; `TANDEM_SNAPSHOT_SETTINGS="<VM>=general;hardware/cpu;options/sharing"`;
`TANDEM_SNAPSHOT_PREFS_TAB=general|devices|network|advanced`; `TANDEM_SNAPSHOT_ASSISTANT_DOWNLOAD=windows|macos|linux`
with `TANDEM_SNAPSHOT_ASSISTANT_PAGE=name` and `TANDEM_SNAPSHOT_ACCOUNT=demo`; `TANDEM_SNAPSHOT_START=<VM>` with
`TANDEM_SNAPSHOT_WAIT=<seconds>`. Pass `-AppleInterfaceStyle Dark` for dark appearance.
