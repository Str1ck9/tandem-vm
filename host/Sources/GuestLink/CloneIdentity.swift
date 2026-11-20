import Foundation
import VMCore

extension GuestLinkHost {
    /// For a clone whose guest still has its source's identity: when the guest tools first answer, they
    /// reset it (GuestIdentityReset) and the guest restarts. Clears the flag in the bundle once the guest
    /// accepted the command. Returns a line for the log, or nil when there was nothing to do.
    public func resetCloneIdentityIfNeeded(_ bundle: inout VMBundle, capabilities: UInt32) async -> String? {
        guard bundle.config.pendingGuestIdentityReset == true, let step = GuestIdentityReset.command(for: bundle.config) else { return nil }
        guard capabilities & guestExecCapability != 0 else {
            return "clone: the guest tools cannot run commands yet; the guest keeps its source's identity until they are updated"
        }
        do {
            let result = try await exec(GuestExecRequest(command: step.command, elevated: step.elevated, timeoutSeconds: 120))
            guard result.status == .completed, result.exitCode == 0 else {
                let detail = String(decoding: result.stderr.prefix(400), as: UTF8.self)
                return "clone: resetting the guest's identity failed (exit \(result.exitCode)): \(detail)"
            }
            bundle.config.pendingGuestIdentityReset = nil
            try? bundle.save()
            return "clone: the guest's identity was reset; it restarts once"
        } catch {
            return "clone: resetting the guest's identity failed: \(error.localizedDescription)"
        }
    }
}
