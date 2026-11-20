import Darwin
import Foundation

/// One zip file with what is needed to understand a problem, and nothing private: Tandem's logs, each
/// VM's logs and settings with secrets and personal paths removed, the helper's log, system facts and
/// Tandem's crash reports. Disks, memory images, shared files and passwords are never included.
public enum Diagnostics {
    /// What the zip contains, in plain words; shown before collecting and written into the zip.
    public static let contentsDescription = """
    Tandem's own log messages of the last two hours, each virtual machine's log files and settings \
    (with passwords, product keys and notes removed, and folders on your Mac reduced to their last name), the \
    network and USB helper's log, crash reports of Tandem and its tools, and facts about this Mac \
    (macOS version, model, memory, free disk, QEMU and helper versions). No disks, no memory images, \
    no files from shared folders and no passwords.
    """

    /// Keys whose values are never copied, at any depth.
    static let secretKeys: Set<String> = ["password", "defaultpassword", "productkey", "notes", "secret", "token"]

    /// Collects into `zip` (overwritten). `extraInfo` adds facts only the caller knows (versions).
    @discardableResult
    public static func collect(library: VMLibrary, extraInfo: [String: String], to zip: URL) throws -> URL {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let staging = fm.temporaryDirectory.appendingPathComponent("Tandem Diagnostics \(stamp)", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        try ("Tandem diagnostics, \(Date())\n\nContents: " + contentsDescription + "\n").write(
            to: staging.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        try systemFacts(extraInfo: extraInfo, library: library).write(
            to: staging.appendingPathComponent("system.txt"), atomically: true, encoding: .utf8)

        // Every VM: logs, settings (cleaned), run record, the names of its snapshots.
        let vms = staging.appendingPathComponent("VMs", isDirectory: true)
        try fm.createDirectory(at: vms, withIntermediateDirectories: true)
        let listing = library.list()
        for bundle in listing.bundles {
            let folder = vms.appendingPathComponent(safeName("\(bundle.config.name)-\(bundle.id.uuidString.prefix(8))"), isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for log in (try? fm.contentsOfDirectory(at: bundle.logsDirectory, includingPropertiesForKeys: nil)) ?? []
            where ["log", "txt"].contains(log.pathExtension) {
                copyTail(of: log, to: folder.appendingPathComponent(log.lastPathComponent), maxBytes: 2 << 20)
            }
            if let data = try? Data(contentsOf: bundle.url.appendingPathComponent("config.json")) {
                try? cleanedJSON(data).write(to: folder.appendingPathComponent("config.json"))
            }
            if let data = try? Data(contentsOf: bundle.runDirectory.appendingPathComponent(RunRecord.fileName)) {
                try? data.write(to: folder.appendingPathComponent("run-host.json"))
            }
            let snapshots = (try? fm.contentsOfDirectory(atPath: bundle.url.appendingPathComponent("snapshots").path)) ?? []
            if !snapshots.isEmpty {
                try? (snapshots.sorted().joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("snapshots.txt"), atomically: true, encoding: .utf8)
            }
        }
        if !listing.failures.isEmpty {
            let lines = listing.failures.map { "\($0.url.lastPathComponent): \($0.reason)" }.joined(separator: "\n")
            try? (lines + "\n").write(to: vms.appendingPathComponent("could-not-load.txt"), atomically: true, encoding: .utf8)
        }

        // The helper's log is world-readable when the helper is installed.
        let helperLog = URL(fileURLWithPath: "/var/log/tandem-nethelper.log")
        if fm.isReadableFile(atPath: helperLog.path) {
            copyTail(of: helperLog, to: staging.appendingPathComponent("helper.log"), maxBytes: 1 << 20)
        }

        // Crash reports of Tandem and its own tools only.
        let reports = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let ours = ["Tandem", "vmctl", "tandem", "TandemNetHelper", "TandemGuestApp", "qemu-system-aarch64", "swtpm"]
        let crashes = staging.appendingPathComponent("Crash reports", isDirectory: true)
        for report in (try? fm.contentsOfDirectory(at: reports, includingPropertiesForKeys: nil)) ?? []
        where ours.contains(where: { report.lastPathComponent.hasPrefix($0 + "-") || report.lastPathComponent.hasPrefix($0 + "_") }) {
            try? fm.createDirectory(at: crashes, withIntermediateDirectories: true)
            // With the home folder's path replaced by "~", so the account name stays out of the zip.
            if let text = try? String(contentsOf: report, encoding: .utf8) {
                try? scrubbedLog(text, home: fm.homeDirectoryForCurrentUser.path).write(
                    to: crashes.appendingPathComponent(report.lastPathComponent), atomically: true, encoding: .utf8)
            } else {
                try? fm.copyItem(at: report, to: crashes.appendingPathComponent(report.lastPathComponent))
            }
        }

        // Tandem's messages in the system log (macOS keeps private values out of it).
        let unified = run("/usr/bin/log", ["show", "--last", "2h", "--style", "compact",
                                            "--predicate", "process == \"Tandem\" OR process == \"vmctl\" OR process == \"tandem\""], limit: 5 << 20)
        try? unified.write(to: staging.appendingPathComponent("tandem-system-log.txt"), atomically: true, encoding: .utf8)

        try? fm.removeItem(at: zip)
        let result = run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", "--keepParent", staging.path, zip.path], limit: 1 << 16)
        guard fm.fileExists(atPath: zip.path) else {
            throw VMError("The diagnostics file could not be written.", detail: result)
        }
        return zip
    }

    // MARK: Pieces

    static func systemFacts(extraInfo: [String: String], library: VMLibrary) -> String {
        var facts: [(String, String)] = []
        facts.append(("macOS", ProcessInfo.processInfo.operatingSystemVersionString))
        facts.append(("Model", sysctlString("hw.model") ?? "unknown"))
        facts.append(("Processors", "\(ProcessInfo.processInfo.processorCount)"))
        facts.append(("Memory", ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory)))
        if let free = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
            facts.append(("Free disk", ByteCountFormatter.string(fromByteCount: free, countStyle: .file)))
        }
        facts.append(("Virtual machines", "\(library.list().bundles.count)"))
        for (key, value) in extraInfo.sorted(by: { $0.key < $1.key }) { facts.append((key, value)) }
        return facts.map { "\($0.0): \($0.1)" }.joined(separator: "\n") + "\n"
    }

    /// The settings without secrets, and Mac paths reduced to their last name.
    public static func cleanedJSON(_ data: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data)
        return try JSONSerialization.data(withJSONObject: clean(object), options: [.prettyPrinted, .sortedKeys])
    }

