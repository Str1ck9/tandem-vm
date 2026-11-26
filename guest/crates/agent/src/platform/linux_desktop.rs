//! Linux guests: the programs a desktop's menu offers, starting them (and opening Mac documents with
//! them) as the signed-in user, and their icons. The agent runs as root, so everything that starts a
//! program switches to the user whose desktop session is running.
use super::linux_text as text;
use super::{GuestProgram, ProgramInfo};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// Keys of a desktop session's environment a launched program needs.
const LAUNCH_KEYS: [&str; 10] = ["DISPLAY", "XAUTHORITY", "WAYLAND_DISPLAY", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS",
    "XDG_CURRENT_DESKTOP", "XDG_SESSION_TYPE", "LANG", "XDG_DATA_DIRS", "GTK_MODULES"];
const DEFAULT_PATH: &str = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin";

#[derive(Debug, Clone)]
pub struct SessionUser {
    pub uid: u32,
    pub gid: u32,
    pub name: String,
    pub home: PathBuf,
    /// The graphical session's own environment (display, bus, runtime folder, language).
    pub env: Vec<(String, String)>,
}

impl SessionUser {
    pub fn env_value(&self, key: &str) -> Option<&str> { self.env.iter().find(|(k, _)| k == key).map(|(_, v)| v.as_str()) }
}

fn accounts() -> Vec<text::Account> { text::parse_passwd(&std::fs::read_to_string("/etc/passwd").unwrap_or_default()) }

fn account_for(uid: u32) -> Option<text::Account> { accounts().into_iter().find(|a| a.uid == uid) }

/// The first person's account of the guest, for when nobody is signed in yet.
pub fn primary_account() -> Option<text::Account> {
    let mut people: Vec<text::Account> = accounts().into_iter().filter(|a| text::is_person(a, a.home.is_dir())).collect();
    people.sort_by_key(|a| a.uid);
    people.into_iter().next()
}

/// The user whose desktop session is running: the owner of a process with a display in its environment,
/// the one with the highest user ID when there are several (not the login screen's). Looked up at most
/// every 4 s; None while nobody is signed in.
pub fn session_user() -> Option<SessionUser> {
    static CACHE: Mutex<Option<(Instant, Option<SessionUser>)>> = Mutex::new(None);
    let mut cache = CACHE.lock().unwrap();
    if let Some((at, found)) = cache.as_ref() {
        if at.elapsed() < Duration::from_secs(4) && found.is_some() { return found.clone(); }
        if at.elapsed() < Duration::from_secs(1) { return found.clone(); }
    }
    let found = find_session_user();
    *cache = Some((Instant::now(), found.clone()));
    found
}

fn find_session_user() -> Option<SessionUser> {
    use std::os::unix::fs::MetadataExt;
    let mut best: Option<(u32, Vec<(String, String)>)> = None;
    for entry in std::fs::read_dir("/proc").ok()?.flatten() {
        if !entry.file_name().to_string_lossy().chars().all(|c| c.is_ascii_digit()) { continue; }
        let uid = match entry.metadata() { Ok(m) => m.uid(), Err(_) => continue };
        if uid < 1000 || uid >= 60000 || best.as_ref().map(|(b, _)| uid <= *b).unwrap_or(false) { continue; }
        let Ok(raw) = std::fs::read(entry.path().join("environ")) else { continue };
        let env: Vec<(String, String)> = raw.split(|b| *b == 0).filter_map(|item| {
            let text = std::str::from_utf8(item).ok()?;
            let (key, value) = text.split_once('=')?;
            LAUNCH_KEYS.contains(&key).then(|| (key.to_string(), value.to_string()))
        }).collect();
        if env.iter().any(|(k, _)| k == "DISPLAY" || k == "WAYLAND_DISPLAY") { best = Some((uid, env)); }
    }
    let (uid, mut env) = best?;
    let account = account_for(uid)?;
    // Where the user's own bus is, when the session did not say.
    if !env.iter().any(|(k, _)| k == "XDG_RUNTIME_DIR") { env.push(("XDG_RUNTIME_DIR".into(), format!("/run/user/{uid}"))); }
    if !env.iter().any(|(k, _)| k == "DBUS_SESSION_BUS_ADDRESS") {
        let runtime = env.iter().find(|(k, _)| k == "XDG_RUNTIME_DIR").map(|(_, v)| v.clone()).unwrap_or_default();
        if Path::new(&runtime).join("bus").exists() { env.push(("DBUS_SESSION_BUS_ADDRESS".into(), format!("unix:path={runtime}/bus"))); }
    }
    Some(SessionUser { uid, gid: account.gid, name: account.name, home: account.home, env })
}

