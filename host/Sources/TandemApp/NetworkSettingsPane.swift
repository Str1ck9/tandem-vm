import AppKit
import NetHelperClient
import SwiftUI
import VMCore

/// Settings > Network: the helper's status (how it is installed, version, Full Disk Access), Restart, and a
/// clear message when the older script helper is still in the way. Its own view, so it follows the
/// helper's status as that is read in the background.
struct NetworkSettingsPane: View {
    @StateObject private var health = HelperHealth()
    @State private var interfaces: [String] = []

    private func note(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    var body: some View {
        Form {
            LabeledContent("Shared network:", value: "Always available")
            let snapshot = health.snapshot
            LabeledContent("Tandem helper (network and USB):") {
                HStack {
                    statusIcon(snapshot?.helper)
                    Text(snapshot?.helper.text ?? "Checking…")
                    helperButton(snapshot)
                }
            }
            if let status = snapshot?.status {
                LabeledContent("Version:", value: "\(status.version)" + (status.features.isEmpty ? "" : " (" + status.features.joined(separator: ", ") + ")"))
                LabeledContent("Full Disk Access:") {
                    HStack {
                        statusIcon(snapshot?.fullDiskAccess)
                        Text(status.fullDiskAccess == "yes" ? "Yes" : status.fullDiskAccess == "no" ? "No" : (snapshot?.fullDiskAccess.text ?? ""))
                        if status.fullDiskAccess != "yes" { Button("Open Full Disk Access") { HelperService.openFullDiskAccess() } }
                    }
                }
                LabeledContent("Restart:") {
                    HStack {
                        Button(health.busy ? "Restarting…" : "Restart Helper") { health.restart() }.disabled(health.busy || status.busy > 0)
                        if status.busy > 0 { Text("In use by a running virtual machine").foregroundStyle(.secondary) }
                    }
                }
                LabeledContent("Adapters that can be bridged:",
                               value: interfaces.isEmpty ? "None found" : interfaces.map(NetHelperInstaller.displayName).joined(separator: ", "))
            }
            if snapshot?.mode == .inApp, snapshot?.legacyInstalled == true {
                Label {
                    Text("The older helper, installed with the script, is still on this Mac (\(HelperService.legacyPlists.filter { FileManager.default.fileExists(atPath: $0) }.joined(separator: ", "))). It serves the same connection, so this copy cannot install its own until it is removed. In Terminal, from the folder Tandem was built in: sudo scripts/install-net-helper.sh --uninstall")
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            }
            if let message = health.message { Text(message).foregroundStyle(.red).textSelection(.enabled) }
            if snapshot?.mode == .inApp {
                note("A small background service inside Tandem, allowed once in System Settings > General > Login Items, does the two things macOS reserves for administrators: bridged networking (a virtual machine on the Mac’s own network; choose it per virtual machine under Configure > Hardware > Network) and handing USB devices that macOS uses itself, such as USB drives and serial adapters, to a virtual machine (Devices > USB). USB drives also need Full Disk Access: switch on “Tandem” itself in Privacy & Security > Full Disk Access, then restart the helper here. It updates with Tandem.")
            } else {
                note("A small background service, installed once with your administrator password (this development build uses scripts/install-net-helper.sh), does the two things macOS reserves for administrators: bridged networking (a virtual machine on the Mac’s own network; choose it per virtual machine under Configure > Hardware > Network) and handing USB devices that macOS uses itself, such as USB drives and serial adapters, to a virtual machine (Devices > USB). USB drives also need Full Disk Access for /Library/PrivilegedHelperTools/\(TandemIdentity.scriptHelper).")
            }
        }
        .formStyle(.grouped)
        .onAppear { health.refresh(); loadInterfaces() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in health.refresh() }
    }

    @ViewBuilder private func helperButton(_ snapshot: HelperHealth.Snapshot?) -> some View {
        if let snapshot {
            if snapshot.mode == .inApp, snapshot.serviceStatus == .requiresApproval {
                Button("Open Login Items") { HelperService.openLoginItems() }
            } else if !(snapshot.mode == .inApp && snapshot.legacyInstalled) {
                Button(health.busy ? "Installing…" : (snapshot.helperRunning ? "Reinstall…" : "Install…")) { health.install() }.disabled(health.busy)
            }
        }
    }

    @ViewBuilder private func statusIcon(_ check: HelperHealth.Check?) -> some View {
        switch check ?? .checking {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Ready")
        case .attention: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).accessibilityLabel("Needs attention")
        case .missing: Image(systemName: "minus.circle").foregroundStyle(.secondary).accessibilityLabel("Not set up")
        case .checking: ProgressView().controlSize(.small).accessibilityLabel("Checking")
        }
    }

    private func loadInterfaces() {
        Task.detached {
            let found = NetHelper.isInstalled ? ((try? NetHelper.interfaces()) ?? []) : []
            await MainActor.run { interfaces = found }
        }
    }
}
