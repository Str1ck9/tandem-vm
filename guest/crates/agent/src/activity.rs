//! What the host needs to know before it suspends an idle VM: how long ago the guest last saw input,
//! how busy its processors are, and who asked for it to stay awake.
//!
//! Anything in the guest can ask: `tandem-agent keep-awake -- <command>` keeps the VM awake while the
//! command runs; `tandem-agent keep-awake --on [reason]` until `tandem-agent keep-awake --off`.
//! Each request is a small file in a folder the agent reads; one that names a process is forgotten
//! when that process is gone. Programs that ask the guest's own system to stay awake (a video player,
//! a backup) count too, where the system lets the agent see them.

use crate::platform;
use std::path::PathBuf;
use std::sync::Mutex;

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Activity {
    /// Seconds since the guest's user last pressed a key or moved the pointer, where that is known.
    pub idle_seconds: Option<u64>,
    /// Processor use over all cores since the last report, 0–100.
    pub cpu_percent: Option<f32>,
    /// Who wants the VM to stay awake, in words for the user.
    pub keep_awake: Vec<String>,
}

impl Activity {
    pub fn to_json(&self) -> String {
        let mut fields: Vec<String> = Vec::new();
        if let Some(idle) = self.idle_seconds { fields.push(format!("\"idleSeconds\":{idle}")); }
        if let Some(cpu) = self.cpu_percent { fields.push(format!("\"cpuPercent\":{:.1}", cpu.clamp(0.0, 100.0))); }
        let reasons: Vec<String> = self.keep_awake.iter().map(|r| platform::json_string(r)).collect();
        fields.push(format!("\"keepAwake\":[{}]", reasons.join(",")));
        format!("{{{}}}", fields.join(","))
    }
}

/// Busy and total processor time at the last report, to turn the running totals into a share.
static LAST_CPU: Mutex<Option<(u64, u64)>> = Mutex::new(None);

fn cpu_percent(now: Option<(u64, u64)>, last: Option<(u64, u64)>) -> Option<f32> {
    let ((busy, total), (last_busy, last_total)) = (now?, last?);
    let (busy, total) = (busy.checked_sub(last_busy)?, total.checked_sub(last_total)?);
    if total == 0 { return None; }
    Some((busy as f32 / total as f32 * 100.0).clamp(0.0, 100.0))
}

/// The guest's activity now. The first call has no processor figure: it needs two readings.
pub fn current() -> Activity {
    let now = platform::cpu_times();
    let last = std::mem::replace(&mut *LAST_CPU.lock().unwrap(), now);
    let mut keep_awake = markers();
    for request in platform::power_requests() {
        if !keep_awake.contains(&request) { keep_awake.push(request); }
    }
    keep_awake.truncate(12);
    Activity { idle_seconds: platform::input_idle_seconds(), cpu_percent: cpu_percent(now, last), keep_awake }
}

// MARK: Keep-awake requests left as files

fn marker_dir() -> PathBuf { platform::keep_awake_dir() }

/// One line of text for the user, from a marker file's content.
fn reason_from(text: &str, fallback: &str) -> String {
    let line = text.lines().next().unwrap_or("").trim();
    let cleaned: String = line.chars().filter(|c| !c.is_control()).take(80).collect();
    if cleaned.is_empty() { fallback.to_string() } else { cleaned }
}

/// The start of a marker file. Any user of the guest may put one in the folder, while the agent reading
/// it runs as root: so only a plain file is read, never through a link (which could point at
/// /etc/shadow), at most 4 KB, and without waiting (a named pipe would block the agent for good).
pub fn read_marker(path: &std::path::Path) -> String {
    use std::io::Read;
    let Ok(meta) = std::fs::symlink_metadata(path) else { return String::new() };
    if !meta.file_type().is_file() { return String::new(); }
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    let Ok(file) = options.open(path) else { return String::new() };
    // Swapped for something else between the two looks: still only a plain file.
    if !file.metadata().map(|m| m.is_file()).unwrap_or(false) { return String::new(); }
    let mut bytes = Vec::new();
    let _ = file.take(4096).read_to_end(&mut bytes);
    String::from_utf8_lossy(&bytes).into_owned()
}

/// The requests in force. A file named after a process id belongs to that process and is removed
/// once the process is gone, so a job that crashed does not keep the VM awake for ever.
pub fn markers() -> Vec<String> {
    let mut reasons = Vec::new();
    let Ok(entries) = std::fs::read_dir(marker_dir()) else { return reasons };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().map(|e| e != "txt").unwrap_or(true) { continue; }
        let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or("").to_string();
        if let Ok(pid) = stem.parse::<u32>() {
            if !platform::pid_alive(pid) { let _ = std::fs::remove_file(&path); continue; }
        }
        let text = read_marker(&path);
        let reason = reason_from(&text, "a keep-awake request");
        if !reasons.contains(&reason) { reasons.push(reason); }
    }
    reasons.sort();
    reasons
}

