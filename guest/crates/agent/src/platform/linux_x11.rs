//! Linux guests: the desktop's windows, read from and steered through the X server (EWMH), the icons
//! of windows, the folder under the pointer for a file drop, and the files selected in a file manager.
//! Speaks the X11 protocol itself (x11rb), as the agent runs as root outside the session and must not
//! depend on any tool being installed in the guest.
use super::linux_desktop::{self as desktop, SessionUser};
use super::linux_text as text;
use super::{GuestWindow, WindowList};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Condvar, Mutex};
use std::time::Duration;
use x11rb::connection::Connection;
use x11rb::protocol::xproto::{self, AtomEnum, ClientMessageEvent, ConnectionExt as _, EventMask, Window};
use x11rb::protocol::xtest::ConnectionExt as _;
use x11rb::protocol::Event;
use x11rb::rust_connection::{DefaultStream, RustConnection};

/// Atoms the agent asks for, interned once per connection.
const ATOM_NAMES: [&str; 14] = [
    "_NET_CLIENT_LIST", "_NET_CLIENT_LIST_STACKING", "_NET_ACTIVE_WINDOW", "_NET_WM_NAME", "WM_NAME", "UTF8_STRING",
    "WM_CLASS", "_NET_WM_PID", "_NET_WM_STATE", "_NET_WM_WINDOW_TYPE", "_NET_FRAME_EXTENTS", "_NET_WM_ICON",
    "_NET_CLOSE_WINDOW", "WM_CHANGE_STATE",
];

pub struct Display {
    conn: RustConnection,
    root: Window,
    atoms: HashMap<&'static str, u32>,
    atom_names: HashMap<u32, String>,
}

fn session_display(user: &SessionUser) -> Option<(String, PathBuf, Vec<u8>, Vec<u8>)> {
    let display = user.env_value("DISPLAY")?;
    let (number, socket) = text::local_display(display)?;
    let path = user.env_value("XAUTHORITY").map(PathBuf::from).unwrap_or_else(|| user.home.join(".Xauthority"));
    let host = std::fs::read_to_string("/proc/sys/kernel/hostname").unwrap_or_default();
    let bytes = std::fs::read(&path).unwrap_or_default();
    let (name, data) = text::parse_xauthority(&bytes, &number, host.trim()).unwrap_or_default();
    Some((number, socket, name, data))
}

impl Display {
    /// Connects to the signed-in user's X server.
    pub fn connect() -> Option<Display> {
        let user = desktop::session_user()?;
        let (_, socket, name, data) = session_display(&user)?;
        let stream = std::os::unix::net::UnixStream::connect(socket).ok()?;
        let (stream, _peer) = DefaultStream::from_unix_stream(stream).ok()?;
        let conn = RustConnection::connect_to_stream_with_auth_info(stream, 0, name, data).ok()?;
        let root = conn.setup().roots.first()?.root;
        let cookies: Vec<_> = ATOM_NAMES.iter().map(|n| conn.intern_atom(false, n.as_bytes()).ok()).collect();
        let mut atoms = HashMap::new();
        for (name, cookie) in ATOM_NAMES.iter().zip(cookies) { atoms.insert(*name, cookie?.reply().ok()?.atom); }
        Some(Display { conn, root, atoms, atom_names: HashMap::new() })
    }

    fn atom(&self, name: &str) -> u32 { self.atoms.get(name).copied().unwrap_or(0) }

    fn atom_name(&mut self, atom: u32) -> String {
        if let Some(name) = self.atom_names.get(&atom) { return name.clone(); }
        let name = self.conn.get_atom_name(atom).ok().and_then(|c| c.reply().ok())
            .map(|r| String::from_utf8_lossy(&r.name).into_owned()).unwrap_or_default();
        self.atom_names.insert(atom, name.clone());
        name
    }

    fn prop_u32(&self, window: Window, property: u32, length: u32) -> Option<Vec<u32>> {
        let reply = self.conn.get_property(false, window, property, AtomEnum::ANY, 0, length).ok()?.reply().ok()?;
        let values: Vec<u32> = reply.value32()?.collect();
        Some(values)
    }

    fn prop_bytes(&self, window: Window, property: u32, kind: u32) -> Option<Vec<u8>> {
        let reply = self.conn.get_property(false, window, property, kind, 0, 4096).ok()?.reply().ok()?;
        (reply.value_len > 0).then_some(reply.value)
    }

