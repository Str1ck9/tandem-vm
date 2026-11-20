//! Everything that differs between guest operating systems.
#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
pub use linux::*;

#[cfg(windows)]
mod windows;
#[cfg(windows)]
pub use windows::*;

// The agent inside a macOS guest (built with `--features macos-guest`).
#[cfg(all(target_os = "macos", feature = "macos-guest"))]
mod macos;
#[cfg(all(target_os = "macos", feature = "macos-guest"))]
pub use macos::*;

// What the macOS agent reads from system tools; always built, so the host's `cargo test` checks it.
#[cfg_attr(not(all(target_os = "macos", feature = "macos-guest")), allow(dead_code))]
pub mod macos_text;

// Development builds on the Mac: enough to compile and run the unit tests.
#[cfg(not(any(target_os = "linux", windows, all(target_os = "macos", feature = "macos-guest"))))]
mod stub;
#[cfg(not(any(target_os = "linux", windows, all(target_os = "macos", feature = "macos-guest"))))]
pub use stub::*;

#[derive(Debug)]
#[cfg_attr(all(target_os = "macos", feature = "macos-guest"), allow(dead_code))]
pub enum DisplayError {
    /// No way to change resolution here (no display server, or the mode does not exist).
    Unsupported,
    Failed(String),
}

#[derive(Debug, Default)]
pub struct GuestInfo {
    pub hostname: String,
    pub os_name: String,
    pub os_version: String,
    pub kernel: String,
    pub ip_addresses: Vec<String>,
    /// The guest's time zone in seconds east of UTC, where the host needs it (Windows).
    pub utc_offset_secs: Option<i32>,
}

impl GuestInfo {
    pub fn to_json(&self) -> String {
        let ips: Vec<String> = self.ip_addresses.iter().map(|ip| json_string(ip)).collect();
        let zone = self.utc_offset_secs.map(|s| format!(",\"utcOffsetSeconds\":{s}")).unwrap_or_default();
        format!(
            "{{\"hostname\":{},\"osName\":{},\"osVersion\":{},\"kernel\":{},\"ipAddresses\":[{}]{}}}",
            json_string(&self.hostname), json_string(&self.os_name), json_string(&self.os_version),
            json_string(&self.kernel), ips.join(","), zone
        )
    }
}

/// One top-level window of the guest's desktop, in physical pixels of the guest screen.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct GuestWindow {
    pub id: u64,
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
    pub pid: u32,
    /// "app" (a window to work in: program windows and dialogs), "popup" (menus, tool tips) or "taskbar".
    pub kind: &'static str,
    /// "normal", "minimized" or "maximized".
    pub state: &'static str,
    pub active: bool,
    pub title: String,
    pub class: String,
    /// File name of the program that owns the window, for example `notepad.exe`.
    pub app: String,
}

/// The guest's desktop size and its windows, front-most first.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct WindowList {
    pub desktop: (i32, i32),
    pub windows: Vec<GuestWindow>,
    /// The window the user is moving or resizing right now, as it was when that began.
    pub moving: Option<MoveStart>,
}

/// A move or resize of a window by the user: the window's frame and the pointer when it began.
/// The host moves its own window with the pointer from these, instead of waiting for each report.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MoveStart {
    pub id: u64,
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
    pub pointer_x: i32,
    pub pointer_y: i32,
    /// The edge or corner grabbed, for a resize ("left", "bottomRight", …); None for a move.
    pub edge: Option<&'static str>,
}

/// The edge a window frame hit-test result (`WM_NCHITTEST`) stands for; None for the title bar and
/// anything that is not a sizing border.
#[cfg_attr(not(windows), allow(dead_code))]
pub fn sizing_edge(hit: isize) -> Option<&'static str> {
    match hit {
        10 => Some("left"), 11 => Some("right"), 12 => Some("top"), 13 => Some("topLeft"),
        14 => Some("topRight"), 15 => Some("bottom"), 16 => Some("bottomLeft"), 17 => Some("bottomRight"),
        _ => None,
    }
}

