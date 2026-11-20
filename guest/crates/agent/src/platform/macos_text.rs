//! What the macOS guest agent reads from the system's own tools, and the commands it runs. Kept apart
//! from `macos.rs` and free of side effects, so the host's `cargo test` checks it.

/// Seconds since the last key press or pointer move, from `ioreg -c IOHIDSystem -d 4`
/// (`"HIDIdleTime" = <nanoseconds>`).
pub fn hid_idle_seconds(ioreg: &str) -> Option<u64> {
    for line in ioreg.lines() {
        let Some(at) = line.find("\"HIDIdleTime\"") else { continue };
        let value = line[at..].split('=').nth(1)?.trim();
        let digits: String = value.chars().take_while(|c| c.is_ascii_digit()).collect();
        return digits.parse::<u64>().ok().map(|ns| ns / 1_000_000_000);
    }
    None
}

/// Assertion types that keep a Mac from going idle or to sleep.
const AWAKE_TYPES: [&str; 5] = [
    "PreventUserIdleSystemSleep", "PreventSystemSleep", "PreventUserIdleDisplaySleep",
    "NoIdleSleepAssertion", "NoDisplaySleepAssertion",
];

/// Programs holding a stay-awake assertion, from `pmset -g assertions`, in words for the user:
/// `caffeinate (caffeinate command-line tool)`. The agent's own assertions are left out.
pub fn awake_assertions(pmset: &str) -> Vec<String> {
    let mut reasons: Vec<String> = Vec::new();
    for line in pmset.lines() {
        let line = line.trim();
        let Some(rest) = line.strip_prefix("pid ") else { continue };
        // pid 1234(caffeinate): [0x…] 00:00:05 PreventUserIdleSystemSleep named: "…"
        let (Some(open), Some(close)) = (rest.find('('), rest.find("):")) else { continue };
        if close < open { continue; }
        let program = rest[open + 1..close].trim();
        let after = &rest[close + 2..];
        if !AWAKE_TYPES.iter().any(|t| after.split_whitespace().any(|w| w == *t)) { continue; }
        if program.is_empty() || program == "tandem-agent" { continue; }
        let named = after.split_once("named:").map(|(_, n)| n.trim().trim_matches('"').trim()).unwrap_or("");
        let cleaned: String = named.chars().filter(|c| !c.is_control()).take(60).collect();
        let reason = if cleaned.is_empty() { program.to_string() } else { format!("{program} ({cleaned})") };
        if !reasons.contains(&reason) { reasons.push(reason); }
    }
    reasons
}

/// The command that shuts down or restarts the guest. With a user signed in, the system is asked the
/// way the Apple menu asks it (programs may save their documents, or refuse); at the login window, or
/// when that fails, `shutdown` does it at once.
pub fn shutdown_commands(console_uid: Option<u32>, restart: bool) -> Vec<Vec<String>> {
    let mut commands = Vec::new();
    if let Some(uid) = console_uid.filter(|&u| u != 0) {
        // «event aevtrrst» restarts, «event aevtrsdn» shuts down: loginwindow's own Apple events.
        let event = if restart { "aevtrrst" } else { "aevtrsdn" };
        commands.push(vec![
            "/bin/launchctl".into(), "asuser".into(), uid.to_string(),
            "/usr/bin/osascript".into(), "-e".into(), format!("tell application \"loginwindow\" to «event {event}»"),
        ]);
    }
    commands.push(vec!["/sbin/shutdown".into(), if restart { "-r" } else { "-h" }.into(), "now".into()]);
    commands
}

/// A command that runs `tool` in the signed-in user's session (where the clipboard lives), from the
/// agent running as root: `launchctl asuser <uid> sudo -u #<uid> <tool> …`.
pub fn as_console_user(uid: u32, tool: &str, args: &[&str]) -> Vec<String> {
    let mut command: Vec<String> = vec![
        "/bin/launchctl".into(), "asuser".into(), uid.to_string(),
        "/usr/bin/sudo".into(), "-n".into(), "-u".into(), format!("#{uid}"), tool.into(),
    ];
    command.extend(args.iter().map(|a| a.to_string()));
    command
}