/// Waits (a few seconds) for a signed-in session, for a request that arrives while one is starting.
fn wait_for_session(seconds: u64) -> Option<SessionUser> {
    let deadline = Instant::now() + Duration::from_secs(seconds);
    loop {
        if let Some(user) = session_user() { return Some(user); }
        if Instant::now() >= deadline { return None; }
        std::thread::sleep(Duration::from_millis(500));
    }
}

/// Starts a program as `user`, detached: its own session, no terminal, the desktop's environment.
pub fn spawn_as(user: &SessionUser, args: &[String]) -> Result<(), String> {
    let Some(program) = args.first() else { return Err("nothing to start".into()) };
    let mut command = Command::new(program);
    command.args(&args[1..]).env_clear().envs(user.env.iter().cloned());
    command.env("HOME", &user.home).env("USER", &user.name).env("LOGNAME", &user.name);
    command.env("PATH", std::env::var("PATH").unwrap_or_else(|_| DEFAULT_PATH.into()));
    command.current_dir(&user.home).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    let (uid, gid) = (user.uid, user.gid);
    let name = std::ffi::CString::new(user.name.clone()).map_err(|_| "the user name is not usable".to_string())?;
    let root = unsafe { libc::geteuid() } == 0;
    // SAFETY: only async-signal-safe calls (setsid, initgroups, setgid, setuid) run between fork and exec.
    unsafe {
        command.pre_exec(move || {
            libc::setsid();
            if root {
                if libc::initgroups(name.as_ptr(), gid as _) != 0 { return Err(std::io::Error::last_os_error()); }
                if libc::setgid(gid as _) != 0 { return Err(std::io::Error::last_os_error()); }
                if libc::setuid(uid as _) != 0 { return Err(std::io::Error::last_os_error()); }
            }
            Ok(())
        });
    }
    let mut child = command.spawn().map_err(|e| format!("{program}: {e}"))?;
    std::thread::spawn(move || { let _ = child.wait(); });
    Ok(())
}

fn have(tool: &str) -> bool {
    std::env::var("PATH").unwrap_or_else(|_| DEFAULT_PATH.into()).split(':').any(|dir| Path::new(dir).join(tool).is_file())
        || DEFAULT_PATH.split(':').any(|dir| Path::new(dir).join(tool).is_file())
}

// MARK: The program list

/// A listed program with where its `.desktop` file is.
#[derive(Debug, Clone)]
struct Listed {
    entry: text::DesktopEntry,
    path: PathBuf,
}

fn application_dirs(home: &Path) -> Vec<PathBuf> {
    vec![
        home.join(".local/share/applications"),
        PathBuf::from("/usr/local/share/applications"),
        PathBuf::from("/usr/share/applications"),
        PathBuf::from("/var/lib/snapd/desktop/applications"),
        PathBuf::from("/var/lib/flatpak/exports/share/applications"),
        home.join(".local/share/flatpak/exports/share/applications"),
    ]
}

fn collect_desktop_files(dir: &Path, base: &Path, depth: u32, out: &mut Vec<(String, PathBuf)>) {
    let Ok(read) = std::fs::read_dir(dir) else { return };
    let mut names: Vec<_> = read.flatten().collect();
    names.sort_by_key(|e| e.file_name());
    for entry in names {
        let path = entry.path();
        if path.is_dir() {
            if depth < 2 { collect_desktop_files(&path, base, depth + 1, out); }
        } else if path.extension().map(|e| e == "desktop").unwrap_or(false) {
            if let Ok(relative) = path.strip_prefix(base) { out.push((text::desktop_file_id(&relative.to_string_lossy()), path.clone())); }
        }
    }
}

