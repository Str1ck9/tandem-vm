//! Files dropped on a guest window from the Mac (event `DROP_FILES`), and files sent to the Mac with
//! `tandem-agent send-to-mac <files…>` (Explorer's "Send to" menu). PROTOCOL.md "file drop".
//!
//! Both go through the share server the host already runs for the guest (WebDAV at 10.0.2.2:<port>),
//! under two hidden names: the host stages dropped files under `TandemDrop`, and takes uploads under
//! `TandemInbox`. Plain HTTP is enough, so nothing here needs Windows' WebDAV client.
use crate::platform;
use link_proto::client::Client;
use link_proto::frame::Buffer;
use link_proto::op;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// Where the guest reaches the host's share server.
pub const HOST: &str = "10.0.2.2";
const INBOX_SHARE: &str = "TandemInbox";
const CALL_TIMEOUT: Option<Duration> = Some(Duration::from_secs(10));

#[derive(Debug, PartialEq)]
pub struct Item {
    /// Below the drop share, percent-encoded as it goes into the URL: `<id>/<name>[/<below>]`.
    pub path: String,
    pub size: u64,
    pub directory: bool,
}

#[derive(Debug, PartialEq)]
pub struct Manifest {
    pub id: String,
    pub port: u16,
    pub share: String,
    pub items: Vec<Item>,
}

impl Manifest {
    pub fn total(&self) -> u64 { self.items.iter().map(|i| i.size).sum() }
}

/// Reads the host's drop description (`FileDrop.Manifest.guestText`).
pub fn parse(text: &str) -> Option<Manifest> {
    let mut lines = text.lines();
    if lines.next()? != "tandem-drop 1" { return None; }
    let mut head = lines.next()?.split('\t');
    let id = head.next()?.to_string();
    let port = head.next()?.parse().ok()?;
    let share = head.next()?.to_string();
    if id.is_empty() || id.contains('/') || share.is_empty() { return None; }
    let mut items = Vec::new();
    for line in lines.filter(|l| !l.is_empty()) {
        let mut parts = line.split('\t');
        let item = match parts.next()? {
            "d" => Item { path: parts.next()?.to_string(), size: 0, directory: true },
            "f" => {
                let size = parts.next()?.parse().ok()?;
                Item { path: parts.next()?.to_string(), size, directory: false }
            }
            _ => return None,
        };
        // Every item lives under this drop, and nothing may climb out of the destination folder.
        let decoded = percent_decode(&item.path)?;
        let mut segments = decoded.split('/');
        if segments.next()? != id { return None; }
        let rest: Vec<&str> = segments.collect();
        if rest.is_empty() || rest.iter().any(|s| s.is_empty() || *s == "." || *s == ".." || s.contains('\\') || s.contains(':')) {
            return None;
        }
        items.push(item);
    }
    Some(Manifest { id, port, share, items })
}

pub fn percent_decode(s: &str) -> Option<String> {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = std::str::from_utf8(bytes.get(i + 1..i + 3)?).ok()?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

pub fn percent_encode(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || b"-._~/".contains(&b) { out.push(b as char) } else { out.push_str(&format!("%{b:02X}")) }
    }
    out
}

/// "report.pdf" taken in `dir` → "report (2).pdf", as Explorer names copies.
pub fn unique_path(dir: &Path, name: &str) -> PathBuf {
    let first = dir.join(name);
    if !first.exists() { return first; }
    let (stem, ext) = match name.rfind('.') {
        Some(dot) if dot > 0 => (&name[..dot], &name[dot..]),
        _ => (name, ""),
    };
    (2..).map(|n| dir.join(format!("{stem} ({n}){ext}"))).find(|p| !p.exists()).unwrap()
}

// MARK: HTTP to the host's share server

fn connect(host: &str, port: u16) -> Result<TcpStream, String> {
    let stream = TcpStream::connect((host, port)).map_err(|e| format!("cannot reach the Mac ({host}:{port}): {e}"))?;
    let _ = stream.set_read_timeout(Some(Duration::from_secs(60)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(60)));
    Ok(stream)
}

