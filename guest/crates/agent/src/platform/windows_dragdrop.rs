//! Windows side of file drops from the Mac and "Send to > Mac" (see `crate::filedrop`).
use std::os::windows::process::CommandExt;
use std::path::PathBuf;
use std::process::Command;
use windows_sys::Win32::Foundation::{HWND, POINT};
use windows_sys::Win32::System::Com::CoTaskMemFree;
use windows_sys::Win32::UI::Shell::{SHGetKnownFolderPath, FOLDERID_Desktop, FOLDERID_Downloads};
use windows_sys::Win32::UI::WindowsAndMessaging::{GetAncestor, GetClassNameW, GetWindowTextW, MessageBoxW, WindowFromPoint, GA_ROOT, MB_ICONWARNING, MB_OK};

const CREATE_NO_WINDOW: u32 = 0x0800_0000;
const SEND_TO_NAME: &str = "Mac (Tandem).lnk";

pub fn file_drop_available() -> bool { true }

fn known_folder(id: &windows_sys::core::GUID) -> Option<PathBuf> {
    unsafe {
        let mut raw: windows_sys::core::PWSTR = std::ptr::null_mut();
        if SHGetKnownFolderPath(id, 0, std::ptr::null_mut(), &mut raw) != 0 || raw.is_null() { return None; }
        let mut len = 0;
        while *raw.add(len) != 0 { len += 1; }
        let path = String::from_utf16_lossy(std::slice::from_raw_parts(raw, len));
        CoTaskMemFree(raw as *const _);
        Some(PathBuf::from(path))
    }
}

fn class_and_title(hwnd: HWND) -> (String, String) {
    let mut class = [0u16; 128];
    let mut title = [0u16; 512];
    unsafe {
        let c = GetClassNameW(hwnd, class.as_mut_ptr(), class.len() as i32).max(0) as usize;
        let t = GetWindowTextW(hwnd, title.as_mut_ptr(), title.len() as i32).max(0) as usize;
        (String::from_utf16_lossy(&class[..c]), String::from_utf16_lossy(&title[..t]))
    }
}

/// The folder an Explorer window shows, from the shell's list of open windows. With several tabs in
/// one window, the tab whose name the window's title carries.
fn explorer_folder(hwnd: HWND, title: &str) -> Option<PathBuf> {
    let title = title.replace('\'', "''");
    let script = format!(
        "$w = @((New-Object -ComObject Shell.Application).Windows() | Where-Object {{ $_.HWND -eq {} }}); \
         $m = $w | Where-Object {{ '{title}'.StartsWith($_.LocationName) }} | Select-Object -First 1; \
         if (-not $m) {{ $m = $w | Select-Object -First 1 }}; \
         if ($m) {{ [Console]::OutputEncoding = [Text.Encoding]::UTF8; $m.Document.Folder.Self.Path }}",
        hwnd as isize);
    let output = Command::new("powershell").args(["-NoProfile", "-NonInteractive", "-Command", &script])
        .creation_flags(CREATE_NO_WINDOW).output().ok()?;
    let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
    // Virtual places (This PC, Home, a library) have no folder on disk to copy into.
    let folder = PathBuf::from(&path);
    (!path.is_empty() && folder.is_dir()).then_some(folder)
}

/// The folder under the guest pixel: the Explorer window there, or the desktop. Nil for anything else.
pub fn drop_target_folder(x: i32, y: i32) -> Option<PathBuf> {
    super::dpi_aware();
    unsafe {
        let hit = WindowFromPoint(POINT { x, y });
        if hit.is_null() { return None; }
        let root = GetAncestor(hit, GA_ROOT);
        let (class, title) = class_and_title(root);
        crate::log_local(&format!("drop at {x},{y}: window class {class} “{title}”"));
        match class.as_str() {
            "Progman" | "WorkerW" => known_folder(&FOLDERID_Desktop),
            "CabinetWClass" | "ExploreWClass" => explorer_folder(root, &title),
            _ => None,
        }
    }
}

