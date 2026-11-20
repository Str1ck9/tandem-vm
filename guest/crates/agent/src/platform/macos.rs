//! The agent inside a macOS guest (Apple's Virtualization framework, so the VZ engine).
//!
//! It runs as root from a LaunchDaemon (`/Library/LaunchDaemons/<prefix>.agent.plist`), so it can
//! set the clock and shut the system down. What belongs to the signed-in user's session (the
//! clipboard, asking programs to quit before a shutdown) it does through `launchctl asuser`.
//!
//! Apple's framework already does the rest: the display follows the window (macOS 14 and later), and
//! shared folders appear by themselves as "My Shared Files".
use super::macos_text;
use super::{DisplayError, GuestInfo};
use std::io::Write;
use std::os::unix::fs::MetadataExt;
use std::process::{Command, Stdio};

pub const OS_ID: u32 = link_proto::os::MACOS;

fn output_of(tool: &str, args: &[&str]) -> Option<String> {
    let output = Command::new(tool).args(args).stdin(Stdio::null()).stderr(Stdio::null()).output().ok()?;
    if !output.status.success() { return None; }
    Some(String::from_utf8_lossy(&output.stdout).into_owned())
}

fn is_root() -> bool { unsafe { libc::geteuid() == 0 } }

fn kernel_release() -> String {
    let mut name: libc::utsname = unsafe { std::mem::zeroed() };
    if unsafe { libc::uname(&mut name) } != 0 { return String::new(); }
    let bytes: Vec<u8> = name.release.iter().take_while(|&&c| c != 0).map(|&c| c as u8).collect();
    String::from_utf8_lossy(&bytes).into_owned()
}

pub fn guest_info() -> GuestInfo {
    let hostname = output_of("/usr/sbin/scutil", &["--get", "ComputerName"]).map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .or_else(|| output_of("/bin/hostname", &[]).map(|s| s.trim().to_string()))
        .unwrap_or_default();
    GuestInfo {
        hostname,
        os_name: "macOS".into(),
        os_version: output_of("/usr/bin/sw_vers", &["-productVersion"]).map(|s| s.trim().to_string()).unwrap_or_default(),
        kernel: kernel_release(),
        ip_addresses: super::primary_ip().into_iter().collect(),
        utc_offset_secs: None,
    }
}

pub fn set_time(secs: i64, nanos: u32) -> Result<(), String> {
    let tv = libc::timeval { tv_sec: secs as _, tv_usec: (nanos / 1000) as _ };
    if unsafe { libc::settimeofday(&tv, std::ptr::null()) } == 0 { Ok(()) }
    else { Err(std::io::Error::last_os_error().to_string()) }
}

/// The user signed in at the screen; None at the login window.
fn console_uid() -> Option<u32> {
    std::fs::metadata("/dev/console").ok().map(|m| m.uid()).filter(|&uid| uid != 0)
}

// MARK: Clipboard
//
// Text only, as with the other guests, through `pbpaste` and `pbcopy` in the user's session.

/// `pbcopy` and `pbpaste` take the text encoding from the locale; the agent's environment has none.
const UTF8: &str = "LANG=en_US.UTF-8";

fn pasteboard_command(tool: &str) -> Option<Command> {
    let args = [UTF8, tool];
    let parts: Vec<String> = if is_root() {
        macos_text::as_console_user(console_uid()?, "/usr/bin/env", &args)
    } else {
        // Started by hand inside the session (a test): the tools work directly.
        std::iter::once("/usr/bin/env".to_string()).chain(args.iter().map(|a| a.to_string())).collect()
    };
    let mut command = Command::new(&parts[0]);
    command.args(&parts[1..]).stderr(Stdio::null());
    Some(command)
}

pub fn clipboard_available() -> bool { !is_root() || console_uid().is_some() }

pub fn clipboard_get() -> Option<String> {
    let output = pasteboard_command("/usr/bin/pbpaste")?.stdin(Stdio::null()).output().ok()?;
    if !output.status.success() { return None; }
    String::from_utf8(output.stdout).ok()
}

pub fn clipboard_set(text: &str) -> Result<(), String> {
    let mut command = pasteboard_command("/usr/bin/pbcopy").ok_or("nobody is signed in")?;
    let mut child = command.stdin(Stdio::piped()).stdout(Stdio::null()).spawn().map_err(|e| e.to_string())?;
    child.stdin.take().ok_or("no input")?.write_all(text.as_bytes()).map_err(|e| e.to_string())?;
    let status = child.wait().map_err(|e| e.to_string())?;
    if status.success() { Ok(()) } else { Err(format!("pbcopy exited with {status}")) }
}

// MARK: Display (Apple's framework resizes the guest's display with the window)

pub fn display_resize_available() -> bool { false }
pub fn current_resolution() -> Option<(u32, u32)> { None }
pub fn set_resolution(_w: u32, _h: u32) -> Result<(), DisplayError> { Err(DisplayError::Unsupported) }

// MARK: Shut down and restart