/// `tandem-agent keep-awake …`. Returns the exit code.
///
///   keep-awake [--reason TEXT] -- COMMAND [ARGS…]   keep the VM awake while the command runs
///   keep-awake --on [TEXT]                          keep it awake until `--off`
///   keep-awake --off
pub fn command_line(args: &[String]) -> i32 {
    let dir = marker_dir();
    if std::fs::create_dir_all(&dir).is_err() { eprintln!("tandem-agent: cannot use {}", dir.display()); return 2; }
    platform::open_to_everyone(&dir);
    let manual = dir.join("manual.txt");
    match args.first().map(String::as_str) {
        Some("--off") => { let _ = std::fs::remove_file(manual); 0 }
        Some("--on") => {
            let reason = if args.len() > 1 { args[1..].join(" ") } else { "Keep awake was switched on inside the VM".to_string() };
            if std::fs::write(&manual, reason).is_ok() { 0 } else { 2 }
        }
        _ => {
            let Some(split) = args.iter().position(|a| a == "--") else {
                eprintln!("usage: tandem-agent keep-awake [--reason TEXT] -- COMMAND [ARGS…] | --on [TEXT] | --off");
                return 2;
            };
            let (options, command) = (&args[..split], &args[split + 1..]);
            let Some(program) = command.first() else { eprintln!("tandem-agent: keep-awake needs a command after --"); return 2 };
            let reason = options.iter().position(|a| a == "--reason").and_then(|i| options.get(i + 1)).cloned()
                .unwrap_or_else(|| format!("{program} is running"));
            let marker = dir.join(format!("{}.txt", std::process::id()));
            if std::fs::write(&marker, reason).is_err() { eprintln!("tandem-agent: cannot write {}", marker.display()); return 2; }
            let status = std::process::Command::new(program).args(&command[1..]).status();
            let _ = std::fs::remove_file(&marker);
            match status {
                Ok(status) => status.code().unwrap_or(1),
                Err(e) => { eprintln!("tandem-agent: cannot run {program}: {e}"); 127 }
            }
        }
    }
}

/// Names of what holds a power request, from Windows' `powercfg /requests`:
///
/// ```text
/// SYSTEM:
/// [PROCESS] \Device\HarddiskVolume3\Program Files\Player\player.exe
/// Playing video
/// ```
///
/// Sections that only concern speed (`PERFBOOST`) or the lock screen are left out.
#[cfg_attr(not(windows), allow(dead_code))]
pub fn parse_power_requests(text: &str) -> Vec<String> {
    let mut reasons: Vec<String> = Vec::new();
    let mut counts = false;
    let mut lines = text.lines().map(|l| l.trim_end_matches('\r')).peekable();
    while let Some(line) = lines.next() {
        let trimmed = line.trim();
        if trimmed.ends_with(':') && !trimmed.starts_with('[') && trimmed.chars().all(|c| c.is_ascii_uppercase() || c == ':') {
            counts = matches!(trimmed, "DISPLAY:" | "SYSTEM:" | "AWAYMODE:" | "EXECUTION:");
            continue;
        }
        if !counts || !trimmed.starts_with('[') { continue; }
        let Some(close) = trimmed.find(']') else { continue };
        let holder = trimmed[close + 1..].trim();
        // Of a program's path, the file name is what a person recognises. A driver is named in words.
        let is_path = holder.starts_with('\\') || holder.contains(":\\");
        let name = if is_path { holder.rsplit('\\').next().unwrap_or(holder).trim() } else { holder };
        let name = if name.is_empty() { trimmed[1..close].to_lowercase() } else { name.to_string() };
        // The next line, when it is not another entry or a blank, says why.
        let why = lines.peek().map(|l| l.trim()).filter(|l| !l.is_empty() && !l.starts_with('[') && !l.ends_with(':')).map(str::to_string);
        let reason = match why { Some(why) => format!("{name} ({why})"), None => name };
        let reason: String = reason.chars().filter(|c| !c.is_control()).take(120).collect();
        if !reasons.contains(&reason) { reasons.push(reason); }
    }
    reasons
}

/// Busy and total processor time from the first line of Linux's /proc/stat.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub fn parse_proc_stat(text: &str) -> Option<(u64, u64)> {
    let line = text.lines().find(|l| l.starts_with("cpu "))?;
    let fields: Vec<u64> = line.split_whitespace().skip(1).filter_map(|f| f.parse().ok()).collect();
    if fields.len() < 4 { return None; }
    let total: u64 = fields.iter().take(8).sum();
    // Fields 4 and 5 are idle and waiting for a disk.
    let idle = fields[3] + fields.get(4).copied().unwrap_or(0);
    Some((total.saturating_sub(idle), total))
}

