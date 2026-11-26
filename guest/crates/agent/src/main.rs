//! Tandem guest agent: one process hosting every guest integration.
//! It opens the channel to the host, says HELLO, then serves host events until the stream ends,
//! and reconnects forever.
// A background agent: no console window at logon on Windows.
#![cfg_attr(windows, windows_subsystem = "windows")]

mod activity;
mod filedrop;
mod exec;
mod platform;
mod shares;
mod timeconv;
mod update;
#[cfg(test)]
mod fuzz_tests;

use link_proto::client::{Client, LinkError};
use link_proto::frame::Buffer;
use link_proto::{capability, event, icon_kind, op, status, transport, MAX_CLIPBOARD_BYTES, PROTOCOL_VERSION};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub const AGENT_VERSION: &str = env!("CARGO_PKG_VERSION");
const CALL_TIMEOUT: Option<Duration> = Some(Duration::from_secs(10));
/// Step the clock only when it is off by more than this.
const TIME_STEP_THRESHOLD_MS: i64 = 500;
/// A wait for a host event that goes unanswered this long means the host forgot the session.
const EVENT_TIMEOUT: Option<Duration> = Some(Duration::from_secs(15));

/// Local log. On Windows the agent has no console, so it appends to `%ProgramData%\Tandem\agent.log`
/// (kept small: the file is restarted when it passes 256 KiB).
pub(crate) fn log_local(message: &str) {
    eprintln!("tandem-agent: {message}");
    #[cfg(windows)]
    {
        use std::io::Write;
        let dir = std::path::PathBuf::from(std::env::var("ProgramData").unwrap_or_else(|_| r"C:\ProgramData".into())).join("Tandem");
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("agent.log");
        if std::fs::metadata(&path).map(|m| m.len() > 256 * 1024).unwrap_or(false) { let _ = std::fs::remove_file(&path); }
        if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(&path) {
            let seconds = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
            let _ = writeln!(file, "{seconds} {message}");
        }
    }
}

/// Logs locally and, when connected, to the host's per-VM log.
fn log(client: &Client, level: u32, message: &str) {
    log_local(message);
    let _ = client.call(op::LOG, level.to_le_bytes().to_vec(), vec![Buffer::input(message.as_bytes())], CALL_TIMEOUT);
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--version") {
        println!("tandem-agent {AGENT_VERSION}");
        return;
    }
    // Started by the "Tandem Launcher" task with the user's normal rights: start what the agent asked for.
    if args.iter().any(|a| a == "--run-requests") {
        platform::run_requests();
        return;
    }
    // `tandem-agent keep-awake …`: run by anything in the guest that wants the VM to stay awake.
    if args.get(1).map(String::as_str) == Some("keep-awake") {
        std::process::exit(activity::command_line(&args[2..]));
    }
    // `tandem-agent send-to-mac <files…>`: Explorer's Send to > Mac (Tandem).
    if args.get(1).map(String::as_str) == Some("send-to-mac") {
        std::process::exit(filedrop::send_to_mac(&args[2..]));
    }
    let once = args.iter().any(|a| a == "--once");
    log_local(&format!("version {AGENT_VERSION} starting"));
    update::clean_up();
    platform::startup();
    platform::install_send_to();
    loop {
        match transport::connect() {
            Ok(connection) => {
                log_local(&format!("connected over {}", connection.description));
                let client = Client::new(connection);
                match run_session(&client) {
                    Ok(()) => log_local("session ended"),
                    Err(e) => log_local(&format!("session failed: {e}")),
                }
            }
            Err(e) => log_local(&format!("no channel to the host yet: {e}")),
        }
        if once { return; }
        std::thread::sleep(Duration::from_secs(2));
    }
}

