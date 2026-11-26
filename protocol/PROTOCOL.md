# GuestLink protocol, version 1

The RPC channel between the host app and the guest agent. This file is the single source of truth; the Swift (`host/Sources/GuestLink`) and Rust (`guest/crates/link-proto`) codecs are both tested against `vectors.json`, which `gen_vectors.py` produces from an independent Python implementation.

The design: one request format, many transports, requests multiplexed by ID, one opcode range per service. Every number here is our own.

## 1. Transports

| Engine | Transport | Guest endpoint | Host endpoint |
|---|---|---|---|
| VZ | virtio-vsock stream | connect to CID 2, port **7700** | `VZVirtioSocketListener` on port 7700 |
| QEMU | virtio-serial port named **`guestlink.0`** | Linux: the `/dev/vportNpM` whose sysfs `name` matches. Windows: `\\.\Global\guestlink.0` | unix socket chardev |

The guest always opens the channel. The host never initiates.

A virtio-serial port has no connection boundary that the host can see, so the protocol does not rely on one: every frame starts with a magic number, and a `HELLO` request resets the session.

## 2. Frame

All integers are little-endian. A frame is:

```
offset size  field
0      4     magic        0x4B4E4C42  (bytes "BLNK")
4      4     totalSize    size of the whole frame in bytes, header included
8      8     requestId    chosen by the guest; a reply carries the request's id
16     2     kind         1 = request, 2 = reply
18     2     opcode
20     4     status       request: 0xFFFFFFFF (pending). reply: see §4
24     4     inlineLen    bytes of inline data
28     2     bufferCount
30     2     reserved     0
32     …     inline       inlineLen bytes, then zero padding to a multiple of 8
…      8×N   descriptors  per buffer: u32 length, u32 flags
…      …     payloads     concatenated, no padding, in descriptor order
…      4     crc32        CRC-32 (IEEE 802.3, as in zlib) of every preceding byte of the frame
```

Limits: `totalSize` ≤ 16 MiB (16 777 216), `bufferCount` ≤ 16. A receiver rejects anything larger.

**Buffers.** `flags` bit 0 = IN (guest to host), bit 1 = OUT (host to guest).

| In a… | A payload is present for buffers with… | `length` means |
|---|---|---|
| request | IN set | payload size if IN is set; otherwise the capacity the guest offers |
| reply | OUT set | bytes returned |

A reply has the same `bufferCount` and flags as its request.

**Resynchronisation.** A receiver discards one byte and searches forward for the next magic when any of these is true at the expected frame start:

- the first four bytes are not the magic;
- `totalSize`, `kind` or `bufferCount` is out of range, or the sizes are inconsistent;
- the CRC does not match;
- it holds an incomplete frame and no byte has arrived for **1 second** (the stall rule).

The CRC and the stall rule exist for one case found in testing: an agent that dies part-way through a frame and restarts on the same virtio-serial port. Without them the receiver would wait for the rest of the dead frame and consume the new session's frames as its payload.

## 3. Sessions and events

1. The guest connects and sends `CORE_HELLO`, and repeats it every 3 seconds until it is answered. On `HELLO` the host drops all state from any earlier session on that stream.
2. The guest keeps one `CORE_WAIT_EVENT` request outstanding. The host replies to it when it has something to tell the guest, and the guest immediately sends another. This is how host-to-guest messages travel.
3. Requests are multiplexed. Replies may arrive in any order and are matched by `requestId`.
4. If the stream fails, the guest reconnects, fails all in-flight requests locally with `CANCELLED`, and sends `HELLO` again.

## 4. Status codes