    /// The managed windows, bottom to top (the window manager's stacking order), and the active one.
    fn stacking(&self) -> (Vec<Window>, Option<Window>) {
        let list = self.prop_u32(self.root, self.atom("_NET_CLIENT_LIST_STACKING"), 4096)
            .filter(|l| !l.is_empty()).or_else(|| self.prop_u32(self.root, self.atom("_NET_CLIENT_LIST"), 4096)).unwrap_or_default();
        let active = self.prop_u32(self.root, self.atom("_NET_ACTIVE_WINDOW"), 1).and_then(|v| v.first().copied()).filter(|w| *w != 0);
        (list, active)
    }

    /// The desktop's size and its windows, front-most first.
    pub fn list(&mut self) -> Option<WindowList> {
        let geometry = self.conn.get_geometry(self.root).ok()?.reply().ok()?;
        let (windows, active) = self.stacking();
        let mut out = Vec::new();
        for &id in windows.iter().rev() {
            if let Some(window) = self.describe(id, active == Some(id)) { out.push(window); }
        }
        Some(WindowList { desktop: (geometry.width as i32, geometry.height as i32), windows: out, moving: None })
    }

    fn describe(&mut self, id: Window, active: bool) -> Option<GuestWindow> {
        let c = &self.conn;
        // Every request goes out before the first answer is read.
        let name_utf8 = c.get_property(false, id, self.atom("_NET_WM_NAME"), AtomEnum::ANY, 0, 1024).ok()?;
        let name_plain = c.get_property(false, id, self.atom("WM_NAME"), AtomEnum::ANY, 0, 1024).ok()?;
        let class = c.get_property(false, id, self.atom("WM_CLASS"), AtomEnum::ANY, 0, 1024).ok()?;
        let pid = c.get_property(false, id, self.atom("_NET_WM_PID"), AtomEnum::ANY, 0, 1).ok()?;
        let state = c.get_property(false, id, self.atom("_NET_WM_STATE"), AtomEnum::ANY, 0, 64).ok()?;
        let kind = c.get_property(false, id, self.atom("_NET_WM_WINDOW_TYPE"), AtomEnum::ANY, 0, 16).ok()?;
        let extents = c.get_property(false, id, self.atom("_NET_FRAME_EXTENTS"), AtomEnum::ANY, 0, 4).ok()?;
        let size = c.get_geometry(id).ok()?;
        let origin = c.translate_coordinates(id, self.root, 0, 0).ok()?;
        let title = name_utf8.reply().ok().filter(|r| r.value_len > 0).map(|r| r.value)
            .or_else(|| name_plain.reply().ok().map(|r| r.value)).map(|v| String::from_utf8_lossy(&v).into_owned()).unwrap_or_default();
        let class_bytes = class.reply().ok().map(|r| r.value).unwrap_or_default();
        let mut class_parts = class_bytes.split(|b| *b == 0).filter(|p| !p.is_empty()).map(|p| String::from_utf8_lossy(p).into_owned());
        let (instance, class_name) = (class_parts.next().unwrap_or_default(), class_parts.next().unwrap_or_default());
        let pid = pid.reply().ok().and_then(|r| r.value32().and_then(|mut v| v.next())).unwrap_or(0);
        let state_atoms: Vec<u32> = state.reply().ok().and_then(|r| r.value32().map(|v| v.collect())).unwrap_or_default();
        let type_atoms: Vec<u32> = kind.reply().ok().and_then(|r| r.value32().map(|v| v.collect())).unwrap_or_default();
        let frame: Vec<u32> = extents.reply().ok().and_then(|r| r.value32().map(|v| v.collect())).unwrap_or_default();
        let (size, origin) = (size.reply().ok()?, origin.reply().ok()?);
        let states: Vec<String> = state_atoms.iter().map(|a| self.atom_name(*a)).collect();
        let types: Vec<String> = type_atoms.iter().map(|a| self.atom_name(*a)).collect();
        let kind = text::window_kind(&types);
        let (left, right, top, bottom) = match frame[..] { [l, r, t, b] => (l as i32, r as i32, t as i32, b as i32), _ => (0, 0, 0, 0) };
        let (x, y) = (origin.dst_x as i32 - left, origin.dst_y as i32 - top);
        let (width, height) = (size.width as i32 + left + right, size.height as i32 + top + bottom);
        let skip_taskbar = states.iter().any(|s| s == "_NET_WM_STATE_SKIP_TASKBAR");
        if !text::worth_listing(kind, width, height, skip_taskbar) { return None; }
        let app = if pid != 0 { std::fs::read_to_string(format!("/proc/{pid}/comm")).map(|s| s.trim().to_string()).unwrap_or_default() } else { String::new() };
        let app = if app.is_empty() { instance.to_lowercase() } else { app };
        Some(GuestWindow {
            id: id as u64, x, y, width, height, pid, kind, state: text::window_state(&states), active,
            title, class: class_name, app,
        })
    }

