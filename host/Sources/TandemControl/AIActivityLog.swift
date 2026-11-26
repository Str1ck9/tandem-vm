import Foundation

/// One call an AI tool made, as the app answered it.
public struct AIActivityEntry: Codable, Equatable, Sendable, Identifiable {
    public var time: Date
    /// The operation (`start`, `snapshot.revert`, `exec`, …).
    public var tool: String
    public var vm: String?
    /// `allowed`, `denied` (a permission said no) or `failed` (allowed, but it did not work).
    public var outcome: String
    /// What the call was about: the command, the folder, the snapshot.
    public var summary: String?
    /// The refusal or the error, for `denied` and `failed`.
    public var message: String?

    public var id: String { "\(time.timeIntervalSince1970)-\(tool)-\(vm ?? "")-\(summary ?? "")" }

    public init(time: Date, tool: String, vm: String?, outcome: String, summary: String? = nil, message: String? = nil) {
        self.time = time; self.tool = tool; self.vm = vm; self.outcome = outcome; self.summary = summary; self.message = message
    }
}

/// A record of what AI tools asked Tandem to do, kept in `ai-activity.log` in the library folder (one JSON
/// object per line, readable by the owner only). It lets the person see what an agent did and what it was
/// refused, whatever the VM's AI level.
public enum AIActivityLog {
    public static let fileName = "ai-activity.log"
    /// The log is moved aside (to `ai-activity.log.1`) when it grows past this many bytes.
    public static let maxBytes = 1_000_000
    private static let lock = NSLock()

    public static func url(libraryRoot: URL) -> URL { libraryRoot.appendingPathComponent(fileName) }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// What the log says about a request from an AI tool and its answer.
    public static func entry(for request: ControlRequest, response: ControlResponse, now: Date = Date()) -> AIActivityEntry {
        let outcome: String
        if response.ok { outcome = "allowed" }
        else if response.error?.code == "refused" { outcome = "denied" }
        else { outcome = "failed" }
        var summary: String?
        switch request.operation {
        case .exec: summary = request.string("command")
        case .share: summary = request.string("path")
        case .unshare: summary = request.string("folder")
        case .snapshotTake, .snapshotRevert, .snapshotDelete: summary = request.string("snapshot") ?? request.string("name")
        case .clone: summary = request.string("name")
        case .launch: summary = request.string("program")
        default: break
        }
        if let text = summary {
            let flat = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            summary = flat.count > 200 ? String(flat.prefix(200)) + "…" : flat
        }
        return AIActivityEntry(time: now, tool: request.op, vm: request.vm, outcome: outcome, summary: summary,
                               message: response.ok ? nil : response.error?.message)
    }

    public static func append(_ entry: AIActivityEntry, libraryRoot: URL, maxBytes: Int = AIActivityLog.maxBytes) {
        lock.lock(); defer { lock.unlock() }
        guard var line = try? encoder().encode(entry) else { return }
        line.append(0x0A)
        let fm = FileManager.default
        let file = url(libraryRoot: libraryRoot)
        try? fm.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int, size > maxBytes {
            let old = libraryRoot.appendingPathComponent(fileName + ".1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: file, to: old)
        }
        if !fm.fileExists(atPath: file.path) {
            fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    /// The newest entries, newest first. Lines that cannot be read are skipped.
    public static func recent(libraryRoot: URL, limit: Int = 50) -> [AIActivityEntry] {
        lock.lock(); defer { lock.unlock() }
        guard limit > 0, let data = try? Data(contentsOf: url(libraryRoot: libraryRoot)) else { return [] }
        var entries: [AIActivityEntry] = []
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true).reversed() {
            if let entry = try? decoder().decode(AIActivityEntry.self, from: Data(line)) { entries.append(entry) }
            if entries.count >= limit { break }
        }
        return entries
    }
}
