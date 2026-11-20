//! Running a command for the host (`EXEC_REQUEST` → `EXEC_RESULT`, PROTOCOL.md "guest commands").
//!
//! Linux: `/bin/sh -c` as root (the agent's own service account), or as another user through `su`.
//! Windows: by default as the signed-in user without administrator rights, through a one-off scheduled
//! task whose output goes to files in the user's temporary folder; with the `ELEVATED` flag, directly
//! from the agent, which runs with the rights the user's logon task gives it.
//! The host decides whether a command may be sent at all (the VM's sharing settings); this side runs it.

use link_proto::client::Client;
use link_proto::frame::Buffer;
use link_proto::{exec_flags, exec_status, op};
use std::io::Read;
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

#[derive(Debug, PartialEq)]
pub struct ExecRequest {
    pub command: String,
    pub user: Option<String>,
    pub timeout: Duration,
    pub max_output: usize,
    pub elevated: bool,
}

#[derive(Debug, Default, PartialEq)]
pub struct ExecOutcome {
    pub status: u32,
    pub exit_code: i32,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
    pub stdout_truncated: bool,
    pub stderr_truncated: bool,
    pub message: String,
}

impl ExecOutcome {
    pub fn failed(status: u32, message: impl Into<String>) -> Self {
        ExecOutcome { status, exit_code: -1, message: message.into(), ..Default::default() }
    }
}

const MAX_OUTPUT: usize = 4 << 20;
const MAX_TIMEOUT: u64 = 3600;

/// Reads `{"command":…,"user":…,"timeout":…,"maxOutput":…}`. Parsed by hand: the agent has no JSON library.
pub fn parse(json: &str, flags: u32) -> Option<ExecRequest> {
    let command = string_field(json, "command")?;
    if command.trim().is_empty() { return None; }
    let timeout = number_field(json, "timeout").unwrap_or(60).clamp(1, MAX_TIMEOUT);
    let max_output = (number_field(json, "maxOutput").unwrap_or(1 << 20) as usize).clamp(1024, MAX_OUTPUT);
    Some(ExecRequest {
        command,
        user: string_field(json, "user").filter(|u| !u.is_empty()),
        timeout: Duration::from_secs(timeout),
        max_output,
        elevated: flags & exec_flags::ELEVATED != 0,
    })
}

/// The value of a top-level string field, with JSON escapes undone.
fn string_field(json: &str, key: &str) -> Option<String> {
    let at = json.find(&format!("\"{key}\""))? + key.len() + 2;
    let rest = json[at..].trim_start().strip_prefix(':')?.trim_start().strip_prefix('"')?;
    let mut out = String::new();
    let mut chars = rest.chars();
    loop {
        match chars.next()? {
            '"' => return Some(out),
            '\\' => match chars.next()? {
                'n' => out.push('\n'),
                't' => out.push('\t'),
                'r' => out.push('\r'),
                'b' => out.push('\u{8}'),
                'f' => out.push('\u{c}'),
                'u' => {
                    let hex: String = chars.by_ref().take(4).collect();
                    let unit = u32::from_str_radix(&hex, 16).ok()?;
                    if (0xD800..0xDC00).contains(&unit) {
                        // A surrogate pair: the low half follows as another \uXXXX.
                        if chars.next()? != '\\' || chars.next()? != 'u' { return None; }
                        let low_hex: String = chars.by_ref().take(4).collect();
                        let low = u32::from_str_radix(&low_hex, 16).ok()?;
                        // Not a low surrogate: refused (it used to subtract below zero and panic).
                        if !(0xDC00..0xE000).contains(&low) { return None; }
                        out.push(char::from_u32(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00))?);
                    } else {
                        out.push(char::from_u32(unit)?);
                    }
                }
                other => out.push(other),
            },
            c => out.push(c),
        }
    }
}

fn number_field(json: &str, key: &str) -> Option<u64> {
    let at = json.find(&format!("\"{key}\""))? + key.len() + 2;
    let rest = json[at..].trim_start().strip_prefix(':')?.trim_start();
    let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
    digits.parse().ok()
}

