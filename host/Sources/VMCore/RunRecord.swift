import Darwin
import Foundation

/// Which process runs a VM, written to `run/host.json` in the bundle while the VM runs and removed when
/// it stops. A record whose host process no longer exists means that process ended without stopping
/// the VM (Tandem crashed or was force-quit): `CrashRecovery` cleans up after it at the next start.
public struct RunRecord: Codable, Equatable, Sendable {
    /// The process that started the VM (Tandem or vmctl).
    public var hostPID: Int32
    /// Its executable name, so a reused process number is not mistaken for it.
    public var hostName: String
    public var hostStarted: Date?
    /// QEMU, swtpm and other helpers of this VM (empty for the VZ engine, which runs in the host).
    public var childPIDs: [Int32]
    /// The same helpers with what identifies each beyond its number (path and start time), so crash
    /// recovery never signals a later process that reused a number. Nil in records written before this.
    public var children: [ChildProcess]?
    /// Short-lived files outside the bundle that belong to this run (QEMU's socket folder).
    public var runFolder: String?
    public var started: Date

    public init(hostPID: Int32 = getpid(), hostName: String = RunRecord.processName(getpid()) ?? "",
                hostStarted: Date? = RunRecord.processStart(getpid()), childPIDs: [Int32] = [], runFolder: String? = nil,
                started: Date = Date()) {
        self.hostPID = hostPID; self.hostName = hostName; self.hostStarted = hostStarted
        self.childPIDs = childPIDs; self.runFolder = runFolder; self.started = started
        self.children = childPIDs.compactMap(ChildProcess.current)
    }

    public static let fileName = "host.json"

    // MARK: Processes

    public static func processName(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
    }

    /// When a process started, to tell it apart from a later process that reused its number.
    public static func processStart(_ pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
    }

    /// The full path of a process's executable.
    public static func processPath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Whether the process that wrote this record is still running.
    public var hostIsAlive: Bool {
        guard kill(hostPID, 0) == 0 || errno == EPERM else { return false }
        guard let name = Self.processName(hostPID), name == hostName else { return false }
        if let hostStarted, let now = Self.processStart(hostPID), abs(now.timeIntervalSince(hostStarted)) > 1 { return false }
        return true
    }
}

extension VMBundle {
    private var runRecordURL: URL { runDirectory.appendingPathComponent(RunRecord.fileName) }

    public func readRunRecord() -> RunRecord? {
        guard let data = try? Data(contentsOf: runRecordURL) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(RunRecord.self, from: data)
    }

    /// Writes the record. It describes the run for crash recovery and diagnostics; the claim on the VM is
    /// the bundle's lease. A failure is logged and returned, not thrown: the VM runs on either way.
    @discardableResult
    public func writeRunRecord(_ record: RunRecord) -> Error? {
        do {
            try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(record).write(to: runRecordURL, options: .atomic)
            return nil
        } catch {
            NSLog("Tandem: the run record of “%@” could not be written: %@", config.name, error.localizedDescription)
            return error
        }
    }

    /// Removes the record, but only one this process wrote: another process may have started the VM since.
    public func clearRunRecord(ifOwnedBy pid: Int32 = getpid()) {
        guard let record = readRunRecord(), record.hostPID == pid else { return }
        try? FileManager.default.removeItem(at: runRecordURL)
    }
}

