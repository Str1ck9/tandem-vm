//! Seamless Mode support that needs Windows' own notifications.
//!
//! 1. Window events. Instead of listing the windows on a fixed timer, a thread with a message loop
//!    listens to Windows' accessibility events (window shown, hidden, moved, reordered, activated,
//!    renamed). The reporter wakes on the first event and lists the windows then, so a change reaches
//!    the host within a few milliseconds while an idle desktop costs almost nothing.
//! 2. The window being dragged. Between "move/size started" and "ended" the report names the window,
//!    its frame and the pointer position at the start, so the host can move its own window with the
//!    pointer instead of waiting for each report.
//! 3. Display scale. Seamless Mode at Retina resolution gives the guest twice as many pixels; the
//!    guest's scale goes to 200% at the same time so text keeps its size and becomes sharp. This is
//!    the same change the Settings app makes, applied at once, without signing out.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Condvar, Mutex, Once};
use std::time::Duration;
use windows_sys::Win32::Foundation::{HWND, LPARAM, POINT, RECT};
use windows_sys::Win32::Devices::Display::{
    DisplayConfigGetDeviceInfo, DisplayConfigSetDeviceInfo, GetDisplayConfigBufferSizes, QueryDisplayConfig,
    DISPLAYCONFIG_DEVICE_INFO_HEADER, DISPLAYCONFIG_MODE_INFO, DISPLAYCONFIG_PATH_INFO, QDC_ONLY_ACTIVE_PATHS,
};
use windows_sys::Win32::Graphics::Dwm::{DwmGetWindowAttribute, DWMWA_EXTENDED_FRAME_BOUNDS};
use windows_sys::Win32::UI::Accessibility::{SetWinEventHook, HWINEVENTHOOK};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    DispatchMessageW, GetAncestor, GetCursorPos, GetMessageW, GetWindowRect, SendMessageTimeoutW, TranslateMessage,
    GA_ROOT, MSG, SMTO_ABORTIFHUNG, WINEVENT_OUTOFCONTEXT, WINEVENT_SKIPOWNPROCESS, WM_NCHITTEST,
};

const EVENT_SYSTEM_FOREGROUND: u32 = 0x0003;
const EVENT_SYSTEM_MOVESIZESTART: u32 = 0x000A;
const EVENT_SYSTEM_MOVESIZEEND: u32 = 0x000B;
const EVENT_SYSTEM_MINIMIZEEND: u32 = 0x0017;
const EVENT_OBJECT_CREATE: u32 = 0x8000;
const EVENT_OBJECT_UNCLOAKED: u32 = 0x8018;
const OBJID_WINDOW: i32 = 0;
const CHILDID_SELF: i32 = 0;

/// Counts window changes; the reporter compares it with the value it last saw.
static CHANGES: AtomicU64 = AtomicU64::new(0);
static WAKE: (Mutex<()>, Condvar) = (Mutex::new(()), Condvar::new());
static MOVING: Mutex<Option<crate::platform::MoveStart>> = Mutex::new(None);
static START: Once = Once::new();

fn changed() {
    CHANGES.fetch_add(1, Ordering::Relaxed);
    WAKE.1.notify_all();
}

unsafe fn frame_of(hwnd: HWND) -> Option<RECT> {
    let mut rect: RECT = std::mem::zeroed();
    let hr = DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS as u32, &mut rect as *mut RECT as *mut _, std::mem::size_of::<RECT>() as u32);
    if hr != 0 && GetWindowRect(hwnd, &mut rect) == 0 { return None; }
    Some(rect)
}