/// Runs the request and sends its `EXEC_RESULT`. Call on a thread of its own.
pub fn run_and_report(client: &Client, request_id: u32, data: &[u8], flags: u32) {
    let outcome = match std::str::from_utf8(data).ok().and_then(|json| parse(json, flags)) {
        Some(request) => run(&request),
        None => ExecOutcome::failed(exec_status::FAILED_TO_START, "the request could not be read"),
    };
    let mut inline = Vec::with_capacity(16);
    inline.extend_from_slice(&request_id.to_le_bytes());
    inline.extend_from_slice(&outcome.exit_code.to_le_bytes());
    inline.extend_from_slice(&outcome.status.to_le_bytes());
    let mut result_flags = 0u32;
    if outcome.stdout_truncated { result_flags |= exec_flags::STDOUT_TRUNCATED; }
    if outcome.stderr_truncated { result_flags |= exec_flags::STDERR_TRUNCATED; }
    inline.extend_from_slice(&result_flags.to_le_bytes());
    let buffers = vec![Buffer::input(&outcome.stdout), Buffer::input(&outcome.stderr), Buffer::input(outcome.message.as_bytes())];
    let _ = client.call(op::EXEC_RESULT, inline, buffers, Some(Duration::from_secs(30)));
}

pub fn run(request: &ExecRequest) -> ExecOutcome {
    run_platform(request)
}

/// The guest tools offer to run commands on Linux and Windows. (The Mac development build could, but it
/// never talks to a host.)
pub fn available() -> bool { cfg!(any(target_os = "linux", windows, all(target_os = "macos", feature = "macos-guest"))) }

// MARK: Linux (and the Mac development build)

#[cfg(unix)]
fn run_platform(request: &ExecRequest) -> ExecOutcome {
    let mut command = match &request.user {
        // macOS's su has no -s; the agent runs as root there, so sudo asks for no password.
        #[cfg(target_os = "macos")]
        Some(user) => { let mut c = Command::new("/usr/bin/sudo"); c.args(["-n", "-H", "-u", user, "/bin/sh", "-c", &request.command]); c }
        // `su -s /bin/sh -c <command> <user>` works with both util-linux and BusyBox.
        #[cfg(not(target_os = "macos"))]
        Some(user) => { let mut c = Command::new("su"); c.args(["-s", "/bin/sh", "-c", &request.command, user]); c }
        None => { let mut c = Command::new("/bin/sh"); c.args(["-c", &request.command]); c }
    };
    command.current_dir("/");
    match piped(command).spawn() {
        Ok(child) => collect(child, request.timeout, request.max_output),
        Err(e) => ExecOutcome::failed(exec_status::FAILED_TO_START, e.to_string()),
    }
}

// MARK: Windows

#[cfg(windows)]
fn run_platform(request: &ExecRequest) -> ExecOutcome {
    if request.elevated { windows::elevated(request) } else { windows::as_signed_in_user(request) }
}

#[cfg(windows)]
mod windows {
    use super::*;
    use std::os::windows::process::CommandExt;

    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    /// Each schtasks call (create, run, end, delete) gets this long: a wedged Task Scheduler must not
    /// outlast the command's own deadline.
    const SCHTASKS_DEADLINE: Duration = Duration::from_secs(30);

    /// Directly from the agent, which has the rights its logon task gives it (administrator when the
    /// user is one).
    pub fn elevated(request: &ExecRequest) -> ExecOutcome {
        let mut command = Command::new("cmd.exe");
        // raw_arg: cmd parses what follows /c itself, so it must reach it unquoted.
        command.raw_arg(format!("/d /s /c \"{}\"", request.command)).creation_flags(CREATE_NO_WINDOW);
        if let Ok(home) = std::env::var("USERPROFILE") { command.current_dir(home); }
        match piped(command).spawn() {
            Ok(child) => collect(child, request.timeout, request.max_output),
            Err(e) => ExecOutcome::failed(exec_status::FAILED_TO_START, e.to_string()),
        }
    }