| Value | Name | Meaning |
|---|---|---|
| `0x00000000` | `OK` | |
| `0xFFFFFFFF` | `PENDING` | Only in requests |
| `0xE0000001` | `UNKNOWN_OPCODE` | No service owns this opcode |
| `0xE0000002` | `BAD_REQUEST` | Malformed inline data or buffers |
| `0xE0000003` | `NOT_SUPPORTED` | Understood but unavailable on this host or guest |
| `0xE0000004` | `INTERNAL` | Handler failed |
| `0xE0000005` | `CANCELLED` | Session reset or transport failure |
| `0xE0000006` | `BUSY` | Retry later |
| `0xE0000007` | `VERSION_MISMATCH` | `HELLO` with an unsupported protocol version |
| `0xE001xxxx` | `ERRNO` | Low 16 bits are a Linux errno value (file services, phase 6) |

## 5. Opcode ranges

One range per service; a service registers its range with the dispatcher.

| Range | Service | Phase |
|---|---|---|
| `0x0000–0x00FF` | core | 4 |
| `0x0100–0x01FF` | time | 4 |
| `0x0200–0x02FF` | clipboard | 4 |
| `0x0300–0x03FF` | display | 4 |
| `0x0400–0x04FF` | file sharing | 6 |
| `0x0500–0x05FF` | agent update | 4 |
| `0x0600–0x06FF` | shell integration (guest windows, programs, icons; file drop at `0x0650–0x065F`; guest commands at `0x0670–0x067F`; drag out at `0x0680–0x068F`) | 6, 7, 14, 16, 17 |
| `0x0700–0xFFFF` | unassigned | |

## 6. Operations

Strings are UTF-8 without a terminator.

### core

| Opcode | Name | Request | Reply |
|---|---|---|---|
| `0x0001` | `HELLO` | inline: `u32 protocolVersion` (=1), `u32 os` (1 Linux, 2 Windows, 3 macOS), `u32 capabilities`. Buffer 0 (IN): agent version string | inline: `u32 protocolVersion`, `u32 hostCapabilities`. `VERSION_MISMATCH` if unsupported |
| `0x0002` | `WAIT_EVENT` | Buffer 0 (OUT): capacity for event data | inline: `u32 event`, `u32 arg0`, `u32 arg1`. Buffer 0: event data |
| `0x0003` | `GUEST_INFO` | Buffer 0 (IN): JSON object `{hostname, osName, osVersion, kernel, ipAddresses[]}` | empty |
| `0x0004` | `LOG` | inline: `u32 level` (0 debug, 1 info, 2 warn, 3 error). Buffer 0 (IN): message | empty |
| `0x0005` | `ECHO` | Buffer 0 (IN), buffer 1 (OUT) | Buffer 1: copy of buffer 0 |

`capabilities` bits (guest): 0 time, 1 clipboard, 2 display resize, 3 shared folders, 4 self-update, 5 restart, 6 window list, 7 programs and icons, 8 opening shared documents in a program, 12 activity reports, 14 file drop, 15 window reports on window events with the window being dragged, and display scale, 16 running commands, 17 Seamless Mode over several displays (work area, resize edge) and dragging files out (9 to 11 and 13 are spoken for by other work).

### Events (the `event` field of a `WAIT_EVENT` reply)