    fn send_to_root(&self, window: Window, message: &str, data: [u32; 5]) -> Result<(), String> {
        let event = ClientMessageEvent::new(32, window, self.atom(message), data);
        let mask = EventMask::SUBSTRUCTURE_REDIRECT | EventMask::SUBSTRUCTURE_NOTIFY;
        self.conn.send_event(false, self.root, mask, event).map_err(|e| e.to_string())?;
        self.conn.flush().map_err(|e| e.to_string())
    }

    fn act(&self, window: Window, action: u32) -> Result<(), String> {
        use link_proto::window_action as a;
        match action {
            // Source 2: a pager, so a window manager that guards against focus stealing obeys.
            a::ACTIVATE | a::RESTORE => self.send_to_root(window, "_NET_ACTIVE_WINDOW", [2, 0, 0, 0, 0]),
            a::CLOSE => self.send_to_root(window, "_NET_CLOSE_WINDOW", [0, 2, 0, 0, 0]),
            a::MINIMIZE => self.send_to_root(window, "WM_CHANGE_STATE", [3, 0, 0, 0, 0]),
            _ => Err(format!("unknown window action {action}")),
        }
    }

    /// The icon a window gives itself (`_NET_WM_ICON`), as BGRA pixels `size` square; else the theme icon
    /// named like its program or its class.
    fn icon(&self, window: Window, size: u32) -> Option<Vec<u8>> {
        if let Some(data) = self.prop_u32(window, self.atom("_NET_WM_ICON"), 1 << 20) {
            if let Some((w, h, rgba)) = text::pick_net_wm_icon(&data, size) {
                return Some(text::fit_to_bgra_premultiplied(&rgba, w, h, size as usize));
            }
        }
        let class = self.prop_bytes(window, self.atom("WM_CLASS"), AtomEnum::ANY.into())?;
        let mut parts = class.split(|b| *b == 0).filter(|p| !p.is_empty()).map(|p| String::from_utf8_lossy(p).into_owned());
        let (instance, class) = (parts.next().unwrap_or_default(), parts.next().unwrap_or_default());
        [instance.to_lowercase(), class.to_lowercase(), instance, class].iter().filter(|n| !n.is_empty()).find_map(|n| desktop::icon_pixels(n, size))
    }

    /// Presses and releases `keys` together (the first is held while the others are tapped), through the
    /// XTEST extension, as a person at the keyboard would.
    fn tap_keys(&self, keysyms: &[u32]) -> Result<(), String> {
        let setup = self.conn.setup();
        let (min, max) = (setup.min_keycode, setup.max_keycode);
        let map = self.conn.get_keyboard_mapping(min, max - min + 1).map_err(|e| e.to_string())?.reply().map_err(|e| e.to_string())?;
        let per = map.keysyms_per_keycode as usize;
        let keycode = |sym: u32| -> Option<u8> {
            (0..(max - min + 1) as usize).find(|i| map.keysyms[i * per..(i + 1) * per].contains(&sym)).map(|i| min + i as u8)
        };
        let codes: Vec<u8> = keysyms.iter().map(|s| keycode(*s).ok_or(format!("no key for {s:#x}"))).collect::<Result<_, _>>()?;
        let fake = |kind: u8, code: u8| self.conn.xtest_fake_input(kind, code, 0, self.root, 0, 0, 0).map(|_| ()).map_err(|e| e.to_string());
        for code in &codes { fake(2, *code)?; }
        for code in codes.iter().rev() { fake(3, *code)?; }
        self.conn.flush().map_err(|e| e.to_string())
    }
}

// MARK: The shared connection

static DISPLAY: Mutex<Option<Display>> = Mutex::new(None);

