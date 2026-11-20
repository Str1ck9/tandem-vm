import Foundation
import VMCore

/// Minimal client for QEMU's JSON control protocol.
///
/// Every command has a deadline and can be cancelled; each waiting command is answered exactly once (by
/// QEMU's reply, its deadline, its cancellation or the connection closing). Commands are written one at a
/// time. The socket is closed only when the client goes away, so a command racing the connection's end can
/// never write to a descriptor that has been reused for something else.
public final class QMPClient: @unchecked Sendable {
    public typealias Event = (name: String, data: [String: Any])

    /// How long a command waits for QEMU's reply unless told otherwise.
    public static let defaultTimeout: TimeInterval = 30
    /// A reply line longer than this ends the connection (QEMU's replies are far smaller).
    static let maxLineBytes = 32 << 20

    private let fd: Int32
    private let lock = NSLock()
    /// Held while a whole command is written, so concurrent commands never interleave on the socket.
    private let writeLock = NSLock()
    private var nextID = 1
    private var waiters: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var closed = false
    public var onEvent: (@Sendable (String, [String: Any]) -> Void)?
    public var onClose: (@Sendable () -> Void)?

    private init(fd: Int32) {
        self.fd = fd
        // A QEMU that stops reading must not keep a writer blocked for good.
        var limit = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
    }

    deinit { Darwin.close(fd) }

    /// Connects, reads the greeting and negotiates capabilities, all within `timeout`.
    public static func connect(path: String, timeout: TimeInterval = 10) async throws -> QMPClient {
        let started = Date()
        let fd = try await UnixSocket.connect(path: path, timeout: timeout)
        let client = QMPClient(fd: fd)
        Thread.detachNewThread { client.readLoop() }
        do {
            let left = max(timeout - Date().timeIntervalSince(started), 1)
            _ = try await client.execute("qmp_capabilities", timeout: left)
        } catch {
            client.close()
            throw error
        }
        return client
    }

    /// Sends a command and waits at most `timeout` seconds for its reply.
    @discardableResult
    public func execute(_ command: String, arguments: [String: Any]? = nil,
                        timeout: TimeInterval = QMPClient.defaultTimeout) async throws -> [String: Any] {
        let id: Int = lock.withLock { let i = nextID; nextID += 1; return i }
        var message: [String: Any] = ["execute": command, "id": id]
        if let arguments { message["arguments"] = arguments }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any], Error>) in
                // Registered only while the connection is open, atomically with that check.
                let registered: Bool = lock.withLock {
                    guard !closed else { return false }
                    waiters[id] = continuation
                    return true
                }
                guard registered else {
                    continuation.resume(throwing: VMError("QMP connection closed."))
                    return
                }
                // Cancelled before it was registered: the handler found nothing to answer.
                if Task.isCancelled { finish(id, with: .failure(CancellationError())); return }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.finish(id, with: .failure(VMError("QEMU did not answer “\(command)” within \(Int(timeout.rounded(.up))) seconds.")))
                }
                if let failure = write(data) { finish(id, with: .failure(failure)) }
            }
        } onCancel: {
            finish(id, with: .failure(CancellationError()))
        }
    }

    /// Answers waiter `id` if it is still waiting; whoever comes second finds nothing.
    private func finish(_ id: Int, with result: Result<[String: Any], Error>) {
        guard let waiter = lock.withLock({ waiters.removeValue(forKey: id) }) else { return }
        waiter.resume(with: result)
    }

    /// Writes one whole command; returns the failure, if any.
    private func write(_ data: Data) -> Error? {
        writeLock.withLock {
            if lock.withLock({ closed }) { return VMError("QMP connection closed.") }
            return data.withUnsafeBytes { raw -> Error? in
                var off = 0
                while off < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                    if n < 0, errno == EINTR { continue }
                    if n <= 0 { return VMError("QMP connection lost.") }
                    off += n
                }
                return nil
            }
        }
    }

    private func readLoop() {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        reading: while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { break }
            // Only the new bytes can hold the end of the line (rescanning a long partial line each time
            // would make an endless one quadratic).
            let hasNewline = buffer[0..<n].contains(0x0A)
            pending.append(contentsOf: buffer[0..<n])
            if !hasNewline {
                if pending.count > Self.maxLineBytes { break reading }
                continue
            }
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending.subdata(in: pending.startIndex..<newline)
                pending.removeSubrange(pending.startIndex...newline)
                guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                handle(object)
            }
            if pending.count > Self.maxLineBytes { break reading }
        }
        let leftover: [CheckedContinuation<[String: Any], Error>] = lock.withLock {
            closed = true
            let all = Array(waiters.values); waiters.removeAll(); return all
        }
        // The descriptor stays open (and so cannot be reused) until the client goes away; this only ends
        // the connection, so writers fail at once.
        Darwin.shutdown(fd, SHUT_RDWR)
        leftover.forEach { $0.resume(throwing: VMError("QMP connection closed.")) }
        onClose?()
    }

    private func handle(_ object: [String: Any]) {
        if let event = object["event"] as? String {
            onEvent?(event, object["data"] as? [String: Any] ?? [:])
            return
        }
        guard let id = object["id"] as? Int else { return }
        if let error = object["error"] as? [String: Any] {
            finish(id, with: .failure(VMError("QEMU rejected the command.", detail: error["desc"] as? String)))
        } else {
            // Most commands return an object. A bare value (a list, a boolean) is passed on as `["value": …]`.
            let result = object["return"]
            finish(id, with: .success((result as? [String: Any]) ?? result.map { ["value": $0] } ?? [:]))
        }
    }

    public func close() {
        let already = lock.withLock { closed }
        if !already { Darwin.shutdown(fd, SHUT_RDWR) }
    }
}
