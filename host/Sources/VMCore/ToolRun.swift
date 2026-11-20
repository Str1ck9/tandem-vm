import Darwin
import Foundation

/// What a tool run through `ToolRun` printed, and how it ended.
public struct ToolResult: Sendable {
    public var status: Int32
    public var output: Data
    public var errors: Data
    public var outputText: String { String(decoding: output, as: UTF8.self) }
    public var errorText: String { String(decoding: errors, as: UTF8.self) }
    public var succeeded: Bool { status == 0 }
}

/// Runs a command-line tool and waits for it, but never forever.
///
/// `Process.waitUntilExit()` can miss an exit and spin for good when it runs on a Swift concurrency
/// thread (seen on 2026-11-15), and reading a pipe to its end before waiting stalls when the tool writes
/// a lot to the other stream. Here both streams are read in the background while the exit is polled, the
/// tool is stopped (SIGTERM, then SIGKILL) when it runs past its limit, and the error names the tool.
public enum ToolRun {
    public enum Stream: Sendable { case capture, discard }

    /// Limits sized to what each kind of tool does.
    public enum Limit {
        /// arp, pgrep, ps, open, codesign, lsregister, qemu-img info or create.
        public static let quick: TimeInterval = 60
        /// hdiutil makehybrid, attach and detach; bsdtar; qemu-img resize and rebase.
        public static let image: TimeInterval = 15 * 60
        /// Unpacking or converting a whole disk image of many gigabytes.
        public static let disk: TimeInterval = 4 * 3600
        /// A tool that shows the administrator password dialog and waits for the user.
        public static let userPrompt: TimeInterval = 30 * 60
    }

    /// The most kept of each stream; a tool that prints more is cut, not allowed to fill memory.
    public static let maximumCapture = 64 << 20

    /// Runs `tool` and blocks the calling thread until it ends or `timeout` seconds pass.
    @discardableResult
    public static func run(_ tool: URL, _ arguments: [String], timeout: TimeInterval,
                           output: Stream = .capture, errors: Stream = .capture,
                           environment: [String: String]? = nil) throws -> ToolResult {
        let running = try Running(tool, arguments, output: output, errors: errors, environment: environment)
        guard running.process.waitForExit(timeout: timeout) else {
            running.process.stopAndWait(grace: 3)
            running.stopCollecting()
            throw timedOut(tool, arguments, timeout)
        }
        return running.result()
    }

