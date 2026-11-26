//! What the Linux agent reads from a desktop session: `.desktop` files, MIME globs, icon names,
//! X11 property values, the user's special folders and the files a file manager puts on the clipboard.
//! Plain text and numbers only, so the host's `cargo test` covers all of it.
#![cfg_attr(not(target_os = "linux"), allow(dead_code))]

use std::path::{Path, PathBuf};

// MARK: .desktop files

/// A program from a `.desktop` file that a desktop's menu would show.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct DesktopEntry {
    /// The desktop file ID: its file name, with `/` inside `applications/` written as `-`.
    pub id: String,
    pub name: String,
    pub exec: String,
    pub icon: String,
    pub mime_types: Vec<String>,
    pub terminal: bool,
}

/// Undoes the escapes a `.desktop` value may carry (`\s`, `\n`, `\t`, `\r`, `\\`).
fn unescape(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    let mut chars = value.chars();
    while let Some(c) = chars.next() {
        if c != '\\' { out.push(c); continue; }
        match chars.next() {
            Some('s') => out.push(' '),
            Some('n') => out.push('\n'),
            Some('t') => out.push('\t'),
            Some('r') => out.push('\r'),
            Some('\\') => out.push('\\'),
            Some(other) => { out.push('\\'); out.push(other); }
            None => out.push('\\'),
        }
    }
    out
}

/// A `;`-separated list; `\;` is a semicolon inside an item.
fn list(value: &str) -> Vec<String> {
    let mut items = Vec::new();
    let mut current = String::new();
    let mut chars = value.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\\' if chars.peek() == Some(&';') => { current.push(';'); chars.next(); }
            ';' => { if !current.is_empty() { items.push(unescape(&current)); } current.clear(); }
            other => current.push(other),
        }
    }
    if !current.is_empty() { items.push(unescape(&current)); }
    items
}

/// Reads one `.desktop` file. `desktops` are the running desktop's names (`XDG_CURRENT_DESKTOP`, split at
/// `:`); `locales` are the user's language tags, most specific first (`["de_DE", "de"]`).
/// Returns None for what a menu would not show: hidden entries, other types, entries limited to another
/// desktop, and entries without a name or command.
pub fn parse_desktop_entry(id: &str, text: &str, desktops: &[String], locales: &[String]) -> Option<DesktopEntry> {
    let mut in_entry = false;
    let (mut kind, mut name, mut exec, mut icon, mut mime) = (String::new(), None::<String>, String::new(), String::new(), String::new());
    let mut localized: Vec<(usize, String)> = Vec::new();
    let (mut hidden, mut terminal) = (false, false);
    let (mut only, mut not): (Vec<String>, Vec<String>) = (Vec::new(), Vec::new());
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') { continue; }
        if line.starts_with('[') { in_entry = line == "[Desktop Entry]"; continue; }
        if !in_entry { continue; }
        let Some((key, value)) = line.split_once('=') else { continue };
        let (key, value) = (key.trim(), value.trim());
        match key {
            "Type" => kind = value.to_string(),
            "Name" => name = Some(unescape(value)),
            "Exec" => exec = value.to_string(),
            "Icon" => icon = unescape(value),
            "MimeType" => mime = value.to_string(),
            "NoDisplay" | "Hidden" => if value == "true" { hidden = true },
            "Terminal" => terminal = value == "true",
            "OnlyShowIn" => only = list(value),
            "NotShowIn" => not = list(value),
            _ => {
                if let Some(locale) = key.strip_prefix("Name[").and_then(|k| k.strip_suffix(']')) {
                    if let Some(rank) = locales.iter().position(|l| l == locale) { localized.push((rank, unescape(value))); }
                }
            }
        }
    }
    if kind != "Application" || hidden || exec.is_empty() { return None; }
    if !only.is_empty() && !only.iter().any(|o| desktops.contains(o)) { return None; }
    if not.iter().any(|n| desktops.contains(n)) { return None; }
    localized.sort_by_key(|(rank, _)| *rank);
    let name = localized.into_iter().next().map(|(_, n)| n).or(name).filter(|n| !n.trim().is_empty())?;
    Some(DesktopEntry { id: id.to_string(), name, exec, icon, mime_types: list(&mime), terminal })
}

/// The ID of a desktop file found at `path` below an `applications` folder: `a/b.desktop` is `a-b.desktop`.
pub fn desktop_file_id(relative: &str) -> String { relative.replace('/', "-") }

/// Splits an `Exec` value into words as the Desktop Entry specification says: spaces separate, double
/// quotes group, and inside quotes a backslash escapes `"`, `` ` ``, `$` and `\`.
pub fn split_exec(exec: &str) -> Vec<String> {
    let mut words = Vec::new();
    let mut current = String::new();
    let (mut in_quotes, mut started) = (false, false);
    let mut chars = exec.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '"' => { in_quotes = !in_quotes; started = true; }
            '\\' if in_quotes => match chars.peek() {
                Some(&n) if matches!(n, '"' | '`' | '$' | '\\') => { current.push(n); chars.next(); }
                _ => current.push('\\'),
            },
            c if c.is_whitespace() && !in_quotes => {
                if started || !current.is_empty() { words.push(std::mem::take(&mut current)); started = false; }
            }
            other => { current.push(other); started = true; }
        }
    }
    if started || !current.is_empty() { words.push(current); }
    words
}

/// The command line for an `Exec` value with the field codes filled in: `%f`, `%u` take the first file,
/// `%F`, `%U` all of them, `%i` becomes `--icon <icon>`, `%c` the name, `%k` the file's path, `%%` a percent
/// sign; the removed codes (`%d %D %n %N %v %m`) vanish.
pub fn exec_arguments(exec: &str, files: &[String], name: &str, icon: &str, desktop_path: &str) -> Vec<String> {
    let mut out = Vec::new();
    for word in split_exec(exec) {
        match word.as_str() {
            "%f" | "%u" => if let Some(first) = files.first() { out.push(first.clone()) },
            "%F" | "%U" => out.extend(files.iter().cloned()),
            "%i" => if !icon.is_empty() { out.push("--icon".into()); out.push(icon.to_string()); },
            _ => {
                let mut text = String::new();
                let mut chars = word.chars();
                while let Some(c) = chars.next() {
                    if c != '%' { text.push(c); continue; }
                    match chars.next() {
                        Some('%') => text.push('%'),
                        Some('c') => text.push_str(name),
                        Some('k') => text.push_str(desktop_path),
                        Some('f' | 'u') => text.push_str(files.first().map(String::as_str).unwrap_or("")),
                        Some('F' | 'U') => text.push_str(&files.join(" ")),
                        Some('i' | 'd' | 'D' | 'n' | 'N' | 'v' | 'm') | None => {}
                        Some(other) => { text.push('%'); text.push(other); }
                    }
                }
                if !text.is_empty() || word.is_empty() { out.push(text); }
            }
        }
    }
    out
}