/// Reads a response's status line and headers. Returns the status and the content length.
fn read_head(reader: &mut BufReader<TcpStream>) -> Result<(u16, Option<u64>), String> {
    let mut line = String::new();
    reader.read_line(&mut line).map_err(|e| format!("no answer from the Mac: {e}"))?;
    let status = line.split_whitespace().nth(1).and_then(|s| s.parse().ok()).ok_or("the Mac's answer could not be read")?;
    let mut length = None;
    loop {
        line.clear();
        reader.read_line(&mut line).map_err(|e| e.to_string())?;
        let trimmed = line.trim_end();
        if trimmed.is_empty() { break; }
        if let Some((name, value)) = trimmed.split_once(':') {
            if name.eq_ignore_ascii_case("content-length") { length = value.trim().parse().ok(); }
        }
    }
    Ok((status, length))
}

/// Fetches `path` (already percent-encoded, starting with `/`) into `dest`, through a temporary file
/// that is renamed when complete. `progress` gets the bytes written so far.
pub fn http_get(host: &str, port: u16, path: &str, dest: &Path, progress: &mut dyn FnMut(u64)) -> Result<u64, String> {
    let mut stream = connect(host, port)?;
    write!(stream, "GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\nConnection: close\r\n\r\n").map_err(|e| e.to_string())?;
    let mut reader = BufReader::with_capacity(256 * 1024, stream);
    let (status, length) = read_head(&mut reader)?;
    if status != 200 { return Err(format!("the Mac answered {status} for {path}")); }
    let length = length.ok_or("the Mac did not say how long the file is")?;
    let partial = dest.with_file_name(format!("{}.tandem-part", dest.file_name().and_then(|n| n.to_str()).unwrap_or("file")));
    let mut file = std::fs::File::create(&partial).map_err(|e| format!("cannot write {}: {e}", partial.display()))?;
    let mut buffer = vec![0u8; 256 * 1024];
    let mut done: u64 = 0;
    let result = (|| {
        while done < length {
            let want = buffer.len().min((length - done) as usize);
            let n = reader.read(&mut buffer[..want]).map_err(|e| format!("the copy was interrupted: {e}"))?;
            if n == 0 { return Err("the Mac closed the connection early".to_string()); }
            file.write_all(&buffer[..n]).map_err(|e| format!("cannot write {}: {e}", dest.display()))?;
            done += n as u64;
            progress(done);
        }
        file.flush().map_err(|e| e.to_string())
    })();
    drop(file);
    match result {
        Ok(()) => {
            std::fs::rename(&partial, dest).map_err(|e| format!("cannot name {}: {e}", dest.display()))?;
            Ok(done)
        }
        Err(e) => { let _ = std::fs::remove_file(&partial); Err(e) }
    }
}

/// Sends a request with an optional body (a file, or bytes). Returns the status.
pub fn http_send(host: &str, port: u16, method: &str, path: &str, body: Option<Body>) -> Result<u16, String> {
    let mut stream = connect(host, port)?;
    let length = match &body { Some(Body::File(p)) => std::fs::metadata(p).map_err(|e| e.to_string())?.len(), Some(Body::Bytes(b)) => b.len() as u64, None => 0 };
    write!(stream, "{method} {path} HTTP/1.1\r\nHost: {host}:{port}\r\nContent-Length: {length}\r\nConnection: close\r\n\r\n")
        .map_err(|e| e.to_string())?;
    match body {
        Some(Body::File(p)) => {
            let mut file = std::fs::File::open(&p).map_err(|e| format!("cannot read {}: {e}", p.display()))?;
            std::io::copy(&mut file, &mut stream).map_err(|e| format!("the copy was interrupted: {e}"))?;
        }
        Some(Body::Bytes(b)) => stream.write_all(&b).map_err(|e| e.to_string())?,
        None => {}
    }
    let mut reader = BufReader::new(stream);
    Ok(read_head(&mut reader)?.0)
}

pub enum Body { File(PathBuf), Bytes(Vec<u8>) }

// MARK: Mac to guest