fn listed_programs() -> Vec<Listed> {
    let (home, env) = match session_user() {
        Some(user) => (user.home.clone(), user.env.clone()),
        None => (primary_account().map(|a| a.home).unwrap_or_else(|| PathBuf::from("/root")), Vec::new()),
    };
    let value = |key: &str| env.iter().find(|(k, _)| k == key).map(|(_, v)| v.clone()).or_else(|| std::env::var(key).ok()).unwrap_or_default();
    let desktops = text::desktop_names(&value("XDG_CURRENT_DESKTOP"));
    let locales = text::locale_tags(&value("LANG"));
    let mut found: Vec<Listed> = Vec::new();
    for dir in application_dirs(&home) {
        let mut files = Vec::new();
        collect_desktop_files(&dir, &dir, 0, &mut files);
        for (id, path) in files {
            if found.iter().any(|l| l.entry.id == id) { continue; }
            let Ok(content) = std::fs::read_to_string(&path) else { continue };
            // Programs that need a terminal (htop, vim) are not Mac-window programs.
            let Some(entry) = text::parse_desktop_entry(&id, &content, &desktops, &locales).filter(|e| !e.terminal) else { continue };
            found.push(Listed { entry, path });
        }
    }
    found.sort_by(|a, b| a.entry.name.to_lowercase().cmp(&b.entry.name.to_lowercase()).then(a.entry.id.cmp(&b.entry.id)));
    found
}

pub fn programs_available() -> bool { (unsafe { libc::geteuid() }) == 0 && Path::new("/usr/share/applications").is_dir() }

pub fn list_programs() -> Vec<GuestProgram> {
    listed_programs().into_iter().map(|l| GuestProgram { name: l.entry.name, id: l.entry.id }).collect()
}

fn find_program(id: &str) -> Option<Listed> { listed_programs().into_iter().find(|l| l.entry.id == id) }

/// The command that starts `listed` with `files` (guest paths), through the desktop's own launcher when
/// there is one (it handles terminals, D-Bus activation and Flatpak/Snap), else the `Exec` line.
fn launch_command(listed: &Listed, files: &[String]) -> Vec<String> {
    if have("gio") {
        let mut args = vec!["gio".to_string(), "launch".to_string(), listed.path.to_string_lossy().into_owned()];
        args.extend(files.iter().cloned());
        return args;
    }
    if files.is_empty() && have("gtk-launch") { return vec!["gtk-launch".to_string(), listed.entry.id.clone()]; }
    text::exec_arguments(&listed.entry.exec, files, &listed.entry.name, &listed.entry.icon, &listed.path.to_string_lossy())
}

pub fn launch_program(id: &str) -> Result<(), String> {
    let listed = find_program(id).ok_or("the program is not installed any more")?;
    let user = wait_for_session(15).ok_or("nobody is signed in to the desktop yet")?;
    spawn_as(&user, &launch_command(&listed, &[]))
}

pub fn program_info(id: &str) -> ProgramInfo {
    let Some(listed) = find_program(id) else { return ProgramInfo::default() };
    let globs = text::parse_mime_globs(&std::fs::read_to_string("/usr/share/mime/globs2").unwrap_or_default());
    let lines: String = text::extensions_for(&listed.entry.mime_types, &globs).iter().map(|e| format!("ext\t{e}\n")).collect();
    let mut info = ProgramInfo::parse(&lines);
    info.target = text::program_target(&listed.entry.exec);
    info.logo = icon_file(&listed.entry.icon, 256).map(|p| p.to_string_lossy().into_owned()).unwrap_or_default();
    info
}

/// Opens Mac documents (`<share>/<path>`, one per entry) with a program from the list, or with each
/// document's default program when `program` is empty.
pub fn open_documents(program: &str, documents: &[String]) -> Result<(), (u32, String)> {
    use link_proto::document_status as status;
    let mut paths = Vec::new();
    for document in documents {
        let path = text::shared_document_path(super::linux::SHARE_ROOT, document, &super::linux::mount_name)
            .ok_or((status::UNREACHABLE, format!("“{document}” is not in a shared folder.")))?;
        if std::fs::metadata(&path).is_err() {
            return Err((status::UNREACHABLE, "The shared Mac folder is not connected in this guest.".into()));
        }
        paths.push(path);
    }
    let user = wait_for_session(15).ok_or((status::FAILED, "Nobody is signed in to the desktop yet.".to_string()))?;
    if program.is_empty() {
        for path in &paths {
            let tool = if have("gio") { vec!["gio".to_string(), "open".to_string(), path.clone()] } else { vec!["xdg-open".to_string(), path.clone()] };
            spawn_as(&user, &tool).map_err(|e| (status::FAILED, e))?;
        }
        return Ok(());
    }
    let listed = find_program(program).ok_or((status::UNKNOWN_PROGRAM, "That program is no longer installed.".to_string()))?;
    spawn_as(&user, &launch_command(&listed, &paths)).map_err(|e| (status::FAILED, e))
}