unsafe extern "system" fn on_event(_hook: HWINEVENTHOOK, event: u32, hwnd: HWND, id_object: i32, id_child: i32, _thread: u32, _time: u32) {
    if hwnd.is_null() || id_object != OBJID_WINDOW || id_child != CHILDID_SELF { return; }
    // Child controls change all the time; only top-level windows are reported.
    if GetAncestor(hwnd, GA_ROOT) != hwnd { return; }
    match event {
        EVENT_SYSTEM_MOVESIZESTART => {
            let mut pointer = POINT { x: 0, y: 0 };
            GetCursorPos(&mut pointer);
            if let Some(rect) = frame_of(hwnd) {
                // Which part of the frame is under the pointer tells a resize (an edge or corner) from a
                // move (the title bar). Asked of the window itself, as Windows does; a hung window
                // counts as a move.
                let lparam = ((pointer.x as u32 & 0xFFFF) | ((pointer.y as u32 & 0xFFFF) << 16)) as LPARAM;
                let mut hit: usize = 0;
                let answered = SendMessageTimeoutW(hwnd, WM_NCHITTEST, 0, lparam, SMTO_ABORTIFHUNG, 50, &mut hit);
                let edge = if answered != 0 { crate::platform::sizing_edge(hit as isize) } else { None };
                *MOVING.lock().unwrap() = Some(crate::platform::MoveStart {
                    id: hwnd as usize as u64, x: rect.left, y: rect.top,
                    width: rect.right - rect.left, height: rect.bottom - rect.top,
                    pointer_x: pointer.x, pointer_y: pointer.y, edge,
                });
            }
        }
        EVENT_SYSTEM_MOVESIZEEND => { *MOVING.lock().unwrap() = None; }
        _ => {}
    }
    changed();
}

/// Starts listening for window events (once; the thread lives as long as the agent).
pub fn window_events_start() {
    START.call_once(|| {
        std::thread::spawn(|| unsafe {
            super::dpi_aware();
            let flags = WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS;
            SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_MINIMIZEEND, std::ptr::null_mut(), Some(on_event), 0, 0, flags);
            SetWinEventHook(EVENT_OBJECT_CREATE, EVENT_OBJECT_UNCLOAKED, std::ptr::null_mut(), Some(on_event), 0, 0, flags);
            // Out-of-context hooks are delivered through this thread's message queue.
            let mut msg: MSG = std::mem::zeroed();
            while GetMessageW(&mut msg, std::ptr::null_mut(), 0, 0) > 0 {
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        });
    });
}

/// The number of window changes seen so far.
pub fn window_change_count() -> u64 { CHANGES.load(Ordering::Relaxed) }

/// Waits until the count differs from `seen`, or the timeout passes.
pub fn wait_window_change(seen: u64, timeout: Duration) {
    let guard = WAKE.0.lock().unwrap();
    let _ = WAKE.1.wait_timeout_while(guard, timeout, |_| CHANGES.load(Ordering::Relaxed) == seen);
}

/// The window being moved or resized by the user right now, as it was when that began.
pub fn moving_window() -> Option<crate::platform::MoveStart> { *MOVING.lock().unwrap() }

// MARK: Display scale

/// The scale steps Windows offers, in percent. The display's own recommended step is index 0 of
/// Windows' relative numbering.
const SCALES: [u32; 12] = [100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500];
const GET_DPI_SCALE: i32 = -3;
const SET_DPI_SCALE: i32 = -4;

#[repr(C)]
struct ScaleGet { header: DISPLAYCONFIG_DEVICE_INFO_HEADER, min_rel: i32, cur_rel: i32, max_rel: i32 }
#[repr(C)]
struct ScaleSet { header: DISPLAYCONFIG_DEVICE_INFO_HEADER, rel: i32 }

/// The first active display's adapter and source, which is what the scale belongs to.
unsafe fn primary_source() -> Option<DISPLAYCONFIG_PATH_INFO> {
    let (mut paths, mut modes) = (0u32, 0u32);
    if GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &mut paths, &mut modes) != 0 || paths == 0 { return None; }
    let mut path_info: Vec<DISPLAYCONFIG_PATH_INFO> = vec![std::mem::zeroed(); paths as usize];
    let mut mode_info: Vec<DISPLAYCONFIG_MODE_INFO> = vec![std::mem::zeroed(); modes as usize];
    if QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &mut paths, path_info.as_mut_ptr(), &mut modes, mode_info.as_mut_ptr(), std::ptr::null_mut()) != 0 {
        return None;
    }
    path_info.into_iter().next()
}

/// (current scale in percent, recommended step index) of the main display.
fn scale_state() -> Result<(u32, usize, DISPLAYCONFIG_PATH_INFO), String> {
    unsafe {
        let path = primary_source().ok_or("no active display")?;
        let mut get = ScaleGet {
            header: DISPLAYCONFIG_DEVICE_INFO_HEADER {
                r#type: GET_DPI_SCALE, size: std::mem::size_of::<ScaleGet>() as u32,
                adapterId: path.sourceInfo.adapterId, id: path.sourceInfo.id,
            },
            min_rel: 0, cur_rel: 0, max_rel: 0,
        };
        let rc = DisplayConfigGetDeviceInfo(&mut get.header);
        if rc != 0 { return Err(format!("reading the display scale failed ({rc})")); }
        let recommended = (-get.min_rel).max(0) as usize;
        let current = (recommended as i32 + get.cur_rel).clamp(0, SCALES.len() as i32 - 1) as usize;
        Ok((SCALES[current], recommended, path))
    }
}

