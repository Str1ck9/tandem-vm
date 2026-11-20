//! Self-update: the host carries the agent build that belongs to it. When that differs from the file
//! this process was started from, the agent downloads it over the channel, swaps the file and restarts.
use link_proto::client::Client;
use link_proto::frame::Buffer;
use link_proto::op;
use std::path::PathBuf;
use std::time::Duration;

const TIMEOUT: Option<Duration> = Some(Duration::from_secs(20));
const CHUNK: usize = 256 * 1024;
/// Set for the process started after an update, so a host whose copy can never match cannot cause a loop.
pub const UPDATED_MARK: &str = "TANDEM_AGENT_UPDATED";

/// FNV-1a, 64 bit. Detects a different or damaged file; the channel to the host is already trusted.
pub fn fnv1a64(data: &[u8]) -> u64 {
    data.iter().fold(0xcbf2_9ce4_8422_2325u64, |hash, byte| (hash ^ *byte as u64).wrapping_mul(0x0000_0100_0000_01b3))
}

/// The host's build of the agent when it is not the one running. `Ok(None)` means up to date,
/// or a host that offers no updates.
pub fn fetch_newer(client: &Client) -> Result<Option<Vec<u8>>, String> {
    let info = match client.call(op::AGENT_UPDATE_INFO, vec![], vec![], TIMEOUT) {
        Ok(reply) if reply.inline.len() >= 12 => reply,
        _ => return Ok(None),
    };
    let size = info.u32_at(0).unwrap_or(0) as usize;
    let hash = u64::from_le_bytes(info.inline[4..12].try_into().unwrap());
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let mine = std::fs::read(&exe).map_err(|e| format!("cannot read {}: {e}", exe.display()))?;
    if mine.len() == size && fnv1a64(&mine) == hash { return Ok(None); }
    if std::env::var_os(UPDATED_MARK).is_some() { return Err("still not the host's build after an update; not trying again".into()); }
    if size == 0 || size > 64 << 20 { return Err(format!("the host offers an agent of {size} bytes")); }

    let mut data = Vec::with_capacity(size);
    while data.len() < size {
        let want = CHUNK.min(size - data.len());
        let reply = client.call(op::AGENT_UPDATE_READ, (data.len() as u32).to_le_bytes().to_vec(), vec![Buffer::output(want)], TIMEOUT)
            .map_err(|e| format!("download failed at byte {}: {e}", data.len()))?;
        let chunk = reply.output(0);
        if chunk.is_empty() { return Err(format!("download ended at byte {} of {size}", data.len())); }
        data.extend_from_slice(chunk);
    }
    if data.len() != size || fnv1a64(&data) != hash { return Err("the downloaded agent does not match the host's checksum".into()); }
    Ok(Some(data))
}

fn sibling(exe: &std::path::Path, extension: &str) -> PathBuf { exe.with_extension(extension) }

/// Removes what the previous update left behind (Windows cannot delete a running program).
pub fn clean_up() {
    if let Ok(exe) = std::env::current_exe() { let _ = std::fs::remove_file(sibling(&exe, "old")); }
}

/// Puts `data` where this program lives. The running process keeps using the old file until it restarts.
pub fn install(data: &[u8]) -> Result<PathBuf, String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let new = sibling(&exe, "new");
    std::fs::write(&new, data).map_err(|e| format!("cannot write {}: {e}", new.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&new, std::fs::Permissions::from_mode(0o755)).map_err(|e| e.to_string())?;
        std::fs::rename(&new, &exe).map_err(|e| format!("cannot replace {}: {e}", exe.display()))?;
    }
    #[cfg(not(unix))]
    {
        // A running program can be renamed but not overwritten.
        let old = sibling(&exe, "old");
        let _ = std::fs::remove_file(&old);
        std::fs::rename(&exe, &old).map_err(|e| format!("cannot move {} aside: {e}", exe.display()))?;
        if let Err(e) = std::fs::rename(&new, &exe) {
            let _ = std::fs::rename(&old, &exe);
            return Err(format!("cannot replace {}: {e}", exe.display()));
        }
    }
    Ok(exe)
}

/// Starts the new build with the same arguments. Returns only when that failed.
pub fn restart(exe: &std::path::Path) -> String {
    let mut command = std::process::Command::new(exe);
    command.args(std::env::args().skip(1)).env(UPDATED_MARK, "1");
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.exec().to_string()
    }
    #[cfg(not(unix))]
    {
        match command.spawn() {
            Ok(_) => std::process::exit(0),
            Err(e) => e.to_string(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fnv_reference_values() {
        assert_eq!(fnv1a64(b""), 0xcbf29ce484222325);
        assert_eq!(fnv1a64(b"a"), 0xaf63dc4c8601ec8c);
        assert_eq!(fnv1a64(b"foobar"), 0x85944171f73967e8);
    }
}
