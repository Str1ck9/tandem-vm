import Darwin
import Foundation

extension Process {
    /// Whether the child has really ended: gone, or a zombie that only waits to be reaped. Unlike
    /// `isRunning` it does not depend on Foundation having processed the exit yet.
    public var hasEnded: Bool {
        guard isRunning else { return true }
        let pid = processIdentifier
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return true }
        return info.pbi_status == UInt32(SZOMB)
    }

    /// Waits up to `timeout` seconds for the process to end. Polls instead of calling `waitUntilExit`,
    /// which can miss the exit and spin forever when it runs on a Swift concurrency thread or races a
    /// `terminate()` (seen in the test suite on 2026-11-15: `-[NSConcreteTask waitUntilExit]` looping in
    /// its run loop with QEMU long gone). Returns whether it ended.
    @discardableResult
    public func waitForExit(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !hasEnded {
            if Date() >= deadline { return false }
            usleep(20_000)
        }
        // A zombie counts as ended, but Foundation has not reaped it yet, and `terminationStatus` throws
        // ("task still running") until it has. Give it a moment, so callers can read the status.
        let reaped = Date().addingTimeInterval(2)
        while isRunning, Date() < reaped { usleep(5_000) }
        return true
    }

    /// Ends the process and waits for it, but never forever: SIGTERM, up to `grace` seconds, then SIGKILL
    /// and up to two more seconds. Safe to call from any thread, and when the process has already ended.
    public func stopAndWait(grace: TimeInterval = 5) {
        guard processIdentifier != 0, !hasEnded else { return }
        terminate()
        if waitForExit(timeout: grace) { return }
        kill(processIdentifier, SIGKILL)
        waitForExit(timeout: 2)
    }
}