    /// Runs `tool` without blocking a thread. Cancelling the task stops the tool.
    @discardableResult
    public static func run(_ tool: URL, _ arguments: [String], timeout: TimeInterval,
                           output: Stream = .capture, errors: Stream = .capture,
                           environment: [String: String]? = nil) async throws -> ToolResult {
        let running = try Running(tool, arguments, output: output, errors: errors, environment: environment)
        let deadline = Date().addingTimeInterval(timeout)
        do {
            while !running.process.hasEnded {
                if Date() >= deadline {
                    running.process.stopAndWait(grace: 3)
                    running.stopCollecting()
                    throw timedOut(tool, arguments, timeout)
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        } catch is CancellationError {
            running.process.stopAndWait(grace: 3)
            running.stopCollecting()
            throw CancellationError()
        }
        running.process.waitForExit(timeout: 2)
        return running.result()
    }

    /// Runs `tool`, returning its standard output; throws `failure` with what it printed when it exits
    /// non-zero. The common shape of most callers.
    @discardableResult
    public static func checked(_ tool: URL, _ arguments: [String], timeout: TimeInterval,
                               failure: @autoclosure () -> String) throws -> String {
        let result = try run(tool, arguments, timeout: timeout)
        guard result.succeeded else { throw failed(result, failure()) }
        return result.outputText
    }

    /// The error for a tool that exited non-zero: its error output, or its normal output when that is empty.
    public static func failed(_ result: ToolResult, _ message: String) -> VMError {
        let text = (result.errors.isEmpty ? result.outputText : result.errorText).trimmingCharacters(in: .whitespacesAndNewlines)
        return VMError(message, detail: text.isEmpty ? "Exit status \(result.status)." : text)
    }

    static func timedOut(_ tool: URL, _ arguments: [String], _ timeout: TimeInterval) -> VMError {
        let name = tool.lastPathComponent
        let command = ([name] + arguments.prefix(4)).joined(separator: " ") + (arguments.count > 4 ? " …" : "")
        return VMError("\(name) did not finish within \(describe(timeout)) and was stopped.", detail: "Command: \(command)")
    }

    /// "45 seconds", "15 minutes", "4 hours".
    public static func describe(_ seconds: TimeInterval) -> String {
        func unit(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        if seconds < 120 { return unit(max(1, Int(seconds.rounded())), "second") }
        if seconds < 2 * 3600 { return unit(Int((seconds / 60).rounded()), "minute") }
        return unit(Int((seconds / 3600).rounded()), "hour")
    }

    /// A launched tool with its two streams being collected.
    private final class Running {
        let process = Process()
        private let output: Collector?
        private let errors: Collector?

        init(_ tool: URL, _ arguments: [String], output: Stream, errors: Stream, environment: [String: String]?) throws {
            process.executableURL = tool
            process.arguments = arguments
            if let environment { process.environment = environment }
            process.standardInput = FileHandle.nullDevice
            let outPipe = output == .capture ? Pipe() : nil
            let errPipe = errors == .capture ? Pipe() : nil
            process.standardOutput = outPipe ?? FileHandle.nullDevice
            process.standardError = errPipe ?? FileHandle.nullDevice
            self.output = outPipe.map { Collector($0.fileHandleForReading) }
            self.errors = errPipe.map { Collector($0.fileHandleForReading) }
            do { try process.run() } catch {
                stopCollecting()
                throw VMError("\(tool.lastPathComponent) could not be started.", detail: error.localizedDescription)
            }
        }

        func stopCollecting() { output?.stop(); errors?.stop() }

        func result() -> ToolResult {
            // The streams end when the tool and anything it started have closed them. A child left
            // running that still holds one must not keep the caller waiting: take what came.
            let deadline = Date().addingTimeInterval(2)
            output?.waitForEnd(timeout: deadline.timeIntervalSinceNow)
            errors?.waitForEnd(timeout: max(0, deadline.timeIntervalSinceNow))
            stopCollecting()
            let status: Int32 = process.isRunning ? -1 : process.terminationStatus
            return ToolResult(status: status, output: output?.data ?? Data(), errors: errors?.data ?? Data())
        }
    }

    /// Reads one stream as data arrives, so a chatty tool never stalls on a full pipe.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private var ended = false
        private let finished = DispatchSemaphore(value: 0)
        private let handle: FileHandle

        init(_ handle: FileHandle) {
            self.handle = handle
            handle.readabilityHandler = { [weak self] h in
                let chunk = h.availableData
                guard let self else { h.readabilityHandler = nil; return }
                if chunk.isEmpty { self.markEnded() } else { self.append(chunk) }
            }
        }

        var data: Data { lock.withLock { buffer } }

        private func append(_ chunk: Data) {
            lock.withLock {
                let room = ToolRun.maximumCapture - buffer.count
                if room > 0 { buffer.append(chunk.prefix(room)) }
            }
        }

        private func markEnded() {
            let first: Bool = lock.withLock { defer { ended = true }; return !ended }
            guard first else { return }
            handle.readabilityHandler = nil
            finished.signal()
        }

        func waitForEnd(timeout: TimeInterval) {
            if lock.withLock({ ended }) { return }
            _ = finished.wait(timeout: .now() + timeout)
        }

        func stop() {
            handle.readabilityHandler = nil
            lock.withLock { ended = true }
        }
    }
}