/// What names a program's process: the first word of its command line without a directory, or without
/// `env VAR=…` and `sh -c` wrappers' own names.
pub fn program_target(exec: &str) -> String {
    let words = split_exec(exec);
    let mut iter = words.iter().peekable();
    while let Some(word) = iter.peek() {
        if word.as_str() == "env" || (word.contains('=') && !word.starts_with('/') && !word.starts_with('%')) { iter.next(); } else { break; }
    }
    iter.next().cloned().unwrap_or_default()
}

// MARK: MIME types to file name extensions

/// Reads `/usr/share/mime/globs2` (`weight:mime:glob[:flags]`) into (mime type, extension with its dot)
/// pairs, for the globs that are plain `*.ext` patterns.
pub fn parse_mime_globs(text: &str) -> Vec<(String, String)> {
    let mut pairs = Vec::new();
    for line in text.lines() {
        if line.starts_with('#') { continue; }
        let mut parts = line.splitn(4, ':');
        let (Some(_weight), Some(mime), Some(glob)) = (parts.next(), parts.next(), parts.next()) else { continue };
        let Some(ext) = glob.strip_prefix("*.") else { continue };
        if ext.is_empty() || ext.contains(['*', '?', '[', '.']) { continue; }
        pairs.push((mime.to_string(), format!(".{}", ext.to_lowercase())));
    }
    pairs
}

/// The extensions a program opens, from the MIME types its `.desktop` file names.
pub fn extensions_for(mimes: &[String], globs: &[(String, String)]) -> Vec<String> {
    let mut out: Vec<String> = globs.iter().filter(|(mime, _)| mimes.contains(mime)).map(|(_, ext)| ext.clone()).collect();
    out.sort();
    out.dedup();
    out
}

// MARK: Icons

/// Square icon sizes themes ship, in the order worth trying for a wanted size: the next ones up first
/// (smallest first), then smaller ones (largest first).
pub fn icon_size_order(wanted: u32) -> Vec<u32> {
    const SIZES: [u32; 11] = [16, 22, 24, 32, 48, 64, 96, 128, 192, 256, 512];
    let mut up: Vec<u32> = SIZES.iter().copied().filter(|s| *s >= wanted).collect();
    let mut down: Vec<u32> = SIZES.iter().copied().filter(|s| *s < wanted).collect();
    down.reverse();
    up.extend(down);
    up
}

/// Where an icon named `name` may be, best first, for the icon folders `bases` (each holding theme folders)
/// and the `themes` to look in. A name that is a path stands for itself.
pub fn icon_candidates(name: &str, wanted: u32, bases: &[PathBuf], themes: &[String], pixmaps: &[PathBuf]) -> Vec<PathBuf> {
    if name.starts_with('/') { return vec![PathBuf::from(name)]; }
    let stem = ["png", "xpm", "svg"].iter().find_map(|e| name.strip_suffix(&format!(".{e}"))).unwrap_or(name);
    let mut out = Vec::new();
    for size in icon_size_order(wanted) {
        for base in bases {
            for theme in themes {
                out.push(base.join(theme).join(format!("{size}x{size}")).join("apps").join(format!("{stem}.png")));
                out.push(base.join(theme).join("apps").join(size.to_string()).join(format!("{stem}.png")));
            }
        }
    }
    for dir in pixmaps { out.push(dir.join(format!("{stem}.png"))); }
    out
}

/// Scales an RGBA picture (straight alpha) to fit a `size` x `size` square, centred on a clear background,
/// and returns it as 32-bit BGRA with the colour multiplied by the opacity: what `ICON` carries.
pub fn fit_to_bgra_premultiplied(rgba: &[u8], width: usize, height: usize, size: usize) -> Vec<u8> {
    let mut out = vec![0u8; size * size * 4];
    if width == 0 || height == 0 || size == 0 || rgba.len() < width * height * 4 { return out; }
    let scale = (size as f64 / width as f64).min(size as f64 / height as f64);
    let (w, h) = (((width as f64 * scale).round() as usize).clamp(1, size), ((height as f64 * scale).round() as usize).clamp(1, size));
    let (left, top) = ((size - w) / 2, (size - h) / 2);
    // Premultiplied source samples, so averaging never bleeds the colour of clear pixels.
    let sample = |x: usize, y: usize| -> [f64; 4] {
        let p = &rgba[(y * width + x) * 4..][..4];
        let a = p[3] as f64 / 255.0;
        [p[0] as f64 * a, p[1] as f64 * a, p[2] as f64 * a, p[3] as f64]
    };
    for oy in 0..h {
        // The source rows and columns this output pixel covers (a box average, which is what looks right
        // when shrinking; for enlarging the box is one pixel).
        let (y0, y1) = (oy as f64 / scale, ((oy + 1) as f64 / scale).max(oy as f64 / scale + 1.0));
        for ox in 0..w {
            let (x0, x1) = (ox as f64 / scale, ((ox + 1) as f64 / scale).max(ox as f64 / scale + 1.0));
            let (mut sum, mut weight) = ([0.0f64; 4], 0.0f64);
            let (ya, yb) = (y0.floor() as usize, (y1.ceil() as usize).min(height));
            let (xa, xb) = (x0.floor() as usize, (x1.ceil() as usize).min(width));
            for sy in ya..yb.max(ya + 1).min(height) {
                let wy = (y1.min(sy as f64 + 1.0) - y0.max(sy as f64)).max(0.0);
                for sx in xa..xb.max(xa + 1).min(width) {
                    let wx = (x1.min(sx as f64 + 1.0) - x0.max(sx as f64)).max(0.0);
                    let s = sample(sx, sy);
                    let wgt = wx * wy;
                    for i in 0..4 { sum[i] += s[i] * wgt; }
                    weight += wgt;
                }
            }
            if weight <= 0.0 { continue; }
            let at = ((top + oy) * size + left + ox) * 4;
            out[at] = (sum[2] / weight).round().clamp(0.0, 255.0) as u8;
            out[at + 1] = (sum[1] / weight).round().clamp(0.0, 255.0) as u8;
            out[at + 2] = (sum[0] / weight).round().clamp(0.0, 255.0) as u8;
            out[at + 3] = (sum[3] / weight).round().clamp(0.0, 255.0) as u8;
        }
    }
    out
}