/// The main display's scale in percent.
pub fn display_scale() -> Option<u32> { scale_state().ok().map(|s| s.0) }

/// Sets the main display's scale (100, 125, … percent). Windows applies it at once; programs that do
/// not handle scale changes redraw at the new size only when reopened.
pub fn set_display_scale(percent: u32) -> Result<(), String> {
    let target = SCALES.iter().position(|&s| s == percent).ok_or(format!("{percent}% is not a scale Windows offers"))?;
    let (current, recommended, path) = scale_state()?;
    if current == percent { return Ok(()); }
    let set = ScaleSet {
        header: DISPLAYCONFIG_DEVICE_INFO_HEADER {
            r#type: SET_DPI_SCALE, size: std::mem::size_of::<ScaleSet>() as u32,
            adapterId: path.sourceInfo.adapterId, id: path.sourceInfo.id,
        },
        rel: target as i32 - recommended as i32,
    };
    let rc = unsafe { DisplayConfigSetDeviceInfo(&set.header) };
    if rc != 0 { return Err(format!("setting the display scale failed ({rc})")); }
    Ok(())
}

/// Processor time this process has used, in milliseconds.
// MARK: Work area

/// The work area Windows had before the host first changed it, to put back.
static ORIGINAL_WORK_AREA: Mutex<Option<RECT>> = Mutex::new(None);
/// The work area the host asked for, kept while Seamless Mode lasts: the task bar recomputes the work
/// area when the resolution changes, which can undo a change made just before.
static WANTED_WORK_AREA: Mutex<Option<RECT>> = Mutex::new(None);

/// Puts the wanted work area back if something replaced it, and fits maximised windows into it.
/// Called from the window-watch loop; cheap when nothing changed.
///
/// The task bar recomputes the work area on its own (after a resolution change, and whenever it
/// re-registers), so the work area alone does not reliably keep maximised windows on the main display.
/// A window that is maximised and does not fill the wanted area is therefore placed there directly; it
/// stays maximised (its title bar's button still restores it).
pub fn keep_work_area() {
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        EnumWindows, IsWindowVisible, IsZoomed, SetWindowPos, SystemParametersInfoW, SPIF_SENDCHANGE, SPI_GETWORKAREA,
        SPI_SETWORKAREA, SWP_NOACTIVATE, SWP_NOOWNERZORDER, SWP_NOZORDER,
    };
    use windows_sys::Win32::Foundation::{BOOL, LPARAM};
    let Some(mut wanted) = *WANTED_WORK_AREA.lock().unwrap() else { return };
    unsafe {
        let mut current: RECT = std::mem::zeroed();
        if SystemParametersInfoW(SPI_GETWORKAREA, 0, &mut current as *mut RECT as *mut _, 0) != 0
            && (current.left, current.top, current.right, current.bottom) != (wanted.left, wanted.top, wanted.right, wanted.bottom) {
            SystemParametersInfoW(SPI_SETWORKAREA, 0, &mut wanted as *mut RECT as *mut _, SPIF_SENDCHANGE);
        }
        unsafe extern "system" fn fit(hwnd: HWND, lparam: LPARAM) -> BOOL {
            let wanted = &*(lparam as *const RECT);
            if IsWindowVisible(hwnd) == 0 || IsZoomed(hwnd) == 0 { return 1; }
            let (Some(frame), true) = (frame_of(hwnd), true) else { return 1 };
            if (frame.left, frame.top, frame.right, frame.bottom) == (wanted.left, wanted.top, wanted.right, wanted.bottom) { return 1; }
            // A maximised window's rectangle reaches past the drawn frame by its invisible borders;
            // keep those, so the drawn frame lands exactly on the wanted area.
            let mut outer: RECT = std::mem::zeroed();
            if GetWindowRect(hwnd, &mut outer) == 0 { return 1; }
            let (l, t, r, b) = (frame.left - outer.left, frame.top - outer.top, outer.right - frame.right, outer.bottom - frame.bottom);
            SetWindowPos(hwnd, std::ptr::null_mut(), wanted.left - l, wanted.top - t,
                         (wanted.right - wanted.left) + l + r, (wanted.bottom - wanted.top) + t + b,
                         SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
            1
        }
        EnumWindows(Some(fit), &wanted as *const RECT as LPARAM);
    }
}