fn send_progress(client: &Client, id: &str, bytes: u64, total: u64) {
    let json = format!("{{\"id\":{},\"bytes\":{bytes},\"total\":{total}}}", platform::json_string(id));
    let _ = client.call(op::DROP_PROGRESS, vec![], vec![Buffer::input(json.as_bytes())], CALL_TIMEOUT);
}

fn send_result(client: &Client, id: &str, status: &str, folder: &Path, files: usize, message: Option<&str>) {
    let message = message.map(|m| format!(",\"message\":{}", platform::json_string(m))).unwrap_or_default();
    let json = format!("{{\"id\":{},\"status\":\"{status}\",\"folder\":{},\"files\":{files}{message}}}",
                       platform::json_string(id), platform::json_string(&folder.display().to_string()));
    let _ = client.call(op::DROP_RESULT, vec![], vec![Buffer::input(json.as_bytes())], CALL_TIMEOUT);
}

/// Copies a drop into the folder under the guest pixel `x`, `y` (an Explorer window or the desktop),
/// or into the user's Downloads folder when there is none, and tells the host how it went.
pub fn receive(client: &Client, x: i32, y: i32, data: &[u8]) {
    let Some(manifest) = std::str::from_utf8(data).ok().and_then(parse) else {
        crate::log_local("a file drop could not be read");
        return;
    };
    let (folder, fell_back) = match platform::drop_target_folder(x, y) {
        Some(folder) => (folder, false),
        None => match platform::fallback_drop_folder() {
            Some(folder) => (folder, true),
            None => return send_result(client, &manifest.id, "failed", Path::new(""), 0, Some("Windows has no Downloads folder to copy into.")),
        },
    };
    crate::log_local(&format!("drop {}: {} items to {} ({})", manifest.id, manifest.items.len(), folder.display(),
                              if fell_back { "nothing under the pointer" } else { "under the pointer" }));
    let outcome = copy_drop(client, &manifest, &folder);
    platform::folder_changed(&folder);
    match outcome {
        Ok(files) => send_result(client, &manifest.id, if fell_back { "fallback" } else { "copied" }, &folder, files, None),
        Err(e) => {
            crate::log_local(&format!("drop {} failed: {e}", manifest.id));
            send_result(client, &manifest.id, "failed", &folder, 0, Some(&format!("Windows could not copy the files: {e}")))
        }
    }
}

fn copy_drop(client: &Client, manifest: &Manifest, folder: &Path) -> Result<usize, String> {
    let total = manifest.total();
    // Top-level names that are taken in the destination get a number; what is inside follows them.
    let mut renamed: Vec<(String, PathBuf)> = Vec::new();
    let mut copied_before: u64 = 0;
    let mut files = 0;
    let mut last_report = Instant::now();
    for item in &manifest.items {
        let decoded = percent_decode(&item.path).ok_or("a file name could not be read")?;
        let below: Vec<&str> = decoded.split('/').skip(1).collect();
        let top = below[0].to_string();
        let base = match renamed.iter().find(|(name, _)| *name == top) {
            Some((_, path)) => path.clone(),
            None => {
                let path = unique_path(folder, &top);
                renamed.push((top.clone(), path.clone()));
                path
            }
        };
        let target = below[1..].iter().fold(base, |p, s| p.join(s));
        if item.directory {
            std::fs::create_dir_all(&target).map_err(|e| format!("cannot make the folder {}: {e}", target.display()))?;
            continue;
        }
        if let Some(parent) = target.parent() { let _ = std::fs::create_dir_all(parent); }
        let url = format!("/{}/{}", percent_encode(&manifest.share), item.path);
        let start = copied_before;
        let got = http_get(HOST, manifest.port, &url, &target, &mut |bytes| {
            if last_report.elapsed() > Duration::from_millis(400) {
                last_report = Instant::now();
                send_progress(client, &manifest.id, start + bytes, total);
            }
        })?;
        // The size the Mac announced when the drop was made; anything else means the file changed or broke.
        if got != item.size {
            let _ = std::fs::remove_file(&target);
            return Err(format!("{} arrived with {got} bytes instead of {}", target.display(), item.size));
        }
        copied_before += item.size;
        files += 1;
    }
    send_progress(client, &manifest.id, total, total);
    Ok(files)
}

// MARK: Guest to Mac