/// The best picture from a `_NET_WM_ICON` value (a run of `width, height, width*height ARGB pixels`):
/// the smallest one at least `wanted` pixels on its longer side, else the largest. Returned as straight RGBA.
pub fn pick_net_wm_icon(data: &[u32], wanted: u32) -> Option<(usize, usize, Vec<u8>)> {
    let mut best: Option<(usize, usize, &[u32])> = None;
    let mut at = 0;
    while at + 2 <= data.len() {
        let (w, h) = (data[at] as usize, data[at + 1] as usize);
        at += 2;
        let count = w.checked_mul(h)?;
        if w == 0 || h == 0 || w > 1024 || h > 1024 || at + count > data.len() { break; }
        let pixels = &data[at..at + count];
        at += count;
        let side = w.max(h) as u32;
        let better = match best {
            None => true,
            Some((bw, bh, _)) => {
                let best_side = bw.max(bh) as u32;
                if best_side >= wanted { side >= wanted && side < best_side } else { side > best_side }
            }
        };
        if better { best = Some((w, h, pixels)); }
    }
    let (w, h, pixels) = best?;
    let mut rgba = Vec::with_capacity(w * h * 4);
    for p in pixels { rgba.extend_from_slice(&[(p >> 16) as u8, (p >> 8) as u8, *p as u8, (p >> 24) as u8]); }
    Some((w, h, rgba))
}

// MARK: Accounts

/// One line of `/etc/passwd`.
#[derive(Debug, Clone, PartialEq)]
pub struct Account {
    pub name: String,
    pub uid: u32,
    pub gid: u32,
    pub home: PathBuf,
}

/// The accounts of `/etc/passwd`.
pub fn parse_passwd(text: &str) -> Vec<Account> {
    text.lines().filter_map(|line| {
        let f: Vec<&str> = line.split(':').collect();
        if f.len() < 6 || f[0].is_empty() || f[0].starts_with('#') { return None; }
        Some(Account { name: f[0].to_string(), uid: f[2].parse().ok()?, gid: f[3].parse().ok()?, home: PathBuf::from(f[5]) })
    }).collect()
}

/// A person's account: an ID in the range normal users get, with a home folder that exists.
pub fn is_person(account: &Account, home_exists: bool) -> bool {
    account.uid >= 1000 && account.uid < 60000 && home_exists && account.name != "nobody"
}

/// The guest path of a shared Mac document: `root` is where the shares are mounted and `relative` is
/// `<share>/<path below it>` as the host writes it. Refuses anything that would leave the shares.
pub fn shared_document_path(root: &str, relative: &str, mount_name: &dyn Fn(&str) -> String) -> Option<String> {
    let parts: Vec<&str> = relative.split('/').filter(|p| !p.is_empty()).collect();
    if parts.len() < 2 { return None; }
    if parts.iter().any(|p| *p == "." || *p == ".." || p.contains('\0')) { return None; }
    let rest = parts[1..].join("/");
    Some(format!("{}/{}/{}", root.trim_end_matches('/'), mount_name(parts[0]), rest))
}

// MARK: X authority

/// The cookie for display number `display` of this host from the bytes of an `.Xauthority` file:
/// the authorisation name and data. Entries for another display number are skipped; an entry with
/// no number matches any.
pub fn parse_xauthority(bytes: &[u8], display: &str, hostname: &str) -> Option<(Vec<u8>, Vec<u8>)> {
    let mut at = 0;
    let take = |at: &mut usize| -> Option<&[u8]> {
        let len = u16::from_be_bytes(bytes.get(*at..*at + 2)?.try_into().ok()?) as usize;
        let part = bytes.get(*at + 2..*at + 2 + len)?;
        *at += 2 + len;
        Some(part)
    };
    let mut wild: Option<(Vec<u8>, Vec<u8>)> = None;
    while at + 2 <= bytes.len() {
        let family = u16::from_be_bytes(bytes[at..at + 2].try_into().ok()?);
        at += 2;
        // A file cut short ends the search with what was found so far.
        let (Some(address), Some(number), Some(name), Some(data)) = (take(&mut at), take(&mut at), take(&mut at), take(&mut at)) else { break };
        if name != b"MIT-MAGIC-COOKIE-1" { continue; }
        if !number.is_empty() && number != display.as_bytes() { continue; }
        let entry = (name.to_vec(), data.to_vec());
        match family {
            256 if address == hostname.as_bytes() => return Some(entry), // Local
            65535 => wild = wild.or(Some(entry)),                          // Wild
            256 => wild = wild.or(Some(entry)),                            // a renamed host: still this machine's socket
            _ => {}
        }
    }
    wild
}

/// The display number and socket path of a `DISPLAY` value for a local display (`:0`, `:1.0`, `unix:0`).
pub fn local_display(display: &str) -> Option<(String, PathBuf)> {
    let rest = display.strip_prefix("unix:").or_else(|| display.strip_prefix(':'))?;
    let number: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
    if number.is_empty() { return None; }
    Some((number.clone(), PathBuf::from(format!("/tmp/.X11-unix/X{number}"))))
}

// MARK: X11 window facts