fn capabilities() -> u32 {
    let mut caps = capability::TIME;
    if platform::clipboard_available() { caps |= capability::CLIPBOARD; }
    if platform::display_resize_available() { caps |= capability::DISPLAY_RESIZE; }
    if platform::shared_folders_available() { caps |= capability::SHARED_FOLDERS; }
    if platform::windows_available() { caps |= capability::WINDOWS; }
    if platform::programs_available() { caps |= capability::PROGRAMS; }
    if platform::documents_available() { caps |= capability::DOCUMENTS; }
    if platform::activity_available() { caps |= capability::ACTIVITY; }
    if platform::file_drop_available() { caps |= capability::FILE_DROP; }
    if platform::windows_available() { caps |= capability::SEAMLESS_DISPLAYS; }
    // Setting the guest's display scale (for Retina resolution) is something Windows guests do.
    #[cfg(not(target_os = "linux"))]
    if platform::windows_available() { caps |= capability::SEAMLESS_EVENTS; }
    if exec::available() { caps |= capability::EXEC; }
    caps | capability::SELF_UPDATE | capability::RESTART
}

/// HELLO, repeated every 3 s until answered (PROTOCOL.md §3).
fn hello(client: &Client) -> Result<(), LinkError> {
    let mut inline = Vec::with_capacity(12);
    inline.extend_from_slice(&PROTOCOL_VERSION.to_le_bytes());
    inline.extend_from_slice(&platform::OS_ID.to_le_bytes());
    inline.extend_from_slice(&capabilities().to_le_bytes());
    for _ in 0..20 {
        match client.call(op::HELLO, inline.clone(), vec![Buffer::input(AGENT_VERSION.as_bytes())], Some(Duration::from_secs(3))) {
            Ok(_) => return Ok(()),
            Err(LinkError::Timeout) => continue,
            Err(e) => return Err(e),
        }
    }
    Err(LinkError::Timeout)
}

fn send_guest_info(client: &Client) {
    let json = platform::guest_info().to_json();
    let _ = client.call(op::GUEST_INFO, vec![], vec![Buffer::input(json.as_bytes())], CALL_TIMEOUT);
}

fn sync_time(client: &Client) {
    let started = std::time::Instant::now();
    let reply = match client.call(op::GET_HOST_TIME, vec![], vec![], CALL_TIMEOUT) {
        Ok(r) if r.inline.len() >= 16 => r,
        _ => return,
    };
    let round_trip = started.elapsed();
    let secs = i64::from_le_bytes(reply.inline[0..8].try_into().unwrap());
    let nanos = reply.u32_at(8).unwrap_or(0);
    // The host sampled its clock about half a round trip ago.
    let host_ms = secs * 1000 + (nanos / 1_000_000) as i64 + (round_trip.as_millis() / 2) as i64;
    sync_clock(client, host_ms, i32::from_le_bytes(reply.inline[12..16].try_into().unwrap()));
}

/// Windows keeps its hardware clock in local time and is shown the host's local time at boot, so what the
/// user expects is the host's wall clock, even when the guest is set to a different time zone. Setting true
/// UTC would move the visible clock by the difference between the two zones.
#[cfg(windows)]
fn sync_clock(client: &Client, host_ms: i64, utc_offset_secs: i32) {
    let host_local_ms = host_ms + utc_offset_secs as i64 * 1000;
    let drift = host_local_ms - platform::local_now_ms();
    if drift.abs() <= TIME_STEP_THRESHOLD_MS { return; }
    match platform::set_local_time(host_local_ms.div_euclid(1000), (host_local_ms.rem_euclid(1000) * 1_000_000) as u32) {
        Ok(()) => log(client, 1, &format!("clock stepped by {drift} ms to match the host's local time")),
        Err(e) => log(client, 2, &format!("clock is off by {drift} ms but could not be set: {e}")),
    }
}

/// Other guests keep UTC in the hardware clock, so the host's UTC time is the right target.
#[cfg(not(windows))]
fn sync_clock(client: &Client, host_ms: i64, _utc_offset_secs: i32) {
    let guest_ms = match std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH) {
        Ok(d) => d.as_millis() as i64,
        Err(_) => 0,
    };
    let drift = host_ms - guest_ms;
    if drift.abs() <= TIME_STEP_THRESHOLD_MS { return; }
    match platform::set_time(host_ms.div_euclid(1000), (host_ms.rem_euclid(1000) * 1_000_000) as u32) {
        Ok(()) => log(client, 1, &format!("clock stepped by {drift} ms to match the host")),
        Err(e) => log(client, 2, &format!("clock is off by {drift} ms but could not be set: {e}")),
    }
}

