use super::{DisplayError, GuestInfo};
use std::io::Write;
use std::process::{Command, Stdio};

pub const OS_ID: u32 = link_proto::os::LINUX;

fn read_trimmed(path: &str) -> String { std::fs::read_to_string(path).unwrap_or_default().trim().to_string() }

fn os_release(key: &str) -> String {
    for line in std::fs::read_to_string("/etc/os-release").unwrap_or_default().lines() {
        if let Some(value) = line.strip_prefix(key).and_then(|rest| rest.strip_prefix('=')) {
            return value.trim_matches('"').to_string();
        }
    }
    String::new()
}

pub fn guest_info() -> GuestInfo {
    GuestInfo {
        hostname: read_trimmed("/proc/sys/kernel/hostname"),
        os_name: os_release("NAME"),
        os_version: os_release("VERSION_ID"),
        kernel: read_trimmed("/proc/sys/kernel/osrelease"),
        ip_addresses: super::primary_ip().into_iter().collect(),
        utc_offset_secs: None,
    }
}

pub fn set_time(secs: i64, nanos: u32) -> Result<(), String> {
    let ts = libc::timespec { tv_sec: secs as _, tv_nsec: nanos as _ };
    if unsafe { libc::clock_settime(libc::CLOCK_REALTIME, &ts) } == 0 { Ok(()) }
    else { Err(std::io::Error::last_os_error().to_string()) }
}

fn have(tool: &str) -> bool {
    std::env::var_os("PATH").map(|paths| std::env::split_paths(&paths).any(|dir| dir.join(tool).is_file())).unwrap_or(false)
}

#[derive(Clone, Copy)]
enum ClipboardTool { Wayland, X11 }

const SESSION_KEYS: [&str; 4] = ["DISPLAY", "XAUTHORITY", "WAYLAND_DISPLAY", "XDG_RUNTIME_DIR"];

/// The display variables of the graphical session. The agent's own when it was started inside one;
/// otherwise (a system service running as root) those of a desktop process, preferring a signed-in
/// user's over the login screen's. Looked up at most every 15 s.
fn session_env() -> Vec<(String, String)> {
    static CACHE: std::sync::Mutex<Option<(std::time::Instant, Vec<(String, String)>)>> = std::sync::Mutex::new(None);
    let own: Vec<(String, String)> = SESSION_KEYS.iter().filter_map(|k| std::env::var(k).ok().map(|v| (k.to_string(), v))).collect();
    if own.iter().any(|(k, _)| k == "DISPLAY" || k == "WAYLAND_DISPLAY") { return own; }
    let mut cache = CACHE.lock().unwrap();
    if let Some((at, env)) = cache.as_ref() {
        if at.elapsed() < std::time::Duration::from_secs(15) { return env.clone(); }
    }
    let found = find_session_env().unwrap_or_default();
    *cache = Some((std::time::Instant::now(), found.clone()));
    found
}

fn find_session_env() -> Option<Vec<(String, String)>> {
    use std::os::unix::fs::MetadataExt;
    let mut best: Option<(u32, Vec<(String, String)>)> = None;
    for entry in std::fs::read_dir("/proc").ok()?.flatten() {
        let name = entry.file_name();
        if !name.to_string_lossy().chars().all(|c| c.is_ascii_digit()) { continue; }
        let uid = match entry.metadata() { Ok(m) => m.uid(), Err(_) => continue };
        if uid == 0 || best.as_ref().map(|(b, _)| *b >= 1000).unwrap_or(false) { continue; }
        let Ok(raw) = std::fs::read(entry.path().join("environ")) else { continue };
        let env = parse_environ(&raw);
        if env.iter().any(|(k, _)| k == "DISPLAY" || k == "WAYLAND_DISPLAY") && best.as_ref().map(|(b, _)| uid > *b).unwrap_or(true) {
            best = Some((uid, env));
        }
    }
    best.map(|(_, env)| env)
}

pub(crate) fn parse_environ(raw: &[u8]) -> Vec<(String, String)> {
    raw.split(|b| *b == 0).filter_map(|item| {
        let text = std::str::from_utf8(item).ok()?;
        let (key, value) = text.split_once('=')?;
        SESSION_KEYS.contains(&key).then(|| (key.to_string(), value.to_string()))
    }).collect()
}

fn session_has(key: &str) -> bool { session_env().iter().any(|(k, _)| k == key) }

/// A command that talks to the graphical session.
fn session_command(tool: &str) -> Command {
    let mut command = Command::new(tool);
    command.envs(session_env());
    command
}