/// Busy and total processor ticks from `host_statistics(HOST_CPU_LOAD_INFO)`:
/// `[user, system, idle, nice]`.
pub fn cpu_ticks(ticks: [u32; 4]) -> (u64, u64) {
    let [user, system, idle, nice] = ticks.map(u64::from);
    (user + system + nice, user + system + idle + nice)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn idle_time_from_ioreg() {
        let text = "+-o IOHIDSystem  <class IOHIDSystem>\n    {\n      \"HIDIdleTime\" = 12500000000\n      \"HIDParameters\" = {}\n";
        assert_eq!(hid_idle_seconds(text), Some(12));
        assert_eq!(hid_idle_seconds("    | |   \"HIDIdleTime\" = 999"), Some(0));
        assert_eq!(hid_idle_seconds("nothing here"), None);
        assert_eq!(hid_idle_seconds("\"HIDIdleTime\" = "), None);
    }

    #[test]
    fn stay_awake_assertions_from_pmset() {
        let text = r#"Assertion status system-wide:
   PreventUserIdleSystemSleep     1
Listed by owning process:
   pid 1234(caffeinate): [0x000011b200019a2f] 00:00:05 PreventUserIdleSystemSleep named: "caffeinate command-line tool"
	Details: caffeinate asserting on behalf of '/bin/sleep' (pid 1235)
   pid 345(coreaudiod): [0x00000a8c00018a1e] 00:01:12 PreventUserIdleSleep named: "com.apple.audio.context"
   pid 88(tandem-agent): [0x1] 00:00:01 PreventSystemSleep named: "Tandem"
   pid 77(Backup): [0x2] 00:00:01 PreventSystemSleep
   pid 1234(caffeinate): [0x000011b200019a30] 00:00:05 PreventUserIdleSystemSleep named: "caffeinate command-line tool"
   pid 9(weird: no closing paren
Kernel Assertions: 0x4=USB
"#;
        assert_eq!(awake_assertions(text), vec!["caffeinate (caffeinate command-line tool)".to_string(), "Backup".to_string()]);
        assert!(awake_assertions("").is_empty());
    }

    #[test]
    fn shutdown_asks_the_signed_in_user_first() {
        let with_user = shutdown_commands(Some(501), true);
        assert_eq!(with_user.len(), 2);
        assert_eq!(with_user[0][..3], ["/bin/launchctl".to_string(), "asuser".into(), "501".into()]);
        assert!(with_user[0][5].contains("aevtrrst"));
        assert_eq!(with_user[1], vec!["/sbin/shutdown".to_string(), "-r".into(), "now".into()]);
        assert!(shutdown_commands(Some(501), false)[0][5].contains("aevtrsdn"));
        // The login window (uid 0) or nobody signed in: straight to shutdown.
        assert_eq!(shutdown_commands(Some(0), false), vec![vec!["/sbin/shutdown".to_string(), "-h".into(), "now".into()]]);
        assert_eq!(shutdown_commands(None, false).len(), 1);
    }

    #[test]
    fn console_user_commands() {
        assert_eq!(as_console_user(501, "/usr/bin/pbpaste", &["-Prefer", "txt"]),
                   ["/bin/launchctl", "asuser", "501", "/usr/bin/sudo", "-n", "-u", "#501", "/usr/bin/pbpaste", "-Prefer", "txt"]);
    }

    #[test]
    fn processor_ticks() {
        assert_eq!(cpu_ticks([10, 5, 80, 5]), (20, 100));
        assert_eq!(cpu_ticks([u32::MAX; 4]), (3 * u32::MAX as u64, 4 * u32::MAX as u64));
    }
}
