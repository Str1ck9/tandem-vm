import Foundation

// "disk-probe": what macOS lets this process (root, when installed) do with a disk, without changing
// anything. Each check opens and closes at once; nothing is read or written. It answers the one question
// the user's test left open on macOS 26: is the refused chown the only refusal, or does macOS also refuse
// root opening the raw disk (then the cause is privacy protection and the fix is Full Disk Access)?

/// The outcome of one system call: "ok" or the error text (for example "Operation not permitted").
private func outcome(_ succeeded: Bool) -> String { succeeded ? "ok" : errnoText() }

/// Checks `/dev/rdiskN` and `/dev/diskN`, and whether this process has Full Disk Access.
func diskProbe(bsd: String) -> [String: Any] {
    guard bsd.range(of: "^disk[0-9]+$", options: .regularExpression) != nil else {
        return ["ok": false, "error": "\(bsd) is not a whole disk name (expected diskN)"]
    }
    var result: [String: Any] = ["ok": true, "bsd": bsd, "euid": Int(geteuid())]
    for (label, path) in [("raw", "/dev/r\(bsd)"), ("block", "/dev/\(bsd)")] {
        var entry: [String: String] = ["path": path]
        var info = stat()
        let found = stat(path, &info) == 0
        entry["stat"] = outcome(found)
        let reader = open(path, O_RDONLY)
        entry["openRead"] = outcome(reader >= 0)
        if reader >= 0 { close(reader) }
        let writer = open(path, O_RDWR)
        entry["openWrite"] = outcome(writer >= 0)
        if writer >= 0 { close(writer) }
        // Giving a node to its current owner changes nothing but is checked like any chown.
        if found { entry["chown"] = outcome(chown(path, info.st_uid, info.st_gid) == 0) }
        result[label] = entry
    }
    result["fullDiskAccess"] = fullDiskAccessState()
    return result
}

/// "yes", "no" or "unknown (…)": whether this process has Full Disk Access. The system's privacy database
/// is readable only with it, also for root. macOS decides this when the process starts, so a grant given
/// later needs a restart of the helper.
func fullDiskAccessState() -> String {
    let tcc = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
    if tcc >= 0 { close(tcc); return "yes" }
    return errno == EPERM ? "no" : "unknown (\(errnoText()))"
}
