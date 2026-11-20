import Foundation
import VMCore

/// Publishes one running VM's services on the Mac: a `ServiceRelay` per service, for as long as the
/// VM runs. What is published is also written to a small status file, so `vmctl services` and the app
/// can show it from another process; a file left behind by a process that died is recognised and removed.
public final class ServicePublisher: @unchecked Sendable {
    public struct Status: Codable, Equatable, Sendable, Identifiable {
        public var service: PublishedService
        /// Nil when the Mac is listening; otherwise why not (the port is taken, for example).
        public var error: String?
        public var id: String { service.name }
        public var isListening: Bool { error == nil }
    }

    /// What one VM has published, as written to its status file.
    public struct Record: Codable, Equatable, Sendable {
        public var vmID: UUID
        public var vmName: String
        public var hostName: String
        /// The process that holds the listening ports.
        public var pid: Int32
        public var services: [Status]
    }

    private let statusDirectory: URL?
    private let lock = NSLock()
    private var relays: [ServiceRelay] = []
    private var record: Record?
    public var onLog: (@Sendable (String) -> Void)?

    /// `statusDirectory`: `statusDirectory(inLibraryRoot:)`, or nil to keep no status file (tests).
    public init(statusDirectory: URL?) { self.statusDirectory = statusDirectory }

    deinit { stop() }

    public static func statusDirectory(inLibraryRoot root: URL) -> URL { root.appendingPathComponent("published", isDirectory: true) }

    public var statuses: [Status] { lock.withLock { record?.services ?? [] } }

    /// Starts listening for every service of the VM. `target` says where a guest port can be reached
    /// right now (nil while the guest's address is not known). A service whose port cannot be had is
    /// reported in the result and does not stop the others, or the VM.
    @discardableResult
    public func start(config: VMConfig, target: @escaping @Sendable (_ guestPort: Int) -> (host: String, port: Int)?) -> [Status] {
        stop()
        guard PublishedServices.publishingAllowed(for: config), let services = config.publishedServices, !services.isEmpty else { return [] }
        var started: [ServiceRelay] = []
        var statuses: [Status] = []
        for service in services {
            let guestPort = service.guestPort
            let relay = ServiceRelay(bindAddress: service.scope.bindAddress, port: service.hostPort) { target(guestPort) }
            relay.onLog = onLog
            do {
                try relay.start()
                started.append(relay)
                statuses.append(Status(service: service, error: nil))
                onLog?("published “\(service.name)”: \(service.scope.bindAddress):\(service.hostPort) → guest port \(guestPort)")
            } catch {
                statuses.append(Status(service: service, error: error.localizedDescription))
                onLog?("could not publish “\(service.name)”: \(error.localizedDescription)")
            }
        }
        let record = Record(vmID: config.id, vmName: config.name, hostName: PublishedServices.hostName(forVMNamed: config.name),
                            pid: getpid(), services: statuses)
        lock.withLock { relays = started; self.record = record }
        write(record)
        return statuses
    }

    public func stop() {
        let (old, id) = lock.withLock { () -> ([ServiceRelay], UUID?) in
            let result = (relays, record?.vmID)
            relays = []; record = nil
            return result
        }
        old.forEach { $0.stop() }
        if let id, let statusDirectory { try? FileManager.default.removeItem(at: Self.file(for: id, in: statusDirectory)) }
    }

    private static func file(for id: UUID, in directory: URL) -> URL { directory.appendingPathComponent(id.uuidString.lowercased() + ".json") }

