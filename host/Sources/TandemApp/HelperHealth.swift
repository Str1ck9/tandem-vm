import AppKit
import EngineQEMU
import Foundation
import NetHelperClient
import ServiceManagement
import VMCore

/// What the welcome window and Settings > Network show about Tandem's moving parts: the bundled tools,
/// the helper (how it is installed, whether it answers, its version) and the helper's Full Disk Access.
/// Read off the main thread (the helper answers over a socket), published on it.
@MainActor
final class HelperHealth: ObservableObject {
    enum Check: Equatable {
        case ok(String)
        case attention(String)
        case missing(String)
        case checking

        var text: String {
            switch self {
            case .ok(let t), .attention(let t), .missing(let t): return t
            case .checking: return "Checking…"
            }
        }
        var isOK: Bool { if case .ok = self { return true } else { return false } }
    }

    /// How this copy installs its helper.
    enum Mode: Equatable {
        /// A packaged, Developer ID–signed app: SMAppService, approved in Login Items.
        case inApp
        /// A development build: scripts/install-net-helper.sh (administrator password).
        case script
    }

    struct Snapshot: Equatable {
        var mode: Mode
        var tools: Check
        var helper: Check
        var fullDiskAccess: Check
        var serviceStatus: SMAppService.Status?
        var legacyInstalled: Bool
        var status: NetHelper.Status?
        /// The helper runs, but from another copy of Tandem or the script while this one has its own.
        var helperIsOtherCopy: Bool

        var helperRunning: Bool { status != nil }
        var allGood: Bool { tools.isOK && helper.isOK && fullDiskAccess.isOK }
    }

    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var busy = false
    @Published var message: String?

    func refresh() {
        Task.detached {
            let next = Self.read()
            await MainActor.run { self.snapshot = next }
        }
    }

    /// Everything, read without the main thread.
    nonisolated static func read() -> Snapshot {
        let mode: Mode = HelperService.isAvailable ? .inApp : .script
        let tools = toolsCheck()
        let legacy = HelperService.legacyInstalled
        let serviceStatus: SMAppService.Status? = mode == .inApp ? HelperService.service.status : nil
        let status = NetHelper.isInstalled ? try? NetHelper.status() : nil

        // Helper.
        let helper: Check
        var otherCopy = false
        if let status {
            let what = status.fromBundle == true ? "in-app helper" : status.fromBundle == false ? "script helper" : "helper"
            let supportsDrives = NetHelper.Info(version: status.version, features: status.features).supportsDisks
            if mode == .inApp, legacy {
                helper = .attention("The older script helper is still installed; remove it, then install the in-app helper")
            } else if mode == .inApp, status.fromBundle == true, (status.label != nil && status.label != TandemIdentity.helper) || serviceStatus != .enabled {
                // The helper another copy of Tandem registered (under another label), still running.
                otherCopy = true
                helper = .attention("Running the helper of another copy of Tandem; install this copy's own")
            } else if mode == .inApp, status.fromBundle == false {
                otherCopy = true
                helper = .attention("Running the script helper (version \(status.version)); this copy can install its own")
            } else if !supportsDrives {
                helper = .attention("Running the \(what), version \(status.version): too old for USB drives, install it again")
            } else {
                helper = .ok("Running the \(what), version \(status.version)")
            }
        } else if NetHelper.isInstalled {
            helper = .attention("Installed but not answering")
        } else if mode == .inApp, serviceStatus == .requiresApproval {
            helper = .attention("Waiting for your approval in System Settings > General > Login Items")
        } else if mode == .inApp, serviceStatus == .enabled {
            helper = .attention("Registered but not running yet")
        } else {
            helper = .missing("Not installed")
        }

        // Full Disk Access, as the helper itself sees it.
        let access: Check
        switch status?.fullDiskAccess {
        case "yes"?: access = .ok("Granted")
        case "no"?: access = .attention(mode == .inApp ? "Not granted: switch on “Tandem” in Full Disk Access" : "Not granted to the script helper")
        case let other?: access = .attention("Cannot tell (\(other))")
        case nil: access = status == nil ? .missing("Needs the helper first") : .attention("This helper cannot report it; install it again")
        }
        return Snapshot(mode: mode, tools: tools, helper: helper, fullDiskAccess: access, serviceStatus: serviceStatus,
                        legacyInstalled: legacy, status: status, helperIsOtherCopy: otherCopy)
    }

    nonisolated static func toolsCheck() -> Check {
        guard let toolchain = try? QEMUToolchain.locate() else { return .missing("QEMU was not found") }
        let bundled = BundledTools.qemuPrefix() != nil
        var parts = ["QEMU " + toolchain.qemuVersion.replacingOccurrences(of: "QEMU emulator version ", with: "").split(separator: " ").first.map(String.init).orEmpty]
        if toolchain.swtpm != nil { parts.append("TPM") } else { return .attention("QEMU found, but swtpm (the TPM for Windows 11) is missing") }
        if BundledTools.qemu3DPrefix() != nil { parts.append("3D") }
        return .ok(parts.joined(separator: ", ") + (bundled ? " — inside Tandem" : " — from this Mac"))
    }

    // MARK: Actions

    func install() {
        run { try NetHelperInstaller.install() }
    }

    func restart() {
        run { try HelperService.restartHelper() }
    }

    private func run(_ work: @escaping @Sendable () throws -> Void) {
        busy = true
        message = nil
        Task.detached {
            let result = Result { try work() }
            // The helper takes a moment to come back after a restart or an approval.
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if NetHelper.isInstalled, (try? NetHelper.info()) != nil { break }
            }
            let next = Self.read()
            await MainActor.run {
                self.busy = false
                self.snapshot = next
                if case .failure(let error) = result {
                    self.message = [error.localizedDescription, (error as? VMError)?.detail].compactMap { $0 }.joined(separator: "\n")
                }
            }
        }
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