/// Runs `f` on the shared connection to the user's X server, connecting (again) when there is none.
/// A failure drops the connection, so the next call starts afresh, for example after a new sign-in.
fn with_display<T>(f: impl FnOnce(&mut Display) -> Option<T>) -> Option<T> {
    let mut guard = DISPLAY.lock().unwrap_or_else(|e| e.into_inner());
    if guard.is_none() { *guard = Display::connect(); }
    let display = guard.as_mut()?;
    let result = f(display);
    if result.is_none() && display.conn.flush().is_err() { *guard = None; }
    result
}

pub fn windows_available() -> bool {
    (unsafe { libc::geteuid() }) == 0 && (std::path::Path::new("/tmp/.X11-unix").is_dir()
        || ["/usr/bin/Xorg", "/usr/lib/xorg/Xorg", "/usr/bin/Xwayland"].iter().any(|p| std::path::Path::new(p).exists()))
}

pub fn list_windows() -> WindowList {
    with_display(|d| d.list()).unwrap_or_default()
}

pub fn window_action(id: u64, action: u32) -> Result<(), String> {
    with_display(|d| Some(d.act(id as Window, action))).ok_or_else(|| "the desktop is not reachable".to_string())?
}

pub fn window_icon(id: u64, size: u32) -> Option<Vec<u8>> { with_display(|d| d.icon(id as Window, size)) }

// MARK: Window events

static CHANGES: Mutex<u64> = Mutex::new(0);
static CHANGED: Condvar = Condvar::new();

fn note_change() {
    *CHANGES.lock().unwrap_or_else(|e| e.into_inner()) += 1;
    CHANGED.notify_all();
}

pub fn window_change_count() -> u64 { *CHANGES.lock().unwrap_or_else(|e| e.into_inner()) }

pub fn wait_window_change(seen: u64, timeout: Duration) {
    let guard = CHANGES.lock().unwrap_or_else(|e| e.into_inner());
    let _ = CHANGED.wait_timeout_while(guard, timeout, |count| *count == seen);
}

/// Starts the thread that turns the X server's window events into change counts, once.
pub fn window_events_start() {
    static STARTED: std::sync::Once = std::sync::Once::new();
    STARTED.call_once(|| {
        std::thread::spawn(|| loop {
            watch_events();
            // No session yet, or the X server went away: try again shortly.
            std::thread::sleep(Duration::from_secs(2));
            note_change();
        });
    });
}

fn watch_events() -> Option<()> {
    let mut display = Display::connect()?;
    let root = display.root;
    let list_atom = display.atom("_NET_CLIENT_LIST");
    let aux = xproto::ChangeWindowAttributesAux::new().event_mask(EventMask::PROPERTY_CHANGE | EventMask::SUBSTRUCTURE_NOTIFY);
    display.conn.change_window_attributes(root, &aux).ok()?;
    let mut subscribed: HashSet<Window> = HashSet::new();
    let mut follow = |display: &Display, subscribed: &mut HashSet<Window>| {
        let (clients, _) = display.stacking();
        subscribed.retain(|w| clients.contains(w));
        for window in clients {
            if subscribed.insert(window) {
                let aux = xproto::ChangeWindowAttributesAux::new().event_mask(EventMask::PROPERTY_CHANGE);
                let _ = display.conn.change_window_attributes(window, &aux);
            }
        }
        let _ = display.conn.flush();
    };
    follow(&display, &mut subscribed);
    note_change();
    loop {
        let event = display.conn.wait_for_event().ok()?;
        match event {
            Event::PropertyNotify(e) if e.window == root && e.atom == list_atom => follow(&display, &mut subscribed),
            Event::PropertyNotify(_) | Event::ConfigureNotify(_) | Event::MapNotify(_) | Event::UnmapNotify(_)
            | Event::DestroyNotify(_) | Event::CreateNotify(_) | Event::ReparentNotify(_) => {}
            _ => continue,
        }
        note_change();
    }
}

// MARK: Dropping files and dragging them out

/// The front-most program window that covers the guest pixel, if any.
fn window_at(x: i32, y: i32) -> Option<GuestWindow> {
    list_windows().windows.into_iter().find(|w| w.kind == "app" && w.state != "minimized"
        && x >= w.x && y >= w.y && x < w.x + w.width && y < w.y + w.height)
}

fn user_directories(user: &SessionUser) -> Vec<(String, PathBuf)> {
    let config = user.home.join(".config/user-dirs.dirs");
    text::parse_user_dirs(&std::fs::read_to_string(config).unwrap_or_default(), &user.home)
}