/// The share server's port, written by the running agent whenever it hears the host's share list,
/// for `send-to-mac`, which runs as its own process.
fn port_file() -> PathBuf { platform::agent_data_dir().join("host-port") }

pub fn remember_port(port: u16) {
    if port == 0 { return; }
    let _ = std::fs::create_dir_all(platform::agent_data_dir());
    let _ = std::fs::write(port_file(), port.to_string());
}

fn remembered_port() -> Option<u16> { std::fs::read_to_string(port_file()).ok()?.trim().parse().ok() }

/// `tandem-agent send-to-mac <files or folders…>`: uploads them to the Mac's Downloads folder.
/// Returns the process exit code; problems are shown in a message box (it runs from Explorer).
pub fn send_to_mac(paths: &[String]) -> i32 {
    match upload(paths) {
        Ok(_) => 0,
        Err(message) => { platform::message_box("Send to Mac", &message); 1 }
    }
}

fn upload(paths: &[String]) -> Result<usize, String> {
    if paths.is_empty() { return Err("Choose files in Explorer, then Send to > Mac.".into()); }
    let id = format!("{:x}{:x}", std::process::id(), std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0));
    upload_as(paths, &id)
}

/// Files dragged out of a Windows window and dropped on the Mac (`DRAG_OUT_FETCH`): uploaded like
/// "Send to > Mac", under the id the host chose, so the host can hand them to the drop. A failure is
/// still marked done, with no names, so the host stops waiting.
pub fn drag_out_fetch(text: &str) {
    let mut lines = text.lines();
    let Some(id) = lines.next().map(str::trim).filter(|i| i.starts_with("dragout-") && i.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')) else {
        crate::log_local("drag out: a fetch without a valid id was ignored");
        return;
    };
    let paths: Vec<String> = lines.map(str::to_string).filter(|p| !p.is_empty()).collect();
    if let Err(e) = upload_as(&paths, id) {
        crate::log_local(&format!("drag out {id} failed: {e}"));
        if let Some(port) = remembered_port() {
            let _ = http_send(HOST, port, "PUT", &format!("/{INBOX_SHARE}/{id}.done"), Some(Body::Bytes(Vec::new())));
        }
    }
}

fn upload_as(paths: &[String], id: &str) -> Result<usize, String> {
    let port = remembered_port().ok_or("The Tandem guest tools have not connected to the Mac yet.")?;
    let base = format!("/{INBOX_SHARE}/{id}");
    match http_send(HOST, port, "MKCOL", &base, None)? {
        201 | 200 | 405 => {}
        403 | 404 => return Err("Sending files to the Mac is turned off for this virtual machine (Configure > Options > Sharing > Clipboard on the Mac).".into()),
        other => return Err(format!("The Mac refused the files ({other}).")),
    }
    let mut names = Vec::new();
    let mut count = 0;
    for path in paths {
        let source = PathBuf::from(path);
        let name = source.file_name().and_then(|n| n.to_str()).ok_or(format!("“{path}” has no name"))?.to_string();
        count += upload_item(port, &source, &format!("{base}/{}", percent_encode(&name)))?;
        names.push(name);
    }
    let done = format!("/{INBOX_SHARE}/{id}.done");
    let status = http_send(HOST, port, "PUT", &done, Some(Body::Bytes((names.join("\n") + "\n").into_bytes())))?;
    if !(200..300).contains(&status) { return Err(format!("The Mac refused the files ({status}).")); }
    Ok(count)
}

