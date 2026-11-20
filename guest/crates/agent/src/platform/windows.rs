//! Run in a Windows 11 ARM64 guest on 2026-11-14: handshake, guest info, clock and clipboard work.
//! Display resize has not been exercised.
//!
//! The clipboard and display calls need the interactive user session, so the agent must be started
//! at logon inside that session, not as a session-0 service.
use super::{DisplayError, GuestInfo};
use std::process::Command;
use windows_sys::Win32::Foundation::{GlobalFree, HANDLE, SYSTEMTIME};
use windows_sys::Win32::Graphics::Gdi::{
    ChangeDisplaySettingsExW, EnumDisplaySettingsW, CDS_TEST, CDS_UPDATEREGISTRY, DEVMODEW, DISP_CHANGE_BADMODE,
    DISP_CHANGE_SUCCESSFUL, DM_PELSHEIGHT, DM_PELSWIDTH, ENUM_CURRENT_SETTINGS,
};
use windows_sys::Win32::System::DataExchange::{CloseClipboard, EmptyClipboard, GetClipboardData, OpenClipboard, SetClipboardData};
use windows_sys::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE};
use windows_sys::Win32::System::SystemInformation::{GetLocalTime, SetLocalTime};

pub const OS_ID: u32 = link_proto::os::WINDOWS;
const CF_UNICODETEXT: u32 = 13;

pub fn guest_info() -> GuestInfo {
    let version = Command::new("cmd").args(["/c", "ver"]).output().ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string()).unwrap_or_default();
    GuestInfo {
        hostname: std::env::var("COMPUTERNAME").unwrap_or_default(),
        os_name: "Windows".into(),
        os_version: version,
        kernel: String::new(),
        ip_addresses: super::primary_ip().into_iter().collect(),
        utc_offset_secs: Some(utc_offset_secs()),
    }
}

/// The guest's wall-clock time as if it were UTC: milliseconds since 1970 of the local date and time.
pub fn local_now_ms() -> i64 {
    let mut st: SYSTEMTIME = unsafe { std::mem::zeroed() };
    unsafe { GetLocalTime(&mut st) };
    crate::timeconv::unix_from_civil(st.wYear as i32, st.wMonth as u32, st.wDay as u32, st.wHour as u32, st.wMinute as u32, st.wSecond as u32) * 1000
        + st.wMilliseconds as i64
}

/// The guest's time zone as seconds east of UTC: local wall-clock time minus UTC, to the quarter hour.
pub fn utc_offset_secs() -> i32 {
    let utc_ms = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0);
    let quarter_hours = ((local_now_ms() - utc_ms) as f64 / 900_000.0).round() as i32;
    quarter_hours * 900
}

/// Sets the guest's wall clock. `secs` is the wanted local date and time expressed as if it were UTC.
/// Windows converts it with the guest's own time zone, so the clock on screen matches the host's
/// whatever zone the guest is set to. Needs the SeSystemtimePrivilege (administrators have it).
pub fn set_local_time(secs: i64, nanos: u32) -> Result<(), String> {
    let c = crate::timeconv::civil_from_unix(secs);
    let st = SYSTEMTIME {
        wYear: c.year as u16, wMonth: c.month as u16, wDayOfWeek: c.weekday as u16, wDay: c.day as u16,
        wHour: c.hour as u16, wMinute: c.minute as u16, wSecond: c.second as u16, wMilliseconds: (nanos / 1_000_000) as u16,
    };
    if unsafe { SetLocalTime(&st) } != 0 { Ok(()) } else { Err(std::io::Error::last_os_error().to_string()) }
}

pub fn clipboard_available() -> bool { true }