fn special_folder(user: &SessionUser, key: &str, fallback: &str) -> PathBuf {
    user_directories(user).into_iter().find(|(k, _)| k == key).map(|(_, p)| p).unwrap_or_else(|| user.home.join(fallback))
}

/// The folder a drop at the guest pixel goes to: the folder a file manager window shows there, or the
/// desktop's folder when the pointer is over the desktop. None for any other program's window.
pub fn drop_target_folder(x: i32, y: i32) -> Option<PathBuf> {
    let user = desktop::session_user()?;
    match window_at(x, y) {
        Some(window) if text::is_file_manager(&window.class) => {
            let special = user_directories(&user);
            text::folder_from_title(&window.title, &user.name, &user.home, &special, &|p| p.is_dir())
        }
        Some(_) => None,
        None => Some(special_folder(&user, "DESKTOP", "Desktop")).filter(|p| p.is_dir()),
    }
}

/// Where a drop goes when no folder is under the pointer: the Downloads folder, made when it is missing.
pub fn fallback_drop_folder() -> Option<PathBuf> {
    let user = desktop::session_user().or_else(|| desktop::primary_account().map(|a| SessionUser {
        uid: a.uid, gid: a.gid, name: a.name, home: a.home, env: Vec::new() }))?;
    let folder = special_folder(&user, "DOWNLOAD", "Downloads");
    let _ = std::fs::create_dir_all(&folder);
    Some(folder)
}

/// From now on this thread creates files as the signed-in user: what a drop writes belongs to them, and
/// only what they may write can be written. Linux keeps the file-system identity per thread, so the
/// agent's other work stays root's.
pub fn act_as_session_user() {
    let Some(user) = desktop::session_user().or_else(|| desktop::primary_account().map(|a| SessionUser {
        uid: a.uid, gid: a.gid, name: a.name, home: a.home, env: Vec::new() })) else { return };
    if (unsafe { libc::geteuid() }) != 0 { return; }
    unsafe {
        libc::setfsgid(user.gid as _);
        libc::setfsuid(user.uid as _);
    }
}

/// Reads what the clipboard offers for `target` with `xclip`, in the user's session.
fn clipboard_target(user: &SessionUser, target: &str) -> Option<String> {
    let mut command = std::process::Command::new("xclip");
    command.args(["-selection", "clipboard", "-t", target, "-o"]).env_clear().envs(user.env.iter().cloned())
        .stdin(std::process::Stdio::null()).stderr(std::process::Stdio::null());
    let output = command.output().ok()?;
    output.status.success().then(|| String::from_utf8_lossy(&output.stdout).into_owned())
}

/// The files selected in the file manager window under the guest pixel. A file manager does not say what
/// is selected, so this copies it: the window gets Ctrl+C and the files it puts on the clipboard are read,
/// then the text that was on the clipboard before is put back.
pub fn selected_files_at(x: i32, y: i32) -> Result<Vec<String>, String> {
    let window = window_at(x, y).filter(|w| text::is_file_manager(&w.class))
        .ok_or("Dragging files out works from a file manager window.")?;
    let user = desktop::session_user().ok_or("Nobody is signed in to the desktop.")?;
    let before = super::clipboard_get();
    super::set_clipboard_paused(true);
    let result = (|| {
        with_display(|d| {
            let _ = d.act(window.id as Window, link_proto::window_action::ACTIVATE);
            std::thread::sleep(Duration::from_millis(120));
            Some(d.tap_keys(&[0xffe3, 0x63])) // Control_L, c
        }).ok_or("The desktop is not reachable.".to_string())??;
        for _ in 0..30 {
            std::thread::sleep(Duration::from_millis(60));
            let targets = clipboard_target(&user, "TARGETS").unwrap_or_default();
            if let Some(target) = text::copied_files_target(&targets) {
                let paths: Vec<String> = text::parse_uri_list(&clipboard_target(&user, target).unwrap_or_default())
                    .into_iter().filter(|p| std::path::Path::new(p).exists()).collect();
                if !paths.is_empty() { return Ok(paths); }
            }
        }
        Err("Nothing is selected in that window.".to_string())
    })();
    if let Some(previous) = before { let _ = super::clipboard_set(&previous); }
    super::set_clipboard_paused(false);
    result
}