fn upload_item(port: u16, source: &Path, url: &str) -> Result<usize, String> {
    let meta = std::fs::metadata(source).map_err(|e| format!("cannot read {}: {e}", source.display()))?;
    if meta.is_dir() {
        let status = http_send(HOST, port, "MKCOL", url, None)?;
        if !(200..300).contains(&status) && status != 405 { return Err(format!("The Mac refused the folder {} ({status}).", source.display())); }
        let mut count = 0;
        for entry in std::fs::read_dir(source).map_err(|e| e.to_string())?.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            count += upload_item(port, &entry.path(), &format!("{url}/{}", percent_encode(&name)))?;
        }
        Ok(count)
    } else {
        let status = http_send(HOST, port, "PUT", url, Some(Body::File(source.to_path_buf())))?;
        if !(200..300).contains(&status) { return Err(format!("The Mac refused {} ({status}).", source.display())); }
        Ok(1)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;

    #[test]
    fn manifest_is_read_and_escapes_are_refused() {
        let text = "tandem-drop 1\nab12cd34\t47123\tTandemDrop\nd\tab12cd34/My%20Folder\nf\t5\tab12cd34/My%20Folder/a.txt\nf\t3\tab12cd34/b%C3%A9.txt\n";
        let m = parse(text).unwrap();
        assert_eq!(m.id, "ab12cd34");
        assert_eq!(m.port, 47123);
        assert_eq!(m.items.len(), 3);
        assert!(m.items[0].directory);
        assert_eq!(m.total(), 8);
        assert_eq!(percent_decode(&m.items[2].path).unwrap(), "ab12cd34/bé.txt");
        // Climbing out of the destination, or naming another drop, is refused.
        assert!(parse("tandem-drop 1\nab\t1\tS\nf\t1\tab/..%2F..%2Fx\n").is_none());
        assert!(parse("tandem-drop 1\nab\t1\tS\nf\t1\tab/../x\n").is_none());
        assert!(parse("tandem-drop 1\nab\t1\tS\nf\t1\tother/x\n").is_none());
        assert!(parse("tandem-drop 1\nab\t1\tS\nf\t1\tab/C:%5Cx\n").is_none());
        assert!(parse("nonsense").is_none());
    }

    #[test]
    fn taken_names_get_a_number() {
        let dir = std::env::temp_dir().join(format!("tandem-drop-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("report.pdf"), b"x").unwrap();
        std::fs::write(dir.join("report (2).pdf"), b"x").unwrap();
        assert_eq!(unique_path(&dir, "report.pdf"), dir.join("report (3).pdf"));
        assert_eq!(unique_path(&dir, "new.txt"), dir.join("new.txt"));
        assert_eq!(percent_encode("a b/é"), "a%20b/%C3%A9");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn get_streams_into_the_file_and_put_sends_the_body() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let body: Vec<u8> = (0..700_000u32).map(|i| (i % 251) as u8).collect();
        let served = body.clone();
        let server = std::thread::spawn(move || {
            // 1: GET
            let (mut s, _) = listener.accept().unwrap();
            let mut r = BufReader::new(s.try_clone().unwrap());
            let mut line = String::new();
            r.read_line(&mut line).unwrap();
            assert!(line.starts_with("GET /TandemDrop/ab/x%20y.bin "));
            loop { let mut l = String::new(); r.read_line(&mut l).unwrap(); if l.trim().is_empty() { break; } }
            write!(s, "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n", served.len()).unwrap();
            s.write_all(&served).unwrap();
            // 2: PUT
            let (mut s, _) = listener.accept().unwrap();
            let mut r = BufReader::new(s.try_clone().unwrap());
            let mut length = 0usize;
            loop {
                let mut l = String::new(); r.read_line(&mut l).unwrap();
                if l.to_lowercase().starts_with("content-length:") { length = l[15..].trim().parse().unwrap(); }
                if l.trim().is_empty() { break; }
            }
            let mut got = vec![0u8; length];
            r.read_exact(&mut got).unwrap();
            write!(s, "HTTP/1.1 201 Created\r\nContent-Length: 0\r\n\r\n").unwrap();
            got
        });
        let dir = std::env::temp_dir().join(format!("tandem-get-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let dest = dir.join("x y.bin");
        let mut last = 0;
        let n = http_get("127.0.0.1", port, "/TandemDrop/ab/x%20y.bin", &dest, &mut |b| last = b).unwrap();
        assert_eq!(n, body.len() as u64);
        assert_eq!(last, body.len() as u64);
        assert_eq!(std::fs::read(&dest).unwrap(), body);
        let status = http_send("127.0.0.1", port, "PUT", "/TandemInbox/1/x", Some(Body::File(dest.clone()))).unwrap();
        assert_eq!(status, 201);
        assert_eq!(server.join().unwrap(), body);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