fn report_display(client: &Client, result: u32) {
    let (w, h) = platform::current_resolution().unwrap_or((0, 0));
    let mut inline = Vec::with_capacity(12);
    inline.extend_from_slice(&w.to_le_bytes());
    inline.extend_from_slice(&h.to_le_bytes());
    inline.extend_from_slice(&result.to_le_bytes());
    let _ = client.call(op::DISPLAY_REPORT, inline, vec![], CALL_TIMEOUT);
}

/// Asks the host which Mac folders are shared and makes them reachable in the guest.
fn sync_shares(client: &Client) {
    if !platform::shared_folders_available() { return; }
    let reply = match client.call(op::SHARE_LIST, vec![], vec![Buffer::output(64 * 1024)], CALL_TIMEOUT) {
        Ok(r) => r,
        Err(_) => return, // an older host has no shared folders
    };
    let Some(info) = std::str::from_utf8(reply.output(0)).ok().and_then(shares::parse) else {
        log(client, 2, "the host's shared folder list could not be read");
        return;
    };
    filedrop::remember_port(info.port);
    match platform::apply_shares(&info) {
        Ok(message) => log(client, 1, &message),
        Err(e) => log(client, 2, &format!("shared folders could not be set up: {e}")),
    }
}

/// Replaces this program with the host's build when the two differ, then restarts into it.
fn update_self(client: &Client) {
    let data = match update::fetch_newer(client) {
        Ok(Some(data)) => data,
        Ok(None) => return,
        Err(e) => return log(client, 2, &format!("agent update skipped: {e}")),
    };
    match update::install(&data) {
        Ok(exe) => {
            log(client, 1, &format!("agent updated to the host's build ({} bytes); restarting", data.len()));
            let error = update::restart(&exe);
            log(client, 3, &format!("the updated agent could not be started: {error}"));
        }
        Err(e) => log(client, 2, &format!("agent update could not be installed: {e}")),
    }
}

/// What the host needs to hear at the start of every session.
fn greet(client: &Client) {
    send_guest_info(client);
    sync_time(client);
    report_display(client, 0);
    sync_shares(client);
}

fn run_session(client: &Arc<Client>) -> Result<(), LinkError> {
    hello(client)?;
    log(client, 1, &format!("agent {AGENT_VERSION} connected"));
    update_self(client);
    greet(client);
    // A session starts outside Seamless Mode: undo a scale change the last one could not undo.
    if scale_marker().exists() {
        log(client, 1, &format!("display scale is {}%; putting back the scale from before Seamless Mode",
            platform::display_scale().map(|p| p.to_string()).unwrap_or("?".into())));
        display_scale(client, 0);
    }

    // Text last moved in either direction, so a change is never echoed back to where it came from.
    let last_clipboard: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(platform::clipboard_get()));
    let background = {
        let client = client.clone();
        let last = last_clipboard.clone();
        std::thread::spawn(move || background_loop(&client, &last))
    };

    // The host turns window reporting on while it shows the guest's windows one by one.
    let watching = Arc::new(AtomicBool::new(false));
    let watcher = {
        let client = client.clone();
        let watching = watching.clone();
        std::thread::spawn(move || window_loop(&client, &watching))
    };

    let reporter = platform::activity_available().then(|| {
        let client = client.clone();
        std::thread::spawn(move || activity_loop(&client))
    });

    let result = event_loop(client, &last_clipboard, &watching);
    if let Some(reporter) = reporter { let _ = reporter.join(); }
    let _ = background.join();
    let _ = watcher.join();
    result
}

