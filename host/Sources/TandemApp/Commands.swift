import AppKit
import SwiftUI
import EngineQEMU
import VMCore

/// The VM that menu commands act on: the one in the frontmost VM window, or the one selected in Control Center.
struct ActiveSessionKey: FocusedValueKey {
    typealias Value = VMSession
}

extension FocusedValues {
    var activeSession: VMSession? {
        get { self[ActiveSessionKey.self] }
        set { self[ActiveSessionKey.self] = newValue }
    }
}

/// Menu bar in the layout familiar from desktop virtualization apps: File, Edit, View, Actions, Devices, Window, Help.
/// Items for features that do not exist yet are present and disabled, so the menus keep their shape.
struct TandemCommands: Commands {
    /// Observed, so the menus are rebuilt whenever any VM changes state; a focused value alone does not
    /// tell SwiftUI that the VM behind it changed.
    @ObservedObject var model: AppModel
    /// `AppModel.menuRevision`: a plain value that differs after every VM change.
    let revision: Int
    @FocusedValue(\.activeSession) private var focused
    /// A seamless window is not a SwiftUI scene, so while one is in front the menus act on its VM.
    /// Otherwise the VM in the frontmost VM window, or the one selected in Control Center.
    private var session: VMSession? { model.seamlessSession ?? focused ?? model.selectedSession }
    @Environment(\.openWindow) private var openWindow

    private func configure(_ place: String?) {
        guard let session else { return }
        openWindow(id: "configuration", value: ConfigurationTarget(id: session.id, place: place))
    }