struct ClipboardGuard;
impl ClipboardGuard {
    fn open() -> Option<ClipboardGuard> {
        // Another process may hold the clipboard briefly; retry a few times.
        for _ in 0..10 {
            if unsafe { OpenClipboard(std::ptr::null_mut()) } != 0 { return Some(ClipboardGuard); }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        None
    }
}
impl Drop for ClipboardGuard {
    fn drop(&mut self) { unsafe { CloseClipboard(); } }
}

pub fn clipboard_get() -> Option<String> {
    let _guard = ClipboardGuard::open()?;
    unsafe {
        let handle: HANDLE = GetClipboardData(CF_UNICODETEXT);
        if handle.is_null() { return None; }
        let ptr = GlobalLock(handle) as *const u16;
        if ptr.is_null() { return None; }
        let mut len = 0usize;
        while *ptr.add(len) != 0 { len += 1; }
        let text = String::from_utf16_lossy(std::slice::from_raw_parts(ptr, len));
        GlobalUnlock(handle);
        Some(text)
    }
}

pub fn clipboard_set(text: &str) -> Result<(), String> {
    let wide: Vec<u16> = text.encode_utf16().chain(std::iter::once(0)).collect();
    let _guard = ClipboardGuard::open().ok_or("clipboard is busy")?;
    unsafe {
        let handle = GlobalAlloc(GMEM_MOVEABLE, wide.len() * 2);
        if handle.is_null() { return Err("out of memory".into()); }
        let ptr = GlobalLock(handle) as *mut u16;
        if ptr.is_null() { GlobalFree(handle); return Err("GlobalLock failed".into()); }
        std::ptr::copy_nonoverlapping(wide.as_ptr(), ptr, wide.len());
        GlobalUnlock(handle);
        EmptyClipboard();
        // On success the system owns the memory; on failure we still do.
        if SetClipboardData(CF_UNICODETEXT, handle).is_null() {
            GlobalFree(handle);
            return Err(std::io::Error::last_os_error().to_string());
        }
    }
    Ok(())
}

pub fn display_resize_available() -> bool { true }

fn current_mode() -> Option<DEVMODEW> {
    let mut mode: DEVMODEW = unsafe { std::mem::zeroed() };
    mode.dmSize = std::mem::size_of::<DEVMODEW>() as u16;
    if unsafe { EnumDisplaySettingsW(std::ptr::null(), ENUM_CURRENT_SETTINGS, &mut mode) } != 0 { Some(mode) } else { None }
}

pub fn current_resolution() -> Option<(u32, u32)> {
    current_mode().map(|m| (m.dmPelsWidth, m.dmPelsHeight))
}

fn change_mode(width: u32, height: u32, flags: u32) -> i32 {
    let Some(mut mode) = current_mode() else { return DISP_CHANGE_BADMODE };
    mode.dmPelsWidth = width;
    mode.dmPelsHeight = height;
    mode.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT;
    unsafe { ChangeDisplaySettingsExW(std::ptr::null(), &mode, std::ptr::null_mut(), flags, std::ptr::null()) }
}

fn listed_modes() -> Vec<(u32, u32)> {
    let mut modes = Vec::new();
    let mut mode: DEVMODEW = unsafe { std::mem::zeroed() };
    mode.dmSize = std::mem::size_of::<DEVMODEW>() as u16;
    let mut index = 0;
    while unsafe { EnumDisplaySettingsW(std::ptr::null(), index, &mut mode) } != 0 && index < 4096 {
        modes.push((mode.dmPelsWidth, mode.dmPelsHeight));
        index += 1;
    }
    modes
}

/// Sets the display to `width`x`height`. A driver that refuses that size gets the best size it accepts
/// that fits inside it (the host's window shows the picture scaled to fit), so the result is reported
/// with the size actually set.
pub fn set_resolution(width: u32, height: u32) -> Result<(), DisplayError> {
    current_mode().ok_or(DisplayError::Unsupported)?;
    match change_mode(width, height, CDS_UPDATEREGISTRY) {
        DISP_CHANGE_SUCCESSFUL => return Ok(()),
        DISP_CHANGE_BADMODE => {}
        other => return Err(DisplayError::Failed(format!("ChangeDisplaySettingsEx returned {other}"))),
    }
    for (w, h) in super::fallback_modes(width, height, &listed_modes()) {
        if change_mode(w, h, CDS_TEST) == DISP_CHANGE_SUCCESSFUL && change_mode(w, h, CDS_UPDATEREGISTRY) == DISP_CHANGE_SUCCESSFUL {
            return Ok(());
        }
    }
    Err(DisplayError::Unsupported)
}

pub fn shutdown(restart: bool) -> Result<(), String> {
    Command::new("shutdown").args([if restart { "/r" } else { "/s" }, "/t", "0"]).status().map_err(|e| e.to_string())
        .and_then(|s| if s.success() { Ok(()) } else { Err(format!("shutdown exited with {s}")) })
}

// MARK: Shared folders
//
// The host serves the shared Mac folders over WebDAV at 10.0.2.2:<port>. Windows opens that with its
// built-in WebClient service as \\10.0.2.2@<port>\DavWWWRoot, so no driver is needed. The agent only
// has to raise WebClient's file size limit and leave a folder link where the user will find it.

const CREATE_NO_WINDOW: u32 = 0x0800_0000;
const WEBCLIENT_PARAMETERS: &str = r"HKLM\SYSTEM\CurrentControlSet\Services\WebClient\Parameters";
const SHARE_LINK_NAME: &str = "Mac Shared Folders";

pub fn shared_folders_available() -> bool { true }

/// Before it was renamed, this agent was installed as "Berth". A copy left behind competes for the one
/// channel to the host (only one program can hold it), so it is stopped and removed.
pub fn startup() {
    const OLD_TASK: &str = "Berth Guest Agent";
    if run_quiet("schtasks", &["/query", "/tn", OLD_TASK]).is_none() { return; }
    let _ = run_quiet("schtasks", &["/end", "/tn", OLD_TASK]);
    let _ = run_quiet("schtasks", &["/delete", "/tn", OLD_TASK, "/f"]);
    let _ = run_quiet("taskkill", &["/f", "/im", "berth-agent.exe"]);
    let folder = std::path::PathBuf::from(std::env::var("ProgramFiles").unwrap_or_else(|_| r"C:\Program Files".into())).join("Berth");
    let _ = std::fs::remove_dir_all(folder);
    crate::log_local("removed the agent installed under its old name (Berth)");
}

fn run_quiet(program: &str, args: &[&str]) -> Option<String> {
    use std::os::windows::process::CommandExt;
    let output = Command::new(program).args(args).creation_flags(CREATE_NO_WINDOW).output().ok()?;
    output.status.success().then(|| String::from_utf8_lossy(&output.stdout).into_owned())
}

fn share_link() -> std::path::PathBuf {
    std::path::PathBuf::from(std::env::var("PUBLIC").unwrap_or_else(|_| r"C:\Users\Public".into())).join("Desktop").join(SHARE_LINK_NAME)
}

/// WebClient refuses files over 50 MB unless told otherwise. 4 GiB - 1 is the most it accepts.
fn raise_file_size_limit() -> bool {
    let current = run_quiet("reg", &["query", WEBCLIENT_PARAMETERS, "/v", "FileSizeLimitInBytes"]).unwrap_or_default();
    if current.to_lowercase().contains("0xffffffff") { return false; }
    run_quiet("reg", &["add", WEBCLIENT_PARAMETERS, "/v", "FileSizeLimitInBytes", "/t", "REG_DWORD", "/d", "0xffffffff", "/f"]).is_some()
}

/// Runs a command line as the signed-in user without elevation. The agent itself is elevated, and
/// Windows keeps separate drive mappings for a user's elevated and normal sides; Explorer is on the
/// normal side. A one-off scheduled task is the supported way to reach it.
fn run_unelevated(command_line: &str) {
    const TASK: &str = "Tandem Drive Mapping";
    let user = std::env::var("USERNAME").unwrap_or_default();
    if user.is_empty() { return; }
    if run_quiet("schtasks", &["/create", "/tn", TASK, "/tr", command_line, "/sc", "once", "/st", "00:00",
                               "/ru", &user, "/it", "/rl", "limited", "/f"]).is_none() { return; }
    let _ = run_quiet("schtasks", &["/run", "/tn", TASK]);
    std::thread::sleep(std::time::Duration::from_secs(3));
    let _ = run_quiet("schtasks", &["/delete", "/tn", TASK, "/f"]);
}

/// Drive letters this user has mapped to a Tandem share, with their targets, from `net use`.
fn mapped_drives() -> Vec<(String, String)> {
    let listing = run_quiet("net", &["use"]).unwrap_or_default();
    parse_net_use(&listing)
}

pub(crate) fn parse_net_use(listing: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    for line in listing.lines() {
        let words: Vec<&str> = line.split_whitespace().collect();
        for pair in words.windows(2) {
            let (letter, target) = (pair[0], pair[1]);
            let is_letter = letter.len() == 2 && letter.ends_with(':') && letter.as_bytes()[0].is_ascii_alphabetic();
            if is_letter && target.starts_with(r"\\10.0.2.2@") { out.push((letter.to_uppercase(), target.to_string())); }
        }
    }
    out
}

fn unmap_drive(letter: &str) {
    let _ = run_quiet("net", &["use", letter, "/delete", "/y"]);
    run_unelevated(&format!("net use {letter} /delete /y"));
}

/// Gives the shared folders a drive letter (Z: when free, otherwise the next one down) named "Mac".
fn map_drive(port: u16, target: &str) -> Option<String> {
    for (letter, existing) in mapped_drives() {
        if existing.eq_ignore_ascii_case(target) { return Some(letter); }
        unmap_drive(&letter); // left from a run on another port
    }
    let letter = (b'M'..=b'Z').rev().map(|c| format!("{}:", c as char))
        .find(|l| !std::path::Path::new(&format!(r"{l}\")).exists())?;
    // The name Explorer shows for the drive.
    let label_key = format!(r"HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2\##10.0.2.2@{port}#DavWWWRoot");
    let _ = run_quiet("reg", &["add", &label_key, "/v", "_LabelFromReg", "/t", "REG_SZ", "/d", "Mac", "/f"]);
    let mapped = run_quiet("net", &["use", &letter, target, "/persistent:no"]).is_some();
    run_unelevated(&format!("net use {letter} {target} /persistent:no"));
    mapped.then_some(letter)
}

/// A bridged VM has two network adapters: its real one, and an isolated one whose only purpose is to
/// reach the Mac's shared folders at 10.0.2.2. The isolated one also announces a gateway and a name
/// server that lead nowhere, so when another adapter has a gateway it is given the lowest priority.
fn demote_host_only_adapter() {
    let script = "$a = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -like '10.0.2.*' } | Select-Object -First 1; \
if ($a) { $other = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.InterfaceIndex -ne $a.InterfaceIndex }; \
if ($other) { Set-NetIPInterface -InterfaceIndex $a.InterfaceIndex -AddressFamily IPv4 -InterfaceMetric 9000 } \
else { Set-NetIPInterface -InterfaceIndex $a.InterfaceIndex -AddressFamily IPv4 -AutomaticMetric Enabled } }";
    let _ = run_quiet("powershell", &["-NoProfile", "-NonInteractive", "-Command", script]);
}

pub fn apply_shares(shares: &crate::shares::Shares) -> Result<String, String> {
    let (port, names) = (shares.port, &shares.names);
    if shares.kind != "webdav" { return Err(format!("this host shares folders over {}, which Windows guests cannot open", shares.kind)); }
    let link = share_link();
    let existing = std::fs::symlink_metadata(&link).ok();
    // Only ever replace or remove a link this agent made; a real folder with that name is left alone.
    let is_our_link = existing.as_ref().map(|m| m.file_type().is_symlink()).unwrap_or(false);
    if port == 0 || names.is_empty() {
        if is_our_link { std::fs::remove_dir(&link).map_err(|e| e.to_string())?; }
        for (letter, _) in mapped_drives() { unmap_drive(&letter); }
        return Ok("no folders are shared".into());
    }
    if existing.is_some() && !is_our_link {
        return Err(format!("{} already exists and is not a link", link.display()));
    }
    if raise_file_size_limit() {
        // The limit is read when the service starts.
        let _ = run_quiet("net", &["stop", "WebClient"]);
    }
    demote_host_only_adapter();
    let _ = run_quiet("sc", &["config", "WebClient", "start=", "auto"]);
    let _ = run_quiet("net", &["start", "WebClient"]);
    let target = format!(r"\\10.0.2.2@{port}\DavWWWRoot");
    // WebClient remembers a failed lookup for a minute. Right after sign-in the service may still be
    // starting, so wait until the server answers before leaving a link for the user to click.
    for _ in 0..15 {
        if std::fs::read_dir(&target).is_ok() { break; }
        std::thread::sleep(std::time::Duration::from_secs(2));
    }
    let drive = map_drive(port, &target).map(|l| format!(", drive {l}")).unwrap_or_else(|| ", no drive letter".into());
    let link_is_current = is_our_link && std::fs::read_link(&link).map(|t| t.to_string_lossy() == target.as_str()).unwrap_or(false);
    if !link_is_current {
        if is_our_link { std::fs::remove_dir(&link).map_err(|e| e.to_string())?; }
        std::os::windows::fs::symlink_dir(&target, &link).map_err(|e| format!("cannot create {}: {e}", link.display()))?;
    }
    Ok(format!("shared folders ready at {target}{drive} ({} shared)", names.join(", ")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn net_use_listing() {
        let listing = "New connections will not be remembered.\r\n\r\nStatus       Local     Remote                    Network\r\n\
-------------------------------------------------------------------------------\r\n\
OK           Z:        \\\\10.0.2.2@47123\\DavWWWRoot Web Client Network\r\n\
             Y:        \\\\server\\share            Microsoft Windows Network\r\n";
        assert_eq!(parse_net_use(listing), vec![("Z:".to_string(), r"\\10.0.2.2@47123\DavWWWRoot".to_string())]);
    }
}

// MARK: Guest windows
//
// The host shows each program window of the guest as a window of its own. For that it needs to know
// which windows are on the guest's screen, where, and in which order; the picture itself comes from
// the guest's screen as usual. Sizes are physical pixels, so the process opts out of DPI scaling.

use windows_sys::Win32::Foundation::{CloseHandle, BOOL, HWND, LPARAM, RECT};
use windows_sys::Win32::Graphics::Dwm::{DwmGetWindowAttribute, DWMWA_CLOAKED, DWMWA_EXTENDED_FRAME_BOUNDS};
use windows_sys::Win32::System::Threading::{AttachThreadInput, GetCurrentThreadId, OpenProcess, QueryFullProcessImageNameW, PROCESS_QUERY_LIMITED_INFORMATION};
use windows_sys::Win32::UI::HiDpi::{SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    BringWindowToTop, SwitchToThisWindow, EnumWindows, GetClassNameW, GetForegroundWindow, GetSystemMetrics, GetWindow, GetWindowLongW, GetWindowRect,
    GetWindowTextW, GetWindowThreadProcessId, IsIconic, IsWindow, IsWindowVisible, IsZoomed, PostMessageW,
    SetForegroundWindow, ShowWindowAsync, GWL_EXSTYLE, GWL_STYLE, GW_OWNER, SM_CXSCREEN, SM_CYSCREEN, SW_MINIMIZE,
    SW_RESTORE, WM_CLOSE, WS_CAPTION, WS_EX_APPWINDOW, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW, WS_EX_TRANSPARENT,
};

pub fn windows_available() -> bool { true }

fn dpi_aware() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| unsafe { SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2); });
}

fn wide_to_string(buffer: &[u16], length: usize) -> String {
    String::from_utf16_lossy(&buffer[..length.min(buffer.len())])
}

/// Program names by process id. The list is taken many times a second, so the lookup is remembered.
fn process_name(pid: u32) -> String {
    static NAMES: std::sync::Mutex<Option<std::collections::HashMap<u32, String>>> = std::sync::Mutex::new(None);
    let mut names = NAMES.lock().unwrap();
    let names = names.get_or_insert_with(Default::default);
    if let Some(name) = names.get(&pid) { return name.clone(); }
    if names.len() > 512 { names.clear(); }
    let name = query_process_name(pid);
    if !name.is_empty() { names.insert(pid, name.clone()); }
    name
}

fn query_process_name(pid: u32) -> String {
    query_process_path(pid).rsplit('\\').next().unwrap_or("").to_string()
}

fn query_process_path(pid: u32) -> String {
    let handle = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) };
    if handle.is_null() { return String::new(); }
    let mut buffer = [0u16; 520];
    let mut length = buffer.len() as u32;
    let ok = unsafe { QueryFullProcessImageNameW(handle, 0, buffer.as_mut_ptr(), &mut length) };
    unsafe { CloseHandle(handle) };
    if ok == 0 { return String::new(); }
    wide_to_string(&buffer, length as usize)
}

unsafe extern "system" fn collect_window(hwnd: HWND, lparam: LPARAM) -> BOOL {
    let list = &mut *(lparam as *mut Vec<super::GuestWindow>);
    if let Some(window) = describe_window(hwnd) { list.push(window); }
    1
}

fn describe_window(hwnd: HWND) -> Option<super::GuestWindow> {
    unsafe {
        if IsWindowVisible(hwnd) == 0 { return None; }
        // Windows of other virtual desktops and suspended store apps are "visible" but not drawn.
        let mut cloaked: u32 = 0;
        DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED as u32, &mut cloaked as *mut u32 as *mut _, 4);
        if cloaked != 0 { return None; }
        let mut class = [0u16; 128];
        let class_length = GetClassNameW(hwnd, class.as_mut_ptr(), class.len() as i32).max(0) as usize;
        let class = wide_to_string(&class, class_length);
        // The desktop itself (wallpaper and icons) is not a window to show.
        if class == "Progman" || class == "WorkerW" { return None; }
        let minimized = IsIconic(hwnd) != 0;
        let mut rect: RECT = std::mem::zeroed();
        // The frame as drawn; GetWindowRect includes an invisible resize border.
        let hr = DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS as u32, &mut rect as *mut RECT as *mut _, std::mem::size_of::<RECT>() as u32);
        if hr != 0 && GetWindowRect(hwnd, &mut rect) == 0 { return None; }
        let (width, height) = (rect.right - rect.left, rect.bottom - rect.top);
        if !minimized && (width <= 0 || height <= 0) { return None; }
        let style = GetWindowLongW(hwnd, GWL_STYLE) as u32;
        let ex_style = GetWindowLongW(hwnd, GWL_EXSTYLE) as u32;
        let owner = GetWindow(hwnd, GW_OWNER);
        let mut title = [0u16; 512];
        let title_length = GetWindowTextW(hwnd, title.as_mut_ptr(), title.len() as i32).max(0) as usize;
        let title = wide_to_string(&title, title_length);
        // The rule Windows itself uses for what gets a task bar button.
        let app_window = ex_style & WS_EX_APPWINDOW != 0
            || (owner.is_null() && ex_style & (WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE) == 0);
        let kind = if class == "Shell_TrayWnd" || class == "Shell_SecondaryTrayWnd" { "taskbar" }
            else if app_window && (style & WS_CAPTION != 0 || !title.is_empty()) { "app" }
            // A dialog owned by another window has no task bar button but is a window to work in.
            else if style & WS_CAPTION == WS_CAPTION && ex_style & WS_EX_TOOLWINDOW == 0 { "app" }
            else { "popup" };
        if minimized && kind != "app" { return None; }
        // Click-through overlays (screen tints, pointer effects) are not windows to show.
        if kind == "popup" && ex_style & WS_EX_TRANSPARENT != 0 { return None; }
        let mut pid: u32 = 0;
        GetWindowThreadProcessId(hwnd, &mut pid);
        Some(super::GuestWindow {
            id: hwnd as usize as u64,
            x: rect.left, y: rect.top, width, height, pid, kind,
            state: if minimized { "minimized" } else if IsZoomed(hwnd) != 0 { "maximized" } else { "normal" },
            active: hwnd == GetForegroundWindow(),
            title, class,
            app: process_name(pid),
        })
    }
}

