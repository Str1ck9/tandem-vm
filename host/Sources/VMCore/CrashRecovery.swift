import Darwin
import Foundation

/// A VM helper process (QEMU, swtpm) as it was when it started: its number alone is not enough, because
/// macOS hands numbers out again once a process has ended.
public struct ChildProcess: Codable, Equatable, Sendable {
    public var pid: Int32
    public var path: String
    public var started: Date

    public init(pid: Int32, path: String, started: Date) { self.pid = pid; self.path = path; self.started = started }

    /// The running process with this number, or nil when there is none (or it cannot be inspected).
    public static func current(_ pid: Int32) -> ChildProcess? {
        guard pid > 0, let path = RunRecord.processPath(pid), let started = RunRecord.processStart(pid) else { return nil }
        return ChildProcess(pid: pid, path: path, started: started)
    }

    /// True only while the process with this number is provably the one recorded: the same executable
    /// and the same start time.
    public var isStillRunning: Bool {
        guard let now = Self.current(pid) else { return false }
        return now.path == path && abs(now.started.timeIntervalSince(started)) < 0.002
    }
}

/// Names of the short-lived folder of sockets a VM run uses, in the temporary directory.
public enum RunFolder {
    /// `tandem-` and the VM's full identifier (32 hex digits), so no two VMs share one. Where the
    /// temporary directory's path is too long for the sockets inside (unix socket paths hold 103 bytes),
    /// the same 128 bits as 26 base-32 characters.
    public static func name(for id: UUID, longestSocketName: String = "qmp.sock",
                            in directory: String = NSTemporaryDirectory()) -> String {
        let hex = "tandem-" + hexDigits(id)
        let base = directory.hasSuffix("/") ? directory : directory + "/"
        if (base + hex + "/" + longestSocketName).utf8.count <= UnixSocket.maxPathLength { return hex }
        return "tandem-" + base32(id)
    }

    /// Every name this VM's folder may have: the two current forms and the 8-character one of older builds.
    public static func names(for id: UUID) -> Set<String> {
        ["tandem-" + hexDigits(id), "tandem-" + base32(id), "tandem-" + id.uuidString.prefix(8).lowercased()]
    }

    public static func hexDigits(_ id: UUID) -> String { id.uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

    public static func base32(_ id: UUID) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        var result = "", buffer = 0, bits = 0
        for byte in bytes {
            buffer = ((buffer << 8) | Int(byte)) & 0xFFFF; bits += 8
            while bits >= 5 { bits -= 5; result.append(alphabet[(buffer >> bits) & 31]) }
        }
        if bits > 0 { result.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return result
    }
}

/// Cleans up after a host process (Tandem or vmctl) that ended without stopping its VMs.
public enum CrashRecovery {
    /// The executable names a VM's helper processes may have; nothing else is ever signalled.
    static let childNames: Set<String> = ["qemu-system-aarch64", "swtpm"]

    public struct Outcome: Equatable, Sendable {
        public var vmName: String
        /// Helper processes that were still running and have been stopped.
        public var stoppedProcesses: Int
        /// Processes that may be this VM's leftovers but could not be proved to be (records from older
        /// builds keep only their numbers). They are left alone.
        public var unconfirmedProcesses: [Int32] = []
        /// Files removed: run records, sockets, partial suspend files, drop folders.
        public var removedItems: [String]
        public var message: String {
            "“\(vmName)” was stopped because Tandem quit unexpectedly while it was running."
                + (stoppedProcesses > 0 ? " Its leftover processes have been ended." : "")
                + " Anything not saved inside the virtual machine was lost."
                + (unconfirmedProcesses.isEmpty ? "" :
                    " Process \(unconfirmedProcesses.map(String.init).joined(separator: ", ")) may be left over from it but could not be confirmed, so it was left running; end it in Activity Monitor if it is.")
        }
    }

