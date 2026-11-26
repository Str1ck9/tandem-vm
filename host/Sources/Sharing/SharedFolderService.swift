import Foundation
import VMCore

/// Publishes a VM's shared folders while it runs. One instance per running VM.
/// Which folders, and whether they may be written, comes from a `SharingPolicy` and nowhere else.
public final class SharedFolderService: @unchecked Sendable {
    private var server: WebDAVServer?
    /// The folders the policy allows, as served; the server also serves `transferShares`.
    private var policyShares: [WebDAVServer.Share] = []
    /// Hidden shares for files moved by hand (`FileDrop`); set by the session from the VM's policy.
    public private(set) var transferShares: [WebDAVServer.Share] = []
    public private(set) var port = 0
    public private(set) var names: [String] = []
    /// How the guest reaches the folders: `webdav`, `9p` or `virtiofs` (see `SharesInfo`).
    public private(set) var kind = "webdav"

    /// The transport a VM's folders use. Windows opens a WebDAV server on the Mac; Linux gets virtio
    /// devices from its engine (9p on QEMU, virtiofs on VZ); macOS mounts virtiofs by itself.
    public static func kind(for config: VMConfig) -> String {
        if config.engine == .vz { return "virtiofs" }
        return config.guestOS == .linux ? "9p" : "webdav"
    }
    public var onLog: (@Sendable (String) -> Void)?
    /// While true the guest is told that nothing is shared, so that it lets go of the folders.
    /// A Linux guest must not have them mounted while its state is saved.
    public var withheld = false
    /// What the guest agent is told.
    public var announcedNames: [String] { withheld ? [] : names }

    /// The sharing lines the command-line tool prints, with the note about what waits for a restart
    /// last: on a running Linux VM (QEMU), a folder added for good is attached at its next start, and
    /// `tandem share` must say so rather than look done.
    public static func summaryLines(_ lines: [String], pendingNote: String?) -> [String] {
        guard let note = pendingNote?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty else { return lines }
        return lines + ["Note: " + note]
    }

    public init() {}

    /// Answer the VM's own process only (set before `start`; the app does, `vmctl` does not).
    public var onlyVMProcess = false
    private let clientProcess = ClientProcess()
    /// The VM's process (QEMU), once it runs; nil while none.
    public func setVMProcess(_ pid: pid_t?) { clientProcess.value = pid }

    final class ClientProcess: @unchecked Sendable {
        private let lock = NSLock()
        private var pid: pid_t?
        var value: pid_t? {
            get { lock.withLock { pid } }
            set { lock.withLock { pid = newValue } }
        }
    }