/// Every window on the guest's screen, front-most first (the order `EnumWindows` gives).
pub fn list_windows() -> super::WindowList {
    dpi_aware();
    let mut windows: Vec<super::GuestWindow> = Vec::new();
    unsafe { EnumWindows(Some(collect_window), &mut windows as *mut Vec<super::GuestWindow> as LPARAM) };
    let desktop = unsafe { (GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN)) };
    super::WindowList { desktop, windows, moving: moving_window() }
}

/// Makes a window the one the user works in. Windows only lets the process that got the last input
/// change the foreground window, so the agent first joins the input queue of the thread that has it.
unsafe fn bring_to_front(hwnd: HWND) -> bool {
    if IsIconic(hwnd) != 0 { ShowWindowAsync(hwnd, SW_RESTORE); }
    if GetForegroundWindow() == hwnd { return true; }
    let me = GetCurrentThreadId();
    let front = GetWindowThreadProcessId(GetForegroundWindow(), std::ptr::null_mut());
    let attached = front != 0 && front != me && AttachThreadInput(me, front, 1) != 0;
    BringWindowToTop(hwnd);
    SetForegroundWindow(hwnd);
    if attached { AttachThreadInput(me, front, 0); }
    if GetForegroundWindow() == hwnd { return true; }
    // What Alt+Tab itself uses; not subject to the same rule.
    SwitchToThisWindow(hwnd, 1);
    for _ in 0..10 {
        if GetForegroundWindow() == hwnd { return true; }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    false
}

pub fn window_action(id: u64, action: u32) -> Result<(), String> {
    use link_proto::window_action as act;
    let hwnd = id as usize as HWND;
    unsafe {
        if IsWindow(hwnd) == 0 { return Err(format!("window {id} no longer exists")); }
        match action {
            act::ACTIVATE => { if !bring_to_front(hwnd) { return Err(format!("Windows did not bring window {id} to the front")); } }
            act::CLOSE => { PostMessageW(hwnd, WM_CLOSE, 0, 0); }
            act::MINIMIZE => { ShowWindowAsync(hwnd, SW_MINIMIZE); }
            act::RESTORE => { ShowWindowAsync(hwnd, SW_RESTORE); }
            other => return Err(format!("unknown window action {other}")),
        }
    }
    Ok(())
}

// MARK: Guest programs and icons
//
// The host lists the guest's programs in its own menus and shows their icons. The list is what the
// Start menu shows (classic programs and store apps alike), and a program is started through the
// shell, so it runs as the signed-in user without the agent's elevation.

use windows_sys::Win32::Graphics::Gdi::{
    CreateCompatibleDC, CreateDIBSection, DeleteDC, DeleteObject, GdiFlush, SelectObject, BITMAPINFO, BITMAPINFOHEADER,
    BI_RGB, DIB_RGB_COLORS,
};
use windows_sys::Win32::System::Com::{CoInitializeEx, CoTaskMemFree, COINIT_APARTMENTTHREADED};
use windows_sys::Win32::UI::Shell::{SHGetFileInfoW, SHParseDisplayName, SHFILEINFOW, SHGFI_ICON, SHGFI_LARGEICON, SHGFI_PIDL};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    DestroyIcon, DrawIconEx, GetClassLongPtrW, PrivateExtractIconsW, SendMessageTimeoutW, DI_MASK, DI_NORMAL, GCLP_HICON,
    HICON, ICON_BIG, SMTO_ABORTIFHUNG, WM_GETICON,
};