/// Periodic work: guest clipboard to host every second, guest info and clock every minute.
fn background_loop(client: &Client, last_clipboard: &Mutex<Option<String>>) {
    let mut tick: u64 = 0;
    while client.is_alive() {
        std::thread::sleep(Duration::from_secs(1));
        tick += 1;
        if platform::clipboard_available() {
            if let Some(text) = platform::clipboard_get() {
                let changed = {
                    let mut last = last_clipboard.lock().unwrap();
                    if last.as_deref() != Some(text.as_str()) { *last = Some(text.clone()); true } else { false }
                };
                if changed && !text.is_empty() && text.len() <= MAX_CLIPBOARD_BYTES {
                    let _ = client.call(op::CLIPBOARD_SET_HOST, vec![], vec![Buffer::input(text.as_bytes())], CALL_TIMEOUT);
                }
            }
        }
        if tick % 60 == 0 {
            send_guest_info(client);
            sync_time(client);
        }
    }
}

/// Ids of the programs last listed for the host; `PROGRAM_LAUNCH` accepts only these.
static KNOWN_PROGRAMS: Mutex<Vec<String>> = Mutex::new(Vec::new());

/// Answers `PROGRAMS_REQUEST`: the guest's installed programs, by name.
fn send_programs(client: &Client) {
    let programs = platform::list_programs();
    *KNOWN_PROGRAMS.lock().unwrap() = programs.iter().map(|p| p.id.clone()).collect();
    let json = platform::programs_to_json(&programs);
    let _ = client.call(op::PROGRAM_LIST, vec![], vec![Buffer::input(json.as_bytes())], CALL_TIMEOUT);
}

/// Tells the host every 20 s how much the guest is in use, so that it can suspend an idle VM and
/// leave a busy one alone. A change in who wants the VM awake is told within 2 s.
fn activity_loop(client: &Client) {
    const PERIOD: u32 = 10; // in 2 s steps
    let mut step = PERIOD - 2; // the first report soon after connecting, with a processor figure
    let mut last_requests: Vec<String> = Vec::new();
    let _ = activity::current(); // the first reading, to measure processor use from
    while client.is_alive() {
        std::thread::sleep(Duration::from_secs(2));
        step += 1;
        let requests = activity::markers();
        if step < PERIOD && requests == last_requests { continue; }
        step = 0;
        last_requests = requests;
        let report = activity::current().to_json();
        match client.call(op::ACTIVITY_REPORT, vec![], vec![Buffer::input(report.as_bytes())], CALL_TIMEOUT) {
            // An older host: it has no idle timer to feed.
            Err(LinkError::Status(s)) if s == status::UNKNOWN_OPCODE => return,
            _ => {}
        }
    }
}

/// Answers `PROGRAM_INFO_REQUEST`: where a program's file is and which file types it opens.
fn send_program_info(client: &Client, id: &str) {
    let info = platform::program_info(id);
    let json = info.to_json(id);
    // A store app's icon is a picture file; its bytes go along as they are (the host can read PNG).
    let logo = if info.logo.is_empty() { Vec::new() } else {
        std::fs::read(&info.logo).ok().filter(|bytes| bytes.len() <= 1024 * 1024).unwrap_or_default()
    };
    let _ = client.call(op::PROGRAM_INFO, vec![], vec![Buffer::input(json.as_bytes()), Buffer::input(&logo)], CALL_TIMEOUT);
}

/// Carries out `DOCUMENT_OPEN` and reports the outcome with `DOCUMENT_RESULT`.
fn open_documents(client: &Client, request: u32, data: &str) {
    let mut lines = data.lines();
    let program = lines.next().unwrap_or("").trim().to_string();
    let documents: Vec<String> = lines.map(|l| l.trim().to_string()).filter(|l| !l.is_empty()).collect();
    let result = (|| {
        if documents.is_empty() { return Err((link_proto::document_status::UNREACHABLE, "No document was named.".to_string())); }
        if !program.is_empty() {
            // Only a program this agent listed can be started. After an agent restart the list is empty: read it again.
            let mut known = KNOWN_PROGRAMS.lock().unwrap().iter().any(|p| *p == program);
            if !known {
                let programs = platform::list_programs();
                known = programs.iter().any(|p| p.id == program);
                *KNOWN_PROGRAMS.lock().unwrap() = programs.into_iter().map(|p| p.id).collect();
            }
            if !known { return Err((link_proto::document_status::UNKNOWN_PROGRAM, "That program is no longer installed in Windows.".to_string())); }
        }
        platform::open_documents(&program, &documents)
    })();
    let (code, message) = match result { Ok(()) => (link_proto::document_status::OK, String::new()), Err(e) => e };
    if code != link_proto::document_status::OK { log(client, 2, &format!("could not open {documents:?} in “{program}”: {message}")); }
    let mut inline = Vec::with_capacity(8);
    inline.extend_from_slice(&request.to_le_bytes());
    inline.extend_from_slice(&code.to_le_bytes());
    let _ = client.call(op::DOCUMENT_RESULT, inline, vec![Buffer::input(message.as_bytes())], CALL_TIMEOUT);
}