/// "app", "popup" or "taskbar" from a window's `_NET_WM_WINDOW_TYPE` atom names (no type means a normal window).
pub fn window_kind(types: &[String]) -> &'static str {
    let has = |name: &str| types.iter().any(|t| t == name);
    if has("_NET_WM_WINDOW_TYPE_DOCK") || has("_NET_WM_WINDOW_TYPE_DESKTOP") { return "taskbar"; }
    const POPUPS: [&str; 8] = ["_NET_WM_WINDOW_TYPE_MENU", "_NET_WM_WINDOW_TYPE_DROPDOWN_MENU", "_NET_WM_WINDOW_TYPE_POPUP_MENU",
        "_NET_WM_WINDOW_TYPE_TOOLTIP", "_NET_WM_WINDOW_TYPE_NOTIFICATION", "_NET_WM_WINDOW_TYPE_COMBO",
        "_NET_WM_WINDOW_TYPE_DND", "_NET_WM_WINDOW_TYPE_SPLASH"];
    if POPUPS.iter().any(|p| has(p)) { return "popup"; }
    "app"
}

/// "minimized", "maximized" or "normal" from `_NET_WM_STATE` atom names.
pub fn window_state(states: &[String]) -> &'static str {
    let has = |name: &str| states.iter().any(|s| s == name);
    if has("_NET_WM_STATE_HIDDEN") { "minimized" }
    else if has("_NET_WM_STATE_MAXIMIZED_HORZ") && has("_NET_WM_STATE_MAXIMIZED_VERT") { "maximized" }
    else { "normal" }
}

/// Whether a window should be listed for the host at all: the desktop's own windows and tiny helper
/// windows are not program windows.
pub fn worth_listing(kind: &str, width: i32, height: i32, skip_taskbar: bool) -> bool {
    if kind == "taskbar" { return width > 0 && height > 0; }
    width >= 8 && height >= 8 && !(skip_taskbar && kind != "app")
}

/// The desktop names from `XDG_CURRENT_DESKTOP` (`ubuntu:GNOME`, `MATE`).
pub fn desktop_names(value: &str) -> Vec<String> {
    value.split(':').filter(|s| !s.is_empty()).map(str::to_string).collect()
}

/// Locale tags to try for a name, most specific first, from `LANG`-style values (`de_DE.UTF-8@euro`).
pub fn locale_tags(value: &str) -> Vec<String> {
    let base = value.split(['.', '@']).next().unwrap_or("");
    if base.is_empty() || base == "C" || base == "POSIX" { return Vec::new(); }
    let mut tags = vec![base.to_string()];
    if let Some((lang, _)) = base.split_once('_') { tags.push(lang.to_string()); }
    tags
}

// MARK: The user's folders

/// `XDG_*_DIR="$HOME/…"` lines of `user-dirs.dirs` as (key without `XDG_` and `_DIR`, path).
pub fn parse_user_dirs(text: &str, home: &Path) -> Vec<(String, PathBuf)> {
    let mut out = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        let Some(rest) = line.strip_prefix("XDG_") else { continue };
        let Some((key, value)) = rest.split_once("_DIR=") else { continue };
        let value = value.trim().trim_matches('"');
        let path = match value.strip_prefix("$HOME") {
            Some(tail) => home.join(tail.trim_start_matches('/')),
            None if value.starts_with('/') => PathBuf::from(value),
            None => continue,
        };
        out.push((key.to_string(), path));
    }
    out
}

/// The folder a file manager window shows, guessed from its title (file managers show the folder's name
/// and not its path): the home folder, one of the user's special folders, or a folder directly below home.
pub fn folder_from_title(title: &str, user: &str, home: &Path, special: &[(String, PathBuf)], is_dir: &dyn Fn(&Path) -> bool) -> Option<PathBuf> {
    // "Documents - File Manager", "Documents — Files", "Documents - Caja": the folder is the first part.
    let name = [" - ", " — ", " – "].iter().find_map(|sep| title.split_once(sep).map(|(first, _)| first.to_string())).unwrap_or_else(|| title.to_string());
    let name = name.trim().trim_end_matches('/').to_string();
    if name.is_empty() { return None; }
    let lower = name.to_lowercase();
    if lower == "home" || lower == "home folder" || lower == user.to_lowercase() || lower == format!("{}'s home", user.to_lowercase()) { return Some(home.to_path_buf()); }
    if let Some((_, path)) = special.iter().find(|(_, p)| p.file_name().map(|f| f.to_string_lossy().to_lowercase()) == Some(lower.clone())) {
        return is_dir(path).then(|| path.clone());
    }
    if name.contains('/') || name == "." || name == ".." { return None; }
    let below = home.join(&name);
    is_dir(&below).then_some(below)
}

/// Window classes of file managers.
pub fn is_file_manager(class: &str) -> bool {
    let lower = class.to_lowercase();
    ["caja", "nautilus", "thunar", "nemo", "pcmanfm", "dolphin", "pantheon-files", "files", "spacefm", "doublecmd", "krusader"].iter().any(|m| lower == *m || lower.ends_with(&format!(".{m}")))
}

// MARK: Files a file manager copies

/// Percent-decodes a `file://` URI into a path; None for anything else.
pub fn file_uri_to_path(uri: &str) -> Option<String> {
    let rest = uri.strip_prefix("file://")?;
    let path = rest.find('/').map(|i| &rest[i..])?; // drop an optional host
    let bytes = path.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = std::str::from_utf8(bytes.get(i + 1..i + 3)?).ok()?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else { out.push(bytes[i]); i += 1; }
    }
    String::from_utf8(out).ok()
}

/// The paths in `text/uri-list` text or in a file manager's `x-special/…-copied-files` text (a first line of
/// `copy` or `cut`, then one URI per line). Duplicates and comments are dropped.
pub fn parse_uri_list(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    for line in text.lines().map(str::trim) {
        if line.is_empty() || line.starts_with('#') || line == "copy" || line == "cut" { continue; }
        if let Some(path) = file_uri_to_path(line) { if !out.contains(&path) { out.push(path); } }
    }
    out
}

/// Which clipboard target holds the copied files, from the list the clipboard offers, best first.
pub fn copied_files_target(targets: &str) -> Option<&'static str> {
    const WANTED: [&str; 4] = ["x-special/mate-copied-files", "x-special/gnome-copied-files", "x-special/nautilus-clipboard", "text/uri-list"];
    WANTED.into_iter().find(|w| targets.lines().any(|t| t.trim() == *w))
}