#[path = "windows_seamless.rs"]
mod seamless;
pub use seamless::{display_scale, keep_work_area, moving_window, process_cpu_ms, rescale_windows, set_display_scale, set_work_area, wait_window_change, window_change_count, window_events_start};

#[path = "windows_activity.rs"]
mod activity;
pub use activity::{activity_available, cpu_times, input_idle_seconds, keep_awake_dir, open_to_everyone, pid_alive, power_requests};

#[path = "windows_dragdrop.rs"]
mod dragdrop;
pub use dragdrop::{agent_data_dir, drop_target_folder, fallback_drop_folder, file_drop_available, folder_changed, install_send_to, message_box, selected_files_at};

#[path = "windows_documents.rs"]
mod documents;
pub use documents::{documents_available, open_documents, program_info, run_requests};

pub fn programs_available() -> bool { true }

fn to_wide(text: &str) -> Vec<u16> { text.encode_utf16().chain(std::iter::once(0)).collect() }

/// The programs in the Start menu, by name. PowerShell's `Get-StartApps` is the one listing that has
/// classic programs and store apps together; the shortcut folders are the fallback.
pub fn list_programs() -> Vec<super::GuestProgram> {
    let script = "[Console]::OutputEncoding = [Text.Encoding]::UTF8; Get-StartApps | ForEach-Object { $_.Name + \"`t\" + $_.AppID }";
    let listed = run_quiet("powershell", &["-NoProfile", "-NonInteractive", "-Command", script]).unwrap_or_default();
    let programs = super::parse_program_lines(&listed);
    if !programs.is_empty() { return programs; }
    let mut lines = String::new();
    for root in ["ProgramData", "APPDATA"] {
        let Ok(base) = std::env::var(root) else { continue };
        collect_shortcuts(&std::path::Path::new(&base).join(r"Microsoft\Windows\Start Menu\Programs"), 0, &mut lines);
    }
    super::parse_program_lines(&lines)
}