/// Columns: WHO UID USER PID COMM WHAT WHY MODE, two or more spaces apart. Only what blocks sleep or
/// idle counts; "delay" inhibitors are held by half the system all the time.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub fn parse_inhibitors(text: &str) -> Vec<String> {
    let mut reasons: Vec<String> = Vec::new();
    for line in text.lines() {
        let columns: Vec<&str> = line.split("  ").map(str::trim).filter(|c| !c.is_empty()).collect();
        if columns.len() < 5 || columns[columns.len() - 1] != "block" { continue; }
        let what = columns[columns.len() - 3];
        if !what.split(':').any(|w| w == "sleep" || w == "idle") { continue; }
        let reason = format!("{} ({})", columns[0], columns[columns.len() - 2]);
        if !reasons.contains(&reason) { reasons.push(reason); }
    }
    reasons
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    #[test]
    fn markers_are_read_as_plain_files_only() {
        let dir = std::env::temp_dir().join(format!("tandem-marker-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let plain = dir.join("1.txt");
        std::fs::write(&plain, "Backing up\nsecond line").unwrap();
        assert_eq!(read_marker(&plain), "Backing up\nsecond line");
        // A link to a file the user could not read themselves is not followed.
        let secret = dir.join("secret");
        std::fs::write(&secret, "root:$6$hash").unwrap();
        let link = dir.join("2.txt");
        std::os::unix::fs::symlink(&secret, &link).unwrap();
        assert_eq!(read_marker(&link), "");
        // A named pipe would block for ever: refused without waiting.
        let fifo = dir.join("3.txt");
        let name = std::ffi::CString::new(fifo.to_str().unwrap()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
        assert_eq!(read_marker(&fifo), "");
        // Huge files: only the start.
        let big = dir.join("4.txt");
        std::fs::write(&big, vec![b'x'; 1 << 20]).unwrap();
        assert_eq!(read_marker(&big).len(), 4096);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn activity_json() {
        let a = Activity { idle_seconds: Some(125), cpu_percent: Some(3.26), keep_awake: vec!["a \"job\"".into()] };
        assert_eq!(a.to_json(), r#"{"idleSeconds":125,"cpuPercent":3.3,"keepAwake":["a \"job\""]}"#);
        assert_eq!(Activity::default().to_json(), r#"{"keepAwake":[]}"#);
    }

    #[test]
    fn cpu_share_needs_two_readings() {
        assert_eq!(cpu_percent(Some((10, 100)), None), None);
        assert_eq!(cpu_percent(Some((35, 200)), Some((10, 100))), Some(25.0));
        assert_eq!(cpu_percent(Some((5, 200)), Some((10, 100))), None, "a counter that went back is not a reading");
        assert_eq!(cpu_percent(Some((10, 100)), Some((10, 100))), None);
    }

    #[test]
    fn marker_text_becomes_one_clean_line() {
        assert_eq!(reason_from("Nightly backup\nsecond line", "x"), "Nightly backup");
        assert_eq!(reason_from("  \n", "a keep-awake request"), "a keep-awake request");
        assert_eq!(reason_from(&"a".repeat(200), "x").len(), 80);
    }

    #[test]
    fn power_requests_are_read_from_the_sections_that_keep_the_system_up() {
        let text = "DISPLAY:\r\n[PROCESS] \\Device\\HarddiskVolume3\\Program Files\\Player\\player.exe\r\nPlaying video\r\n\r\n\
SYSTEM:\r\n[DRIVER] High Definition Audio Device (HDAUDIO\\FUNC_01)\r\nAn audio stream is currently in use.\r\n\
[PROCESS] \\Device\\HarddiskVolume3\\Windows\\System32\\backup.exe\r\n\r\n\
AWAYMODE:\r\nNone.\r\n\r\nEXECUTION:\r\nNone.\r\n\r\nPERFBOOST:\r\n[PROCESS] \\Device\\x\\boost.exe\r\n\r\nACTIVELOCKSCREEN:\r\nNone.\r\n";
        assert_eq!(parse_power_requests(text), vec![
            "player.exe (Playing video)".to_string(),
            "High Definition Audio Device (HDAUDIO\\FUNC_01) (An audio stream is currently in use.)".to_string(),
            "backup.exe".to_string(),
        ]);
        assert_eq!(parse_power_requests("DISPLAY:\nNone.\n\nSYSTEM:\nNone.\n"), Vec::<String>::new());
    }

    #[test]
    fn proc_stat_first_line() {
        let text = "cpu  100 0 50 800 50 0 0 0 0 0\ncpu0 1 2 3 4\n";
        assert_eq!(parse_proc_stat(text), Some((150, 1000)));
        assert_eq!(parse_proc_stat("intr 1 2 3\n"), None);
    }

    #[test]
    fn only_blocking_sleep_or_idle_inhibitors_count() {
        let text = "ModemManager    0  root  812  ModemManager   sleep        ModemManager needs to reset devices  delay\n\
GNOME Shell   1000  kali 1500  gnome-shell    sleep:idle   Playing video                        block\n\
Backup tool   1000  kali 1700  backup         shutdown     Writing                              block\n";
        assert_eq!(parse_inhibitors(text), vec!["GNOME Shell (Playing video)".to_string()]);
    }
}