// MARK: Screen sizes the display driver does not list

/// A video mode in the form `xrandr --newmode` takes: the pixel clock in MHz, then the horizontal and
/// vertical timings (shown, sync start, sync end, total).
#[derive(Debug, Clone, PartialEq)]
pub struct Modeline {
    pub clock_mhz: f64,
    pub horizontal: [u32; 4],
    pub vertical: [u32; 4],
}

impl Modeline {
    /// The arguments after the mode's name for `xrandr --newmode`.
    pub fn xrandr_arguments(&self) -> Vec<String> {
        let mut args = vec![format!("{:.2}", self.clock_mhz)];
        args.extend(self.horizontal.iter().map(u32::to_string));
        args.extend(self.vertical.iter().map(u32::to_string));
        args.push("+hsync".into());
        args.push("-vsync".into());
        args
    }
}

/// The VESA CVT mode with reduced blanking (what `cvt -r` prints) for a size at `hz` refresh: short
/// blanking intervals, which virtual displays and flat panels take. The width is rounded down to a
/// multiple of 8, as CVT does.
pub fn cvt_reduced_blanking(width: u32, height: u32, hz: f64) -> Modeline {
    let h = (width / 8) * 8;
    let v = height;
    // The vertical sync width depends on the picture's shape.
    let vsync: u32 = if h * 3 == v * 4 { 4 } else if h * 9 == v * 16 { 5 } else if h * 10 == v * 16 { 6 }
        else if h * 4 == v * 5 || h * 9 == v * 15 { 7 } else { 10 };
    let line_period_us = (1_000_000.0 / hz - 460.0) / v as f64;
    let blanking_lines = (460.0 / line_period_us).floor() as u32 + 1;
    let blanking = blanking_lines.max(3 + vsync + 6);
    let (total_h, total_v) = (h + 160, v + blanking);
    let clock = (hz * total_v as f64 * total_h as f64 / 1_000_000.0 / 0.25).floor() * 0.25;
    Modeline {
        clock_mhz: clock,
        horizontal: [h, h + 48, h + 48 + 32, total_h],
        vertical: [v, v + 3, v + 3 + vsync, total_v],
    }
}

// MARK: "Send to Mac" entries for file managers

pub const SEND_TO_NAME: &str = "Send to Mac (Tandem)";

/// A script for the Nautilus, Caja and similar "Scripts" menus.
pub fn send_to_script(agent: &str) -> String {
    format!("#!/bin/sh\n# Installed by the Tandem guest tools.\nexec {agent} send-to-mac \"$@\"\n")
}

/// A Nemo action (Nemo's right-click menu).
pub fn nemo_action(agent: &str) -> String {
    format!("[Nemo Action]\nName={SEND_TO_NAME}\nComment=Copy the selected files to the Mac\nExec={agent} send-to-mac %F\nIcon-Name=go-next\nSelection=any\nExtensions=any;\n")
}

/// A Thunar custom action (`uca.xml` entry); the unique id marks it as ours.
pub fn thunar_action(agent: &str) -> String {
    format!("<action>\n\t<icon>go-next</icon>\n\t<name>{SEND_TO_NAME}</name>\n\t<unique-id>tandem-send-to-mac-1</unique-id>\n\t<command>{agent} send-to-mac %F</command>\n\t<description>Copy the selected files to the Mac</description>\n\t<patterns>*</patterns>\n\t<directories/>\n\t<audio-files/>\n\t<image-files/>\n\t<other-files/>\n\t<text-files/>\n\t<video-files/>\n</action>\n")
}

/// A libfm file-manager action (PCManFM and friends).
pub fn libfm_action(agent: &str) -> String {
    format!("[Desktop Entry]\nType=Action\nName={SEND_TO_NAME}\nIcon=go-next\nTcandidates=all\nProfiles=profile-zero;\n\n[X-Action-Profile profile-zero]\nExec={agent} send-to-mac %F\nName=Default profile\n")
}

