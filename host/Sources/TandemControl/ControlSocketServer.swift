import Foundation

/// Serves the control protocol on a Unix socket: one thread per connection, one request per line.
///
/// Each request is answered by `handle`. The socket file is owner-only and every peer must run as this
/// user. A budget bounds what any local client (a buggy script, a stuck MCP server) can hold: at most
/// `maxConnections` at once (more are told "busy" and closed), and a connection that sends nothing for
/// `idleTimeout` is closed. The `tandem` command and its MCP server reconnect on their own.
public final class ControlSocketServer: @unchecked Sendable {
    public static let defaultMaxConnections = 32
    public static let defaultIdleTimeout: TimeInterval = 600

    private let path: String
    private let maxConnections: Int
    private let idleTimeout: TimeInterval
    private let handle: @Sendable (ControlRequest) async -> ControlResponse
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var active = 0

    public init(path: String, maxConnections: Int = ControlSocketServer.defaultMaxConnections,
                idleTimeout: TimeInterval = ControlSocketServer.defaultIdleTimeout,
                handle: @escaping @Sendable (ControlRequest) async -> ControlResponse) {
        self.path = path
        self.maxConnections = max(1, maxConnections)
        self.idleTimeout = idleTimeout
        self.handle = handle
    }

    /// Connections being served now.
    public var activeConnections: Int { lock.withLock { active } }

    public func start() throws {
        let fd = try ControlSocket.listen(path: path)
        lock.withLock { listener = fd }
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "tandem.control.accept"
        thread.start()
    }

    public func stop() {
        let fd = lock.withLock { () -> Int32 in let f = listener; listener = -1; return f }
        guard fd >= 0 else { return }
        shutdown(fd, SHUT_RDWR)
        close(fd)
        unlink(path)
    }

    deinit { stop() }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { if errno == EINTR { continue }; return }
            guard ControlSocket.peerIsSameUser(client) else { close(client); continue }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let admitted = lock.withLock { () -> Bool in
                guard active < maxConnections else { return false }
                active += 1
                return true
            }
            guard admitted else {
                // Say why, so the client does not take it for a crash; never wait on it.
                var brief = timeval(tv_sec: 1, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &brief, socklen_t(MemoryLayout<timeval>.size))
                let busy = ControlResponse.failure(0, ControlError("busy", "Tandem has too many control connections open. Try again in a moment."))
                if let data = try? ControlCoding.encode(busy) { _ = ControlSocket.writeAll(client, data) }
                close(client)
                continue
            }
            // A read that waits longer than this ends the connection.
            var idle = timeval(tv_sec: Int(max(1, idleTimeout.rounded(.down))), tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &idle, socklen_t(MemoryLayout<timeval>.size))
            let thread = Thread { [weak self] in
                self?.serve(client)
                close(client)
                if let self { self.lock.withLock { self.active -= 1 } }
            }
            thread.name = "tandem.control.client"
            thread.start()
        }
    }

    private func serve(_ fd: Int32) {
        var buffer = Data()
        while let line = ControlSocket.readLine(fd, buffer: &buffer, limit: 8 << 20) {
            if line.isEmpty { continue }
            let response: ControlResponse
            if let request = try? ControlCoding.decode(ControlRequest.self, line: line) {
                let done = DispatchSemaphore(value: 0)
                let box = ResponseBox()
                let handle = self.handle
                Task { box.value = await handle(request); done.signal() }
                done.wait()
                response = box.value ?? .failure(request.id, .failed("No answer."))
            } else {
                response = .failure(0, ControlError("bad-request", "The request is not valid JSON for control protocol version \(ControlProtocol.version)."))
            }
            guard let data = try? ControlCoding.encode(response), ControlSocket.writeAll(fd, data) else { return }
        }
    }
}

private final class ResponseBox: @unchecked Sendable { var value: ControlResponse? }
