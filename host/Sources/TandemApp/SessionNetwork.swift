import EngineQEMU
import Foundation
import VMCore

/// Network changes on a VM that is running. QEMU takes port forwards, the virtual cable and the network
/// source while the guest runs; the engine says what it did and what waits for the next start. Whatever is
/// asked for is saved, so a later start has it all.
extension VMSession {
    /// True when this VM's network can be changed now: a QEMU VM that runs or is paused.
    var canChangeNetworkLive: Bool { engine is QEMUEngine && (state == .running || state == .paused) }

    func applyNetworkLive(_ requested: NetworkConfig, behavior: VMBehavior) async throws -> NetworkApplyResult {
        guard let qemu = engine as? QEMUEngine, canChangeNetworkLive else {
            throw VMError("The network of “\(config.name)” can be changed while it runs only on the QEMU engine.")
        }
        // What the user typed is what a later start uses, whatever happens to the running VM.
        var saved = bundle.config
        saved.network = requested
        saved.behavior = behavior == VMBehavior() ? nil : behavior
        let result = try await qemu.applyNetwork(requested)
        bundle.config = saved
        try bundle.save()
        screen?.inputSettings = GuestInputSettings(behavior)
        networkApplyResult = result
        return result
    }

    /// The words under the Network pane for what the last change did.
    static func networkSummary(_ result: NetworkApplyResult) -> [(symbol: String, text: String)] {
        result.applied.map { ("checkmark.circle.fill", $0) }
            + result.atNextStart.map { ("arrow.clockwise.circle", $0) }
            + result.failures.map { ("exclamationmark.triangle.fill", $0) }
    }
}