pub fn shutdown(restart: bool) -> Result<(), String> {
    let mut last = String::from("no command to run");
    for parts in macos_text::shutdown_commands(console_uid(), restart) {
        match Command::new(&parts[0]).args(&parts[1..]).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).status() {
            Ok(status) if status.success() => return Ok(()),
            Ok(status) => last = format!("{} exited with {status}", parts[0]),
            Err(e) => last = format!("{}: {e}", parts[0]),
        }
    }
    Err(last)
}

// MARK: Shared folders (mounted by macOS itself: the "My Shared Files" volume)

pub fn shared_folders_available() -> bool { false }
pub fn apply_shares(_shares: &crate::shares::Shares) -> Result<String, String> { Err("not supported".into()) }

pub fn startup() {}

// MARK: Guest windows, programs and documents (not offered for macOS guests)

pub fn windows_available() -> bool { false }
pub fn list_windows() -> super::WindowList { super::WindowList::default() }
pub fn window_action(_id: u64, _action: u32) -> Result<(), String> { Err("not supported".into()) }
pub fn window_events_start() {}
pub fn window_change_count() -> u64 { 0 }
pub fn wait_window_change(_seen: u64, timeout: std::time::Duration) { std::thread::sleep(timeout) }
pub fn display_scale() -> Option<u32> { None }
pub fn rescale_windows(_factor: f64) {}
/// Processor time this process has used, in milliseconds.
pub fn process_cpu_ms() -> u64 {
    let mut usage: libc::rusage = unsafe { std::mem::zeroed() };
    if unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut usage) } != 0 { return 0; }
    let ms = |t: libc::timeval| t.tv_sec as u64 * 1000 + t.tv_usec as u64 / 1000;
    ms(usage.ru_utime) + ms(usage.ru_stime)
}
pub fn set_display_scale(_percent: u32) -> Result<(), String> { Err("not supported".into()) }
pub fn set_work_area(_area: Option<(i32, i32, i32, i32)>) -> Result<(), String> { Err("not supported".into()) }
pub fn keep_work_area() {}

pub fn programs_available() -> bool { false }
pub fn list_programs() -> Vec<super::GuestProgram> { Vec::new() }
pub fn launch_program(_id: &str) -> Result<(), String> { Err("not supported".into()) }
pub fn window_icon(_id: u64, _size: u32) -> Option<Vec<u8>> { None }
pub fn program_icon(_id: &str, _size: u32) -> Option<Vec<u8>> { None }

pub fn documents_available() -> bool { false }
pub fn program_info(_id: &str) -> super::ProgramInfo { super::ProgramInfo::default() }
pub fn open_documents(_program: &str, _documents: &[String]) -> Result<(), (u32, String)> {
    Err((link_proto::document_status::NOT_SUPPORTED, "this guest cannot open Mac documents".into()))
}
pub fn run_requests() {}

// MARK: Activity
//
// Input idle time from the HID system, processor load from the kernel, and the programs that hold a
// stay-awake assertion (`caffeinate`, a backup, a video player).

pub fn activity_available() -> bool { true }

pub fn input_idle_seconds() -> Option<u64> {
    macos_text::hid_idle_seconds(&output_of("/usr/sbin/ioreg", &["-c", "IOHIDSystem", "-d", "4"])?)
}

pub fn cpu_times() -> Option<(u64, u64)> {
    let mut info: libc::host_cpu_load_info = unsafe { std::mem::zeroed() };
    let mut count = libc::HOST_CPU_LOAD_INFO_COUNT;
    #[allow(deprecated)]
    let host = unsafe { libc::mach_host_self() };
    let rc = unsafe { libc::host_statistics(host, libc::HOST_CPU_LOAD_INFO, &mut info as *mut _ as *mut libc::integer_t, &mut count) };
    if rc != 0 { return None; }
    Some(macos_text::cpu_ticks(info.cpu_ticks))
}

pub fn power_requests() -> Vec<String> {
    output_of("/usr/bin/pmset", &["-g", "assertions"]).map(|t| macos_text::awake_assertions(&t)).unwrap_or_default()
}

/// One folder for every user of the guest; emptied at each start.
pub fn keep_awake_dir() -> std::path::PathBuf { std::path::PathBuf::from("/var/run/tandem-keep-awake") }

pub fn open_to_everyone(dir: &std::path::Path) {
    use std::os::unix::fs::PermissionsExt;
    let _ = std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o1777));
}

pub fn pid_alive(pid: u32) -> bool {
    if unsafe { libc::kill(pid as i32, 0) } == 0 { return true; }
    std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

// MARK: Files dropped from the Mac (Windows only for now)

pub fn file_drop_available() -> bool { false }
pub fn drop_target_folder(_x: i32, _y: i32) -> Option<std::path::PathBuf> { None }
pub fn fallback_drop_folder() -> Option<std::path::PathBuf> { None }
pub fn selected_files_at(_x: i32, _y: i32) -> Result<Vec<String>, String> { Err("Dragging files out works with Windows guests.".into()) }
pub fn agent_data_dir() -> std::path::PathBuf { std::path::PathBuf::from("/Library/Application Support/Tandem Agent") }
pub fn message_box(title: &str, text: &str) { eprintln!("{title}: {text}"); }
pub fn install_send_to() {}
pub fn folder_changed(_folder: &std::path::Path) {}