/// The files and folders selected in the File Explorer window at a guest pixel, for a drag out of the
/// guest onto the Mac. Other windows (and the desktop, whose selection the shell does not hand out
/// this way) give an explanation instead.
pub fn selected_files_at(x: i32, y: i32) -> Result<Vec<String>, String> {
    super::dpi_aware();
    let (root, class, title) = unsafe {
        let hit = WindowFromPoint(POINT { x, y });
        if hit.is_null() { return Err("Nothing was under the pointer.".into()); }
        let root = GetAncestor(hit, GA_ROOT);
        let (class, title) = class_and_title(root);
        (root, class, title)
    };
    if class != "CabinetWClass" && class != "ExploreWClass" {
        return Err("Files can be dragged to the Mac from File Explorer windows. From other programs, save the file and use Send to > Mac.".into());
    }
    let title = title.replace('\'', "''");
    let script = format!(
        "$w = @((New-Object -ComObject Shell.Application).Windows() | Where-Object {{ $_.HWND -eq {} }}); \
         $m = $w | Where-Object {{ '{title}'.StartsWith($_.LocationName) }} | Select-Object -First 1; \
         if (-not $m) {{ $m = $w | Select-Object -First 1 }}; \
         if ($m) {{ [Console]::OutputEncoding = [Text.Encoding]::UTF8; $m.Document.SelectedItems() | ForEach-Object {{ $_.Path }} }}",
        root as isize);
    let output = Command::new("powershell").args(["-NoProfile", "-NonInteractive", "-Command", &script])
        .creation_flags(CREATE_NO_WINDOW).output().map_err(|e| e.to_string())?;
    // Only real files and folders: virtual items (This PC, a library, a zip's inside) have no path to copy.
    let paths: Vec<String> = String::from_utf8_lossy(&output.stdout).lines().map(|l| l.trim().to_string())
        .filter(|p| !p.is_empty() && std::path::Path::new(p).exists()).collect();
    crate::log_local(&format!("drag out from {x},{y}: {} selected in “{title}”", paths.len()));
    if paths.is_empty() { return Err("Nothing that can be copied to the Mac was selected.".into()); }
    Ok(paths)
}

/// Tells Explorer a folder's contents changed, so an open window shows dropped files at once.
pub fn folder_changed(folder: &std::path::Path) {
    use windows_sys::Win32::UI::Shell::{SHChangeNotify, SHCNE_UPDATEDIR, SHCNF_FLUSH, SHCNF_PATHW};
    let wide: Vec<u16> = folder.as_os_str().to_string_lossy().encode_utf16().chain(std::iter::once(0)).collect();
    unsafe { SHChangeNotify(SHCNE_UPDATEDIR as i32, SHCNF_PATHW | SHCNF_FLUSH, wide.as_ptr() as *const _, std::ptr::null()); }
}

/// Where files go when nothing under the pointer holds files.
pub fn fallback_drop_folder() -> Option<PathBuf> { known_folder(&FOLDERID_Downloads) }

/// Only Linux guests switch the file-system identity of the copying thread to the signed-in user.
pub fn act_as_session_user() {}

pub fn agent_data_dir() -> PathBuf {
    PathBuf::from(std::env::var("ProgramData").unwrap_or_else(|_| r"C:\ProgramData".into())).join("Tandem")
}

pub fn message_box(title: &str, text: &str) {
    let wide = |s: &str| s.encode_utf16().chain(std::iter::once(0)).collect::<Vec<u16>>();
    let (t, m) = (wide(title), wide(text));
    unsafe { MessageBoxW(std::ptr::null_mut(), m.as_ptr(), t.as_ptr(), MB_OK | MB_ICONWARNING); }
}

/// Puts "Mac (Tandem)" in Explorer's Send to menu, pointing at this program. Once per user.
pub fn install_send_to() {
    let Ok(appdata) = std::env::var("APPDATA") else { return };
    let link = PathBuf::from(appdata).join(r"Microsoft\Windows\SendTo").join(SEND_TO_NAME);
    let Ok(exe) = std::env::current_exe() else { return };
    // An agent that updated itself runs from the same path, so an existing shortcut stays right.
    if link.exists() { return; }
    let script = format!(
        "$s = (New-Object -ComObject WScript.Shell).CreateShortcut('{}'); $s.TargetPath = '{}'; $s.Arguments = 'send-to-mac'; \
         $s.Description = 'Copy to the Mac''s Downloads folder'; $s.IconLocation = '{},0'; $s.Save()",
        link.display().to_string().replace('\'', "''"), exe.display().to_string().replace('\'', "''"), exe.display().to_string().replace('\'', "''"));
    let ok = Command::new("powershell").args(["-NoProfile", "-NonInteractive", "-Command", &script])
        .creation_flags(CREATE_NO_WINDOW).status().map(|s| s.success()).unwrap_or(false);
    crate::log_local(if ok { "added “Mac (Tandem)” to Explorer's Send to menu" } else { "could not add the Send to menu entry" });
}
