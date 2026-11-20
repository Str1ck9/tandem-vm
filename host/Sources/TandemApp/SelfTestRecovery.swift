import AppKit
import VMCore

/// Crash-recovery trial, driven from a shell:
///   TANDEM_SNAPSHOT_HOLD=<vm>   start the VM and keep running, so the shell can `kill -9` this process;
///   TANDEM_SNAPSHOT_RECOVERY=1  report what recovery did at launch (and the notice), then quit.
@MainActor
enum SelfTestRecovery {
    /// True when this trial took over the self-test run.
    static func run(model: AppModel) -> Bool {
        let env = ProcessInfo.processInfo.environment
        if let name = env["TANDEM_SNAPSHOT_HOLD"], let session = model.sessions.first(where: { $0.config.name == name }) {
            session.start()
            Task { @MainActor in
                for _ in 0..<120 where session.state != .running { try? await Task.sleep(nanoseconds: 500_000_000) }
                let record = session.bundle.readRunRecord()
                print("selftest: holding “\(name)” state=\(session.state.rawValue) app pid=\(getpid()) children=\(record?.childPIDs ?? []) runFolder=\(record?.runFolder ?? "none")")
            }
            return true
        }
        if env["TANDEM_SNAPSHOT_RECOVERY"] != nil {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                print("selftest: notice=\(model.recoveryNotice ?? "none")")
                SelfTest.snapshotWindows(tag: "recovery")
                for session in model.sessions {
                    print("selftest: “\(session.config.name)” state=\(session.state.rawValue) record=\(session.bundle.readRunRecord() == nil ? "none" : "present")")
                }
                exit(0)
            }
            return true
        }
        return false
    }
}