    /// Runs schtasks, giving up (and stopping it) after `SCHTASKS_DEADLINE`.
    fn schtasks(args: &[&str]) -> bool {
        let Ok(mut child) = Command::new("schtasks").args(args).creation_flags(CREATE_NO_WINDOW)
            .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn() else { return false };
        let deadline = Instant::now() + SCHTASKS_DEADLINE;
        loop {
            match child.try_wait() {
                Ok(Some(status)) => return status.success(),
                Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(50)),
                _ => { let _ = child.kill(); let _ = child.wait(); return false; }
            }
        }
    }

    /// The one-off task and its spool folder, removed on every way out of `as_signed_in_user`.
    struct Spool { dir: std::path::PathBuf, task: Option<String> }
    impl Drop for Spool {
        fn drop(&mut self) {
            if let Some(task) = &self.task { schtasks(&["/delete", "/tn", task, "/f"]); }
            let _ = std::fs::remove_dir_all(&self.dir);
        }
    }

    /// As the signed-in user without administrator rights: a one-off scheduled task with the limited run
    /// level, writing its output to files the agent then reads. (The agent runs elevated when the user is
    /// an administrator, and a process cannot simply drop those rights for a child.)
    pub fn as_signed_in_user(request: &ExecRequest) -> ExecOutcome {
        let user = std::env::var("USERNAME").unwrap_or_default();
        if user.is_empty() { return ExecOutcome::failed(exec_status::FAILED_TO_START, "no signed-in user is known"); }
        let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
        let id = format!("{}-{}", std::process::id(), nanos);
        let dir = std::env::temp_dir().join(format!("tandem-exec-{id}"));
        if let Err(e) = std::fs::create_dir_all(&dir) { return ExecOutcome::failed(exec_status::FAILED_TO_START, e.to_string()); }
        let mut spool = Spool { dir: dir.clone(), task: None };
        let path = |name: &str| dir.join(name).to_string_lossy().into_owned();
        // The exit code is written to a temporary name and moved when complete, so a half-written file is never read.
        let script = format!(
            "@echo off\r\ncd /d \"%USERPROFILE%\"\r\n( {} ) > \"{}\" 2> \"{}\"\r\necho %ERRORLEVEL%> \"{}\"\r\nmove /y \"{}\" \"{}\" >nul\r\n",
            request.command, path("out.txt"), path("err.txt"), path("code.tmp"), path("code.tmp"), path("code.txt"));
        if let Err(e) = std::fs::write(dir.join("run.cmd"), script) { return ExecOutcome::failed(exec_status::FAILED_TO_START, e.to_string()); }
        let task = format!("Tandem Command {id}");
        // conhost --headless: no console window flashes up on the user's screen (Windows 11).
        let action = format!("conhost.exe --headless cmd.exe /d /c \"{}\"", path("run.cmd"));
        let created = schtasks(&["/create", "/tn", &task, "/tr", &action, "/sc", "once", "/st", "00:00",
                                 "/ru", &user, "/it", "/rl", "limited", "/f"]);
        // Deleted on the way out even when only the create timed out (it may have gone through).
        spool.task = Some(task.clone());
        if !created || !schtasks(&["/run", "/tn", &task]) {
            return ExecOutcome::failed(exec_status::FAILED_TO_START, "the command could not be started as the signed-in user");
        }
        let deadline = Instant::now() + request.timeout;
        let code_file = dir.join("code.txt");
        let limit = spool_limit(request.max_output);
        loop {
            if code_file.exists() { return finish(&dir, request.max_output); }
            // The output goes to files the command writes itself: past the limit the command is stopped,
            // so it cannot fill the guest's disk.
            let written = file_len(&dir.join("out.txt")) + file_len(&dir.join("err.txt"));
            let over = written > limit;
            if over || Instant::now() >= deadline {
                schtasks(&["/end", "/tn", &task]);
                let mut outcome = finish(&dir, request.max_output);
                outcome.status = exec_status::TIMED_OUT;
                outcome.exit_code = -1;
                outcome.message = if over {
                    format!("stopped: its output passed {} MB", limit >> 20)
                } else {
                    format!("stopped after {} s", request.timeout.as_secs())
                };
                if over { outcome.stdout_truncated = true; }
                return outcome;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
    }

    fn file_len(path: &std::path::Path) -> u64 { std::fs::metadata(path).map(|m| m.len()).unwrap_or(0) }

    fn finish(dir: &std::path::Path, max: usize) -> ExecOutcome {
        let (stdout, stdout_truncated) = read_capped(&dir.join("out.txt"), max);
        let (stderr, stderr_truncated) = read_capped(&dir.join("err.txt"), max);
        let code = std::fs::read_to_string(dir.join("code.txt")).ok().and_then(|s| s.trim().parse().ok()).unwrap_or(-1);
        ExecOutcome { status: exec_status::COMPLETED, exit_code: code, stdout, stderr, stdout_truncated, stderr_truncated, message: String::new() }
    }
}

// MARK: Shared by the platforms

/// How long the output may take to end after the command itself has ended or been stopped. A process the
/// command left running in the background may keep its output open for good; past this grace the agent
/// stops reading and answers with what it has.
const DRAIN_GRACE: Duration = Duration::from_secs(2);

/// What a reader thread has kept of one stream so far.
#[derive(Default)]
struct Captured { data: Vec<u8>, truncated: bool, done: bool }
type SharedCapture = Arc<(Mutex<Captured>, Condvar)>;

/// The command's process tree: a process group on Unix (the child leads its own, see `piped`), a job
/// object on Windows. Stopped as a whole at the deadline, so nothing it started keeps running.
struct Tree {
    #[cfg(unix)]
    group: i32,
    #[cfg(windows)]
    job: Option<windows_job::Job>,
}

impl Tree {
    fn of(child: &Child) -> Tree {
        #[cfg(unix)]
        { Tree { group: child.id() as i32 } }
        #[cfg(windows)]
        { Tree { job: windows_job::Job::holding(child) } }
        #[cfg(not(any(unix, windows)))]
        { let _ = child; Tree {} }
    }

    fn stop(&self) {
        #[cfg(unix)]
        if self.group > 0 { unsafe { libc::kill(-self.group, libc::SIGKILL); } }
        #[cfg(windows)]
        if let Some(job) = &self.job { job.terminate(); }
    }
}

/// Waits for a child with piped output, keeping at most `max` bytes of each stream. At the deadline the
/// child and everything it started are stopped. The output is collected for at most `DRAIN_GRACE` after
/// the child has ended, so a background process holding the pipes cannot hold the answer back.
pub fn collect(mut child: Child, timeout: Duration, max: usize) -> ExecOutcome {
    let tree = Tree::of(&child);
    let stdout = child.stdout.take().map(|s| reader(s, max));
    let stderr = child.stderr.take().map(|s| reader(s, max));
    let deadline = Instant::now() + timeout;
    let mut timed_out = false;
    let code = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status.code().unwrap_or(-1),
            Ok(None) if Instant::now() >= deadline => {
                timed_out = true;
                tree.stop();
                let _ = child.kill();
                let _ = child.wait();
                break -1;
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(20)),
            Err(e) => {
                tree.stop();
                let _ = child.kill();
                return ExecOutcome::failed(exec_status::FAILED_TO_START, e.to_string());
            }
        }
    };
    let drain_until = Instant::now() + DRAIN_GRACE;
    let (stdout, stdout_truncated, out_done) = stdout.map(|c| take(&c, drain_until)).unwrap_or((Vec::new(), false, true));
    let (stderr, stderr_truncated, err_done) = stderr.map(|c| take(&c, drain_until)).unwrap_or((Vec::new(), false, true));
    let mut message = if timed_out { format!("stopped after {} s", timeout.as_secs()) } else { String::new() };
    if !(out_done && err_done) {
        if !message.is_empty() { message.push_str("; "); }
        message.push_str("a process the command left running still holds its output, which was not read to the end");
    }
    ExecOutcome {
        status: if timed_out { exec_status::TIMED_OUT } else { exec_status::COMPLETED },
        exit_code: code,
        stdout, stderr, stdout_truncated, stderr_truncated,
        message,
    }
}