/// A clipboard exists only inside a graphical session with a helper tool installed.
fn clipboard_tool() -> Option<ClipboardTool> {
    if session_has("WAYLAND_DISPLAY") && have("wl-copy") && have("wl-paste") { return Some(ClipboardTool::Wayland); }
    if session_has("DISPLAY") && have("xclip") { return Some(ClipboardTool::X11); }
    None
}

pub fn clipboard_available() -> bool { clipboard_tool().is_some() }

pub fn clipboard_get() -> Option<String> {
    if CLIPBOARD_PAUSED.load(std::sync::atomic::Ordering::SeqCst) { return None; }
    let output = match clipboard_tool()? {
        ClipboardTool::Wayland => session_command("wl-paste").args(["--no-newline", "--type", "text/plain"]).stderr(Stdio::null()).output(),
        ClipboardTool::X11 => session_command("xclip").args(["-selection", "clipboard", "-o"]).stderr(Stdio::null()).output(),
    }.ok()?;
    if !output.status.success() { return None; }
    String::from_utf8(output.stdout).ok()
}

pub fn clipboard_set(text: &str) -> Result<(), String> {
    let mut command = match clipboard_tool().ok_or("no clipboard tool in this session")? {
        ClipboardTool::Wayland => session_command("wl-copy"),
        ClipboardTool::X11 => { let mut c = session_command("xclip"); c.args(["-selection", "clipboard", "-i"]); c }
    };
    let mut child = command.stdin(Stdio::piped()).stdout(Stdio::null()).stderr(Stdio::null()).spawn().map_err(|e| e.to_string())?;
    child.stdin.take().ok_or("no stdin")?.write_all(text.as_bytes()).map_err(|e| e.to_string())?;
    child.wait().map_err(|e| e.to_string()).and_then(|s| if s.success() { Ok(()) } else { Err(format!("clipboard tool exited with {s}")) })
}

pub fn display_resize_available() -> bool { session_has("DISPLAY") && have("xrandr") }

/// First connected output and its current mode, from `xrandr --current`.
fn xrandr_state() -> Option<(String, u32, u32)> {
    let out = session_command("xrandr").arg("--current").stderr(Stdio::null()).output().ok()?;
    let text = String::from_utf8_lossy(&out.stdout).to_string();
    parse_xrandr(&text)
}

pub(crate) fn parse_xrandr(text: &str) -> Option<(String, u32, u32)> {
    let mut output: Option<String> = None;
    for line in text.lines() {
        if line.contains(" connected") {
            output = line.split_whitespace().next().map(str::to_string);
        } else if line.starts_with(' ') && line.contains('*') {
            let mode = line.split_whitespace().next()?;
            let (w, h) = mode.split_once('x')?;
            let h: String = h.chars().take_while(|c| c.is_ascii_digit()).collect();
            return Some((output?, w.parse().ok()?, h.parse().ok()?));
        }
    }
    None
}

pub fn current_resolution() -> Option<(u32, u32)> {
    if !display_resize_available() { return None; }
    xrandr_state().map(|(_, w, h)| (w, h))
}

pub fn set_resolution(width: u32, height: u32) -> Result<(), DisplayError> {
    if !display_resize_available() { return Err(DisplayError::Unsupported); }
    let (output, _, _) = xrandr_state().ok_or(DisplayError::Unsupported)?;
    let status = session_command("xrandr").args(["--output", &output, "--mode", &format!("{width}x{height}")])
        .stderr(Stdio::null()).status().map_err(|e| DisplayError::Failed(e.to_string()))?;
    if status.success() { return Ok(()); }
    // The mode is not in the driver's list (a window of any size on the Mac, or Seamless Mode's desktop):
    // make one with the standard reduced-blanking timings, offer it to the output and use it.
    let name = format!("{width}x{height}_tandem");
    let modeline = super::linux_text::cvt_reduced_blanking(width, height, 60.0);
    let _ = session_command("xrandr").arg("--newmode").arg(&name).args(modeline.xrandr_arguments()).stderr(Stdio::null()).status();
    let _ = session_command("xrandr").args(["--addmode", &output, &name]).stderr(Stdio::null()).status();
    let status = session_command("xrandr").args(["--output", &output, "--mode", &name]).stderr(Stdio::null()).status()
        .map_err(|e| DisplayError::Failed(e.to_string()))?;
    if status.success() { Ok(()) } else { Err(DisplayError::Unsupported) }
}

pub fn shutdown(restart: bool) -> Result<(), String> {
    let action = if restart { "reboot" } else { "poweroff" };
    for (tool, args) in [("systemctl", &[action][..]), (action, &[][..])] {
        if have(tool) {
            return Command::new(tool).args(args).status().map_err(|e| e.to_string())
                .and_then(|s| if s.success() { Ok(()) } else { Err(format!("{tool} exited with {s}")) });
        }
    }
    Err(format!("no {action} command found"))
}