/// Answers `ICON_REQUEST`. A request that finds no icon is answered too (size 0), so the host can move on.
fn send_icon(client: &Client, kind: u32, size: u32, key: &[u8]) {
    let size = size.clamp(16, 256);
    let pixels = match kind {
        icon_kind::WINDOW if key.len() >= 8 => platform::window_icon(u64::from_le_bytes(key[..8].try_into().unwrap()), size),
        icon_kind::PROGRAM => std::str::from_utf8(key).ok().and_then(|id| platform::program_icon(id, size)),
        _ => None,
    };
    let (side, pixels) = match pixels {
        Some(p) if p.len() == (size * size * 4) as usize => (size, p),
        _ => (0, Vec::new()),
    };
    let mut inline = Vec::with_capacity(12);
    inline.extend_from_slice(&kind.to_le_bytes());
    inline.extend_from_slice(&side.to_le_bytes());
    inline.extend_from_slice(&side.to_le_bytes());
    let _ = client.call(op::ICON, inline, vec![Buffer::input(key), Buffer::input(&pixels)], CALL_TIMEOUT);
}

/// Sets the guest's display scale for Seamless Mode at Retina resolution; 0 puts back the scale the
/// guest had before the first change.
///
/// The scale to go back to is kept in a file, not only in memory: a guest shut down or a host that quit
/// while in Seamless Mode would otherwise leave Windows at 200% at its normal resolution.
fn display_scale(client: &Client, percent: u32) {
    let marker = scale_marker();
    let target = if percent == 0 {
        if !marker.exists() { return; }
        // A record cut short by a power-off is empty: Windows' own default for a virtual display then.
        std::fs::read_to_string(&marker).ok().and_then(|t| t.trim().parse::<u32>().ok()).unwrap_or(100)
    } else {
        if !marker.exists() {
            if let Some(current) = platform::display_scale() {
                if let Some(dir) = marker.parent() { let _ = std::fs::create_dir_all(dir); }
                // Flushed at once: the point is to survive the VM being powered off.
                if let Ok(mut file) = std::fs::File::create(&marker) {
                    use std::io::Write;
                    let _ = file.write_all(current.to_string().as_bytes());
                    let _ = file.sync_all();
                }
            }
        }
        percent
    };
    let before = platform::display_scale();
    match platform::set_display_scale(target) {
        Ok(()) => {
            if percent == 0 { let _ = std::fs::remove_file(&marker); }
            // Open windows keep their look: Windows would leave them at their old size in pixels.
            if let Some(before) = before.filter(|&b| b != target) {
                std::thread::sleep(std::time::Duration::from_millis(400));
                platform::rescale_windows(target as f64 / before as f64);
            }
            log(client, 1, &format!("display scale set to {target}%"));
        }
        Err(e) => log(client, 2, &format!("display scale {target}% not set: {e}")),
    }
}

/// Where the guest's own display scale is remembered while Seamless Mode has changed it.
fn scale_marker() -> std::path::PathBuf {
    let base = std::env::var("ProgramData").map(std::path::PathBuf::from).unwrap_or_else(|_| std::env::temp_dir());
    base.join("Tandem").join("display-scale-before.txt")
}

