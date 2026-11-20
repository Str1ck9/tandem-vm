import Foundation
import VMCore

extension NetHelper {
    /// Asks the helper (root) to unmount a USB disk on the Mac and serve its raw disk over NBD on a unix
    /// socket only this user can reach; QEMU reads it from there. macOS keeps its own driver: nothing is
    /// captured, which macOS 26 does not allow without Apple's entitlement. The helper keeps the disk until
    /// `release()` (mounted on the Mac again) or until the lease is dropped (left unmounted).
    public static func disk(bsd: String) throws -> DiskLease {
        let info: Info
        do { info = try self.info() }
        catch { throw VMError("The Tandem helper is needed for USB drives.", detail: "macOS only lets an administrator hand a disk to a virtual machine. \(installAdvice)") }
        guard info.supportsDisks else {
            throw VMError("The installed Tandem helper is too old for USB drives.", detail: "Install it again. \(installAdvice)")
        }
        let connection = try Connection()
        do {
            let reply = try connection.request(["op": "disk", "bsd": bsd])
            guard let socket = reply["socket"] as? String else { throw VMError("The Tandem helper did not hand over the disk.") }
            return DiskLease(connection: connection, bsd: bsd, socketPath: socket,
                             readOnly: reply["readOnly"] as? Bool ?? false,
                             size: (reply["size"] as? NSNumber)?.uint64Value ?? 0)
        } catch {
            connection.close()
            throw error
        }
    }

    /// What macOS lets the helper (root) do with a disk, without changing anything.
    public static func diskProbe(bsd: String) throws -> DiskProbe {
        let info = try self.info()
        guard info.supportsProbe else {
            throw VMError("The installed Tandem helper is too old to check disks.", detail: "Install it again. \(installAdvice)")
        }
        let connection = try Connection()
        defer { connection.close() }
        return DiskProbe(try connection.request(["op": "disk-probe", "bsd": bsd]))
    }
}

/// The helper's answer to "disk-probe": for the raw and the block node, the outcome of stat, open for
/// reading, open for writing and chown ("ok" or the error text), and whether the helper has Full Disk Access.
public struct DiskProbe: Equatable, Sendable {
    public struct Node: Equatable, Sendable {
        public var path: String
        public var stat: String?
        public var openRead: String?
        public var openWrite: String?
        public var chown: String?
    }
    public var bsd: String
    public var effectiveUID: Int?
    public var raw: Node?
    public var block: Node?
    public var fullDiskAccess: String?

    public init(_ reply: [String: Any]) {
        func node(_ key: String) -> Node? {
            guard let entry = reply[key] as? [String: Any] else { return nil }
            return Node(path: entry["path"] as? String ?? "", stat: entry["stat"] as? String, openRead: entry["openRead"] as? String,
                        openWrite: entry["openWrite"] as? String, chown: entry["chown"] as? String)
        }
        bsd = reply["bsd"] as? String ?? ""
        effectiveUID = reply["euid"] as? Int
        raw = node("raw")
        block = node("block")
        fullDiskAccess = reply["fullDiskAccess"] as? String
    }

    static let notPermitted = "Operation not permitted"

    /// Whether the helper can serve the drive (it only needs to open the raw disk).
    public var canServe: Bool { raw?.openRead == "ok" }

    /// One plain sentence on what this means and what to do.
    public var verdict: String {
        guard let raw else { return "The helper did not report on /dev/r\(bsd)." }
        if raw.stat != "ok" { return "There is no disk \(bsd) (\(raw.stat ?? "?"))." }
        if raw.openRead == "ok" {
            let writable = raw.openWrite == "ok" ? "for reading and writing" : "for reading only (\(raw.openWrite ?? "?"))"
            return "The helper can open \(raw.path) \(writable), so the drive can be served to a VM."
        }
        if raw.openRead == Self.notPermitted {
            if fullDiskAccess == "no" {
                return "macOS does not let the helper open \(raw.path), because the helper has no Full Disk Access. \(NetHelper.fullDiskAccessAdvice)"
            }
            return "macOS does not let the helper open \(raw.path) (Operation not permitted), even though it has Full Disk Access (\(fullDiskAccess ?? "unknown"))."
        }
        return "The helper cannot open \(raw.path): \(raw.openRead ?? "unknown error")."
    }

    /// The report, line by line, as `vmctl usb-probe` prints it.
    public var report: [String] {
        var lines = ["Helper runs as uid \(effectiveUID.map(String.init) ?? "?"); Full Disk Access: \(fullDiskAccess ?? "?")"]
        for node in [raw, block].compactMap({ $0 }) {
            lines.append("\(node.path): stat \(node.stat ?? "-"), open for reading \(node.openRead ?? "-"), open for writing \(node.openWrite ?? "-"), chown \(node.chown ?? "-")")
        }
        lines.append(verdict)
        return lines
    }
}

/// A USB disk served by the helper. `socketPath` is a unix socket speaking NBD, which QEMU reads.
/// `release()` tells the helper the VM has let go: the server stops and the disk is mounted on the Mac
/// again. `abandon()` drops the lease without that, which leaves the disk unmounted.
public final class DiskLease: @unchecked Sendable {
    private let connection: NetHelper.Connection
    public let bsd: String
    public let socketPath: String
    public let readOnly: Bool
    public let size: UInt64

    init(connection: NetHelper.Connection, bsd: String, socketPath: String, readOnly: Bool, size: UInt64) {
        self.connection = connection
        self.bsd = bsd
        self.socketPath = socketPath
        self.readOnly = readOnly
        self.size = size
    }

    /// Returns the helper's warning when macOS could not mount the disk again (nil when it did).
    @discardableResult
    public func release() -> String? {
        let answer = try? connection.request(["op": "release-disk"])
        connection.close()
        return answer?["warning"] as? String
    }

    public func abandon() { connection.close() }
}