fn collect_shortcuts(folder: &std::path::Path, depth: u32, lines: &mut String) {
    let Ok(entries) = std::fs::read_dir(folder) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            if depth < 4 { collect_shortcuts(&path, depth + 1, lines); }
        } else if path.extension().map(|e| e.eq_ignore_ascii_case("lnk")).unwrap_or(false) {
            if let (Some(name), Some(full)) = (path.file_stem().and_then(|n| n.to_str()), path.to_str()) {
                lines.push_str(&format!("{name}\t{full}\n"));
            }
        }
    }
}

/// Starts a program from `list_programs`. Explorer hands the request to the desktop shell that is
/// already running, so the program starts as the user would have started it, without elevation.
pub fn launch_program(id: &str) -> Result<(), String> {
    use std::os::windows::process::CommandExt;
    let target = if id.to_lowercase().ends_with(".lnk") { id.to_string() } else { format!(r"shell:AppsFolder\{id}") };
    Command::new("explorer.exe").arg(target).creation_flags(CREATE_NO_WINDOW).spawn().map(|_| ()).map_err(|e| e.to_string())
}

/// Draws an icon into a square of 32-bit BGRA pixels, top row first, colour premultiplied by opacity.
unsafe fn render_icon(icon: HICON, size: i32) -> Option<Vec<u8>> {
    let dc = CreateCompatibleDC(std::ptr::null_mut());
    if dc.is_null() { return None; }
    let mut info: BITMAPINFO = std::mem::zeroed();
    info.bmiHeader.biSize = std::mem::size_of::<BITMAPINFOHEADER>() as u32;
    info.bmiHeader.biWidth = size;
    info.bmiHeader.biHeight = -size; // top-down
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB as u32;
    let draw = |flags: u32| -> Option<Vec<u8>> {
        let mut bits: *mut core::ffi::c_void = std::ptr::null_mut();
        let bitmap = CreateDIBSection(dc, &info, DIB_RGB_COLORS, &mut bits, std::ptr::null_mut(), 0);
        if bitmap.is_null() || bits.is_null() { return None; }
        let previous = SelectObject(dc, bitmap);
        let drawn = DrawIconEx(dc, 0, 0, icon, size, size, 0, std::ptr::null_mut(), flags);
        GdiFlush();
        let pixels = std::slice::from_raw_parts(bits as *const u8, (size * size * 4) as usize).to_vec();
        SelectObject(dc, previous);
        DeleteObject(bitmap);
        (drawn != 0).then_some(pixels)
    };
    let mut pixels = draw(DI_NORMAL);
    if let Some(p) = pixels.as_mut() {
        // An old-style icon has no alpha channel; its opacity is in a separate mask.
        if super::lacks_alpha(p) {
            match draw(DI_MASK) {
                Some(mask) => super::apply_icon_mask(p, &mask),
                None => pixels = None,
            }
        }
    }
    DeleteDC(dc);
    pixels
}