    private func start() {
        guard let session else { return }
        openWindow(id: "vm", value: session.id)
        if session.can(.start) { session.start() } else if session.can(.resume) { session.resume() }
    }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Tandem") { NSApp.activate(ignoringOtherApps: true); openWindow(id: "about") }
            Button("Check for Updates…") { NSApp.activate(ignoringOtherApps: true); SoftwareUpdate.shared.check(userInitiated: true) }
        }
        CommandGroup(before: .appTermination) {
            Button("Uninstall Tandem…") { NSApp.activate(ignoringOtherApps: true); openWindow(id: "uninstall") }
            Divider()
        }
        CommandGroup(replacing: .newItem) {
            Button("New…") { NotificationCenter.default.post(name: .newVM, object: nil) }.keyboardShortcut("n")
            Button("Import from Parallels…") { NotificationCenter.default.post(name: .importVM, object: nil) }.keyboardShortcut("i")
            Divider()
            Button(session.map { "Clone “\($0.config.name)”…" } ?? "Clone…") {
                openWindow(id: "library")
                if let id = session?.id { NotificationCenter.default.post(name: .cloneVM, object: id) }
            }
            .disabled(session == nil || session?.state.isActive == true || session?.provisioning != nil)
            Button(session.map { "Remove “\($0.config.name)”…" } ?? "Remove…") {
                openWindow(id: "library")
                if let id = session?.id { NotificationCenter.default.post(name: .removeVM, object: id) }
            }
            .disabled(session == nil || session?.state.isActive == true)
        }
        CommandGroup(after: .toolbar) {
            Button("Take Screenshot") { session?.saveScreenshotToDesktop() }
                .disabled(session?.screen == nil)
            if session?.isSeamless == true {
                Button("Exit Seamless Mode") { session?.exitSeamless() }.keyboardShortcut("c", modifiers: [.command, .control])
            } else {
                Button("Enter Seamless Mode") { session?.enterSeamless() }.keyboardShortcut("c", modifiers: [.command, .control])
                    .disabled(session?.canSeamless != true)
            }
            Button("Enter Picture in Picture") {}.disabled(true)
            Divider()
        }
        CommandMenu("Actions") {
            Button(session?.can(.resume) == true || session?.isSuspended == true ? "Resume" : "Start") { start() }
                .disabled(!(session?.can(.start) == true || session?.can(.resume) == true))
            Divider()
            Button("Pause") { session?.pause() }.disabled(session?.can(.pause) != true)
            Button("Suspend") { session?.suspend() }.disabled(session?.canSuspend != true)
            Button("Shut Down") { session?.stop() }.disabled(session?.can(.stop) != true)
            Button("Restart") { session?.restart() }.disabled(session?.canRestart != true)
            Divider()
            if session?.isSuspended == true && session?.state.isActive != true {
                // Stopping a suspended VM means giving up what it had in memory.
                Button("Stop…") { session.map(confirmDiscard) }
            } else {
                Button("Stop") { session?.forceStop() }.disabled(session?.can(.forceStop) != true)
            }
            Button("Reset") { session?.reset() }.disabled(session?.canReset != true)
            // Holds the idle timer off for this VM (PowerMonitor.swift).
            Toggle("Keep Awake", isOn: Binding(get: { session?.power.keepAwake ?? false }, set: { _ in session?.toggleKeepAwake() })).accessibilityLabel("Keep Awake")
                .disabled(session == nil)
            Divider()
            if session?.config.guestOS == .macos {
                Button(session?.hasMacOSTools == true ? "Reinstall Tandem Tools…" : "Install Tandem Tools…") { session?.installMacOSTools() }
                    .disabled(session?.canInstallMacOSTools != true)
                Divider()
            }
            Button("Take Snapshot…") { if let id = session?.id { openWindow(id: "snapshots", value: id) } }.disabled(session == nil)
            Button("Manage Snapshots…") { if let id = session?.id { openWindow(id: "snapshots", value: id) } }.disabled(session == nil)
            Divider()
            Button("Configure…") { configure(nil) }.disabled(session == nil)
        }
        CommandMenu("Devices") {
            Menu("Keyboard") {
                Button("Ctrl + Alt + Del") { session?.sendKeys([0x1D, 0x38, 0xD3]) }
                Button("Windows Key") { session?.sendKeys([0xDB]) }
                Button("Alt + Tab") { session?.sendKeys([0x38, 0x0F]) }
                Button("Alt + F4") { session?.sendKeys([0x38, 0x3E]) }
                Button("Print Screen") { session?.sendKeys([0xB7]) }
            }
            .disabled(session?.screen == nil)
            Menu("Sharing") {
                if let session, !session.sharingPolicy.folders.isEmpty {
                    Section("Shared folders:") {
                        ForEach(session.sharingPolicy.folders.map(\.folder), id: \.name) { folder in
                            Button(folder.name) { NSWorkspace.shared.open(URL(fileURLWithPath: folder.hostPath)) }
                        }
                    }
                }
                Button("Configure…") { configure("options/sharing") }
            }
            .disabled(session == nil)
            Menu("CD/DVD") { Button("Configure…") { configure("hardware/cd") } }.disabled(session == nil)
            Menu("Network") { Button("Configure…") { configure("hardware/network") } }.disabled(session == nil)
            Menu("USB") {
                let devices = HostUSBDevice.list()
                if devices.isEmpty { Text("No USB devices are plugged into this Mac") }
                ForEach(devices) { device in
                    // Each device says how it would reach the VM. Devices a macOS driver holds (other than
                    // drives and serial ports) cannot be taken on macOS 26 and are shown but not offered.
                    Toggle("\(device.name) — \(device.routeLabel)", isOn: Binding(get: { session?.usbAttached.contains(device.qemuID) ?? false },
                                                      set: { _ in session?.toggleUSB(device) }))
                    .disabled(!device.canBeHandedToVM && session?.usbAttached.contains(device.qemuID) != true)
                }
                if devices.contains(where: { !$0.canBeHandedToVM }) {
                    Divider()
                    Text("Devices macOS uses with its own driver cannot be given to a VM: macOS 26 allows that only to apps with an Apple entitlement. USB drives and serial devices are handed over another way.")
                }
            }
            .disabled(session?.supportsUSB != true)
        }
        CommandGroup(after: .help) {
            Button("Welcome…") { NSApp.activate(ignoringOtherApps: true); openWindow(id: "welcome") }
            Button("Collect Diagnostics…") { DiagnosticsCommand.run(library: model.vmLibrary) }
        }
        CommandGroup(before: .windowList) {
            Button("Control Center") { openWindow(id: "library") }.keyboardShortcut("c", modifiers: [.command, .control, .shift])
            Button("Resource Monitor") { openWindow(id: "resources") }
            Divider()
        }
    }
}

extension Notification.Name {
    static let newVM = Notification.Name("tandem.newVM")
    static let importVM = Notification.Name("tandem.importVM")
    static let removeVM = Notification.Name("tandem.removeVM")
}
