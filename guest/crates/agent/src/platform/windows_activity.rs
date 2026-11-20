//! What Windows can say about being in use (see `activity.rs`). Run in a Windows 11 ARM64 guest on 2026-11-15.

use super::run_quiet;
use std::path::PathBuf;
use windows_sys::Win32::Foundation::{CloseHandle, FILETIME};
use windows_sys::Win32::System::SystemInformation::GetTickCount;
use windows_sys::Win32::System::Threading::{GetExitCodeProcess, GetSystemTimes, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION};
use windows_sys::Win32::UI::Input::KeyboardAndMouse::{GetLastInputInfo, LASTINPUTINFO};

pub fn activity_available() -> bool { true }

/// Seconds since the last key press or pointer movement in the user's session. Input that comes from
/// the Mac through the virtual keyboard and pointer counts, as it should.
pub fn input_idle_seconds() -> Option<u64> {
    let mut info = LASTINPUTINFO { cbSize: std::mem::size_of::<LASTINPUTINFO>() as u32, dwTime: 0 };
    if unsafe { GetLastInputInfo(&mut info) } == 0 { return None; }
    // Both are milliseconds since boot in 32 bits; the subtraction survives the wrap after 49 days.
    Some((unsafe { GetTickCount() }.wrapping_sub(info.dwTime) / 1000) as u64)
}

fn ticks(time: &FILETIME) -> u64 { (time.dwHighDateTime as u64) << 32 | time.dwLowDateTime as u64 }

/// Busy and total processor time over all cores since boot, in the same unit.
pub fn cpu_times() -> Option<(u64, u64)> {
    let (mut idle, mut kernel, mut user): (FILETIME, FILETIME, FILETIME) = unsafe { std::mem::zeroed() };
    if unsafe { GetSystemTimes(&mut idle, &mut kernel, &mut user) } == 0 { return None; }
    // Kernel time includes idle time.
    let total = ticks(&kernel) + ticks(&user);
    Some((total.saturating_sub(ticks(&idle)), total))
}

/// Programs and drivers that asked Windows itself to stay awake. Only an administrator may ask;
/// an agent without those rights reports none.
pub fn power_requests() -> Vec<String> {
    run_quiet("powercfg", &["/requests"]).map(|text| crate::activity::parse_power_requests(&text)).unwrap_or_default()
}

/// Per user: the agent runs as the signed-in user, and so does whatever asks.
pub fn keep_awake_dir() -> PathBuf {
    PathBuf::from(std::env::var("LOCALAPPDATA").unwrap_or_else(|_| r"C:\Users\Public".into())).join("Tandem").join("keep-awake")
}

pub fn open_to_everyone(_dir: &std::path::Path) {}

pub fn pid_alive(pid: u32) -> bool {
    const STILL_ACTIVE: u32 = 259;
    unsafe {
        let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if handle.is_null() { return false; }
        let mut code = 0u32;
        let ok = GetExitCodeProcess(handle, &mut code);
        CloseHandle(handle);
        ok != 0 && code == STILL_ACTIVE
    }
}
