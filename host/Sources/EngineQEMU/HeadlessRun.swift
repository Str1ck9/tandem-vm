import Foundation
import VMCore

/// A VM run with no window, to completion: used to make templates.
public enum HeadlessRun {
    /// Starts the VM without a display and returns once the guest has powered itself off. Throws when
    /// QEMU fails, after `timeout` seconds, or on cancellation; the VM is stopped in those cases.
    public static func untilPowerOff(_ bundle: VMBundle, timeout: TimeInterval) async throws {
        let toolchain = try QEMUToolchain.locate()
        try QEMUEngine.prepare(bundle: bundle, toolchain: toolchain, paths: QEMURunPaths.forVM(bundle.id))
        let engine = await MainActor.run { QEMUEngine(bundle: bundle, displayMode: .none) }
        try await engine.start()
        let deadline = Date().addingTimeInterval(timeout)
        do {
            while true {
                let state = engine.lifecycle.state
                if state == .stopped { return }
                if state == .error {
                    throw engine.lifecycle.lastError ?? VMError("“\(bundle.config.name)” stopped with an error.")
                }
                if Date() > deadline {
                    throw VMError("Setting up “\(bundle.config.name)” took longer than \(Int(timeout / 60)) minutes and was stopped.",
                                  detail: "Its console log is \(bundle.logsDirectory.appendingPathComponent("console.log").path).")
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        } catch {
            try? await engine.forceStop()
            for _ in 0..<50 where engine.lifecycle.state != .stopped && engine.lifecycle.state != .error {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            throw error
        }
    }
}