// MARK: Shared folders
//
// The Mac folders arrive as virtio devices: one 9p device per folder on the QEMU engine (tags tandem0,
// tandem1, … in the order of the host's list), or one virtiofs device holding them all on the VZ engine
// (tag "tandem"). Mounting needs root, so only an agent installed as a system service offers this.

pub(crate) const SHARE_ROOT: &str = "/media/mac";

pub fn shared_folders_available() -> bool { (unsafe { libc::geteuid() }) == 0 }

/// Mount points under `SHARE_ROOT` with their file system type, from /proc/mounts.
fn share_mounts() -> Vec<(String, String)> {
    parse_mounts(&std::fs::read_to_string("/proc/mounts").unwrap_or_default())
}

pub(crate) fn parse_mounts(table: &str) -> Vec<(String, String)> {
    table.lines().filter_map(|line| {
        let mut fields = line.split_whitespace();
        let point = fields.nth(1)?.replace("\\040", " ");
        let kind = fields.next()?.to_string();
        (point == SHARE_ROOT || point.starts_with(&format!("{SHARE_ROOT}/"))).then_some((point, kind))
    }).collect()
}

/// A share name as a single path component.
pub(crate) fn mount_name(name: &str) -> String {
    let cleaned: String = name.chars().map(|c| if c == '/' || c == '\0' { '_' } else { c }).collect();
    if cleaned.is_empty() || cleaned == "." || cleaned == ".." { "_".into() } else { cleaned }
}

fn run(tool: &str, args: &[&str]) -> Result<(), String> {
    let output = Command::new(tool).args(args).output().map_err(|e| format!("{tool}: {e}"))?;
    if output.status.success() { Ok(()) } else { Err(format!("{tool} {}: {}", args.join(" "), String::from_utf8_lossy(&output.stderr).trim())) }
}