/// The icon of the program a window belongs to: from the program file at the wanted size when it has
/// one, otherwise the icon the window itself carries. Store apps offer neither; the host then falls
/// back to the icon of the program with the window's name.
pub fn window_icon(id: u64, size: u32) -> Option<Vec<u8>> {
    let hwnd = id as usize as HWND;
    let size = size.clamp(16, 256) as i32;
    unsafe {
        if IsWindow(hwnd) == 0 { return None; }
        let mut pid: u32 = 0;
        GetWindowThreadProcessId(hwnd, &mut pid);
        let path = query_process_path(pid);
        // The frame host draws every store app's window; its own icon says nothing about the app.
        if !path.is_empty() && !path.to_lowercase().ends_with("applicationframehost.exe") {
            let wide = to_wide(&path);
            let mut icon: HICON = std::ptr::null_mut();
            let mut icon_id: u32 = 0;
            let found = PrivateExtractIconsW(wide.as_ptr(), 0, size, size, &mut icon, &mut icon_id, 1, 0);
            if found > 0 && found != u32::MAX && !icon.is_null() {
                let pixels = render_icon(icon, size);
                DestroyIcon(icon);
                if pixels.is_some() { return pixels; }
            }
        }
        let mut result: usize = 0;
        SendMessageTimeoutW(hwnd, WM_GETICON, ICON_BIG as usize, 0, SMTO_ABORTIFHUNG, 200, &mut result);
        let mut icon = result as HICON;
        if icon.is_null() { icon = GetClassLongPtrW(hwnd, GCLP_HICON) as HICON; }
        // These belong to the window; they are not ours to destroy.
        if icon.is_null() { None } else { render_icon(icon, size) }
    }
}

