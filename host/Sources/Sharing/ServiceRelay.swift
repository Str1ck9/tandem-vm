import Foundation
import VMCore

/// Where a relay sends a connection: asked afresh for every connection, so a guest that has come back
/// with another address, or behind another forwarded port, is found again without the relay restarting.
public typealias RelayTarget = @Sendable () -> (host: String, port: Int)?

/// Listens on a port of the Mac and passes each TCP connection on to a guest service.
/// Listening on 127.0.0.1 keeps the service to this Mac; 0.0.0.0 opens it to the local network.
///
/// Each connection costs three threads and two descriptors, and a service published to the network is
/// reachable by anyone there, so connections are budgeted: at most `maxConnections` per relay and
/// `globalMaxConnections` across all relays (more are closed at once), and a connection on which neither
/// side has sent anything for `idleTimeout` is closed.
public final class ServiceRelay: @unchecked Sendable {
    public static let defaultMaxConnections = 64
    public static let defaultIdleTimeout: TimeInterval = 3600
    /// Across every relay in this process.
    public static let globalMaxConnections = 256
    private static let globalLock = NSLock()
    nonisolated(unsafe) private static var globalActive = 0
    /// Connections being relayed by all relays now.
    public static var globalActiveConnections: Int { globalLock.withLock { globalActive } }

    public let bindAddress: String
    public let port: Int
    public let maxConnections: Int
    public let idleTimeout: TimeInterval
    private let target: RelayTarget
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var open: Set<Int32> = []
    private var active = 0
    private var stopped = false
    /// Connections passed on since the relay started.
    public private(set) var connectionCount = 0
    /// Connections turned away because a budget was full.
    public private(set) var refusedCount = 0
    public var onLog: (@Sendable (String) -> Void)?

    public init(bindAddress: String, port: Int, maxConnections: Int = ServiceRelay.defaultMaxConnections,
                idleTimeout: TimeInterval = ServiceRelay.defaultIdleTimeout, target: @escaping RelayTarget) {
        self.bindAddress = bindAddress; self.port = port; self.target = target
        self.maxConnections = max(1, maxConnections); self.idleTimeout = idleTimeout
    }

    /// Connections this relay is serving now (including ones still reaching the guest).
    public var activeConnections: Int { lock.withLock { active } }

    deinit { stop() }

    /// True when nothing is listening on the port right now.
    public static func portIsFree(_ port: Int, bindAddress: String = "0.0.0.0") -> Bool {
        guard let fd = try? listenSocket(bindAddress: bindAddress, port: port) else { return false }
        close(fd)
        return true
    }