| Value | Name | arg0, arg1 | Data |
|---|---|---|---|
| 1 | `CLIPBOARD_CHANGED` | — | new host clipboard text |
| 2 | `DISPLAY_RESIZE` | width, height in pixels | — |
| 3 | `TIME_RESYNC` | — | — |
| 4 | `SHUTDOWN_REQUEST` | arg0: 0 power off, 1 restart (only sent to agents with capability bit 5) | — |
| 6 | `SHARES_CHANGED` | — | — (the guest calls `SHARE_LIST` again) |
| 7 | `WINDOW_WATCH` | arg0: 1 start reporting windows, 0 stop | — |
| 8 | `WINDOW_ACTION` | arg0: 1 activate, 2 close, 3 minimize, 4 restore | `u64` window id |
| 9 | `ICON_REQUEST` | arg0: icon kind (1 window, 2 program), arg1: wanted size in pixels (16–256, square) | the key: `u64` window id, or a program id (UTF-8) |
| 10 | `PROGRAMS_REQUEST` | — | — (the guest answers with `PROGRAM_LIST`) |
| 11 | `PROGRAM_LAUNCH` | — | a program id from the last `PROGRAM_LIST` (UTF-8) |
| 12 | `DOCUMENT_OPEN` | arg0: a request number, echoed in `DOCUMENT_RESULT` | UTF-8 lines: a program id (an empty line for the default program), then one document per line as `<share>/<path>` |
| 13 | `PROGRAM_INFO_REQUEST` | — | a program id (UTF-8); the guest answers with `PROGRAM_INFO` |
| 32 | `DROP_FILES` | arg0, arg1: the guest pixel the files were dropped on | the drop's description (text, see "file drop") |
| 36 | `DISPLAY_SCALE` | arg0: scale in percent (100, 125, 150, 175, 200, …), or 0 to put back the scale from before the first change | — |
| 40 | `EXEC_REQUEST` | arg0: a request number, echoed in `EXEC_RESULT`; arg1: flags (bit 0: Windows, run elevated) | JSON `{"command":…,"user":…,"timeout":seconds,"maxOutput":bytes}` (only to agents with capability bit 16) |
| 44 | `WORK_AREA` | — | four `i32` (x, y, width, height) of the work area for maximised windows in guest pixels, or empty to put back the guest's own (only to agents with capability bit 17) |
| 45 | `DRAG_OUT_QUERY` | arg0, arg1: the guest pixel a drag began at | — (the guest answers with `DRAG_OUT_ITEMS`) |
| 46 | `DRAG_OUT_FETCH` | — | text: an upload id (`dragout-…`) on the first line, then one Windows path per line |
| 5 | `NONE` | — | — (sent to release a waiter, for example at host shutdown) |

### time

| Opcode | Name | Request | Reply |
|---|---|---|---|
| `0x0100` | `GET_HOST_TIME` | none | inline: `i64 unixSeconds`, `u32 nanoseconds`, `i32 utcOffsetSeconds` |

A Windows guest sets its **local** time to the host's local time (`unixSeconds + utcOffsetSeconds`), because its hardware clock is in local time and the user expects the clock on screen to match the host even when the guest's time zone differs. Other guests set UTC.

### clipboard

| Opcode | Name | Request | Reply |
|---|---|---|---|
| `0x0200` | `SET_HOST` | Buffer 0 (IN): text. The guest clipboard changed | empty |
| `0x0201` | `GET_HOST` | Buffer 0 (OUT): capacity | Buffer 0: host clipboard text |

Text over 1 MiB is not transferred; the sender gets `BAD_REQUEST`.

### display

| Opcode | Name | Request | Reply |
|---|---|---|---|
| `0x0300` | `REPORT` | inline: `u32 width`, `u32 height`, `u32 result` (0 applied, 1 unsupported mode, 2 failed). Sent after a `DISPLAY_RESIZE` event and at start-up | empty |

### file sharing

| Opcode | Name | Request | Reply |
|---|---|---|---|
| `0x0400` | `SHARE_LIST` | Buffer 0 (OUT): capacity | Buffer 0: JSON `{"kind":"webdav","port":N,"shares":["name",…]}` |

`kind` says how the folders reach the guest; a reply without it means `webdav`.