/// Reads a stream to its end on a thread, keeping the first `max` bytes (the rest is read and dropped,
/// so the child never blocks on a full pipe).
fn reader<R: Read + Send + 'static>(mut stream: R, max: usize) -> SharedCapture {
    let shared: SharedCapture = Arc::new((Mutex::new(Captured::default()), Condvar::new()));
    let writer = shared.clone();
    std::thread::spawn(move || {
        let mut chunk = [0u8; 16384];
        loop {
            match stream.read(&mut chunk) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    let mut captured = writer.0.lock().unwrap_or_else(|e| e.into_inner());
                    let room = max.saturating_sub(captured.data.len());
                    if n > room { captured.truncated = true; }
                    captured.data.extend_from_slice(&chunk[..n.min(room)]);
                }
            }
        }
        writer.0.lock().unwrap_or_else(|e| e.into_inner()).done = true;
        writer.1.notify_all();
    });
    shared
}

/// What a reader has kept, once it has finished or `until` has passed: (data, truncated, finished).
fn take(shared: &SharedCapture, until: Instant) -> (Vec<u8>, bool, bool) {
    let mut captured = shared.0.lock().unwrap_or_else(|e| e.into_inner());
    while !captured.done {
        let now = Instant::now();
        if now >= until { break; }
        captured = shared.1.wait_timeout(captured, until - now).unwrap_or_else(|e| e.into_inner()).0;
    }
    (std::mem::take(&mut captured.data), captured.truncated, captured.done)
}