    /// True when a program on this Mac accepts connections on the port. The system lets a listener on
    /// 127.0.0.1 and one on every interface share a port number, so asking to bind does not find them all.
    static func somethingListens(on port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port)).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }

    private static func listenSocket(bindAddress: String, port: Int) throws -> Int32 {
        if somethingListens(on: port) { throw VMError("Port \(port) on the Mac is in use by another program.") }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VMError("Could not create a socket.", detail: String(cString: strerror(errno))) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port)).bigEndian
        guard inet_pton(AF_INET, bindAddress, &address.sin_addr) == 1 else { close(fd); throw VMError("“\(bindAddress)” is not an address to listen on.") }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 64) == 0 else {
            let code = errno
            close(fd)
            if code == EADDRINUSE { throw VMError("Port \(port) on the Mac is in use by another program.") }
            throw VMError("Could not listen on port \(port).", detail: String(cString: strerror(code)))
        }
        return fd
    }

    public func start() throws {
        let fd = try Self.listenSocket(bindAddress: bindAddress, port: port)
        lock.withLock { listener = fd; stopped = false }
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "tandem.relay.\(port)"
        thread.start()
    }

    public func stop() {
        let fd = lock.withLock { () -> Int32 in
            stopped = true
            // Shutting the sockets down wakes the threads that are copying; each closes its own descriptors,
            // under this lock, so none of these numbers can have been reused for something else.
            for connection in open { shutdown(connection, SHUT_RDWR) }
            let result = listener
            listener = -1
            return result
        }
        if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd) }
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return // the listener was closed
            }
            if lock.withLock({ stopped }) { close(client); return }
            guard admit(client) else {
                close(client)
                let refused = lock.withLock { () -> Int in refusedCount += 1; return refusedCount }
                // One line now and then, not one per refused connection.
                if refused == 1 || refused % 100 == 0 {
                    onLog?("port \(port): too many connections, refused \(refused) so far")
                }
                continue
            }
            var yes: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            let thread = Thread { [weak self] in
                guard let self else { close(client); return }
                self.serve(client)
            }
            thread.stackSize = 256 << 10
            thread.start()
        }
    }

    /// Takes a place in both budgets, and tracks the client from now on, so that `stop` can end it even
    /// while the guest is still being reached.
    private func admit(_ client: Int32) -> Bool {
        Self.globalLock.lock()
        defer { Self.globalLock.unlock() }
        guard Self.globalActive < Self.globalMaxConnections else { return false }
        return lock.withLock {
            guard !stopped, active < maxConnections else { return false }
            active += 1
            Self.globalActive += 1
            open.insert(client)
            return true
        }
    }

    /// Gives back the places taken by `admit` and closes the descriptors, under the lock (see `stop`).
    private func release(_ descriptors: [Int32]) {
        lock.withLock {
            for fd in descriptors { open.remove(fd); close(fd) }
            active -= 1
        }
        Self.globalLock.withLock { Self.globalActive -= 1 }
    }

    private static func connect(host: String, port: Int) -> Int32? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let first = list else { return nil }
        defer { freeaddrinfo(list) }
        let fd = socket(first.pointee.ai_family, first.pointee.ai_socktype, first.pointee.ai_protocol)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        // A guest that is restarting must not hold a caller for the system's default of over a minute.
        var timeout = timeval(tv_sec: 8, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard Darwin.connect(fd, first.pointee.ai_addr, first.pointee.ai_addrlen) == 0 else { close(fd); return nil }
        var none = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &none, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    private func serve(_ client: Int32) {
        guard let destination = target(), let upstream = Self.connect(host: destination.host, port: destination.port) else {
            onLog?("port \(port): the guest service is not reachable")
            release([client])
            return
        }
        let accepted = lock.withLock { () -> Bool in
            if stopped { return false }
            open.insert(upstream); connectionCount += 1
            return true
        }
        guard accepted else { close(upstream); release([client]); return }
        // Reads wake up now and then to check the connection's idle time.
        let activity = Activity()
        // A write that cannot move for the whole idle time (a peer that stopped reading) ends it too.
        var wake = Self.interval(min(max(idleTimeout, 0.05), 30))
        var stall = Self.interval(max(idleTimeout, 0.05))
        for fd in [client, upstream] {
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wake, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &stall, socklen_t(MemoryLayout<timeval>.size))
        }
        // One thread per direction. When one side finishes sending, the other is told (half close),
        // so protocols that end a request by closing their sending side still get their answer.
        let group = DispatchGroup()
        let idleTimeout = self.idleTimeout
        for (from, to) in [(client, upstream), (upstream, client)] {
            group.enter()
            let thread = Thread {
                if Self.copy(from: from, to: to, activity: activity, idleTimeout: idleTimeout) == .idle {
                    // Idle in both directions: end the whole connection, not just this half.
                    shutdown(from, SHUT_RDWR); shutdown(to, SHUT_RDWR)
                } else {
                    shutdown(to, SHUT_WR)
                }
                group.leave()
            }
            thread.stackSize = 256 << 10
            thread.start()
        }
        group.wait()
        if activity.timedOut { onLog?("port \(port): closed a connection idle for \(Int(idleTimeout)) s") }
        release([client, upstream])
    }

    private static func interval(_ seconds: TimeInterval) -> timeval {
        let whole = seconds.rounded(.down)
        return timeval(tv_sec: Int(whole), tv_usec: Int32((seconds - whole) * 1_000_000))
    }

    /// When either direction last moved data.
    final class Activity: @unchecked Sendable {
        private let lock = NSLock()
        private var last = Date()
        private var idle = false
        func touch() { lock.withLock { last = Date() } }
        func idleFor() -> TimeInterval { lock.withLock { Date().timeIntervalSince(last) } }
        func markTimedOut() { lock.withLock { idle = true } }
        var timedOut: Bool { lock.withLock { idle } }
    }

    enum CopyEnd { case finished, idle }

    static func copy(from: Int32, to: Int32, activity: Activity, idleTimeout: TimeInterval) -> CopyEnd {
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let count = read(from, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                // Nothing this way for a while; the connection is idle only if the other way is quiet too.
                if activity.timedOut || activity.idleFor() >= idleTimeout { activity.markTimedOut(); return .idle }
                continue
            }
            guard count > 0 else { return .finished }
            activity.touch()
            var sent = 0
            while sent < count {
                let written = buffer.withUnsafeBytes { write(to, $0.baseAddress! + sent, count - sent) }
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { return .finished }
                sent += written
            }
        }
    }
}