/// Seamless Mode over several Mac displays lays the guest's one monitor over all of them; the work
/// area (where maximised windows go) is then set to the part on the Mac's main display, so maximising
/// fills one display instead of the whole arrangement. None puts back the guest's own.
pub fn set_work_area(area: Option<(i32, i32, i32, i32)>) -> Result<(), String> {
    use windows_sys::Win32::UI::WindowsAndMessaging::{SystemParametersInfoW, SPIF_SENDCHANGE, SPI_GETWORKAREA, SPI_SETWORKAREA};
    unsafe {
        let mut saved = ORIGINAL_WORK_AREA.lock().unwrap();
        let mut target: RECT = match area {
            Some((x, y, w, h)) => {
                if saved.is_none() {
                    let mut current: RECT = std::mem::zeroed();
                    if SystemParametersInfoW(SPI_GETWORKAREA, 0, &mut current as *mut RECT as *mut _, 0) != 0 { *saved = Some(current); }
                }
                let rect = RECT { left: x, top: y, right: x + w, bottom: y + h };
                *WANTED_WORK_AREA.lock().unwrap() = Some(rect);
                rect
            }
            None => {
                *WANTED_WORK_AREA.lock().unwrap() = None;
                match saved.take() { Some(r) => r, None => return Ok(()) }
            }
        };
        if SystemParametersInfoW(SPI_SETWORKAREA, 0, &mut target as *mut RECT as *mut _, SPIF_SENDCHANGE) == 0 {
            return Err(std::io::Error::last_os_error().to_string());
        }
    }
    Ok(())
}

pub fn process_cpu_ms() -> u64 {
    use windows_sys::Win32::Foundation::FILETIME;
    use windows_sys::Win32::System::Threading::{GetCurrentProcess, GetProcessTimes};
    let (mut a, mut b, mut kernel, mut user): (FILETIME, FILETIME, FILETIME, FILETIME) = unsafe { std::mem::zeroed() };
    if unsafe { GetProcessTimes(GetCurrentProcess(), &mut a, &mut b, &mut kernel, &mut user) } == 0 { return 0; }
    let ticks = |t: &FILETIME| ((t.dwHighDateTime as u64) << 32) | t.dwLowDateTime as u64;
    (ticks(&kernel) + ticks(&user)) / 10_000
}

/// Scales the open program windows by `factor` (position and size), so that after a change of display
/// scale they stay where they were and as large as they looked. Windows itself keeps a window's size
/// in pixels when the scale changes, which would leave every open window half as large on the Mac.
/// Maximised and minimised windows are left to Windows.
pub fn rescale_windows(factor: f64) {
    use windows_sys::Win32::Foundation::{BOOL, LPARAM};
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        EnumWindows, GetWindowLongW, IsIconic, IsWindowVisible, IsZoomed, SetWindowPos, GWL_STYLE, SWP_NOACTIVATE,
        SWP_NOOWNERZORDER, SWP_NOZORDER, WS_CAPTION,
    };
    if (factor - 1.0).abs() < 0.01 { return; }
    unsafe extern "system" fn collect(hwnd: HWND, lparam: LPARAM) -> BOOL {
        (*(lparam as *mut Vec<HWND>)).push(hwnd);
        1
    }
    super::dpi_aware();
    let mut all: Vec<HWND> = Vec::new();
    unsafe { EnumWindows(Some(collect), &mut all as *mut Vec<HWND> as LPARAM) };
    for hwnd in all {
        unsafe {
            if IsWindowVisible(hwnd) == 0 || IsIconic(hwnd) != 0 || IsZoomed(hwnd) != 0 { continue; }
            if GetWindowLongW(hwnd, GWL_STYLE) as u32 & WS_CAPTION != WS_CAPTION { continue; }
            let mut rect: RECT = std::mem::zeroed();
            if GetWindowRect(hwnd, &mut rect) == 0 { continue; }
            let scale = |v: i32| (v as f64 * factor).round() as i32;
            SetWindowPos(hwnd, std::ptr::null_mut(), scale(rect.left), scale(rect.top),
                         scale(rect.right - rect.left), scale(rect.bottom - rect.top),
                         SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_NOACTIVATE);
        }
    }
}