/// Reads at most `max` bytes of a file (Windows' unelevated path writes output to files): never more
/// than that is held in memory, however much the command wrote. One byte more says whether it was cut.
#[cfg_attr(not(windows), allow(dead_code))]
pub fn read_capped(path: &std::path::Path, max: usize) -> (Vec<u8>, bool) {
    let Ok(file) = std::fs::File::open(path) else { return (Vec::new(), false) };
    let mut data = Vec::new();
    let _ = file.take(max as u64 + 1).read_to_end(&mut data);
    if data.len() > max { data.truncate(max); (data, true) } else { (data, false) }
}

/// How much a command's spooled output may grow on the guest's disk before it is stopped.
#[cfg_attr(not(windows), allow(dead_code))]
pub fn spool_limit(max_output: usize) -> u64 { (max_output as u64).saturating_mul(4).max(64 << 20) }

/// A command with piped output, in a process tree of its own (on Unix, a process group it leads).
pub fn piped(mut command: Command) -> Command {
    command.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
    #[cfg(unix)]
    { use std::os::unix::process::CommandExt; command.process_group(0); }
    command
}

#[cfg(windows)]
mod windows_job {
    use std::os::windows::io::AsRawHandle;
    use std::process::Child;
    use windows_sys::Win32::Foundation::{CloseHandle, HANDLE};
    use windows_sys::Win32::System::JobObjects::{AssignProcessToJobObject, CreateJobObjectW, TerminateJobObject};

    /// A job object holding the command and, from then on, every process it starts. Not
    /// kill-on-close: a program the command started on purpose (`start notepad`) keeps running when
    /// the command ends normally; only the deadline stops the whole job.
    pub struct Job(HANDLE);
    unsafe impl Send for Job {}
    unsafe impl Sync for Job {}

    impl Job {
        /// The child is put in the job straight after it starts. (Anything it starts in the few
        /// instructions before that is not in it; cmd.exe starts nothing that early.)
        pub fn holding(child: &Child) -> Option<Job> {
            unsafe {
                let job = CreateJobObjectW(std::ptr::null(), std::ptr::null());
                if job.is_null() { return None; }
                if AssignProcessToJobObject(job, child.as_raw_handle() as HANDLE) == 0 {
                    CloseHandle(job);
                    return None;
                }
                Some(Job(job))
            }
        }

        pub fn terminate(&self) { unsafe { TerminateJobObject(self.0, 1); } }
    }