/// The icon the Start menu shows for a program from `list_programs`.
pub fn program_icon(id: &str, size: u32) -> Option<Vec<u8>> {
    let size = size.clamp(16, 256) as i32;
    // The shell hands out small icons. For a large one (a Dock icon on the Mac), go to the program
    // file itself when it is known; it holds the icon at every size.
    if size > 48 {
        if let Some(target) = documents::known_target(id).filter(|t| !t.is_empty()) {
            let wide = to_wide(&target);
            let mut icon: HICON = std::ptr::null_mut();
            let mut icon_id: u32 = 0;
            let found = unsafe { PrivateExtractIconsW(wide.as_ptr(), 0, size, size, &mut icon, &mut icon_id, 1, 0) };
            if found > 0 && found != u32::MAX && !icon.is_null() {
                let pixels = unsafe { render_icon(icon, size) };
                unsafe { DestroyIcon(icon) };
                if pixels.is_some() { return pixels; }
            }
        }
    }
    unsafe {
        // Shell calls want COM on their thread. Asking again on the same thread is harmless.
        CoInitializeEx(std::ptr::null(), COINIT_APARTMENTTHREADED as u32);
        let mut info: SHFILEINFOW = std::mem::zeroed();
        let info_size = std::mem::size_of::<SHFILEINFOW>() as u32;
        let got = if id.to_lowercase().ends_with(".lnk") {
            let wide = to_wide(id);
            SHGetFileInfoW(wide.as_ptr(), 0, &mut info, info_size, SHGFI_ICON | SHGFI_LARGEICON)
        } else {
            let wide = to_wide(&format!(r"shell:AppsFolder\{id}"));
            let mut item = std::ptr::null_mut();
            if SHParseDisplayName(wide.as_ptr(), std::ptr::null_mut(), &mut item, 0, std::ptr::null_mut()) != 0 || item.is_null() {
                return None;
            }
            let got = SHGetFileInfoW(item as *const u16, 0, &mut info, info_size, SHGFI_PIDL | SHGFI_ICON | SHGFI_LARGEICON);
            CoTaskMemFree(item as *const core::ffi::c_void);
            got
        };
        if got == 0 || info.hIcon.is_null() { return None; }
        let pixels = render_icon(info.hIcon, size);
        DestroyIcon(info.hIcon);
        pixels
    }
}
