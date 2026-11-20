//! Guest side of the GuestLink protocol. The specification is `protocol/PROTOCOL.md`.
pub mod client;
pub mod frame;
pub mod transport;

pub const PROTOCOL_VERSION: u32 = 1;
pub const VSOCK_PORT: u32 = 7700;
pub const SERIAL_PORT_NAME: &str = "guestlink.0";
pub const MAX_CLIPBOARD_BYTES: usize = 1 << 20;

pub mod status {
    pub const OK: u32 = 0;
    pub const PENDING: u32 = 0xFFFF_FFFF;
    pub const UNKNOWN_OPCODE: u32 = 0xE000_0001;
    pub const BAD_REQUEST: u32 = 0xE000_0002;
    pub const NOT_SUPPORTED: u32 = 0xE000_0003;
    pub const INTERNAL: u32 = 0xE000_0004;
    pub const CANCELLED: u32 = 0xE000_0005;
    pub const BUSY: u32 = 0xE000_0006;
    pub const VERSION_MISMATCH: u32 = 0xE000_0007;
}

pub mod op {
    pub const HELLO: u16 = 0x0001;
    pub const WAIT_EVENT: u16 = 0x0002;
    pub const GUEST_INFO: u16 = 0x0003;
    pub const LOG: u16 = 0x0004;
    pub const ECHO: u16 = 0x0005;
    pub const GET_HOST_TIME: u16 = 0x0100;
    pub const CLIPBOARD_SET_HOST: u16 = 0x0200;
    pub const CLIPBOARD_GET_HOST: u16 = 0x0201;
    pub const DISPLAY_REPORT: u16 = 0x0300;
    pub const SHARE_LIST: u16 = 0x0400;
    pub const AGENT_UPDATE_INFO: u16 = 0x0500;
    pub const AGENT_UPDATE_READ: u16 = 0x0501;
    pub const WINDOW_REPORT: u16 = 0x0600;
    pub const ICON: u16 = 0x0601;
    pub const PROGRAM_LIST: u16 = 0x0602;
    /// The outcome of a `DOCUMENT_OPEN`: inline `u32 request`, `u32 status` (see `document_status`);
    /// buffer 0 (IN): a message for the user when the status is not `OK`.
    pub const DOCUMENT_RESULT: u16 = 0x0603;
    /// Answer to `PROGRAM_INFO_REQUEST`: buffer 0 (IN) JSON `{"id":…,"target":…,"extensions":[…]}`.
    pub const PROGRAM_INFO: u16 = 0x0604;
    /// How much the guest is in use, sent every 20 s by agents with the `ACTIVITY` capability:
    /// buffer 0 (IN) JSON `{"idleSeconds":…,"cpuPercent":…,"keepAwake":["…"]}`; the first two are
    /// left out where the guest cannot tell. A host that does not know the operation is not asked again.
    pub const ACTIVITY_REPORT: u16 = 0x0605;
    /// While a `DROP_FILES` is copied: buffer 0 (IN) JSON `{"id":…,"bytes":…,"total":…}`.
    pub const DROP_PROGRESS: u16 = 0x0650;
    /// When it is done: buffer 0 (IN) JSON `{"id":…,"status":"copied"|"fallback"|"failed","folder":…,"files":…[,"message":…]}`.
    pub const DROP_RESULT: u16 = 0x0651;
    /// The outcome of an `EXEC_REQUEST`: inline `u32 request`, `i32 exit code`, `u32 status` (see
    /// `exec_status`), `u32 flags` (`exec_flags`); buffers 0 stdout, 1 stderr, 2 a message (all IN).
    pub const EXEC_RESULT: u16 = 0x0670;
    /// The answer to `DRAG_OUT_QUERY`: buffer 0 (IN) JSON `{"x":…,"y":…,"paths":[…][,"message":…]}`.
    pub const DRAG_OUT_ITEMS: u16 = 0x0680;
}

pub mod exec_status {
    pub const COMPLETED: u32 = 0;
    pub const TIMED_OUT: u32 = 1;
    pub const FAILED_TO_START: u32 = 2;
    pub const NOT_SUPPORTED: u32 = 3;
}

pub mod exec_flags {
    /// In `EXEC_REQUEST` arg1: Windows, run with the agent's administrator rights.
    pub const ELEVATED: u32 = 1;
    /// In `EXEC_RESULT` flags.
    pub const STDOUT_TRUNCATED: u32 = 1;
    pub const STDERR_TRUNCATED: u32 = 2;
}