impl WindowList {
    pub fn to_json(&self) -> String {
        let windows: Vec<String> = self.windows.iter().map(|w| format!(
            "{{\"id\":{},\"x\":{},\"y\":{},\"width\":{},\"height\":{},\"pid\":{},\"kind\":\"{}\",\"state\":\"{}\",\"active\":{},\"title\":{},\"class\":{},\"app\":{}}}",
            w.id, w.x, w.y, w.width, w.height, w.pid, w.kind, w.state, w.active,
            json_string(&w.title), json_string(&w.class), json_string(&w.app))).collect();
        let moving = self.moving.map(|m| format!(
            ",\"moving\":{{\"id\":{},\"x\":{},\"y\":{},\"width\":{},\"height\":{},\"pointerX\":{},\"pointerY\":{}{}}}",
            m.id, m.x, m.y, m.width, m.height, m.pointer_x, m.pointer_y,
            m.edge.map(|e| format!(",\"edge\":\"{e}\"")).unwrap_or_default())).unwrap_or_default();
        format!("{{\"desktop\":[{},{}],\"windows\":[{}]{}}}", self.desktop.0, self.desktop.1, windows.join(","), moving)
    }
}

/// A program the guest's user can start, as listed in its Start menu.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct GuestProgram {
    pub name: String,
    /// What starts it: opaque to the host, which hands it back in `PROGRAM_LAUNCH`.
    pub id: String,
}

/// What the host needs to make a Mac-side launcher for a program: where its program file is (empty
/// for store apps) and the file name extensions it opens, each with its leading dot.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct ProgramInfo {
    pub target: String,
    pub extensions: Vec<String>,
    /// A picture file with the program's icon at a large size (store apps keep theirs as PNG files).
    /// Not part of the JSON: the agent sends the file's bytes alongside.
    pub logo: String,
}

impl ProgramInfo {
    pub fn to_json(&self, id: &str) -> String {
        let extensions: Vec<String> = self.extensions.iter().map(|e| json_string(e)).collect();
        format!("{{\"id\":{},\"target\":{},\"extensions\":[{}]}}", json_string(id), json_string(&self.target), extensions.join(","))
    }

    /// Reads "target<TAB>path" and "ext<TAB>.txt" lines. Extensions are lower-cased, checked and sorted.
    #[cfg_attr(not(windows), allow(dead_code))]
    pub fn parse(text: &str) -> ProgramInfo {
        let mut info = ProgramInfo::default();
        for line in text.lines() {
            let Some((kind, value)) = line.trim_end_matches('\r').trim_start_matches('\u{feff}').split_once('\t') else { continue };
            let value = value.trim();
            match kind {
                "target" => info.target = value.to_string(),
                "logo" => info.logo = value.to_string(),
                "ext" => {
                    let ext = value.to_lowercase();
                    let ok = ext.len() >= 2 && ext.len() <= 16 && ext.starts_with('.')
                        && ext[1..].chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == '+');
                    if ok && !info.extensions.contains(&ext) { info.extensions.push(ext); }
                }
                _ => {}
            }
        }
        info.extensions.sort();
        info.extensions.truncate(300);
        info
    }
}

/// The guest path of a shared document: `root` is where the shares are (`Z:` or a UNC path), `relative`
/// is `<share>/<path>` as the host names it. Refuses anything that would leave the shares.
#[cfg_attr(not(windows), allow(dead_code))]
pub fn shared_document_path(root: &str, relative: &str) -> Option<String> {
    let parts: Vec<&str> = relative.split('/').filter(|p| !p.is_empty()).collect();
    if parts.len() < 2 { return None; }
    if parts.iter().any(|p| *p == "." || *p == ".." || p.contains('\\') || p.contains(':') || p.contains('"')) { return None; }
    Some(format!("{}\\{}", root.trim_end_matches('\\'), parts.join("\\")))
}

/// Steps handed from the agent, which runs with the administrator's rights, to a copy of itself that
/// runs with the user's normal rights (a program must not inherit the agent's elevation).
/// One step per line: `check<TAB>path` waits for a file to be reachable; `open<TAB>target<TAB>parameters`
/// starts a program.
#[derive(Debug, Clone, PartialEq)]
pub enum LaunchStep {
    Check(String),
    Open { target: String, parameters: String },
}

#[cfg_attr(not(windows), allow(dead_code))]
pub fn encode_launch_steps(steps: &[LaunchStep]) -> String {
    steps.iter().map(|s| match s {
        LaunchStep::Check(path) => format!("check\t{path}\n"),
        LaunchStep::Open { target, parameters } => format!("open\t{target}\t{parameters}\n"),
    }).collect()
}