- `webdav` (Windows guests on QEMU): the host serves the folders over WebDAV on its loopback interface at `port` (0 when nothing is shared), one top-level folder per share. The guest reaches it at `10.0.2.2:port` (QEMU's shared network only); the server refuses requests whose `Host` is anything else. Windows opens it through the built-in WebClient service as `\\10.0.2.2@port\DavWWWRoot`; the agent maps it to a drive letter (Z: when free) named "Mac", for the user's normal and elevated sides, and leaves a link on the public desktop. The port is derived from the VM's ID, so it normally stays the same across runs.
- `9p` (Linux guests on QEMU): one virtio-9p device per share, mount tags `tandem0`, `tandem1`, … in the order of `shares`. The agent, running as root, mounts each at `/media/mac/<name>`. Files keep the Mac user's numeric owner, so a guest user with a different user ID can read them but needs root to change files it did not create.
- `virtiofs` (VZ guests): one virtiofs device holding every share as a sub-folder. A Linux agent mounts tag `tandem` at `/media/mac`. A macOS guest needs no agent: the device carries Apple's automount tag and appears in the Finder.

### agent update

| Opcode | Name | Request | Reply |
|---|---|---|---|
| `0x0500` | `AGENT_UPDATE_INFO` | — | inline: `u32 size`, `u64 fnv1a64` of the host's agent build for this guest's OS. `NOT_SUPPORTED` when the host has none |
| `0x0501` | `AGENT_UPDATE_READ` | inline: `u32 offset`. Buffer 0 (OUT): capacity | Buffer 0: the bytes from `offset`, at most the capacity |

After `HELLO` the agent compares the size and checksum with the file it was started from. When they differ it downloads the host's build, checks it, swaps it in (on Windows the running file is renamed aside first) and restarts into it. A process started by an update does not update again, so a mismatch that cannot be cured does not loop. The checksum guards against damage, not tampering: the channel itself is the trust boundary.

### guest windows

| Opcode | Name | Request | Reply |
|---|---|---|---|
| `0x0600` | `WINDOW_REPORT` | Buffer 0 (IN): JSON `{"desktop":[w,h],"windows":[…]}` | — |
| `0x0601` | `ICON` | inline: `u32 kind`, `u32 width`, `u32 height`. Buffer 0 (IN): the key from the request. Buffer 1 (IN): `width × height` pixels, 32-bit BGRA, top row first, colour premultiplied by opacity | — |
| `0x0602` | `PROGRAM_LIST` | Buffer 0 (IN): JSON `{"programs":[{"name":…,"id":…}]}`, sorted by name | — |
| `0x0603` | `DOCUMENT_RESULT` | inline: `u32 request` (from `DOCUMENT_OPEN`), `u32 status` (0 ok, 1 the guest cannot reach the document, 2 the program could not be started, 3 the program is not in the list, 4 not supported). Buffer 0 (IN): a message for the user when the status is not 0 | — |
| `0x0604` | `PROGRAM_INFO` | Buffer 0 (IN): JSON `{"id":…,"target":…,"extensions":[".txt",…]}`. Buffer 1 (IN): the program's icon as a picture file's bytes (PNG), or empty | — |

`WINDOW_REPORT` is sent by the agent only between `WINDOW_WATCH` 1 and 0, and only when the list changed. Windows are listed front-most first. Each has `id` (opaque `u64`), `x`, `y`, `width`, `height` in physical pixels of the guest screen (the frame as drawn), `pid`, `kind` (`app`: a window to work in, that is program windows and dialogs; `popup`: menus, tool tips and other helpers; `taskbar`), `state` (`normal`, `minimized`, `maximized`), `active`, `title`, `class`, `app` (program file name). The desktop background is not listed.

Agents with capability bit 15 take the list when Windows reports a window event (shown, hidden, moved, reordered, activated, renamed), at most once per 8 ms, and every 500 ms otherwise; older agents every 40 ms. While the user moves or resizes a window the report also has `"moving":{"id","x","y","width","height","pointerX","pointerY"}`: the window's frame and the pointer when the move began, so the host can move its window with the pointer between reports. Agents with capability bit 17 add `"edge"` for a resize (`left`, `right`, `top`, `bottom`, `topLeft`, `topRight`, `bottomLeft`, `bottomRight`, from the window's own hit test at the pointer when the resize began); without it the report is a move. When the host stops watching, the agent logs how many lists it took and the processor time used.