    static func clean(_ value: Any, key: String? = nil) -> Any {
        if let dictionary = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dictionary where !secretKeys.contains(k.lowercased()) { out[k] = clean(v, key: k) }
            return out
        }
        if let array = value as? [Any] { return array.map { clean($0, key: key) } }
        if let text = value as? String, text.hasPrefix("/") {
            // A Mac path says where the user keeps things; its last name is enough to diagnose.
            let last = URL(fileURLWithPath: text).lastPathComponent
            return "…/" + last
        }
        return value
    }

    static func copyTail(of source: URL, to destination: URL, maxBytes: Int) {
        guard let handle = try? FileHandle(forReadingFrom: source) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        let text = scrubbedLog(String(decoding: data, as: UTF8.self), home: NSHomeDirectory())
        try? Data(text.utf8).write(to: destination)
    }

    /// A log as it may leave the Mac: the home folder's path (it carries the user's name) becomes "~",
    /// and the text of commands run in a guest from the Mac (which may hold passwords) is left out.
    public static func scrubbedLog(_ text: String, home: String) -> String {
        var lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            var cleaned = line
            if !home.isEmpty, home != "/" { cleaned = cleaned.replacingOccurrences(of: home, with: "~") }
            if let marker = cleaned.range(of: "command from the Mac ("), let colon = cleaned.range(of: "): ", range: marker.upperBound..<cleaned.endIndex) {
                cleaned = String(cleaned[..<colon.upperBound]) + "[command not included]"
            }
            lines[index] = cleaned
        }
        return lines.joined(separator: "\n")
    }

    static func safeName(_ name: String) -> String {
        String(name.map { "/:\\".contains($0) ? "-" : $0 })
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Output of a tool, at most `limit` bytes; never waits more than 60 s.
    static func run(_ path: String, _ arguments: [String], limit: Int) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-diag-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: output) }
        guard let handle = try? FileHandle(forWritingTo: output) else { return "" }
        process.standardOutput = handle
        process.standardError = handle
        do { try process.run() } catch { return "\(error)" }
        if !process.waitForExit(timeout: 60) { process.stopAndWait(grace: 1) }
        try? handle.close()
        let data = (try? Data(contentsOf: output)) ?? Data()
        return String(decoding: data.suffix(limit), as: UTF8.self)
    }
}