#[cfg_attr(not(windows), allow(dead_code))]
pub fn parse_launch_steps(text: &str) -> Vec<LaunchStep> {
    text.lines().filter_map(|line| {
        let mut fields = line.trim_end_matches('\r').splitn(3, '\t');
        match (fields.next()?, fields.next(), fields.next()) {
            ("check", Some(path), None) if !path.is_empty() => Some(LaunchStep::Check(path.to_string())),
            ("open", Some(target), parameters) if !target.is_empty() =>
                Some(LaunchStep::Open { target: target.to_string(), parameters: parameters.unwrap_or("").to_string() }),
            _ => None,
        }
    }).collect()
}

#[cfg(test)]
mod document_tests {
    use super::*;

    #[test]
    fn program_info_lines_and_json() {
        let info = ProgramInfo::parse("\u{feff}target\tC:\\Program Files\\X\\x.exe\r\next\t.TXT\r\next\t.txt\next\tnodot\next\t.a b\next\t.log\n");
        assert_eq!(info.target, r"C:\Program Files\X\x.exe");
        assert_eq!(info.extensions, vec![".log", ".txt"]);
        assert_eq!(info.to_json("a!b"), r#"{"id":"a!b","target":"C:\\Program Files\\X\\x.exe","extensions":[".log",".txt"]}"#);
    }

    #[test]
    fn shared_paths_stay_inside_the_shares() {
        assert_eq!(shared_document_path("Z:", "Home/notes/a b.txt").as_deref(), Some(r"Z:\Home\notes\a b.txt"));
        assert_eq!(shared_document_path(r"\\10.0.2.2@47000\DavWWWRoot\", "Home/a.txt").as_deref(), Some(r"\\10.0.2.2@47000\DavWWWRoot\Home\a.txt"));
        assert_eq!(shared_document_path("Z:", "Home/../secret.txt"), None);
        assert_eq!(shared_document_path("Z:", "Home"), None, "a share alone is not a document");
        assert_eq!(shared_document_path("Z:", r"Home/a\..\b.txt"), None);
        assert_eq!(shared_document_path("Z:", "Home/C:evil"), None);
    }

    #[test]
    fn launch_steps_round_trip() {
        let steps = vec![LaunchStep::Check(r"Z:\Home\a.txt".into()),
                         LaunchStep::Open { target: r"shell:AppsFolder\X!App".into(), parameters: "\"Z:\\Home\\a.txt\"".into() },
                         LaunchStep::Open { target: "notepad.exe".into(), parameters: String::new() }];
        assert_eq!(parse_launch_steps(&encode_launch_steps(&steps)), steps);
        assert_eq!(parse_launch_steps("bogus\tx\nopen\t\n"), vec![]);
    }
}

pub fn programs_to_json(programs: &[GuestProgram]) -> String {
    let items: Vec<String> = programs.iter()
        .map(|p| format!("{{\"name\":{},\"id\":{}}}", json_string(&p.name), json_string(&p.id))).collect();
    format!("{{\"programs\":[{}]}}", items.join(","))
}

/// Reads "name<TAB>id" lines (what the Windows agent asks PowerShell's `Get-StartApps` for).
/// Leaves out documents and uninstallers, which the Start menu also lists; sorts by name.
#[cfg_attr(not(windows), allow(dead_code))]
pub fn parse_program_lines(text: &str) -> Vec<GuestProgram> {
    const NOT_PROGRAMS: [&str; 9] = [".url", ".chm", ".txt", ".htm", ".html", ".pdf", ".ini", ".rtf", ".md"];
    let mut programs: Vec<GuestProgram> = Vec::new();
    for line in text.lines() {
        let Some((name, id)) = line.trim_end_matches('\r').split_once('\t') else { continue };
        let (name, id) = (name.trim().trim_start_matches('\u{feff}'), id.trim());
        if name.is_empty() || id.is_empty() { continue; }
        let lower = id.to_lowercase();
        if NOT_PROGRAMS.iter().any(|ext| lower.ends_with(ext)) { continue; }
        if name.to_lowercase().contains("uninstall") { continue; }
        if programs.iter().any(|p| p.id == id) { continue; }
        programs.push(GuestProgram { name: name.to_string(), id: id.to_string() });
    }
    programs.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    programs
}

/// Gives an icon drawn without an alpha channel its opacity from the icon's mask.
/// Both are 32-bit BGRA rows; in the mask, black marks the icon's own pixels. Pixels outside become clear.
#[cfg_attr(not(windows), allow(dead_code))]
pub fn apply_icon_mask(pixels: &mut [u8], mask: &[u8]) {
    for (pixel, m) in pixels.chunks_exact_mut(4).zip(mask.chunks_exact(4)) {
        if m[0] == 0 && m[1] == 0 && m[2] == 0 { pixel[3] = 255 } else { pixel.copy_from_slice(&[0, 0, 0, 0]) }
    }
}

/// True when no pixel of a 32-bit BGRA picture has any opacity.
#[cfg_attr(not(windows), allow(dead_code))]
pub fn lacks_alpha(pixels: &[u8]) -> bool { pixels.chunks_exact(4).all(|p| p[3] == 0) }

#[cfg(test)]
mod program_tests {
    use super::*;

    #[test]
    fn program_lines_are_filtered_sorted_and_deduplicated() {
        let text = "\u{feff}Notepad\tMicrosoft.WindowsNotepad_8wekyb3d8bbwe!App\r\nCalculator\tMicrosoft.WindowsCalculator_8wekyb3d8bbwe!App\r\n\
Read Me\t{6D809377-6AF0-444B-8957-A3773F02200E}\\Tool\\readme.HTML\r\nUninstall Tool\t{6D80}\\Tool\\unins000.exe\r\n\
broken line\r\n\tno name\r\nalpha tool\tC:\\Tools\\alpha.exe\r\nNotepad again\tMicrosoft.WindowsNotepad_8wekyb3d8bbwe!App\r\n";
        let programs = parse_program_lines(text);
        assert_eq!(programs.iter().map(|p| p.name.as_str()).collect::<Vec<_>>(), ["alpha tool", "Calculator", "Notepad"]);
        assert_eq!(programs[2].id, "Microsoft.WindowsNotepad_8wekyb3d8bbwe!App");
    }

    #[test]
    fn program_list_json_escapes_backslashes() {
        let json = programs_to_json(&[GuestProgram { name: "a \"b\"".into(), id: r"C:\x\y.lnk".into() }]);
        assert_eq!(json, r#"{"programs":[{"name":"a \"b\"","id":"C:\\x\\y.lnk"}]}"#);
    }

    #[test]
    fn icon_mask_gives_opacity() {
        // Two pixels: the first belongs to the icon (black in the mask), the second does not.
        let mut pixels = vec![10, 20, 30, 0, 40, 50, 60, 0];
        assert!(lacks_alpha(&pixels));
        apply_icon_mask(&mut pixels, &[0, 0, 0, 0, 255, 255, 255, 0]);
        assert_eq!(pixels, [10, 20, 30, 255, 0, 0, 0, 0]);
        assert!(!lacks_alpha(&pixels));
    }
}

#[cfg(test)]
mod window_tests {
    use super::*;

    #[test]
    fn window_list_json_escapes_titles() {
        let list = WindowList { desktop: (1920, 1080), windows: vec![GuestWindow {
            id: 0x1_0000_0002, x: -8, y: 0, width: 800, height: 600, pid: 42, kind: "app", state: "normal",
            active: true, title: "a \"b\"".into(), class: "Notepad".into(), app: "notepad.exe".into() }], moving: None };
        assert_eq!(list.to_json(), r#"{"desktop":[1920,1080],"windows":[{"id":4294967298,"x":-8,"y":0,"width":800,"height":600,"pid":42,"kind":"app","state":"normal","active":true,"title":"a \"b\"","class":"Notepad","app":"notepad.exe"}]}"#);
    }

    #[test]
    fn window_list_json_names_the_window_being_moved() {
        let list = WindowList { desktop: (100, 50), windows: vec![], moving: Some(MoveStart {
            id: 7, x: 10, y: 20, width: 300, height: 200, pointer_x: 150, pointer_y: 30, edge: None }) };
        assert_eq!(list.to_json(), r#"{"desktop":[100,50],"windows":[],"moving":{"id":7,"x":10,"y":20,"width":300,"height":200,"pointerX":150,"pointerY":30}}"#);
        let resize = WindowList { desktop: (100, 50), windows: vec![], moving: Some(MoveStart {
            id: 7, x: 10, y: 20, width: 300, height: 200, pointer_x: 310, pointer_y: 220, edge: sizing_edge(17) }) };
        assert!(resize.to_json().ends_with(r#""pointerY":220,"edge":"bottomRight"}}"#));
        assert_eq!(sizing_edge(2), None, "the title bar is a move");
        assert_eq!(sizing_edge(10), Some("left"));
    }
}

pub fn json_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// The address the guest uses to reach the outside, found without sending anything:
/// connecting a UDP socket only selects a route.
pub fn primary_ip() -> Option<String> {
    let socket = std::net::UdpSocket::bind("0.0.0.0:0").ok()?;
    socket.connect("192.0.2.1:9").ok()?; // TEST-NET-1, never routed
    let ip = socket.local_addr().ok()?.ip();
    if ip.is_unspecified() || ip.is_loopback() { None } else { Some(ip.to_string()) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_escaping() {
        assert_eq!(json_string("a\"b\\c\n\u{1}é"), "\"a\\\"b\\\\c\\n\\u0001é\"");
        let info = GuestInfo { hostname: "h".into(), os_name: "Alpine \"Linux\"".into(), os_version: "3".into(),
                               kernel: "6".into(), ip_addresses: vec!["10.0.2.15".into(), "fe80::1".into()], utc_offset_secs: None };
        assert_eq!(info.to_json(),
            "{\"hostname\":\"h\",\"osName\":\"Alpine \\\"Linux\\\"\",\"osVersion\":\"3\",\"kernel\":\"6\",\"ipAddresses\":[\"10.0.2.15\",\"fe80::1\"]}");
        let zoned = GuestInfo { utc_offset_secs: Some(-21600), ..Default::default() };
        assert!(zoned.to_json().ends_with("\"ipAddresses\":[],\"utcOffsetSeconds\":-21600}"));
    }
}

/// Common display sizes, largest first. Some display drivers (the 3D one in particular) offer only a fixed
/// table of sizes and do not list them, so these are tried when the asked-for size is refused.
#[cfg_attr(not(windows), allow(dead_code))]
const COMMON_MODES: [(u32, u32); 15] = [
    (3840, 2160), (2560, 1600), (2560, 1440), (1920, 1200), (1920, 1080), (1680, 1050), (1600, 1200), (1600, 900),
    (1440, 900), (1366, 768), (1280, 1024), (1280, 800), (1280, 720), (1024, 768), (800, 600),
];

/// The sizes worth trying instead of `width`x`height`: what the driver lists plus the common ones, that fit
/// inside the asked-for size, best first (closest shape, then largest).
#[cfg_attr(not(windows), allow(dead_code))]
pub fn fallback_modes(width: u32, height: u32, listed: &[(u32, u32)]) -> Vec<(u32, u32)> {
    let mut all: Vec<(u32, u32)> = listed.iter().copied().chain(COMMON_MODES.iter().copied())
        .filter(|&(w, h)| w <= width && h <= height && (w, h) != (width, height)).collect();
    all.sort();
    all.dedup();
    let wanted = width as f64 / height.max(1) as f64;
    all.sort_by(|a, b| {
        let shape = |m: &(u32, u32)| ((m.0 as f64 / m.1 as f64) - wanted).abs() > 0.05;
        shape(a).cmp(&shape(b)).then((b.0 * b.1).cmp(&(a.0 * a.1)))
    });
    all
}


#[cfg(test)]
mod fallback_mode_tests {
    use super::fallback_modes;

    #[test]
    fn retina_size_falls_back_to_largest_mode_of_a_similar_shape() {
        // A 16:10 Mac window asking for 3024x1890: 2560x1600 first, then 1920x1200, 1680x1050, 1440x900, 1280x800.
        let modes = fallback_modes(3024, 1890, &[]);
        assert_eq!(&modes[..5], &[(2560, 1600), (1920, 1200), (1680, 1050), (1440, 900), (1280, 800)]);
    }

    #[test]
    fn only_sizes_that_fit_and_listed_modes_count_too() {
        let modes = fallback_modes(1512, 870, &[(1500, 860)]);
        assert!(modes.iter().all(|&(w, h)| w <= 1512 && h <= 870));
        assert!(modes.contains(&(1500, 860)));
        assert!(!modes.contains(&(1512, 870)), "the refused size itself is not retried");
        assert_eq!(fallback_modes(640, 480, &[]), Vec::<(u32, u32)>::new());
    }
}