`DISPLAY_SCALE` sets the scale of the guest's main display the way the Settings app does: at once, without signing out. Open windows are scaled by the same factor so they keep their apparent size and place. The scale from before the first change is kept in `%ProgramData%\Tandem\display-scale-before.txt` (flushed to disk), and put back by `DISPLAY_SCALE` 0 or, if the VM stopped in between, when the agent next connects.

Agents with capability bit 7 answer `ICON_REQUEST` with `ICON` and `PROGRAMS_REQUEST` with `PROGRAM_LIST`. An icon that cannot be found is answered with width and height 0 and no pixels, so the host can go on to its next request; the host asks for one icon at a time, because queued events of one kind replace each other. For a window the icon is that of its program. The program list is what the guest's Start menu offers; `id` is opaque to the host. `PROGRAM_LAUNCH` starts a listed program as the signed-in user, without the agent's elevation; an id the agent did not list is refused, so the host cannot name arbitrary commands.

Agents with capability bit 8 open shared documents in a program of the user's choosing. `DOCUMENT_OPEN` names a program from the list (or none, for each document's default program) and the documents as `<share name>/<path below the share>`, with `/` between path components; the agent turns that into a path below its own mount of the shares, refuses anything that would leave them (`..`, drive letters), waits up to 25 s for each document to be reachable, starts the program with the documents as the signed-in user without the agent's elevation, and answers with `DOCUMENT_RESULT`. The host sends one `DOCUMENT_OPEN` at a time and waits for its result. `PROGRAM_INFO_REQUEST` asks where a listed program's file is (`target`, empty for a store app) and which file name extensions it opens; the answer is `PROGRAM_INFO`. Both take seconds in the guest and do not hold up other events.

### activity

| Opcode | Name | Request | Reply |
|---|---|---|---|
| `0x0605` | `ACTIVITY_REPORT` | Buffer 0 (IN): JSON `{"idleSeconds":…,"cpuPercent":…,"keepAwake":["…"]}` | — |

Agents with capability bit 12 send this every 20 s, and within 2 s when the list of keep-awake requests changes. `idleSeconds` is the time since the guest's user last pressed a key or moved the pointer (input sent from the host counts); `cpuPercent` is processor use over all cores since the previous report, 0 to 100; both are left out where the guest cannot tell. `keepAwake` names who wants the VM to stay awake, in words for the user: requests made with `tandem-agent keep-awake` inside the guest (`keep-awake -- <command>` for as long as the command runs, `keep-awake --on [reason]` until `--off`), and programs that asked the guest's own system to stay awake (Windows power requests; blocking sleep or idle inhibitors under systemd). The host uses the report for its opt-in idle timer and never suspends a VM whose last report names a keep-awake request. A host that answers `UNKNOWN_OPCODE` is not sent further reports in that session.

### file drop

| Opcode | Name | Request | Reply |
|---|---|---|---|
| `0x0650` | `DROP_PROGRESS` | Buffer 0 (IN): JSON `{"id":…,"bytes":…,"total":…}` | — |
| `0x0651` | `DROP_RESULT` | Buffer 0 (IN): JSON `{"id":…,"status":"copied"\|"fallback"\|"failed","folder":…,"files":…[,"message":…]}` | — |

Files dropped on a guest window from the Mac (agents with capability bit 14). The host copies the dropped items into a folder it serves from its share server (the WebDAV server of "file sharing", reached at `10.0.2.2:<port>`) under the hidden name `TandemDrop`: not announced in `SHARE_LIST`, not listed at the server's root, read-only. It then sends `DROP_FILES` with the guest pixel and this description:

```
tandem-drop 1
<id>\t<port>\t<share>
d\t<path>            a folder
f\t<size>\t<path>    a file
```