/// Adds Thunar's action to an existing `uca.xml`, or makes a new one; None when it is there already.
pub fn merge_thunar_uca(existing: Option<&str>, agent: &str) -> Option<String> {
    let action = thunar_action(agent);
    match existing {
        None => Some(format!("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<actions>\n{action}</actions>\n")),
        Some(text) if text.contains("tandem-send-to-mac-") => None,
        Some(text) => text.rfind("</actions>").map(|at| format!("{}{}{}", &text[..at], action, &text[at..])),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strings(items: &[&str]) -> Vec<String> { items.iter().map(|s| s.to_string()).collect() }

    #[test]
    fn desktop_entry_is_read_and_filtered() {
        let text = "[Desktop Entry]\nType=Application\nName=Text Editor\nName[de]=Texteditor\nName[de_DE]=Texteditor (DE)\nExec=pluma %U\nIcon=accessories-text-editor\nMimeType=text/plain;text/x-c;\nCategories=Utility;\n\n[Desktop Action new]\nName=New Window\nExec=pluma --new-window\n";
        let entry = parse_desktop_entry("pluma.desktop", text, &strings(&["MATE"]), &[]).unwrap();
        assert_eq!((entry.name.as_str(), entry.exec.as_str(), entry.icon.as_str()), ("Text Editor", "pluma %U", "accessories-text-editor"));
        assert_eq!(entry.mime_types, strings(&["text/plain", "text/x-c"]));
        let german = parse_desktop_entry("pluma.desktop", text, &strings(&["MATE"]), &strings(&["de_DE", "de"])).unwrap();
        assert_eq!(german.name, "Texteditor (DE)", "the most specific tag wins");
        assert!(parse_desktop_entry("x.desktop", "[Desktop Entry]\nType=Application\nName=X\nExec=x\nNoDisplay=true\n", &[], &[]).is_none());
        assert!(parse_desktop_entry("x.desktop", "[Desktop Entry]\nType=Application\nName=X\nExec=x\nHidden=true\n", &[], &[]).is_none());
        assert!(parse_desktop_entry("x.desktop", "[Desktop Entry]\nType=Link\nName=X\nURL=http://x\n", &[], &[]).is_none());
        assert!(parse_desktop_entry("x.desktop", "[Desktop Entry]\nType=Application\nName=X\n", &[], &[]).is_none(), "no command");
        assert!(parse_desktop_entry("x.desktop", "[Desktop Entry]\nType=Application\nName=X\nExec=x\nOnlyShowIn=GNOME;\n", &strings(&["MATE"]), &[]).is_none());
        assert!(parse_desktop_entry("x.desktop", "[Desktop Entry]\nType=Application\nName=X\nExec=x\nOnlyShowIn=GNOME;MATE;\n", &strings(&["MATE"]), &[]).is_some());
        assert!(parse_desktop_entry("x.desktop", "[Desktop Entry]\nType=Application\nName=X\nExec=x\nNotShowIn=MATE;\n", &strings(&["MATE"]), &[]).is_none());
        assert_eq!(desktop_file_id("kde/app.desktop"), "kde-app.desktop");
    }

    #[test]
    fn exec_lines_follow_the_specification() {
        assert_eq!(split_exec(r#"env "FOO=a b" "/opt/my app/run" --flag"#), strings(&["env", "FOO=a b", "/opt/my app/run", "--flag"]));
        assert_eq!(split_exec(r#"sh -c "echo \"hi\" \$HOME""#), strings(&["sh", "-c", r#"echo "hi" $HOME"#]));
        assert_eq!(split_exec(r#"a "" b"#), strings(&["a", "", "b"]));
        let files = strings(&["/home/u/a.txt", "/home/u/b c.txt"]);
        assert_eq!(exec_arguments("pluma %U", &files, "Pluma", "", ""), strings(&["pluma", "/home/u/a.txt", "/home/u/b c.txt"]));
        assert_eq!(exec_arguments("pluma %f", &files, "Pluma", "", ""), strings(&["pluma", "/home/u/a.txt"]));
        assert_eq!(exec_arguments("pluma %U", &[], "Pluma", "", ""), strings(&["pluma"]));
        assert_eq!(exec_arguments("app %i %c --pct=100%% %k", &[], "My App", "icon-name", "/usr/share/applications/app.desktop"),
                   strings(&["app", "--icon", "icon-name", "My App", "--pct=100%", "/usr/share/applications/app.desktop"]));
        assert_eq!(exec_arguments("app --file=%f", &files, "A", "", ""), strings(&["app", "--file=/home/u/a.txt"]));
        assert_eq!(exec_arguments("app %d %n", &files, "A", "", ""), strings(&["app"]));
        assert_eq!(program_target("env GTK_DEBUG=1 /usr/bin/pluma %U"), "/usr/bin/pluma");
        assert_eq!(program_target("firefox %u"), "firefox");
        assert_eq!(program_target(""), "");
    }

    #[test]
    fn mime_globs_become_extensions() {
        let globs = parse_mime_globs("# comment\n50:text/plain:*.txt\n50:text/x-c:*.c\n50:text/x-c:*.h\n50:application/x-tar:*.tar.gz\n10:image/png:*.PNG\n50:text/x-makefile:Makefile\n50:video/mp4:*.mp4:cs\n");
        assert_eq!(extensions_for(&strings(&["text/plain", "text/x-c", "video/mp4"]), &globs), strings(&[".c", ".h", ".mp4", ".txt"]));
        assert_eq!(extensions_for(&strings(&["image/png"]), &globs), strings(&[".png"]));
        assert!(extensions_for(&strings(&["application/x-tar"]), &globs).is_empty(), "compound extensions are not offered");
        assert!(extensions_for(&[], &globs).is_empty());
    }

    #[test]
    fn icon_sizes_and_candidates() {
        assert_eq!(icon_size_order(48), vec![48, 64, 96, 128, 192, 256, 512, 32, 24, 22, 16]);
        assert_eq!(icon_size_order(1000)[0], 512);
        assert_eq!(icon_size_order(8)[0], 16);
        let bases = vec![PathBuf::from("/usr/share/icons")];
        let themes = strings(&["hicolor", "Yaru"]);
        let pix = vec![PathBuf::from("/usr/share/pixmaps")];
        let candidates = icon_candidates("firefox", 48, &bases, &themes, &pix);
        assert_eq!(candidates[0], PathBuf::from("/usr/share/icons/hicolor/48x48/apps/firefox.png"));
        assert_eq!(candidates[1], PathBuf::from("/usr/share/icons/hicolor/apps/48/firefox.png"));
        assert_eq!(candidates[2], PathBuf::from("/usr/share/icons/Yaru/48x48/apps/firefox.png"));
        assert_eq!(candidates.last().unwrap(), &PathBuf::from("/usr/share/pixmaps/firefox.png"));
        assert_eq!(icon_candidates("foo.svg", 32, &bases, &themes, &[])[0], PathBuf::from("/usr/share/icons/hicolor/32x32/apps/foo.png"));
        assert_eq!(icon_candidates("/opt/x/icon.png", 32, &bases, &themes, &pix), vec![PathBuf::from("/opt/x/icon.png")]);
    }

    #[test]
    fn pictures_are_fitted_premultiplied_and_swapped_to_bgra() {
        // One opaque red pixel scaled up to 4x4.
        let out = fit_to_bgra_premultiplied(&[255, 0, 0, 255], 1, 1, 4);
        assert_eq!(out.len(), 64);
        assert!(out.chunks(4).all(|p| p == [0, 0, 255, 255]), "BGRA of opaque red");
        // A wide 2x1 picture (left green, right clear) in a 4x4 square: centred, two rows tall, padded clear.
        let wide = fit_to_bgra_premultiplied(&[0, 255, 0, 255, 0, 0, 0, 0], 2, 1, 4);
        let pixel = |x: usize, y: usize| &wide[(y * 4 + x) * 4..][..4];
        assert_eq!(pixel(0, 0), [0, 0, 0, 0], "padding above");
        assert_eq!(pixel(0, 1), [0, 255, 0, 255], "green on the left");
        assert_eq!(pixel(3, 1), [0, 0, 0, 0], "clear on the right");
        assert_eq!(pixel(0, 3), [0, 0, 0, 0], "padding below");
        // Half-transparent white: premultiplied colour is half as bright as the opacity says.
        let half = fit_to_bgra_premultiplied(&[255, 255, 255, 128], 1, 1, 1);
        assert_eq!(half, vec![128, 128, 128, 128]);
        // Shrinking averages: a 2x2 of black and white becomes mid grey.
        let mixed = fit_to_bgra_premultiplied(&[0, 0, 0, 255, 255, 255, 255, 255, 255, 255, 255, 255, 0, 0, 0, 255], 2, 2, 1);
        assert_eq!(mixed, vec![128, 128, 128, 255]);
        assert_eq!(fit_to_bgra_premultiplied(&[], 0, 0, 2), vec![0; 16]);
    }

    #[test]
    fn net_wm_icon_picks_a_size() {
        let mut data = vec![2u32, 2];
        data.extend([0xFF11_2233, 0xFF11_2233, 0xFF11_2233, 0xFF11_2233]);
        data.extend([4u32, 4]);
        data.extend(std::iter::repeat(0x80FF_0000).take(16));
        let (w, _, rgba) = pick_net_wm_icon(&data, 3).unwrap();
        assert_eq!(w, 4, "the smallest that is big enough");
        assert_eq!(&rgba[..4], [255, 0, 0, 128]);
        let (w, _, rgba) = pick_net_wm_icon(&data, 2).unwrap();
        assert_eq!(w, 2);
        assert_eq!(&rgba[..4], [0x11, 0x22, 0x33, 255]);
        assert_eq!(pick_net_wm_icon(&data, 64).unwrap().0, 4, "else the largest");
        assert!(pick_net_wm_icon(&[], 16).is_none());
        assert!(pick_net_wm_icon(&[4, 4, 1, 2], 16).is_none(), "cut short");
        assert!(pick_net_wm_icon(&[0, 0], 16).is_none());
    }

    fn xauth_entry(family: u16, address: &str, number: &str, name: &str, data: &[u8]) -> Vec<u8> {
        let mut out = family.to_be_bytes().to_vec();
        for part in [address.as_bytes(), number.as_bytes(), name.as_bytes(), data] {
            out.extend((part.len() as u16).to_be_bytes());
            out.extend(part);
        }
        out
    }

    #[test]
    fn xauthority_cookie_is_found() {
        let mut file = xauth_entry(256, "other", "0", "MIT-MAGIC-COOKIE-1", b"wrong");
        file.extend(xauth_entry(256, "ubuntu", "1", "MIT-MAGIC-COOKIE-1", b"display1"));
        file.extend(xauth_entry(256, "ubuntu", "0", "XDM-AUTHORIZATION-1", b"nope"));
        file.extend(xauth_entry(256, "ubuntu", "0", "MIT-MAGIC-COOKIE-1", b"right"));
        assert_eq!(parse_xauthority(&file, "0", "ubuntu"), Some((b"MIT-MAGIC-COOKIE-1".to_vec(), b"right".to_vec())));
        assert_eq!(parse_xauthority(&file, "1", "ubuntu").unwrap().1, b"display1");
        let wild = xauth_entry(65535, "", "", "MIT-MAGIC-COOKIE-1", b"any");
        assert_eq!(parse_xauthority(&wild, "7", "ubuntu").unwrap().1, b"any");
        // A cut-off file ends the search; a cookie for another host name is the fallback (a renamed machine).
        assert_eq!(parse_xauthority(&file[..file.len() - 3], "0", "ubuntu").map(|e| e.1), Some(b"wrong".to_vec()));
        assert_eq!(parse_xauthority(b"", "0", "h"), None);
        assert_eq!(local_display(":0"), Some(("0".into(), PathBuf::from("/tmp/.X11-unix/X0"))));
        assert_eq!(local_display(":10.1").unwrap().0, "10");
        assert_eq!(local_display("unix:2").unwrap().0, "2");
        assert_eq!(local_display("host:0"), None);
    }

    #[test]
    fn accounts_and_shared_documents() {
        let accounts = parse_passwd("root:x:0:0:root:/root:/bin/bash\nkim:x:1000:1000:Kim,,,:/home/kim:/bin/bash\nnobody:x:65534:65534::/nonexistent:/usr/sbin/nologin\nbad line\n");
        assert_eq!(accounts.len(), 3);
        assert_eq!(accounts[1], Account { name: "kim".into(), uid: 1000, gid: 1000, home: PathBuf::from("/home/kim") });
        assert!(is_person(&accounts[1], true) && !is_person(&accounts[1], false) && !is_person(&accounts[0], true) && !is_person(&accounts[2], true));
        let mount = |name: &str| name.replace('/', "_");
        assert_eq!(shared_document_path("/media/mac", "Home/notes/a b.txt", &mount).as_deref(), Some("/media/mac/Home/notes/a b.txt"));
        assert_eq!(shared_document_path("/media/mac/", "Home/a.txt", &mount).as_deref(), Some("/media/mac/Home/a.txt"));
        assert_eq!(shared_document_path("/media/mac", "Home/../../etc/passwd", &mount), None);
        assert_eq!(shared_document_path("/media/mac", "Home", &mount), None, "a share alone is not a document");
        assert_eq!(shared_document_path("/media/mac", "Home/./a", &mount), None);
    }

    #[test]
    fn window_facts() {
        assert_eq!(window_kind(&[]), "app");
        assert_eq!(window_kind(&strings(&["_NET_WM_WINDOW_TYPE_DIALOG"])), "app");
        assert_eq!(window_kind(&strings(&["_NET_WM_WINDOW_TYPE_DOCK"])), "taskbar");
        assert_eq!(window_kind(&strings(&["_NET_WM_WINDOW_TYPE_DROPDOWN_MENU", "_NET_WM_WINDOW_TYPE_NORMAL"])), "popup");
        assert_eq!(window_state(&strings(&["_NET_WM_STATE_HIDDEN"])), "minimized");
        assert_eq!(window_state(&strings(&["_NET_WM_STATE_MAXIMIZED_VERT", "_NET_WM_STATE_MAXIMIZED_HORZ"])), "maximized");
        assert_eq!(window_state(&strings(&["_NET_WM_STATE_MAXIMIZED_VERT"])), "normal");
        assert!(worth_listing("app", 800, 600, false));
        assert!(!worth_listing("app", 4, 4, false));
        assert!(worth_listing("taskbar", 1280, 28, true));
        assert!(!worth_listing("popup", 100, 100, true));
        assert_eq!(desktop_names("ubuntu:GNOME"), strings(&["ubuntu", "GNOME"]));
        assert_eq!(locale_tags("de_DE.UTF-8"), strings(&["de_DE", "de"]));
        assert_eq!(locale_tags("en"), strings(&["en"]));
        assert!(locale_tags("C.UTF-8").is_empty());
    }

    #[test]
    fn folders_from_titles() {
        let home = PathBuf::from("/home/kim");
        let special = parse_user_dirs("# comment\nXDG_DESKTOP_DIR=\"$HOME/Desktop\"\nXDG_DOWNLOAD_DIR=\"$HOME/Downloads\"\nXDG_DOCUMENTS_DIR=\"$HOME/Dokumente\"\nXDG_VIDEOS_DIR=\"/mnt/videos\"\nXDG_BAD_DIR=relative\n", &home);
        assert_eq!(special.len(), 4);
        assert_eq!(special[0], ("DESKTOP".to_string(), PathBuf::from("/home/kim/Desktop")));
        assert_eq!(special[3].1, PathBuf::from("/mnt/videos"));
        let exists = |p: &Path| ["/home/kim", "/home/kim/Desktop", "/home/kim/Downloads", "/home/kim/Dokumente", "/home/kim/Projects", "/mnt/videos"].contains(&p.to_str().unwrap());
        let f = |t: &str| folder_from_title(t, "kim", &home, &special, &exists);
        assert_eq!(f("kim"), Some(home.clone()));
        assert_eq!(f("Home"), Some(home.clone()));
        assert_eq!(f("Downloads"), Some(PathBuf::from("/home/kim/Downloads")));
        assert_eq!(f("Dokumente - File Manager"), Some(PathBuf::from("/home/kim/Dokumente")));
        assert_eq!(f("Videos"), Some(PathBuf::from("/mnt/videos")), "the folder is named by its last part");
        assert_eq!(f("Projects — Files"), Some(PathBuf::from("/home/kim/Projects")));
        assert_eq!(f("Nope"), None);
        assert_eq!(f(".."), None);
        assert_eq!(f("a/b"), None);
        assert_eq!(f(""), None);
        assert!(is_file_manager("Caja") && is_file_manager("org.gnome.Nautilus") && is_file_manager("Thunar") && !is_file_manager("Firefox"));
    }

    #[test]
    fn copied_files_from_the_clipboard() {
        assert_eq!(file_uri_to_path("file:///home/kim/a%20b.txt"), Some("/home/kim/a b.txt".into()));
        assert_eq!(file_uri_to_path("file://localhost/tmp/x"), Some("/tmp/x".into()));
        assert_eq!(file_uri_to_path("http://x/y"), None);
        assert_eq!(file_uri_to_path("file:///bad%zz"), None);
        let text = "copy\nfile:///home/kim/a.txt\nfile:///home/kim/My%20Folder\n\n# c\nfile:///home/kim/a.txt\nsmb://nas/x\n";
        assert_eq!(parse_uri_list(text), vec!["/home/kim/a.txt".to_string(), "/home/kim/My Folder".to_string()]);
        assert_eq!(copied_files_target("TARGETS\nx-special/gnome-copied-files\ntext/plain\n"), Some("x-special/gnome-copied-files"));
        assert_eq!(copied_files_target("x-special/mate-copied-files\nx-special/gnome-copied-files"), Some("x-special/mate-copied-files"));
        assert_eq!(copied_files_target("text/uri-list\nUTF8_STRING"), Some("text/uri-list"));
        assert_eq!(copied_files_target("UTF8_STRING\nSTRING"), None);
    }

    #[test]
    fn reduced_blanking_modes_match_cvt() {
        // `cvt -r 1920 1080` and `cvt -r 1280 800`.
        let full_hd = cvt_reduced_blanking(1920, 1080, 60.0);
        assert_eq!(full_hd, Modeline { clock_mhz: 138.5, horizontal: [1920, 1968, 2000, 2080], vertical: [1080, 1083, 1088, 1111] });
        assert_eq!(cvt_reduced_blanking(1280, 800, 60.0),
                   Modeline { clock_mhz: 71.0, horizontal: [1280, 1328, 1360, 1440], vertical: [800, 803, 809, 823] });
        assert_eq!(full_hd.xrandr_arguments(), ["138.50", "1920", "1968", "2000", "2080", "1080", "1083", "1088", "1111", "+hsync", "-vsync"]);
        // An odd size: the width is rounded down to 8, and the mode is sane.
        let odd = cvt_reduced_blanking(1470, 853, 60.0);
        assert_eq!(odd.horizontal[0], 1464);
        assert!(odd.vertical[3] > 853 && odd.clock_mhz > 50.0 && odd.clock_mhz < 150.0);
    }

    #[test]
    fn send_to_entries() {
        assert!(send_to_script("/usr/local/bin/tandem-agent").contains("exec /usr/local/bin/tandem-agent send-to-mac \"$@\""));
        assert!(nemo_action("/x/agent").contains("Exec=/x/agent send-to-mac %F"));
        assert!(libfm_action("/x/agent").contains("Exec=/x/agent send-to-mac %F"));
        let fresh = merge_thunar_uca(None, "/x/agent").unwrap();
        assert!(fresh.starts_with("<?xml") && fresh.contains("<unique-id>tandem-send-to-mac-1</unique-id>") && fresh.trim_end().ends_with("</actions>"));
        let existing = "<?xml version=\"1.0\"?>\n<actions>\n<action><name>Other</name></action>\n</actions>\n";
        let merged = merge_thunar_uca(Some(existing), "/x/agent").unwrap();
        assert!(merged.contains("<name>Other</name>") && merged.contains(SEND_TO_NAME) && merged.trim_end().ends_with("</actions>"));
        assert_eq!(merge_thunar_uca(Some(&merged), "/x/agent"), None, "added once");
        assert_eq!(merge_thunar_uca(Some("not xml"), "/x/agent"), None);
    }
}