pub mod event {
    pub const CLIPBOARD_CHANGED: u32 = 1;
    pub const DISPLAY_RESIZE: u32 = 2;
    pub const TIME_RESYNC: u32 = 3;
    pub const SHUTDOWN_REQUEST: u32 = 4;
    pub const NONE: u32 = 5;
    pub const SHARES_CHANGED: u32 = 6;
    /// arg0: 1 start reporting the guest's windows, 0 stop.
    pub const WINDOW_WATCH: u32 = 7;
    /// arg0: action (see `window_action`); data: the window id, u64 little-endian.
    pub const WINDOW_ACTION: u32 = 8;
    /// arg0: icon kind, arg1: wanted size in pixels (the icon is square); data: the key.
    /// Answered with an `ICON` request.
    pub const ICON_REQUEST: u32 = 9;
    /// Answered with a `PROGRAM_LIST` request.
    pub const PROGRAMS_REQUEST: u32 = 10;
    /// data: a program id from the last `PROGRAM_LIST` (UTF-8). Ids the agent did not list are refused.
    pub const PROGRAM_LAUNCH: u32 = 11;
    /// arg0: a request number, echoed in `DOCUMENT_RESULT`. data (UTF-8 lines): a program id from the
    /// last `PROGRAM_LIST` (an empty line: each document's default program), then one document per
    /// line as `<share name>/<path below the share>`.
    pub const DOCUMENT_OPEN: u32 = 12;
    /// data: a program id (UTF-8). Answered with a `PROGRAM_INFO` request.
    pub const PROGRAM_INFO_REQUEST: u32 = 13;
    /// Files dropped on a guest window. arg0, arg1: the guest pixel; data: the drop's description
    /// (`tandem-drop 1` text, PROTOCOL.md "file drop"). Answered with `DROP_PROGRESS` and `DROP_RESULT`.
    pub const DROP_FILES: u32 = 32;
    /// arg0: the display scale in percent (100, 125, 150, 175, 200, …), or 0 to put back the scale the
    /// guest had before the first change. Sent with Seamless Mode at Retina resolution.
    pub const DISPLAY_SCALE: u32 = 36;
    /// Run a command: arg0 a request number (echoed in `EXEC_RESULT`), arg1 flags (`exec_flags`),
    /// data JSON `{"command":…,"user":…,"timeout":seconds,"maxOutput":bytes}`.
    pub const EXEC_REQUEST: u32 = 40;
    /// Seamless Mode over several Mac displays: data is four i32 (x, y, width, height, little-endian)
    /// of the work area for maximised windows, in guest pixels; empty data puts back the guest's own.
    pub const WORK_AREA: u32 = 44;
    /// A drag that began at guest pixel (arg0, arg1) left the guest's windows on the Mac: answer with the
    /// files selected in the File Explorer window there (`DRAG_OUT_ITEMS`).
    pub const DRAG_OUT_QUERY: u32 = 45;
    /// Upload files for a drop on the Mac: data is text, the upload id on the first line, then one path
    /// per line; they go into the inbox share as "Send to > Mac" does, under that id.
    pub const DRAG_OUT_FETCH: u32 = 46;
}

pub mod document_status {
    pub const OK: u32 = 0;
    /// The guest cannot reach the document (the share is not there, or the file is not).
    pub const UNREACHABLE: u32 = 1;
    /// The program could not be started with the document.
    pub const FAILED: u32 = 2;
    /// The program is not one the agent listed.
    pub const UNKNOWN_PROGRAM: u32 = 3;
    pub const NOT_SUPPORTED: u32 = 4;
}

pub mod icon_kind {
    /// The key is a window id (`u64` little-endian); the icon is that of the window's program.
    pub const WINDOW: u32 = 1;
    /// The key is a program id from `PROGRAM_LIST` (UTF-8).
    pub const PROGRAM: u32 = 2;
}

pub mod os {
    pub const LINUX: u32 = 1;
    pub const WINDOWS: u32 = 2;
    pub const MACOS: u32 = 3;
}

pub mod window_action {
    pub const ACTIVATE: u32 = 1;
    pub const CLOSE: u32 = 2;
    pub const MINIMIZE: u32 = 3;
    pub const RESTORE: u32 = 4;
}

pub mod capability {
    pub const TIME: u32 = 1 << 0;
    pub const CLIPBOARD: u32 = 1 << 1;
    pub const DISPLAY_RESIZE: u32 = 1 << 2;
    pub const SHARED_FOLDERS: u32 = 1 << 3;
    pub const SELF_UPDATE: u32 = 1 << 4;
    /// `SHUTDOWN_REQUEST` with arg0 = 1 restarts the guest instead of powering it off.
    pub const RESTART: u32 = 1 << 5;
    /// The agent can list the guest's windows and act on them (`WINDOW_REPORT`).
    pub const WINDOWS: u32 = 1 << 6;
    /// The agent can list the guest's installed programs, start one, and hand out icons.
    pub const PROGRAMS: u32 = 1 << 7;
    /// The agent can open shared Mac documents in a chosen program (`DOCUMENT_OPEN`) and say which
    /// file types a program opens (`PROGRAM_INFO_REQUEST`).
    pub const DOCUMENTS: u32 = 1 << 8;
    /// The agent reports how much the guest is in use and who asked for it to stay awake (`ACTIVITY_REPORT`).
    pub const ACTIVITY: u32 = 1 << 12;
    /// The agent takes files dropped from the Mac (`DROP_FILES`) and offers "Send to > Mac".
    pub const FILE_DROP: u32 = 1 << 14;
    /// Window reports follow window events (and name the window being dragged), and the agent sets the
    /// guest's display scale on request (`DISPLAY_SCALE`).
    pub const SEAMLESS_EVENTS: u32 = 1 << 15;
    /// The agent runs commands for the host (`EXEC_REQUEST`).
    pub const EXEC: u32 = 1 << 16;
    /// The agent sets the work area on request (`WORK_AREA`) and reports resizes with their edge.
    pub const SEAMLESS_DISPLAYS: u32 = 1 << 17;
}

#[cfg(test)]
mod fuzz_tests;