Paths are below the share, start with `<id>/`, use `/` between components and are percent-encoded (they go into the URL as they are). Folders come before their contents. The agent refuses a description with `..`, `\`, `:` or another drop's id in a path. It chooses the destination from the window under the pixel: the folder an Explorer window shows, or the desktop; anything else (or a virtual place such as This PC) gives the user's Downloads folder and the status `fallback`. A top-level name already taken there gets a number (`name (2).ext`); the contents of a renamed folder follow it. Each file is fetched with a plain HTTP `GET /<share>/<path>` into a temporary name, checked against the announced size and renamed; `DROP_PROGRESS` is sent at most every 0.4 s, and `DROP_RESULT` once at the end. The host deletes its copy when the result arrives, and its whole staging folder when the VM starts or stops; it gives up after 60 s without word from the guest. One drop per VM at a time.

The other way, the agent puts "Mac (Tandem)" in Explorer's Send to menu, which runs `tandem-agent send-to-mac <paths…>`. That process reads the share server's port from the file the running agent keeps (`%ProgramData%\Tandem\host-port`), creates `TandemInbox/<id>/` (`MKCOL`), uploads each item (`PUT`, folders with `MKCOL`), and finally writes `TandemInbox/<id>.done` with the top-level names, one per line. The host serves `TandemInbox` (hidden, writable) only while the VM may send files to the Mac, watches it, and moves each finished upload into the Mac's Downloads folder, numbering names that are taken. A refusal (`403`/`404`) is shown in a message box in the guest.

Both directions follow the VM's clipboard setting (`SharingPolicy.allowsFilesToGuest` / `allowsFilesToMac`): no shared folder is needed, and the restricted preset turns both off; revoking a direction removes its hidden share at once.
### guest commands

| Opcode | Name | Request | Reply |
|---|---|---|---|
| `0x0670` | `EXEC_RESULT` | inline: `u32 request`, `i32 exit code`, `u32 status` (0 completed, 1 timed out, 2 failed to start, 3 not supported), `u32 flags` (bit 0 stdout cut short, bit 1 stderr cut short). Buffers (IN): 0 stdout, 1 stderr, 2 a message when the status is not 0 | — |

Agents with capability bit 16 run the `command` of an `EXEC_REQUEST` on a thread of their own and answer with `EXEC_RESULT`. Linux: `/bin/sh -c` as root (the agent's service), or `su -s /bin/sh -c <command> <user>` with `user`. Windows: `cmd /c` as the signed-in user without administrator rights (a one-off limited scheduled task whose output goes to files in the user's temporary folder), or, with flag bit 0, directly from the agent with its rights. `timeout` (1–3600 s, default 60) ends the command; `maxOutput` (1 KiB–4 MiB, default 1 MiB) caps each of stdout and stderr, which are raw bytes in the guest's own encoding. Events of one kind replace each other while queued, so the host sends one request at a time per VM. Whether a command may be sent at all is decided on the host: the VM's sharing profile names who may run commands (`commands`: `off`, `macUser` — the default, the Mac's user through `tandem` — or `macUserAndAI`, adding AI tools through `tandem mcp`).

### Seamless Mode over several displays

The guest has one monitor; in Seamless Mode the host lays it over the bounding rectangle of all Mac displays, at the sharpest display's pixels per point when that fits the display device (5120 x 2880), else 1, else less. Gaps between displays of different sizes are part of the guest's desktop but on no Mac screen. With more than one display the host sends `WORK_AREA` with the main display's part, so maximised windows fill that display rather than the whole arrangement, and an empty `WORK_AREA` when the mode ends. Agents with capability bit 17 set it with `SPI_SETWORKAREA` and keep the original to put back.

### drag out

| Opcode | Name | Request | Reply |
|---|---|---|---|
| `0x0680` | `DRAG_OUT_ITEMS` | buffer 0 (IN): JSON `{"x":…,"y":…,"paths":[…][,"message":…]}` | — |

In Seamless Mode a drag that began in a File Explorer window and leaves every guest window on the Mac is taken over by the host: it cancels the guest's drag (Escape, then the button up) and sends `DRAG_OUT_QUERY` with the guest pixel where the drag began. The agent (capability bit 17) answers `DRAG_OUT_ITEMS` with the full paths of the items selected in that Explorer window, or no paths and a `message` (another kind of window, nothing selected). The host carries on the drag with file promises; when one is dropped it sends `DRAG_OUT_FETCH`, and the agent uploads those paths into the inbox share exactly as "Send to > Mac" does, under the given id, finishing with `<id>.done` (empty when the upload failed). The host keeps `dragout-` uploads out of the Downloads delivery and moves each to where it was dropped. Allowed in the same direction as files sent to the Mac (the clipboard setting).

### Linux guests

The Linux agent (a systemd service running as root) fills the same operations from the signed-in user's X11 desktop. It speaks the X11 protocol itself, so no tools need to be installed in the guest; `xclip` serves the clipboard and file drag-out. Wayland sessions are not served (only their XWayland windows would show).

- **Capabilities.** It sets bits 6 (windows), 7 (programs and icons), 8 (opening shared documents), 14 (file drop) and 17 (drag out, work area), plus the common ones. It does **not** set bit 15: it has no display scale to change (`DISPLAY_SCALE` is ignored), so the host never asks for Retina pixels.
- **Windows.** `id` is the X window id. The list comes from the window manager's `_NET_CLIENT_LIST_STACKING`, with the frame rectangle (`_NET_FRAME_EXTENTS` added to the client's geometry). `kind` is `app` for normal windows and dialogs, `popup` for menus and tool tips, `taskbar` for docks and the desktop window; `state` follows `_NET_WM_STATE` (hidden is `minimized`). `class` is the `WM_CLASS` class, `app` the process name from `/proc/<pid>/comm`. Reports follow property and configure events of the root and of each client window. `WINDOW_ACTION` is sent as the EWMH requests `_NET_ACTIVE_WINDOW` (activate, restore), `_NET_CLOSE_WINDOW` and `WM_CHANGE_STATE` (minimize). A window's icon is its `_NET_WM_ICON`, else the theme icon named like its class.
- **Programs.** The list is the desktop's `.desktop` files (user, system, Snap and Flatpak folders), without `NoDisplay`/`Hidden` entries, entries for other desktops and entries that need a terminal; the id is the desktop file ID. They are started with `gio launch` as the signed-in user, in that user's session environment. `PROGRAM_INFO`'s `target` is the first word of `Exec`, and `extensions` come from the entry's MIME types through `/usr/share/mime/globs2`. A program icon is the PNG of the entry's `Icon` from the icon themes.
- **Documents.** `<share>/<path>` is the file under `/media/mac/<share>/<path>`; the program is started with `gio launch <desktop file> <paths>` (an empty program id uses `gio open`).
- **File drop.** The copy runs as the signed-in user (the thread's file-system identity is switched). The destination is the folder a file manager window shows at the pointer (read from the window title), the desktop folder when the pointer is over the desktop, else the Downloads folder. "Send to Mac (Tandem)" is added to the Scripts menus of Nautilus and Caja and to the Nemo, Thunar and PCManFM menus.
- **Drag out.** `DRAG_OUT_QUERY` is answered for file manager windows: the agent activates the window, sends Ctrl+C through the XTEST extension, reads the copied file list from the clipboard and puts the earlier text back. The clipboard is not forwarded to the host while this runs.
- **Display size.** `DISPLAY_RESIZE` to a size the display driver does not list makes a CVT reduced-blanking mode with `xrandr --newmode` and uses it.

## 7. Versioning

`protocolVersion` changes only for incompatible changes to the frame or to an existing operation. New operations and events are added without a version change: an old peer answers `UNKNOWN_OPCODE` and ignores events it does not know.
