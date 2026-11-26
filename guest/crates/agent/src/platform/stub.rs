use super::{DisplayError, GuestInfo};
pub const OS_ID: u32 = link_proto::os::MACOS;
pub fn guest_info() -> GuestInfo { GuestInfo { ip_addresses: super::primary_ip().into_iter().collect(), ..Default::default() } }
pub fn set_time(_secs: i64, _nanos: u32) -> Result<(), String> { Err("not supported".into()) }
pub fn clipboard_available() -> bool { false }
pub fn clipboard_get() -> Option<String> { None }
pub fn clipboard_set(_text: &str) -> Result<(), String> { Err("not supported".into()) }
pub fn display_resize_available() -> bool { false }
pub fn current_resolution() -> Option<(u32, u32)> { None }
pub fn set_resolution(_w: u32, _h: u32) -> Result<(), DisplayError> { Err(DisplayError::Unsupported) }
pub fn shutdown(_restart: bool) -> Result<(), String> { Err("not supported".into()) }
pub fn shared_folders_available() -> bool { false }
pub fn apply_shares(_shares: &crate::shares::Shares) -> Result<String, String> { Err("not supported".into()) }

/// Nothing to tidy up on this platform.
pub fn startup() {}

// MARK: Guest windows (not offered on this system)

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

// MARK: Guest programs and icons (not offered on this system)

pub fn programs_available() -> bool { false }
pub fn list_programs() -> Vec<super::GuestProgram> { Vec::new() }
pub fn launch_program(_id: &str) -> Result<(), String> { Err("not supported".into()) }
pub fn window_icon(_id: u64, _size: u32) -> Option<Vec<u8>> { None }
pub fn program_icon(_id: &str, _size: u32) -> Option<Vec<u8>> { None }

// MARK: Opening shared documents (not offered on this system)

pub fn documents_available() -> bool { false }
pub fn program_info(_id: &str) -> super::ProgramInfo { super::ProgramInfo::default() }
pub fn open_documents(_program: &str, _documents: &[String]) -> Result<(), (u32, String)> {
    Err((link_proto::document_status::NOT_SUPPORTED, "this guest cannot open Mac documents".into()))
}
pub fn run_requests() {}

// MARK: Activity (development builds: enough for the keep-awake command to run)

pub fn activity_available() -> bool { false }
pub fn input_idle_seconds() -> Option<u64> { None }
pub fn cpu_times() -> Option<(u64, u64)> { None }
pub fn power_requests() -> Vec<String> { Vec::new() }
pub fn keep_awake_dir() -> std::path::PathBuf { std::env::temp_dir().join("tandem-keep-awake") }
pub fn open_to_everyone(_dir: &std::path::Path) {}
pub fn pid_alive(pid: u32) -> bool { unsafe { libc::kill(pid as i32, 0) == 0 } }

// MARK: Files dropped from the Mac (Windows only for now)

pub fn file_drop_available() -> bool { false }
pub fn drop_target_folder(_x: i32, _y: i32) -> Option<std::path::PathBuf> { None }
pub fn fallback_drop_folder() -> Option<std::path::PathBuf> { None }
pub fn selected_files_at(_x: i32, _y: i32) -> Result<Vec<String>, String> { Err("Dragging files out works with Windows guests.".into()) }
pub fn agent_data_dir() -> std::path::PathBuf { std::env::temp_dir().join("tandem-agent") }
pub fn message_box(title: &str, text: &str) { eprintln!("{title}: {text}"); }
pub fn install_send_to() {}
pub fn folder_changed(_folder: &std::path::Path) {}
/// Only Linux guests switch the file-system identity of the copying thread to the signed-in user.
pub fn act_as_session_user() {}
