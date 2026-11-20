import Foundation
import VMCore

// Running a command inside the guest (capability bit 16; PROTOCOL.md "guest commands").
//
// The host posts EXEC_REQUEST (event 40: arg0 request id, arg1 flags, data the JSON below); the guest
// tools run the command on a thread of their own and answer with EXEC_RESULT (0x0670). Events of one
// kind replace each other while queued, so the host runs one command per VM at a time.

/// What to run. `command` is one line for the guest's shell (`cmd /c` on Windows, `/bin/sh -c` on Linux).
public struct GuestExecRequest: Codable, Equatable, Sendable {
    public var command: String
    /// Linux: run as this user instead of root. Windows: ignored (always the signed-in user).
    public var user: String?
    /// Windows: run with the administrator rights the guest tools have. Default: as the signed-in user, unelevated.
    public var elevated: Bool
    public var timeoutSeconds: Int
    /// Most bytes kept of each of standard output and standard error.
    public var maxOutputBytes: Int

    public static let defaultTimeout = 60
    public static let maxTimeout = 3600
    public static let defaultMaxOutput = 1 << 20
    public static let maxOutputLimit = 4 << 20

    public init(command: String, user: String? = nil, elevated: Bool = false, timeoutSeconds: Int = defaultTimeout,
                maxOutputBytes: Int = defaultMaxOutput) {
        self.command = command; self.user = user; self.elevated = elevated
        self.timeoutSeconds = min(max(timeoutSeconds, 1), Self.maxTimeout)
        self.maxOutputBytes = min(max(maxOutputBytes, 1024), Self.maxOutputLimit)
    }

    /// The event's data: what the guest tools read.
    public func payload() -> Data {
        var object: [String: Any] = ["command": command, "timeout": timeoutSeconds, "maxOutput": maxOutputBytes]
        if let user, !user.isEmpty { object["user"] = user }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}

public struct GuestExecResult: Equatable, Sendable {
    public enum Status: UInt32, Sendable {
        case completed = 0, timedOut = 1, failedToStart = 2, notSupported = 3
    }
    public var status: Status
    /// The command's exit code; meaningful when `status` is `.completed`.
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data
    public var stdoutTruncated: Bool
    public var stderrTruncated: Bool
    /// Why the command did not complete, from the guest tools.
    public var message: String

    public init(status: Status, exitCode: Int32, stdout: Data = Data(), stderr: Data = Data(),
                stdoutTruncated: Bool = false, stderrTruncated: Bool = false, message: String = "") {
        self.status = status; self.exitCode = exitCode; self.stdout = stdout; self.stderr = stderr
        self.stdoutTruncated = stdoutTruncated; self.stderrTruncated = stderrTruncated; self.message = message
    }

    public static let flagStdoutTruncated: UInt32 = 1
    public static let flagStderrTruncated: UInt32 = 2

    /// Parses EXEC_RESULT: inline `u32 id, i32 exit, u32 status, u32 flags`; buffers stdout, stderr, message.
    static func parse(inline: Data, buffers: (Int) -> Data?) -> (id: UInt32, result: GuestExecResult)? {
        guard inline.count >= 16 else { return nil }
        let flags = inline.readLE(UInt32.self, at: 12)
        let result = GuestExecResult(
            status: Status(rawValue: inline.readLE(UInt32.self, at: 8)) ?? .failedToStart,
            exitCode: Int32(bitPattern: inline.readLE(UInt32.self, at: 4)),
            stdout: buffers(0) ?? Data(), stderr: buffers(1) ?? Data(),
            stdoutTruncated: flags & flagStdoutTruncated != 0, stderrTruncated: flags & flagStderrTruncated != 0,
            message: buffers(2).flatMap { String(data: $0, encoding: .utf8) } ?? "")
        return (inline.readLE(UInt32.self, at: 0), result)
    }
}

/// Commands waiting for their result. One at a time per VM.
final class ExecRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var nextID: UInt32 = 1
    private var busy = false
    private var waiting: [UInt32: CheckedContinuation<GuestExecResult?, Never>] = [:]

    func acquire() -> Bool { lock.withLock { if busy { return false }; busy = true; return true } }
    func release() { lock.withLock { busy = false } }

    func register(_ continuation: CheckedContinuation<GuestExecResult?, Never>) -> UInt32 {
        lock.withLock {
            let id = nextID
            nextID = nextID == UInt32.max ? 1 : nextID + 1
            waiting[id] = continuation
            return id
        }
    }

    /// Resumes the waiter of `id` once; later calls for the same id do nothing.
    func finish(_ id: UInt32, _ result: GuestExecResult?) {
        let continuation = lock.withLock { waiting.removeValue(forKey: id) }
        continuation?.resume(returning: result)
    }
}

public let guestExecCapability: UInt32 = 1 << 16

extension GuestLinkHost {
    /// Runs a command in the guest and returns what it printed. Throws when the guest tools cannot run it
    /// (not connected, too old, or no answer within the command's timeout plus a margin).
    public func exec(_ request: GuestExecRequest) async throws -> GuestExecResult {
        guard let session, let hello = session.hello else { throw VMError("The guest tools are not connected.") }
        guard hello.capabilities & guestExecCapability != 0 else {
            throw VMError("This VM’s guest tools cannot run commands yet.", detail: "Restart the VM so its guest tools update themselves.")
        }
        // One command at a time: wait for the one before to finish.
        let deadline = Date().addingTimeInterval(Double(request.timeoutSeconds) + 30)
        while !execs.acquire() {
            if Date() > deadline { throw VMError("Another command is still running in this VM.") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        defer { execs.release() }
        let registry = execs
        let margin = Double(request.timeoutSeconds) + 15
        let result: GuestExecResult? = await withCheckedContinuation { continuation in
            let id = registry.register(continuation)
            session.post(LinkEvent(.execRequest, arg0: id, arg1: request.elevated ? 1 : 0, data: request.payload()))
            DispatchQueue.global().asyncAfter(deadline: .now() + margin) { registry.finish(id, nil) }
        }
        guard let result else {
            throw VMError("The guest tools did not answer within \(Int(margin)) seconds.", detail: "The command may still be running in the guest.")
        }
        return result
    }

    func execResultArrived(_ request: LinkRequest) {
        guard let parsed = GuestExecResult.parse(inline: request.inline, buffers: { request.input($0) }) else {
            request.reply(status: LinkStatus.badRequest); return
        }
        execs.finish(parsed.id, parsed.result)
        request.reply()
    }
}