    private func write(_ record: Record) {
        guard let statusDirectory else { return }
        try? FileManager.default.createDirectory(at: statusDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(record).write(to: Self.file(for: record.vmID, in: statusDirectory), options: .atomic)
    }

    /// What is published right now, by any process. Status files of processes that no longer run, and of
    /// VMs that no longer exist (`knownVMs`, when given), are stale: they are deleted and left out.
    public static func active(in statusDirectory: URL, knownVMs: Set<UUID>? = nil) -> [Record] {
        let fm = FileManager.default
        var records: [Record] = []
        for url in (try? fm.contentsOfDirectory(at: statusDirectory, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url), let record = try? JSONDecoder().decode(Record.self, from: data) else {
                try? fm.removeItem(at: url)
                continue
            }
            let alive = kill(record.pid, 0) == 0 || errno == EPERM
            if !alive || knownVMs.map({ !$0.contains(record.vmID) }) == true {
                try? fm.removeItem(at: url)
                continue
            }
            records.append(record)
        }
        return records.sorted { $0.vmName.localizedCaseInsensitiveCompare($1.vmName) == .orderedAscending }
    }

    /// Where a guest port of this VM can be reached from the Mac at this moment.
    /// On the QEMU engine's shared network the guest has no address the Mac can reach, so the engine
    /// forwards a private loopback port per guest port (`backends`, from `backendPorts`). On every other
    /// network the guest has a real address: the one its tools reported, or the one the Mac's address
    /// table has for its network card. It is looked up per connection, so a new address is picked up.
    public static func target(config: VMConfig, backends: [Int: Int],
                              reportedAddresses: @escaping @Sendable () -> [String]?) -> @Sendable (Int) -> (host: String, port: Int)? {
        if config.engine == .qemu && config.network.mode == .nat {
            return { guestPort in backends[guestPort].map { ("127.0.0.1", $0) } }
        }
        let mac = config.network.mac
        return { guestPort in
            (GuestAddress.first(of: reportedAddresses()) ?? GuestAddress.lookup(mac: mac)).map { ($0, guestPort) }
        }
    }

    /// True when this VM's services need the QEMU engine's loopback forwarding (see `target`).
    public static func needsBackends(_ config: VMConfig) -> Bool {
        config.engine == .qemu && config.network.mode == .nat && !(config.publishedServices ?? []).isEmpty
            && PublishedServices.publishingAllowed(for: config)
    }

    /// A free loopback port for each guest port: where the QEMU engine's own forwarding listens, behind the relay.
    public static func backendPorts(for services: [PublishedService]) -> [Int: Int] {
        var result: [Int: Int] = [:]
        for guestPort in Set(services.map(\.guestPort)) {
            if let port = freeLoopbackPort() { result[guestPort] = port }
        }
        return result
    }

    static func freeLoopbackPort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { return nil }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        return named == 0 ? Int(UInt16(bigEndian: address.sin_port)) : nil
    }
}

/// Finds a guest's current IPv4 address when it is on a network the Mac can reach directly
/// (Apple's engine's shared network, or bridged).
public enum GuestAddress {
    /// The first usable IPv4 address the guest tools reported.
    public static func first(of reported: [String]?) -> String? {
        reported?.first { address in
            let parts = address.split(separator: ".")
            return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil } && !address.hasPrefix("127.") && !address.hasPrefix("169.254.")
        }
    }

    /// `aa:0b:…` and `AA:B:…` are the same address; `arp` drops leading zeros.
    static func normalized(mac: String) -> String {
        mac.lowercased().split(separator: ":").map { String(UInt8($0, radix: 16) ?? 0, radix: 16) }.joined(separator: ":")
    }

    /// The address in the output of `arp -an` that belongs to a network card.
    public static func address(forMAC mac: String, inARPTable table: String) -> String? {
        let wanted = normalized(mac: mac)
        for line in table.split(separator: "\n") {
            // ? (192.168.64.5) at 5e:a5:65:7c:4e:dc on bridge100 ifscope [bridge]
            guard let open = line.firstIndex(of: "("), let close = line.firstIndex(of: ")"), open < close,
                  let at = line.range(of: " at ") else { continue }
            let found = line[at.upperBound...].split(separator: " ").first.map(String.init) ?? ""
            if found.contains(":"), normalized(mac: found) == wanted { return String(line[line.index(after: open)..<close]) }
        }
        return nil
    }

    /// Asks the Mac's own address table: works without guest tools once the guest has sent anything.
    public static func lookup(mac: String) -> String? {
        // -n: no name lookups, so a slow DNS server cannot hold it up; the limit covers the rest.
        guard let table = try? ToolRun.run(URL(fileURLWithPath: "/usr/sbin/arp"), ["-an"], timeout: 10, errors: .discard) else { return nil }
        return address(forMAC: mac, inARPTable: table.outputText)
    }
}
