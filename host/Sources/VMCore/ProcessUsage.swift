import Darwin
import Foundation

/// What a process has used: processor time since it started, and the memory the system charges it.
public struct ProcessUsage: Equatable, Sendable {
    public var cpuSeconds: Double
    /// The "memory footprint" Activity Monitor shows: what would be freed if the process ended.
    public var footprintBytes: UInt64
    public init(cpuSeconds: Double, footprintBytes: UInt64) { self.cpuSeconds = cpuSeconds; self.footprintBytes = footprintBytes }

    /// Nil when the process is gone or belongs to another user.
    public static func of(pid: Int32) -> ProcessUsage? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        // The times are in the machine's own tick, not nanoseconds.
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = Double(info.ri_user_time + info.ri_system_time)
        let seconds = ticks * Double(timebase.numer) / Double(max(timebase.denom, 1)) / 1e9
        return ProcessUsage(cpuSeconds: seconds, footprintBytes: info.ri_phys_footprint)
    }

    /// Percent of one processor core used between two readings `seconds` apart. Above 100 on several cores.
    public static func cpuPercent(from earlier: ProcessUsage, to later: ProcessUsage, over seconds: TimeInterval) -> Double? {
        guard seconds > 0, later.cpuSeconds >= earlier.cpuSeconds else { return nil }
        return (later.cpuSeconds - earlier.cpuSeconds) / seconds * 100
    }
}