pub fn apply_shares(shares: &crate::shares::Shares) -> Result<String, String> {
    let wanted: Vec<(String, String)> = match shares.kind.as_str() {
        "9p" => shares.names.iter().enumerate().map(|(i, n)| (format!("tandem{i}"), format!("{SHARE_ROOT}/{}", mount_name(n)))).collect(),
        "virtiofs" if !shares.names.is_empty() => vec![("tandem".into(), SHARE_ROOT.into())],
        "virtiofs" => vec![],
        other => return Err(format!("this host shares folders over {other}, which this agent cannot mount")),
    };
    let fs_type = if shares.kind == "9p" { "9p" } else { "virtiofs" };
    let mounted = share_mounts();
    // Longest paths first, so a folder is released before the one that contains it.
    let mut stale: Vec<&(String, String)> = mounted.iter().filter(|(point, _)| !wanted.iter().any(|(_, w)| w == point)).collect();
    stale.sort_by_key(|(point, _)| std::cmp::Reverse(point.len()));
    for (point, _) in stale {
        run("umount", &[point])?;
        let _ = std::fs::remove_dir(point);
    }
    if wanted.is_empty() {
        let _ = std::fs::remove_dir(SHARE_ROOT);
        return Ok("no folders are shared".into());
    }
    if fs_type == "9p" { let _ = run("modprobe", &["9pnet_virtio"]); } else { let _ = run("modprobe", &["virtiofs"]); }
    let mut failures = Vec::new();
    for (tag, point) in &wanted {
        if mounted.iter().any(|(p, _)| p == point) { continue; }
        if let Err(e) = std::fs::create_dir_all(point) { failures.push(format!("{point}: {e}")); continue; }
        let result = if fs_type == "9p" {
            run("mount", &["-t", "9p", "-o", "trans=virtio,version=9p2000.L,msize=262144", tag, point])
        } else {
            run("mount", &["-t", "virtiofs", tag, point])
        };
        if let Err(e) = result { failures.push(e); }
    }
    if failures.is_empty() { Ok(format!("shared folders ready under {SHARE_ROOT} ({} shared)", shares.names.join(", "))) }
    else { Err(failures.join("; ")) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn xrandr_parsing() {
        let text = "Screen 0: minimum 320 x 200, current 1280 x 800, maximum 8192 x 8192\n\
Virtual-1 connected primary 1280x800+0+0 0mm x 0mm\n\
   1024x768      60.00 +  59.95\n\
   1280x800      59.81*\n\
   1920x1080     60.00\n\
Virtual-2 disconnected\n";
        assert_eq!(parse_xrandr(text), Some(("Virtual-1".to_string(), 1280, 800)));
        assert_eq!(parse_xrandr("Screen 0\n"), None);
    }

    #[test]
    fn mount_table_and_names() {
        let table = "/dev/vda2 / ext4 rw 0 0\ntandem0 /media/mac/Home 9p rw 0 0\ntandem1 /media/mac/My\\040Files 9p ro 0 0\ntmpfs /media/machine tmpfs rw 0 0\n";
        assert_eq!(parse_mounts(table), vec![("/media/mac/Home".to_string(), "9p".to_string()), ("/media/mac/My Files".to_string(), "9p".to_string())]);
        assert_eq!(mount_name("a/b"), "a_b");
        assert_eq!(mount_name(".."), "_");
    }

    #[test]
    fn session_variables_from_environ() {
        let raw = b"HOME=/home/k\0DISPLAY=:0\0XAUTHORITY=/home/k/.Xauthority\0PATH=/bin\0";
        assert_eq!(parse_environ(raw), vec![("DISPLAY".to_string(), ":0".to_string()), ("XAUTHORITY".to_string(), "/home/k/.Xauthority".to_string())]);
    }
}


/// Nothing to tidy up on this platform.
pub fn startup() {}

// MARK: Guest windows (from the X server; see linux_x11.rs)

pub fn windows_available() -> bool { super::linux_x11::windows_available() }
pub fn list_windows() -> super::WindowList { super::linux_x11::list_windows() }
pub fn window_action(id: u64, action: u32) -> Result<(), String> { super::linux_x11::window_action(id, action) }
pub fn window_events_start() { super::linux_x11::window_events_start() }
pub fn window_change_count() -> u64 { super::linux_x11::window_change_count() }
pub fn wait_window_change(seen: u64, timeout: std::time::Duration) { super::linux_x11::wait_window_change(seen, timeout) }
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

// MARK: Guest programs and icons (from the desktop's .desktop files; see linux_desktop.rs)

pub fn programs_available() -> bool { super::linux_desktop::programs_available() }
pub fn list_programs() -> Vec<super::GuestProgram> { super::linux_desktop::list_programs() }
pub fn launch_program(id: &str) -> Result<(), String> { super::linux_desktop::launch_program(id) }
pub fn window_icon(id: u64, size: u32) -> Option<Vec<u8>> { super::linux_x11::window_icon(id, size) }
pub fn program_icon(id: &str, size: u32) -> Option<Vec<u8>> { super::linux_desktop::program_icon(id, size) }

// MARK: Opening shared documents

pub fn documents_available() -> bool { programs_available() && shared_folders_available() }
pub fn program_info(id: &str) -> super::ProgramInfo { super::linux_desktop::program_info(id) }
pub fn open_documents(program: &str, documents: &[String]) -> Result<(), (u32, String)> {
    super::linux_desktop::open_documents(program, documents)
}
pub fn run_requests() {}

// MARK: Activity
//
// What a Linux guest can say about being in use (see `activity.rs`): processor time from /proc, input
// idle time where an X session and `xprintidle` are there, and whoever holds a "block" inhibitor for
// sleep or idle with systemd.

pub fn activity_available() -> bool { true }

pub fn input_idle_seconds() -> Option<u64> {
    if !have("xprintidle") { return None; }
    let output = session_command("xprintidle").stderr(Stdio::null()).output().ok()?;
    if !output.status.success() { return None; }
    String::from_utf8_lossy(&output.stdout).trim().parse::<u64>().ok().map(|ms| ms / 1000)
}

/// Busy and total processor time over all cores since boot, from the first line of /proc/stat.
pub fn cpu_times() -> Option<(u64, u64)> {
    let text = std::fs::read_to_string("/proc/stat").ok()?;
    crate::activity::parse_proc_stat(&text)
}

pub fn power_requests() -> Vec<String> {
    if !have("systemd-inhibit") { return Vec::new(); }
    let Ok(output) = Command::new("systemd-inhibit").args(["--list", "--no-legend", "--no-pager"]).stderr(Stdio::null()).output() else { return Vec::new() };
    crate::activity::parse_inhibitors(&String::from_utf8_lossy(&output.stdout))
}

/// One folder for every user of the guest; the agent itself runs as root.
pub fn keep_awake_dir() -> std::path::PathBuf { std::path::PathBuf::from("/run/tandem-keep-awake") }

pub fn open_to_everyone(dir: &std::path::Path) {
    use std::os::unix::fs::PermissionsExt;
    let _ = std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o1777));
}

pub fn pid_alive(pid: u32) -> bool { std::path::Path::new(&format!("/proc/{pid}")).exists() }