/// While the host watches, tells it about the guest's windows whenever they change. Windows' own
/// window events wake it; the list is still taken every half second in case an event is missed.
fn window_loop(client: &Client, watching: &AtomicBool) {
    let mut last: Option<String> = None;
    // What watching cost, logged when the host stops watching.
    let (mut scans, mut reports, mut started) = (0u64, 0u64, None::<(std::time::Instant, u64)>);
    if platform::windows_available() { platform::window_events_start(); }
    while client.is_alive() {
        if !watching.load(Ordering::Relaxed) {
            if let Some((since, cpu)) = started.take() {
                let used = platform::process_cpu_ms().saturating_sub(cpu);
                log(client, 1, &format!("window watch: {scans} scans, {reports} reports, {used} ms of processor time in {} s",
                    since.elapsed().as_secs()));
                (scans, reports) = (0, 0);
            }
            last = None;
            std::thread::sleep(Duration::from_millis(250));
            continue;
        }
        if started.is_none() { started = Some((std::time::Instant::now(), platform::process_cpu_ms())); }
        let seen = platform::window_change_count();
        platform::keep_work_area();
        let report = platform::list_windows().to_json();
        scans += 1;
        if last.as_deref() != Some(report.as_str()) {
            let sent = client.call(op::WINDOW_REPORT, vec![], vec![Buffer::input(report.as_bytes())], CALL_TIMEOUT);
            if sent.is_ok() { last = Some(report); reports += 1; }
        }
        // Coalesce a burst of events (a drag sends one per pointer move) into one report per 8 ms.
        std::thread::sleep(Duration::from_millis(8));
        platform::wait_window_change(seen, Duration::from_millis(500));
    }
}

