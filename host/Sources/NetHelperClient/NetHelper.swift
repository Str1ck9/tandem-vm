import Foundation
import VMCore

/// Client for the Tandem network helper (`TandemNetHelper`), the root daemon that provides bridged
/// networking. Installed once with `scripts/install-net-helper.sh`.
public enum NetHelper {
    public static let defaultSocketPath = "/var/run/tandem-net.sock"
    /// The helper's control socket. Tests point this at a helper they started themselves.
    nonisolated(unsafe) public static var socketPath = ProcessInfo.processInfo.environment["TANDEM_NET_SOCKET"] ?? defaultSocketPath

    /// True when the helper's socket exists. It can still refuse this user; `interfaces()` finds that out.
    public static var isInstalled: Bool {
        var info = stat()
        return lstat(socketPath, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK
    }

    /// Network interfaces of this Mac that can be bridged, for example `en0`.
    public static func interfaces() throws -> [String] {
        let connection = try Connection()
        defer { connection.close() }
        let reply = try connection.request(["op": "interfaces"])
        return reply["interfaces"] as? [String] ?? []
    }

    /// Asks the helper for a bridge onto `interface`. `peerPath` is where the VM's datagram socket is,
    /// or will be, bound. The bridge lasts until the lease is closed.
    public static func bridge(interface: String, peerPath: String) throws -> BridgeLease {
        let connection = try Connection()
        do {
            let reply = try connection.request(["op": "bridge", "interface": interface, "peer": peerPath])
            guard let path = reply["socket"] as? String else { throw VMError("The network helper sent an incomplete answer.") }
            return BridgeLease(connection: connection, helperSocketPath: path,
                               mtu: reply["mtu"] as? Int ?? 1500, maxPacketSize: reply["maxPacketSize"] as? Int ?? 1514)
        } catch {
            connection.close()
            throw error
        }
    }

    /// What the installed helper can do. An old helper answers version 1 without features.
    public struct Info: Equatable, Sendable {
        public var version: Int
        public var features: [String]
        public var supportsUSB: Bool { version >= 2 && features.contains("usb") }
        /// Can hand a USB disk to a VM. Protocol 3 lent the device node by chown, which macOS 26 refuses
        /// even root; protocol 4 serves the disk over NBD instead.
        public var supportsDisks: Bool { version >= 4 && features.contains("disk") }
        /// Answers "disk-probe" (protocol 4).
        public var supportsProbe: Bool { version >= 4 && features.contains("probe") }
        /// Answers "restart": exits so launchd starts it afresh (picks up a new Full Disk Access grant).
        public var supportsRestart: Bool { features.contains("restart") }

        public init(version: Int, features: [String]) { self.version = version; self.features = features }
    }

    /// What the running helper reports about itself ("status", or pieced together for older helpers).
    public struct Status: Equatable, Sendable {
        public var version: Int
        public var features: [String]
        /// "yes", "no", "unknown (…)", or nil when the helper cannot tell.
        public var fullDiskAccess: String?
        /// Started by SMAppService from inside Tandem.app (nil: an older helper that does not say).
        public var fromBundle: Bool?
        public var pid: Int?
        public var program: String?
        /// Connections holding a bridge, USB device or drive.
        public var busy: Int
        /// The launchd label it runs under (nil: a helper that does not say, or not started by launchd).
        public var label: String?
        public var canRestart: Bool { features.contains("restart") }

        public init(version: Int, features: [String], fullDiskAccess: String?, fromBundle: Bool?, pid: Int?, program: String?, busy: Int,
                    label: String? = nil) {
            self.version = version; self.features = features; self.fullDiskAccess = fullDiskAccess
            self.fromBundle = fromBundle; self.pid = pid; self.program = program; self.busy = busy; self.label = label
        }
    }

    public static func status() throws -> Status {
        let info = try self.info()
        if info.features.contains("status") {
            let connection = try Connection()
            defer { connection.close() }
            let reply = try connection.request(["op": "status"])
            return Status(version: info.version, features: info.features, fullDiskAccess: reply["fullDiskAccess"] as? String,
                          fromBundle: reply["fromBundle"] as? Bool, pid: reply["pid"] as? Int, program: reply["program"] as? String,
                          busy: reply["busy"] as? Int ?? 0, label: (reply["label"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
        // Protocol 4 without "status": the disk probe also answers Full Disk Access. A disk name that
        // cannot exist, so nothing is opened.
        var access: String?
        if info.supportsProbe, let probe = try? diskProbe(bsd: "disk9999") { access = probe.fullDiskAccess }
        return Status(version: info.version, features: info.features, fullDiskAccess: access, fromBundle: nil, pid: nil, program: nil, busy: 0)
    }

    /// Asks the helper to exit so launchd starts it again. Refused while it serves a VM.
    public static func restart() throws {
        let connection = try Connection()
        defer { connection.close() }
        _ = try connection.request(["op": "restart"])
    }

    public static func info() throws -> Info {
        let connection = try Connection()
        defer { connection.close() }
        let reply = try connection.request(["op": "version"])
        return Info(version: reply["version"] as? Int ?? 1, features: reply["features"] as? [String] ?? ["bridge"])
    }

    /// What the user should do to get a helper that can take USB devices.
    public static let installAdvice = "Install it once from Tandem > Settings > Network (it asks for your administrator password), or run: sudo scripts/install-net-helper.sh"

    /// What the user should do when macOS refuses the helper (root) access to a disk. An in-app helper
    /// (SMAppService) is listed under the app's own name; the script's helper by its path.
    public static var fullDiskAccessAdvice: String {
        appHelperAdvice ? "Switch on Full Disk Access for “Tandem” itself in System Settings > Privacy & Security > Full Disk Access, then click Restart helper in Tandem > Settings > Network."
            : scriptFullDiskAccessAdvice
    }
    /// Set by the app when this copy installs its helper with SMAppService.
    nonisolated(unsafe) public static var appHelperAdvice = false
    public static var scriptFullDiskAccessAdvice: String {
        "Allow Full Disk Access for '\(TandemIdentity.scriptHelper)' in System Settings > Privacy & Security > Full Disk Access (click +, press Command-Shift-G and enter /Library/PrivilegedHelperTools/\(TandemIdentity.scriptHelper))."
    }

    /// Asks the helper to take a USB device away from macOS and hand it over as a usbredir stream on a
    /// unix socket. The device stays redirected until the lease is closed.
    public static func usb(vendor: Int, product: Int, location: UInt32) throws -> USBLease {
        let info: Info
        do { info = try self.info() }
        catch { throw VMError("The Tandem helper is needed for this device.", detail: "macOS only lets an administrator take a device away from its own drivers. \(installAdvice)") }
        guard info.supportsUSB else {
            throw VMError("The installed Tandem helper is too old for USB devices.", detail: "Install it again. \(installAdvice)")
        }
        let connection = try Connection()
        do {
            let reply = try connection.request(["op": "usb", "vendor": vendor, "product": product, "location": Int(location)])
            guard let path = reply["socket"] as? String else { throw VMError("The Tandem helper sent an incomplete answer.") }
            return USBLease(connection: connection, socketPath: path)
        } catch {
            connection.close()
            throw error
        }
    }

    /// A datagram socket bound at `path` and connected to the helper's end of a bridge. Each datagram is
    /// one Ethernet frame. The caller owns the descriptor and removes `path` when done.
    public static func makeClientSocket(at path: String, connectedTo helperPath: String) throws -> Int32 {
        let local = try address(path), remote = try address(helperPath)
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw VMError("socket() failed.", detail: String(cString: strerror(errno))) }
        func fail(_ what: String) -> VMError {
            let reason = String(cString: strerror(errno))
            Darwin.close(fd)
            return VMError(what, detail: reason)
        }
        // Unix datagrams are limited to 2048 bytes until the buffers are raised.
        for (option, bytes) in [(SO_SNDBUF, Int32(256 * 1024)), (SO_RCVBUF, Int32(2 * 1024 * 1024))] {
            var value = bytes
            setsockopt(fd, SOL_SOCKET, option, &value, socklen_t(MemoryLayout<Int32>.size))
        }
        unlink(path)
        guard withSockaddr(local, { bind(fd, $0, $1) }) == 0 else { throw fail("Cannot bind \(path).") }
        chmod(path, 0o600)
        guard withSockaddr(remote, { connect(fd, $0, $1) }) == 0 else {
            let error = fail("Cannot connect to the network helper's socket \(helperPath).")
            unlink(path)
            throw error
        }
        return fd
    }

    static func address(_ path: String) throws -> sockaddr_un {
        guard path.utf8.count <= UnixSocket.maxPathLength else { throw VMError("Socket path is too long (\(path.utf8.count) bytes): \(path)") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: path.utf8) }
        return addr
    }

    static func withSockaddr<R>(_ addr: sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R {
        var addr = addr
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    /// One control connection: a JSON line out, a JSON line back.
    final class Connection: @unchecked Sendable {
        private let fd: Int32
        private let lock = NSLock()
        private var closed = false

        init() throws {
            guard NetHelper.isInstalled else {
                throw VMError("The Tandem network helper is not installed.", detail: "Bridged networking needs it. Run scripts/install-net-helper.sh with sudo once.")
            }
            do { fd = try UnixSocket.connect(path: NetHelper.socketPath) }
            catch { throw VMError("Cannot reach the Tandem network helper.", detail: (error as? VMError)?.detail ?? "\(error)") }
            // A helper that stops answering must not hang the app.
            var timeout = timeval(tv_sec: 20, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        }

        func request(_ object: [String: Any]) throws -> [String: Any] {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(0x0A)
            let sent = data.withUnsafeBytes { raw -> Bool in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n <= 0 { return false }
                    offset += n
                }
                return true
            }
            guard sent else { throw VMError("The network helper closed the connection.") }
            var line = Data()
            var byte: UInt8 = 0
            while true {
                let n = Darwin.read(fd, &byte, 1)
                guard n == 1 else { throw VMError("The network helper did not answer.") }
                if byte == 0x0A { break }
                line.append(byte)
                guard line.count <= 65536 else { throw VMError("The network helper sent an oversized answer.") }
            }
            guard let reply = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                throw VMError("The network helper sent an unreadable answer.")
            }
            guard reply["ok"] as? Bool == true else {
                throw VMError("The network helper refused the request.", detail: reply["error"] as? String)
            }
            return reply
        }

        func close() {
            let already: Bool = lock.withLock { let was = closed; closed = true; return was }
            if !already { Darwin.close(fd) }
        }

        deinit { close() }
    }
}

/// A USB device redirected by the helper. QEMU's `usb-redir` connects to `socketPath`. Closing the lease
/// (or the app exiting) ends the redirection and gives the device back to macOS.
public final class USBLease: @unchecked Sendable {
    private let connection: NetHelper.Connection
    public let socketPath: String

    init(connection: NetHelper.Connection, socketPath: String) {
        self.connection = connection
        self.socketPath = socketPath
    }

    public func close() { connection.close() }
}

/// A live bridge. The helper tears it down when the lease is closed or the app exits.
public final class BridgeLease: @unchecked Sendable {
    private let connection: NetHelper.Connection
    /// The helper's datagram socket: what the VM's socket sends to.
    public let helperSocketPath: String
    public let mtu: Int
    public let maxPacketSize: Int

    init(connection: NetHelper.Connection, helperSocketPath: String, mtu: Int, maxPacketSize: Int) {
        self.connection = connection
        self.helperSocketPath = helperSocketPath
        self.mtu = mtu
        self.maxPacketSize = maxPacketSize
    }

    public func close() { connection.close() }
}