// MARK: Icons

fn icon_themes(bases: &[PathBuf]) -> Vec<String> {
    static CACHE: Mutex<Option<Vec<String>>> = Mutex::new(None);
    let mut cache = CACHE.lock().unwrap();
    if let Some(themes) = cache.as_ref() { return themes.clone(); }
    let mut themes: Vec<String> = ["hicolor", "Yaru", "Humanity", "mate", "Adwaita", "gnome", "elementary", "Papirus", "breeze", "oxygen", "Yaru-mate", "Yaru-dark"]
        .iter().map(|s| s.to_string()).collect();
    for base in bases {
        if let Ok(read) = std::fs::read_dir(base) {
            let mut names: Vec<String> = read.flatten().filter(|e| e.path().is_dir()).map(|e| e.file_name().to_string_lossy().into_owned()).collect();
            names.sort();
            for name in names { if !themes.contains(&name) { themes.push(name); } }
        }
    }
    *cache = Some(themes.clone());
    themes
}

/// Every PNG that may hold the icon `name` (a path or a theme icon name), best first, that exists.
fn icon_files(name: &str, wanted: u32) -> Vec<PathBuf> {
    if name.is_empty() { return Vec::new(); }
    let home = session_user().map(|u| u.home).or_else(|| primary_account().map(|a| a.home));
    let mut bases = Vec::new();
    if let Some(home) = &home { bases.push(home.join(".local/share/icons")); bases.push(home.join(".icons")); }
    for dir in ["/usr/local/share/icons", "/usr/share/icons", "/var/lib/snapd/desktop/icons", "/var/lib/flatpak/exports/share/icons"] { bases.push(PathBuf::from(dir)); }
    let themes = icon_themes(&bases);
    let pixmaps = [PathBuf::from("/usr/share/pixmaps")];
    text::icon_candidates(name, wanted, &bases, &themes, &pixmaps).into_iter()
        .filter(|p| p.extension().map(|e| e == "png").unwrap_or(false) && p.is_file()).collect()
}

/// The file of the best PNG for an icon.
fn icon_file(name: &str, wanted: u32) -> Option<PathBuf> { icon_files(name, wanted).into_iter().next() }

/// A PNG file as straight RGBA, 8 bits a channel.
fn decode_png(path: &Path) -> Option<(usize, usize, Vec<u8>)> {
    let file = std::fs::File::open(path).ok()?;
    let mut decoder = png::Decoder::new(std::io::BufReader::new(file));
    decoder.set_transformations(png::Transformations::normalize_to_color8());
    let mut reader = decoder.read_info().ok()?;
    let mut buffer = vec![0u8; reader.output_buffer_size()];
    let info = reader.next_frame(&mut buffer).ok()?;
    let (w, h) = (info.width as usize, info.height as usize);
    if w == 0 || h == 0 || w > 4096 || h > 4096 { return None; }
    let data = &buffer[..info.buffer_size()];
    let rgba: Vec<u8> = match info.color_type {
        png::ColorType::Rgba => data.to_vec(),
        png::ColorType::Rgb => data.chunks_exact(3).flat_map(|p| [p[0], p[1], p[2], 255]).collect(),
        png::ColorType::GrayscaleAlpha => data.chunks_exact(2).flat_map(|p| [p[0], p[0], p[0], p[1]]).collect(),
        png::ColorType::Grayscale => data.iter().flat_map(|g| [*g, *g, *g, 255]).collect(),
        png::ColorType::Indexed => return None,
    };
    (rgba.len() == w * h * 4).then_some((w, h, rgba))
}

/// The icon of a listed program as BGRA pixels, `size` x `size`.
pub fn program_icon(id: &str, size: u32) -> Option<Vec<u8>> {
    let listed = find_program(id)?;
    icon_pixels(&listed.entry.icon, size)
}

/// An icon by name as BGRA pixels, `size` x `size`. Several files may not decode (a theme can ship a
/// broken one): they are tried in order.
pub fn icon_pixels(name: &str, size: u32) -> Option<Vec<u8>> {
    icon_files(name, size).into_iter().find_map(|path| {
        let (w, h, rgba) = decode_png(&path)?;
        Some(text::fit_to_bgra_premultiplied(&rgba, w, h, size as usize))
    })
}