    impl Drop for Job {
        fn drop(&mut self) { unsafe { CloseHandle(self.0); } }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_the_request_with_escapes_and_limits() {
        let json = r#"{"command":"echo \"hi\" é\nls","maxOutput":99999999,"timeout":5,"user":"tester"}"#;
        let request = parse(json, exec_flags::ELEVATED).unwrap();
        assert_eq!(request.command, "echo \"hi\" é\nls");
        assert_eq!(request.user.as_deref(), Some("tester"));
        assert_eq!(request.timeout, Duration::from_secs(5));
        assert_eq!(request.max_output, MAX_OUTPUT);
        assert!(request.elevated);
        let plain = parse(r#"{"command":"true"}"#, 0).unwrap();
        assert_eq!(plain.timeout, Duration::from_secs(60));
        assert!(!plain.elevated);
        assert_eq!(plain.user, None);
        assert!(parse(r#"{"command":"  "}"#, 0).is_none());
        assert!(parse(r#"{"timeout":5}"#, 0).is_none());
    }

    #[test]
    fn surrogate_pairs_decode() {
        assert_eq!(string_field(r#"{"command":"😀"}"#, "command").as_deref(), Some("😀"));
    }

    #[cfg(unix)]
    #[test]
    fn collects_output_exit_code_and_truncation() {
        let child = piped({ let mut c = Command::new("/bin/sh"); c.args(["-c", "printf 'abcdef'; printf err >&2; exit 3"]); c }).spawn().unwrap();
        let outcome = collect(child, Duration::from_secs(5), 4);
        assert_eq!(outcome.status, exec_status::COMPLETED);
        assert_eq!(outcome.exit_code, 3);
        assert_eq!(outcome.stdout, b"abcd");
        assert!(outcome.stdout_truncated);
        assert_eq!(outcome.stderr, b"err");
        assert!(!outcome.stderr_truncated);
    }

    #[cfg(unix)]
    #[test]
    fn a_command_past_its_deadline_is_stopped() {
        let child = piped({ let mut c = Command::new("/bin/sh"); c.args(["-c", "sleep 5"]); c }).spawn().unwrap();
        let started = Instant::now();
        let outcome = collect(child, Duration::from_millis(300), 1024);
        assert_eq!(outcome.status, exec_status::TIMED_OUT);
        assert!(started.elapsed() < Duration::from_secs(3));
    }

    /// Review R11: `sleep 2 & wait` with a 100 ms timeout took 2,010 ms, because the background
    /// child kept the pipes open. The whole group is stopped now.
    #[cfg(unix)]
    #[test]
    fn a_timeout_stops_the_commands_background_children_too() {
        let dir = std::env::temp_dir().join(format!("tandem-exec-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let pid_file = dir.join("pid");
        let script = format!("sleep 30 & echo $! > '{}'; wait", pid_file.display());
        let child = piped({ let mut c = Command::new("/bin/sh"); c.args(["-c", &script]); c }).spawn().unwrap();
        let started = Instant::now();
        let outcome = collect(child, Duration::from_millis(300), 1024);
        assert_eq!(outcome.status, exec_status::TIMED_OUT);
        assert!(started.elapsed() < Duration::from_millis(1500), "answered after {:?}", started.elapsed());
        let pid: i32 = std::fs::read_to_string(&pid_file).unwrap().trim().parse().unwrap();
        std::thread::sleep(Duration::from_millis(200));
        let alive = unsafe { libc::kill(pid, 0) } == 0;
        if alive { unsafe { libc::kill(pid, libc::SIGKILL); } }
        let _ = std::fs::remove_dir_all(&dir);
        assert!(!alive, "the background sleep was stopped with the command");
    }

    /// A command that ends while a process it left behind still holds the output: the answer comes
    /// after the drain grace with the output so far, and that process is left alone (it was not timed out).
    #[cfg(unix)]
    #[test]
    fn output_held_open_by_a_leftover_process_does_not_hold_the_answer_back() {
        let script = "echo before; sleep 30 & echo $! >&2";
        let child = piped({ let mut c = Command::new("/bin/sh"); c.args(["-c", script]); c }).spawn().unwrap();
        let started = Instant::now();
        let outcome = collect(child, Duration::from_secs(20), 1024);
        let elapsed = started.elapsed();
        let pid: i32 = String::from_utf8_lossy(&outcome.stderr).trim().parse().unwrap_or(0);
        let alive = pid > 0 && unsafe { libc::kill(pid, 0) } == 0;
        if pid > 0 { unsafe { libc::kill(pid, libc::SIGKILL); } }
        assert_eq!(outcome.status, exec_status::COMPLETED);
        assert_eq!(outcome.exit_code, 0);
        assert_eq!(outcome.stdout, b"before\n");
        assert!(elapsed < DRAIN_GRACE + Duration::from_secs(1), "answered after {elapsed:?}");
        assert!(outcome.message.contains("still holds its output"), "{}", outcome.message);
        assert!(alive, "a program the command started on purpose keeps running");
    }

    /// Review R12: the spooled output is read up to the limit only.
    #[test]
    fn spooled_output_is_read_up_to_the_limit_only() {
        let path = std::env::temp_dir().join(format!("tandem-spool-test-{}", std::process::id()));
        std::fs::write(&path, vec![b'x'; 10_000]).unwrap();
        let (data, truncated) = read_capped(&path, 4096);
        assert_eq!(data.len(), 4096);
        assert!(truncated);
        let (all, cut) = read_capped(&path, 10_000);
        assert_eq!(all.len(), 10_000);
        assert!(!cut, "exactly the limit is not cut");
        let _ = std::fs::remove_file(&path);
        assert_eq!(read_capped(&path, 10), (Vec::new(), false), "a missing file reads as empty");
        assert_eq!(spool_limit(1 << 20), 64 << 20);
        assert_eq!(spool_limit(MAX_OUTPUT), 64 << 20);
        assert_eq!(spool_limit(usize::MAX), u64::MAX, "no overflow");
    }
}