fn event_loop(client: &Arc<Client>, last_clipboard: &Mutex<Option<String>>, watching: &AtomicBool) -> Result<(), LinkError> {
    loop {
        let reply = match client.call(op::WAIT_EVENT, vec![], vec![Buffer::output(MAX_CLIPBOARD_BYTES)], EVENT_TIMEOUT) {
            Ok(r) => r,
            // The host answers every wait within a few seconds. Silence means it no longer knows this
            // agent: the VM was suspended and resumed, and a new host process is on the other end.
            Err(LinkError::Timeout) => {
                hello(client)?;
                log(client, 1, "the host lost this session (resumed VM?); registered again");
                greet(client);
                continue;
            }
            // Another waiter replaced this one, or the host is busy: ask again.
            Err(LinkError::Status(s)) if s == status::CANCELLED || s == status::BUSY => continue,
            Err(e) => return Err(e),
        };
        let kind = reply.u32_at(0).unwrap_or(event::NONE);
        match kind {
            event::CLIPBOARD_CHANGED => {
                if let Ok(text) = std::str::from_utf8(reply.output(0)) {
                    *last_clipboard.lock().unwrap() = Some(text.to_string());
                    if let Err(e) = platform::clipboard_set(text) {
                        log(client, 2, &format!("could not set the clipboard: {e}"));
                    }
                }
            }
            event::DISPLAY_RESIZE => {
                let (w, h) = (reply.u32_at(4).unwrap_or(0), reply.u32_at(8).unwrap_or(0));
                let result = match platform::set_resolution(w, h) {
                    Ok(()) => 0,
                    Err(platform::DisplayError::Unsupported) => 1,
                    Err(platform::DisplayError::Failed(e)) => {
                        log(client, 2, &format!("resize to {w}x{h} failed: {e}"));
                        2
                    }
                };
                report_display(client, result);
            }
            event::TIME_RESYNC => sync_time(client),
            event::SHARES_CHANGED => sync_shares(client),
            event::SHUTDOWN_REQUEST => {
                let restart = reply.u32_at(4).unwrap_or(0) == 1;
                log(client, 1, if restart { "host asked for restart" } else { "host asked for shutdown" });
                if let Err(e) = platform::shutdown(restart) {
                    log(client, 3, &format!("{} failed: {e}", if restart { "restart" } else { "shutdown" }));
                }
            }
            event::WINDOW_WATCH => watching.store(reply.u32_at(4).unwrap_or(0) == 1, Ordering::Relaxed),
            event::WINDOW_ACTION => {
                let data = reply.output(0);
                if data.len() >= 8 {
                    let id = u64::from_le_bytes(data[..8].try_into().unwrap());
                    if let Err(e) = platform::window_action(id, reply.u32_at(4).unwrap_or(0)) {
                        log(client, 2, &format!("window action failed: {e}"));
                    }
                }
            }
            event::ICON_REQUEST => send_icon(client, reply.u32_at(4).unwrap_or(0), reply.u32_at(8).unwrap_or(0), reply.output(0)),
            event::PROGRAMS_REQUEST => send_programs(client),
            event::PROGRAM_LAUNCH => {
                let id = String::from_utf8_lossy(reply.output(0)).into_owned();
                // Only what this agent itself listed can be started: the host cannot name arbitrary commands.
                let known = KNOWN_PROGRAMS.lock().unwrap().iter().any(|p| *p == id);
                let result = if known { platform::launch_program(&id) } else { Err("it is not in the program list".into()) };
                if let Err(e) = result { log(client, 2, &format!("could not start “{id}”: {e}")); }
            }
            // Both take seconds (a program is started; the registry is read), so neither holds up the events behind it.
            event::DOCUMENT_OPEN => {
                let (client, request) = (client.clone(), reply.u32_at(4).unwrap_or(0));
                let data = String::from_utf8_lossy(reply.output(0)).into_owned();
                std::thread::spawn(move || open_documents(&client, request, &data));
            }
            event::DISPLAY_SCALE => display_scale(client, reply.u32_at(4).unwrap_or(0)),
            event::DRAG_OUT_QUERY => {
                let (client, x, y) = (client.clone(), reply.u32_at(4).unwrap_or(0) as i32, reply.u32_at(8).unwrap_or(0) as i32);
                // Asking the shell takes a few hundred milliseconds; the event loop must not wait for it.
                std::thread::spawn(move || {
                    let json = match platform::selected_files_at(x, y) {
                        Ok(paths) => format!("{{\"x\":{x},\"y\":{y},\"paths\":[{}]}}",
                                             paths.iter().map(|p| platform::json_string(p)).collect::<Vec<_>>().join(",")),
                        Err(message) => format!("{{\"x\":{x},\"y\":{y},\"paths\":[],\"message\":{}}}", platform::json_string(&message)),
                    };
                    let _ = client.call(op::DRAG_OUT_ITEMS, vec![], vec![Buffer::input(json.as_bytes())], CALL_TIMEOUT);
                });
            }
            event::DRAG_OUT_FETCH => {
                let text = String::from_utf8_lossy(reply.output(0)).into_owned();
                std::thread::spawn(move || filedrop::drag_out_fetch(&text));
            }
            event::WORK_AREA => {
                let data = reply.output(0);
                let area = (data.len() >= 16).then(|| {
                    let n = |i: usize| i32::from_le_bytes(data[i..i + 4].try_into().unwrap());
                    (n(0), n(4), n(8), n(12))
                });
                match platform::set_work_area(area) {
                    Ok(()) => log(client, 1, &match area {
                        Some((x, y, w, h)) => format!("work area set to {w}x{h} at {x},{y}"),
                        None => "work area put back".to_string(),
                    }),
                    Err(e) => log(client, 2, &format!("work area: {e}")),
                }
            }
            event::PROGRAM_INFO_REQUEST => {
                let client = client.clone();
                let id = String::from_utf8_lossy(reply.output(0)).into_owned();
                std::thread::spawn(move || send_program_info(&client, &id));
            }
            event::DROP_FILES => {
                let (client, x, y) = (client.clone(), reply.u32_at(4).unwrap_or(0) as i32, reply.u32_at(8).unwrap_or(0) as i32);
                let data = reply.output(0).to_vec();
                std::thread::spawn(move || filedrop::receive(&client, x, y, &data));
            }
            // Commands can take minutes; each runs on its own thread (exec.rs).
            event::EXEC_REQUEST => {
                let (client, request, flags) = (client.clone(), reply.u32_at(4).unwrap_or(0), reply.u32_at(8).unwrap_or(0));
                let data = reply.output(0).to_vec();
                std::thread::spawn(move || exec::run_and_report(&client, request, &data, flags));
            }
            _ => {} // NONE and events from a newer host are ignored (PROTOCOL.md §7).
        }
    }
}
