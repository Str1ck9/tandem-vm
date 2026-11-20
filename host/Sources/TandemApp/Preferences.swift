import AppKit
import GuestLink
import SwiftUI
import EngineQEMU
import NetHelperClient
import VMCore

/// Application preferences: toolbar tabs across the top, one page each.
/// Options that do nothing yet are shown greyed out and say so.
struct PreferencesView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("guestAppDockTiles") private var guestAppDockTiles = true
    @State private var folderError: String?
    /// Self-tests open a given tab (TANDEM_SNAPSHOT_PREFS_TAB=network).
    @State private var tab = ProcessInfo.processInfo.environment["TANDEM_SNAPSHOT_PREFS_TAB"] ?? "general"

    var body: some View {
        TabView(selection: $tab) {
            general.tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            devices.tabItem { Label("Devices", systemImage: "externaldrive.connected.to.line.below") }.tag("devices")
            network.tabItem { Label("Network", systemImage: "network") }.tag("network")
            advanced.tabItem { Label("Advanced", systemImage: "gearshape.2") }.tag("advanced")
        }
        .frame(width: 560, height: 420)
        // Read when the window opens and when the Network tab is chosen (a tab's own onAppear does not
        // always fire inside the Settings window).
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private var general: some View {
        Form {
            Toggle("Show Tandem icon in menu bar", isOn: $showMenuBarIcon)
            Toggle("Show Windows programs in the Dock in Seamless Mode", isOn: $guestAppDockTiles)
            LabeledContent("Virtual machines folder:") {
                HStack {
                    Text(model.libraryPath).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
            HStack {
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: model.libraryPath)) }
                Button("Use Default") { setFolder(nil) }.disabled(model.usesDefaultVMsFolder)
                Button("Change…") { chooseFolder() }
            }
            if let folderError { Text(folderError).foregroundStyle(.red).textSelection(.enabled) }
            note("New and imported virtual machines are kept in this folder. Virtual machines you already have stay where they are and remain in Control Center.")
            LabeledContent("Appearance:", value: "Follows macOS")
            UpdateSettings()
        }
        .formStyle(.grouped)
    }

    private var devices: some View {
        Form {
            Picker("When a new external device is detected:", selection: .constant(0)) {
                Text("Connect it to my Mac").tag(0)
                Text("Connect it to the active virtual machine").tag(1)
                Text("Ask me what to do").tag(2)
            }
            .pickerStyle(.radioGroup)
            .disabled(true)
            note("Not available yet: new devices always stay with the Mac. To hand one to a running virtual machine, use Devices > USB in the menu bar.")
        }
        .formStyle(.grouped)
    }

    private var network: some View { NetworkSettingsPane() }

    private var advanced: some View {
        Form {
            LabeledContent("QEMU:") {
                Text((try? QEMUToolchain.locate()).map { $0.qemuVersion.replacingOccurrences(of: "QEMU emulator version ", with: "") + ($0.isPatchedBuild ? " (Tandem build)" : "") } ?? "Not found")
            }
            LabeledContent("Guest tools for Windows:", value: GuestTools.windowsAgent == nil ? "Not included in this build" : "Included")
            LabeledContent("Guest tools for Linux:", value: GuestTools.linuxAgent == nil ? "Not included in this build" : "Included")
            LabeledContent("Guest tools for macOS:", value: GuestTools.macOSAgent == nil ? "Not included in this build" : "Included")
            note("Virtual machines update their guest tools from this copy of Tandem when they start.")
            CommandLineSettings()
            TemplatesSettings()
            CrashReportSettings()
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Virtual Machines Folder"
        panel.message = "Choose the folder for new and imported virtual machines."
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: model.libraryPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setFolder(url)
    }

    private func setFolder(_ url: URL?) {
        do { try model.setVMsFolder(url); folderError = nil }
        catch { folderError = [error.localizedDescription, (error as? VMError)?.detail].compactMap { $0 }.joined(separator: "\n") }
    }

}

/// The menu behind the Tandem icon in the Mac's menu bar: each virtual machine with its actions,
/// then Control Center, New and Preferences.
struct StatusMenu: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ForEach(model.sessions) { session in StatusMenuVM(session: session) }
        if model.sessions.isEmpty { Text("No virtual machines") }
        Divider()
        Button("Control Center") { show("library") }
        Button("Resource Monitor") { show("resources") }
        Button("New…") { show("library"); NotificationCenter.default.post(name: .newVM, object: nil) }
        Button("Preferences…") { NSApp.activate(ignoringOtherApps: true); openSettings() }
        Divider()
        Button("Quit Tandem") { NSApp.terminate(nil) }
    }

    private func show(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
    }
}

private struct StatusMenuVM: View {
    @ObservedObject var session: VMSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu("\(session.config.name) — \(session.statusLabel)") {
            if session.can(.start) {
                Button(session.isSuspended ? "Resume" : "Start") { showWindow(); session.start() }
            }
            if session.can(.resume) { Button("Resume") { session.resume() } }
            if session.can(.pause) { Button("Pause") { session.pause() } }
            if session.canSuspend { Button("Suspend") { session.suspend() } }
            if session.can(.stop) { Button("Shut Down") { session.stop() } }
            if session.state.isActive {
                Toggle("Keep Awake", isOn: Binding(get: { session.power.keepAwake }, set: { _ in session.toggleKeepAwake() }))
                if let summary = session.powerSummary { Text(AppDelegate.menuTitle(summary)) }
            }
            if session.canRestart { Button("Restart") { session.restart() } }
            if session.isSeamless, !session.openGuestWindows.isEmpty {
                Section("Open Windows") {
                    ForEach(session.openGuestWindows) { window in
                        Button { session.activateGuestWindow(window.id) } label: { menuLabel(AppDelegate.menuTitle(window.title), session.icon(for: window)) }
                    }
                }
            }
            if !session.guestPrograms.isEmpty, session.state == .running {
                Menu("Windows Programs") {
                    Button("Keep Programs on the Mac…") { NSApp.activate(ignoringOtherApps: true); openWindow(id: "macapps", value: session.id) }
                    Divider()
                    ForEach(session.guestPrograms) { program in
                        Button { session.launch(program) } label: { menuLabel(AppDelegate.menuTitle(program.name), session.icon(for: program)) }
                    }
                }
            }
            if session.isSeamless { Button("Exit Seamless Mode") { session.exitSeamless() } }
            else if session.canSeamless { Button("Enter Seamless Mode") { session.enterSeamless() } }
            if session.state.isActive, !session.isSeamless { Button("Show Window") { showWindow() } }
            Divider()
            Button("Manage Snapshots…") { NSApp.activate(ignoringOtherApps: true); openWindow(id: "snapshots", value: session.id) }
            if !session.state.isActive {
                Button("Clone…") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "library")
                    NotificationCenter.default.post(name: .cloneVM, object: session.id)
                }
            }
            Button("Configure…") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "configuration", value: ConfigurationTarget(id: session.id, place: nil))
            }
        }
    }

    private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "vm", value: session.id)
    }

    @ViewBuilder private func menuLabel(_ title: String, _ icon: CGImage?) -> some View {
        if let image = session.image(icon) { Label { Text(title) } icon: { Image(nsImage: image) } } else { Text(title) }
    }
}
