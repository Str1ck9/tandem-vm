import AppKit
import Combine
import SwiftUI
import VMCore

/// The first thing a packaged Tandem shows (once), and Help > Welcome… afterwards: the few one-time
/// steps macOS asks for, each with its live status and the one button that does it.
///
///   1. Tools: QEMU, the TPM and the 3D QEMU, which a packaged app carries inside it.
///   2. The helper (bridged networking, USB devices and drives): registered with SMAppService and
///      approved once in Login Items; a development build installs it with the script instead.
///   3. Full Disk Access for the helper, which USB drives need. macOS lists an in-app helper under the
///      app's own name, so the switch to turn on is “Tandem”; the grant applies once the helper restarts.
struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var health = HelperHealth()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    /// While the window is open the checks are read again every few seconds and whenever Tandem comes back
    /// to the front (after System Settings), so a switch turned on there shows up here by itself.
    private let ticker = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Tandem").font(.largeTitle.weight(.semibold))
                    Text("Three one-time checks, then create your first virtual machine.").foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 0) {
                row(number: 1, title: "Virtualization tools", purpose: "QEMU runs Windows and Linux; its TPM lets Windows 11 install. They come inside Tandem.",
                    check: health.snapshot?.tools) { EmptyView() }
                Divider()
                row(number: 2, title: "Tandem helper", purpose: helperPurpose, check: health.snapshot?.helper) { helperButton }
                Divider()
                row(number: 3, title: "Full Disk Access", purpose: accessPurpose, check: health.snapshot?.fullDiskAccess) { accessButtons }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))

            if let message = health.message {
                Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            Text("Steps 2 and 3 are optional: shared networking, shared folders and the clipboard work without them. They are needed for bridged networking and for giving USB devices and drives to a virtual machine. Tandem never asks for your password for them; macOS asks you to switch them on.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Check Again") { health.refresh() }
                Spacer()
                Button("Close") { dismissWindow(id: "welcome") }.keyboardShortcut(.cancelAction)
                Button(model.sessions.isEmpty ? "Create Your First VM…" : "Create a VM…") {
                    dismissWindow(id: "welcome")
                    openWindow(id: "library")
                    NotificationCenter.default.post(name: .newVM, object: nil)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 640)
        .onAppear { health.refresh(); WelcomeWindow.markShown() }
        .onReceive(ticker) { _ in if !health.busy { health.refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in health.refresh() }
    }

    private var helperPurpose: String {
        health.snapshot?.mode == .script
            ? "Bridged networking and USB devices need a small background service. This development build installs it with your administrator password."
            : "Bridged networking and USB devices need a small background service inside Tandem. macOS asks you to allow it once in Login Items: switch on Tandem under “Allow in the Background” (if Tandem is listed twice, switch on the one that is off)."
    }

    private var accessPurpose: String {
        health.snapshot?.mode == .script
            ? "USB drives: macOS lets the helper read a whole drive only with Full Disk Access. Add /Library/PrivilegedHelperTools/\(TandemIdentity.scriptHelper) with +."
            : "USB drives: macOS lets the helper read a whole drive only with Full Disk Access. Switch on “Tandem” itself in the list (the helper is listed under Tandem's name), then restart the helper. If the list shows Tandem twice (one left by an earlier copy), switch on the one that is off."
    }

    @ViewBuilder private var helperButton: some View {
        if let snapshot = health.snapshot {
            if snapshot.legacyInstalled, snapshot.mode == .inApp {
                Button("How to Remove…") { health.message = "In Terminal, from the folder Tandem was built in:\nsudo scripts/install-net-helper.sh --uninstall\nThen click Install here." }
            } else if snapshot.mode == .inApp, snapshot.serviceStatus == .requiresApproval {
                Button("Open Login Items") { HelperService.openLoginItems() }
            } else if !snapshot.helper.isOK || snapshot.helperIsOtherCopy {
                Button(health.busy ? "Installing…" : "Install…") { health.install() }.disabled(health.busy)
            }
        }
    }

    @ViewBuilder private var accessButtons: some View {
        if let snapshot = health.snapshot, snapshot.helperRunning, !snapshot.fullDiskAccess.isOK {
            VStack(alignment: .trailing, spacing: 6) {
                Button("Open Full Disk Access") { HelperService.openFullDiskAccess() }
                Button(health.busy ? "Restarting…" : "Restart Helper") { health.restart() }.disabled(health.busy)
            }
        }
    }

    private func row<Buttons: View>(number: Int, title: String, purpose: String, check: HelperHealth.Check?,
                                    @ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon(check).font(.title2).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(number). \(title)").font(.headline)
                Text((check ?? .checking).text).foregroundStyle(color(check))
                Text(purpose).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            buttons()
        }
        .padding(14)
    }

    @ViewBuilder private func statusIcon(_ check: HelperHealth.Check?) -> some View {
        switch check ?? .checking {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Ready")
        case .attention: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).accessibilityLabel("Needs attention")
        case .missing: Image(systemName: "circle.dashed").foregroundStyle(.secondary).accessibilityLabel("Not set up")
        case .checking: ProgressView().controlSize(.small).accessibilityLabel("Checking")
        }
    }

    private func color(_ check: HelperHealth.Check?) -> Color {
        switch check ?? .checking {
        case .ok: return .green
        case .attention: return .orange
        case .missing, .checking: return .secondary
        }
    }
}

@MainActor
enum WelcomeWindow {
    static let shownKey = "welcomeShown"

    static func markShown() { if SelfTest.directory == nil { UserDefaults.standard.set(true, forKey: shownKey) } }

    /// Only a packaged copy (one that carries its helper) greets on its first launch; development builds and
    /// self-tests never open it unasked.
    static var shouldShowAtLaunch: Bool {
        HelperService.isAvailable && !UserDefaults.standard.bool(forKey: shownKey) && SelfTest.directory == nil
    }
}

/// Opens the welcome window on the first launch of a packaged Tandem.
struct FirstRunWelcome: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content.onAppear {
            guard WelcomeWindow.shouldShowAtLaunch else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { openWindow(id: "welcome") }
        }
    }
}