    /// Nil when the VM was not left behind. Runs under the bundle's lease: `lease` when the caller holds it
    /// (an engine about to start the VM), otherwise one taken here; a VM someone else holds is never touched.
    @discardableResult
    public static func recover(_ bundle: VMBundle, holding lease: BundleLease? = nil,
                               signal: (Int32, Int32) -> Int32 = { kill($0, $1) },
                               settle: () -> Void = { usleep(1_500_000) }) -> Outcome? {
        guard let record = bundle.readRunRecord(), !record.hostIsAlive else { return nil }
        let own = lease == nil ? BundleLease.tryAcquire(bundle, purpose: "recovering after a crash") : nil
        defer { own?.release() }
        guard lease?.covers(bundle) == true || own != nil else { return nil }

        // Only helpers whose identity was recorded and still matches are signalled, each checked again
        // just before its signal: the number may have gone to another VM's QEMU since.
        func isOurs(_ child: ChildProcess) -> Bool {
            child.pid > 0 && childNames.contains(URL(fileURLWithPath: child.path).lastPathComponent) && child.isStillRunning
        }
        let known = record.children ?? []
        var terminated: [ChildProcess] = []
        for child in known where isOurs(child) {
            if signal(child.pid, SIGTERM) == 0 { terminated.append(child) }
        }
        if !terminated.isEmpty {
            // A moment to exit cleanly, then the hard way for any that would not.
            settle()
            for child in terminated where isOurs(child) { _ = signal(child.pid, SIGKILL) }
        }
        let identified = Set(known.map(\.pid))
        let unconfirmed = record.childPIDs.filter { pid in
            pid > 0 && !identified.contains(pid) && RunRecord.processName(pid).map(childNames.contains) == true
        }

        let fm = FileManager.default
        var removed: [String] = []
        func remove(_ url: URL) {
            guard fm.fileExists(atPath: url.path) else { return }
            if (try? fm.removeItem(at: url)) != nil { removed.append(url.lastPathComponent) }
        }
        if let folder = record.runFolder, isOwnRunFolder(folder, for: bundle.id) { remove(URL(fileURLWithPath: folder)) }
        // A suspend that was cut off half-way cannot be resumed; the finished file, if any, stays.
        remove(bundle.url.appendingPathComponent(".suspend.partial"))
        remove(bundle.url.appendingPathComponent(".suspend.partial.zst"))
        // Access given until shutdown ends with the run; staged drops are copies of Mac files.
        remove(bundle.runDirectory.appendingPathComponent("temporary-sharing.json"))
        remove(bundle.runDirectory.appendingPathComponent("drops"))
        remove(bundle.runDirectory.appendingPathComponent(RunRecord.fileName))
        return Outcome(vmName: bundle.config.name, stoppedProcesses: terminated.count, unconfirmedProcesses: unconfirmed,
                       removedItems: removed)
    }

    /// Only Tandem's own socket folders in the temporary directory are ever deleted.
    static func isOwnRunFolder(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.resolvingSymlinksInPath()
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        return parent.path == temp.path && url.lastPathComponent.hasPrefix("tandem-")
    }

    /// And of those only the one named for this VM, so a record cannot point recovery at another VM's sockets.
    static func isOwnRunFolder(_ path: String, for id: UUID) -> Bool {
        isOwnRunFolder(path) && RunFolder.names(for: id).contains(URL(fileURLWithPath: path).standardizedFileURL.lastPathComponent)
    }

    /// Refuses to start a VM that another live process (another Tandem, or vmctl) is running. The lease is
    /// the claim; this catches builds from before leases, which only wrote a record.
    public static func requireNotRunningElsewhere(_ bundle: VMBundle) throws {
        guard let record = bundle.readRunRecord(), record.hostIsAlive, record.hostPID != getpid() else { return }
        throw VMError("“\(bundle.config.name)” is already running in another program (\(record.hostName), process \(record.hostPID)).",
                      detail: "Stop it there first, or quit that program.")
    }
}