// MARK: Files dropped from the Mac, and files sent to it

/// Needs the shares' server on the Mac (reached through the guest's network), a root agent that can write
/// as the user, and an X session to find the folder under the pointer in.
pub fn file_drop_available() -> bool { (unsafe { libc::geteuid() }) == 0 && super::linux_x11::windows_available() }
pub fn drop_target_folder(x: i32, y: i32) -> Option<std::path::PathBuf> { super::linux_x11::drop_target_folder(x, y) }
pub fn fallback_drop_folder() -> Option<std::path::PathBuf> { super::linux_x11::fallback_drop_folder() }
pub fn act_as_session_user() { super::linux_x11::act_as_session_user() }
pub fn selected_files_at(x: i32, y: i32) -> Result<Vec<String>, String> { super::linux_x11::selected_files_at(x, y) }
pub fn agent_data_dir() -> std::path::PathBuf { std::path::PathBuf::from("/var/lib/tandem") }

/// While the files of a drag-out are read through the clipboard, the clipboard is not forwarded to the Mac.
static CLIPBOARD_PAUSED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
pub(crate) fn set_clipboard_paused(paused: bool) { CLIPBOARD_PAUSED.store(paused, std::sync::atomic::Ordering::SeqCst) }

/// Shows a message to the person at the desktop; the agent runs "Send to Mac" as that person, so the
/// session's display is in its environment.
pub fn message_box(title: &str, text: &str) {
    eprintln!("{title}: {text}");
    for (tool, args) in [("zenity", vec!["--error", "--no-markup", "--title", title, "--text", text]),
                         ("kdialog", vec!["--title", title, "--error", text]),
                         ("notify-send", vec![title, text]),
                         ("xmessage", vec!["-center", text])] {
        if have(tool) && Command::new(tool).args(&args).status().map(|s| s.success()).unwrap_or(false) { return; }
    }
}

/// Adds "Send to Mac (Tandem)" to the file managers of every person's account: a script for the
/// Nautilus and Caja Scripts menus, an action for Nemo, Thunar and PCManFM.
pub fn install_send_to() {
    use std::os::unix::fs::{chown, PermissionsExt};
    if (unsafe { libc::geteuid() }) != 0 { return; }
    let agent = std::env::current_exe().ok().map(|p| p.to_string_lossy().into_owned()).unwrap_or_else(|| "/usr/local/bin/tandem-agent".into());
    let accounts = super::linux_text::parse_passwd(&std::fs::read_to_string("/etc/passwd").unwrap_or_default());
    for account in accounts.iter().filter(|a| super::linux_text::is_person(a, a.home.is_dir())) {
        let write = |path: std::path::PathBuf, content: &str, executable: bool| {
            if std::fs::read_to_string(&path).map(|old| old == content).unwrap_or(false) { return; }
            // Folders made on the way belong to the person too.
            let mut made = Vec::new();
            let mut dir = path.parent().map(std::path::Path::to_path_buf);
            while let Some(d) = dir.filter(|d| !d.exists() && d.starts_with(&account.home)) { made.push(d.clone()); dir = d.parent().map(std::path::Path::to_path_buf); }
            if std::fs::create_dir_all(path.parent().unwrap_or(&account.home)).is_err() { return; }
            for d in &made { let _ = chown(d, Some(account.uid), Some(account.gid)); }
            if std::fs::write(&path, content).is_err() { return; }
            let _ = chown(&path, Some(account.uid), Some(account.gid));
            if executable { let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)); }
        };
        let name = super::linux_text::SEND_TO_NAME;
        if have("nautilus") { write(account.home.join(".local/share/nautilus/scripts").join(name), &super::linux_text::send_to_script(&agent), true); }
        if have("caja") { write(account.home.join(".config/caja/scripts").join(name), &super::linux_text::send_to_script(&agent), true); }
        if have("nemo") { write(account.home.join(".local/share/nemo/actions/tandem-send-to-mac.nemo_action"), &super::linux_text::nemo_action(&agent), false); }
        if have("pcmanfm") || have("pcmanfm-qt") {
            write(account.home.join(".local/share/file-manager/actions/tandem-send-to-mac.desktop"), &super::linux_text::libfm_action(&agent), false);
        }
        if have("thunar") {
            let path = account.home.join(".config/Thunar/uca.xml");
            let existing = std::fs::read_to_string(&path).ok();
            if let Some(merged) = super::linux_text::merge_thunar_uca(existing.as_deref(), &agent) { write(path, &merged, false); }
        }
    }
}

/// Nothing to refresh: a file manager lists a folder's files by itself.
pub fn folder_changed(_folder: &std::path::Path) {}