    /// A port that stays the same for a VM across runs, so links made inside the guest keep working.
    /// The range 47000–48999 is unassigned; if the port is taken, any free one is used instead.
    public static func preferredPort(for id: UUID) -> UInt16 {
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        let hash = bytes.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 }
        return UInt16(47000 + hash % 2000)
    }

    public static func shares(for policy: SharingPolicy) -> [WebDAVServer.Share] {
        policy.folders.map { WebDAVServer.Share(name: $0.folder.name, root: URL(fileURLWithPath: $0.folder.hostPath), readOnly: $0.folder.readOnly) }
    }

    public static func shares(for config: VMConfig) -> [WebDAVServer.Share] { shares(for: SharingPolicy(config)) }

    /// The folders the engine attached as devices when the VM started (9p, virtiofs). They cannot be
    /// taken away from a running guest one by one.
    private var bootFolders: [SharedFolder] = []
    /// The VM's folders can be changed while it runs (true for the WebDAV server).
    public var changesApplyLive: Bool { kind == "webdav" }

    /// Where a Mac file is for the guest: `<share name>/<path below the share>`, or nil when the file is
    /// in none of the folders the VM's sharing policy lets it have. The deepest folder that holds the file wins.
    public static func sharedPath(for file: String, in policy: SharingPolicy) -> String? {
        let path = URL(fileURLWithPath: file).standardizedFileURL.resolvingSymlinksInPath().path
        var best: (name: String, root: String)?
        for folder in policy.folders.map(\.folder) {
            let root = URL(fileURLWithPath: folder.hostPath).standardizedFileURL.resolvingSymlinksInPath().path
            let prefix = root.hasSuffix("/") ? root : root + "/"
            guard path.hasPrefix(prefix), path.count > prefix.count else { continue }
            if best == nil || root.count > best!.root.count { best = (folder.name, root) }
        }
        guard let best else { return nil }
        let below = String(path.dropFirst(best.root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return best.name + "/" + below
    }

    public static func sharedPath(for file: String, in config: VMConfig) -> String? { sharedPath(for: file, in: SharingPolicy(config)) }

    /// Starts serving the VM's folders, as far as `policy` allows (the VM's own profile when nil).
    /// Windows guests get a server on the Mac, started even when nothing is shared yet, so that a folder
    /// can be added while the VM runs. For the other guests the engine attaches the folders as devices
    /// and this only records their names for the guest agent.
    public func start(config: VMConfig, policy: SharingPolicy? = nil) throws {
        stop()
        let policy = policy ?? SharingPolicy(config)
        let shares = Self.shares(for: policy)
        kind = Self.kind(for: config)
        if kind != "webdav" {
            bootFolders = policy.folders.map(\.folder)
            names = shares.map(\.name)
            // Linux on QEMU has its folders as devices, but files dropped on it and sent from it still go
            // through a server on the Mac that serves only the hidden drop and inbox shares.
            guard config.supportsGuestFileDrop, config.engine == .qemu else { return }
            policyShares = []
        } else {
            policyShares = shares
        }
        let server = WebDAVServer(shares: policyShares + transferShares)
        server.onLog = onLog
        if onlyVMProcess {
            // Until the VM's process is known nothing is answered; then only it and the `nc` it runs per
            // connection. Other processes and other users on the Mac cannot use the folders.
            server.acceptPeer = { [weak server, client = clientProcess] peerPort in
                guard let server, let pid = client.value else { return false }
                return LoopbackPeer.connection(fromPort: peerPort, toPort: server.port, isHeldByProcessOrChildOf: pid)
            }
        }
        do { port = Int(try server.start(port: Self.preferredPort(for: config.id))) }
        catch { port = Int(try server.start(port: 0)) }
        names = shares.map(\.name)
        self.server = server
    }

    /// What a change of policy did to a running VM's folders.
    public struct Change: Equatable, Sendable {
        /// The guest must be told to read its list of folders again.
        public var announce = false
        /// What could not be done until the VM is restarted, in words for the user. Nil when all applied.
        public var deferred: String?
        /// Folders that are devices and were taken away or narrowed: their positions in the list the VM
        /// started with. The engine pulls these devices out, so the guest cannot mount them again.
        public var revokedDevices: [Int] = []
        public init(announce: Bool = false, deferred: String? = nil, revokedDevices: [Int] = []) {
            self.announce = announce; self.deferred = deferred; self.revokedDevices = revokedDevices
        }
    }

    /// Applies a new policy while the VM runs. Taking access away always happens at once; giving
    /// access may have to wait for a restart where folders are devices fixed at start.
    /// `devicesUpdated`: the engine has already replaced the folders of its device (the VZ engine can).
    @discardableResult
    public func apply(_ policy: SharingPolicy, devicesUpdated: Bool = false) -> Change {
        let shares = Self.shares(for: policy)
        var change = Change()
        // Only a WebDAV guest's folders go through the server; a Linux guest's are devices (its server
        // carries nothing but the hidden drop and inbox shares).
        if let server, kind == "webdav" {
            if policyShares != shares {
                // From this line on the server answers for the new list only.
                policyShares = shares
                server.shares = shares + transferShares
                names = shares.map(\.name)
                change.announce = true
            }
            return change
        }
        guard kind != "webdav" else { return change }   // not running
        let wanted = policy.folders.map(\.folder)
        if devicesUpdated || wanted == bootFolders {
            if devicesUpdated { bootFolders = wanted }
            change.announce = names != wanted.map(\.name)
            names = wanted.map(\.name)
            return change
        }
        // Devices fixed at start. The guest finds each folder by its position in the list, so one
        // cannot be dropped from the middle: when any is taken away or narrowed, all are disconnected.
        let revoked = bootFolders.indices.filter { index in
            let old = bootFolders[index]
            return !wanted.contains { $0.hostPath == old.hostPath && $0.name == old.name && ($0.readOnly || !old.readOnly) }
        }
        if !revoked.isEmpty {
            change.announce = !names.isEmpty
            change.revokedDevices = kind == "9p" ? revoked : []
            names = []
            change.deferred = "This virtual machine’s folders are attached when it starts. A folder was taken away: it is removed from the virtual machine now, and its other Mac folders are disconnected until it is restarted."
        } else {
            change.deferred = "This virtual machine’s folders are attached when it starts. The new folder appears after a restart."
        }
        return change
    }

    /// Tells the server the guest's time zone (seconds east of UTC), as its agent reports it. A Windows
    /// guest shows the Mac's wall-clock time in its own zone, so file times must be shifted by the
    /// difference between the two zones to read the same on both sides.
    public func setGuestUTCOffset(_ seconds: Int?, hostOffset: Int = TimeZone.current.secondsFromGMT()) {
        // The guest reports its offset; real ones are within a day. Anything else is ignored rather than
        // subtracted (Int.min overflowed and trapped the app; found by the fuzz tests).
        let offset = seconds.flatMap { (-86_400...86_400).contains($0) ? $0 : nil }
        server?.clockSkew = offset.map { TimeInterval(hostOffset - $0) } ?? 0
    }

    /// Serves (or stops serving) the hidden shares for files moved by hand. Only for a running server
    /// (Windows guests); returns false when there is none.
    @discardableResult
    public func setTransferShares(_ shares: [WebDAVServer.Share]) -> Bool {
        let hidden = shares.map { WebDAVServer.Share(name: $0.name, root: $0.root, readOnly: $0.readOnly, hidden: true) }
        transferShares = hidden
        guard let server else { return false }
        server.shares = policyShares + hidden
        return true
    }

    public func stop() {
        policyShares = []
        transferShares = []
        server?.stop()
        server = nil
        clientProcess.value = nil
        port = 0
        names = []
        bootFolders = []
        withheld = false
    }
}
