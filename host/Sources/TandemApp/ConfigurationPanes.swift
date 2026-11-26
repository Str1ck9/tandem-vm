import AppKit
import EngineQEMU
import SwiftUI
import VMCore

// The Options and Hardware panes added after the first set: Startup and Shutdown, Applications,
// Full Screen, Maintenance, Mouse & Keyboard, Sound & Camera, Shared Printers and Boot Order.
// Each edits the configuration draft of the configuration window. Behaviour settings can be saved
// while the VM runs; sound and boot order need it stopped (`locked`).

private func paneNote(_ text: String) -> some View {
    Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
}

private extension Binding where Value == VMConfig {
    /// The behaviour settings of the draft, created on first change.
    var behavior: Binding<VMBehavior> {
        Binding<VMBehavior>(get: { wrappedValue.behaviorOrDefault },
                            set: { wrappedValue.behavior = $0 == VMBehavior() ? nil : $0 })
    }
    var sound: Binding<SoundConfig> {
        Binding<SoundConfig>(get: { wrappedValue.soundOrDefault },
                             set: { wrappedValue.sound = $0 == SoundConfig() ? nil : $0 })
    }
    var boot: Binding<BootConfig> {
        Binding<BootConfig>(get: { wrappedValue.bootOrDefault },
                            set: { wrappedValue.boot = $0 == BootConfig() ? nil : $0 })
    }
}

// MARK: Options > Startup and Shutdown

struct StartupPane: View {
    @Binding var config: VMConfig
    @ObservedObject var session: VMSession

    private var canSeamless: Bool {
        config.supportsSeamless(linuxEnabled: LinuxIntegration.seamlessEnabled) && !VMSession.seamlessBlockedBy3D(config)
    }

    var body: some View {
        let behavior = $config.behavior
        Form {
            Section("Starting") {
                Picker("Start automatically", selection: behavior.autoStart) {
                    Text("Never").tag(VMBehavior.AutoStart.never)
                    Text("When Tandem opens").tag(VMBehavior.AutoStart.withTandem)
                    Text("When I log in to the Mac").tag(VMBehavior.AutoStart.withMac)
                }
                if behavior.wrappedValue.autoStart == .withMac {
                    paneNote("Tandem is added to the Mac’s login items and starts this virtual machine when it opens. macOS may ask you to allow that in System Settings > General > Login Items."
                             + (LoginItem.appIsInApplications ? "" : " This copy of Tandem is not in the Applications folder; macOS will open it from where it is now."))
                }
                Picker("Start in", selection: behavior.startupView) {
                    Text("A window").tag(VMBehavior.StartupView.window)
                    Text("Full screen").tag(VMBehavior.StartupView.fullScreen)
                    if canSeamless || behavior.wrappedValue.startupView == .seamless {
                        Text("Seamless Mode").tag(VMBehavior.StartupView.seamless)
                    }
                }
                if behavior.wrappedValue.startupView == .seamless {
                    paneNote("The virtual machine starts in its window and changes to Seamless Mode as soon as its guest tools have connected.")
                } else if VMSession.seamlessBlockedBy3D(config) {
                    paneNote(VMSession.seamless3DNote)
                } else if !canSeamless {
                    paneNote("Seamless Mode is available for Windows virtual machines with the guest tools, and for Linux ones when it is turned on in Tandem’s Settings > Advanced.")
                }
            }
            Section("Stopping") {
                Picker("After it shuts down", selection: behavior.afterShutdown) {
                    Text("Close its window").tag(VMBehavior.AfterShutdown.closeWindow)
                    Text("Keep its window open").tag(VMBehavior.AfterShutdown.keepWindow)
                    Text("Quit Tandem").tag(VMBehavior.AfterShutdown.quitTandem)
                }
                if behavior.wrappedValue.afterShutdown == .quitTandem {
                    paneNote("Tandem quits when this virtual machine shuts down and no other one is running.")
                }
                Picker("When its window is closed", selection: behavior.onWindowClose) {
                    Text("Keep running").tag(VMBehavior.OnWindowClose.keepRunning)
                    Text("Suspend").tag(VMBehavior.OnWindowClose.suspend)
                    Text("Shut down").tag(VMBehavior.OnWindowClose.shutDown)
                }
                Picker("When Tandem quits", selection: behavior.onQuit) {
                    Text("Ask me").tag(VMBehavior.OnQuit.ask)
                    Text("Suspend").tag(VMBehavior.OnQuit.suspend)
                    Text("Shut down").tag(VMBehavior.OnQuit.shutDown)
                    Text("Stop (power off)").tag(VMBehavior.OnQuit.stop)
                }
                paneNote("Suspending saves the virtual machine exactly as it is and continues from there next time. A shutdown that takes longer than a minute and a half is ended by powering off.")
            }
            Section("When idle") {
                PowerSettingsFields(settings: Binding(get: { config.power ?? PowerSettings() },
                                                      set: { config.power = $0 == PowerSettings() ? nil : $0 }))
                paneNote("While the virtual machine runs, change these in Window > Resource Monitor, which also shows what keeps it awake.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Options > Applications

struct ApplicationsPane: View {
    @Binding var config: VMConfig
    @ObservedObject var session: VMSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let behavior = $config.behavior
        Form {
            if config.supportsGuestPrograms {
                Section("Dock") {
                    Picker("\(config.guestSystemWord) programs in the Dock", selection: behavior.dockTiles) {
                        Text("As set in Tandem’s Settings (\(GuestAppTiles.isEnabled ? "shown" : "not shown"))").tag(Bool?.none)
                        Text("Show").tag(Bool?.some(true))
                        Text("Do not show").tag(Bool?.some(false))
                    }
                    paneNote("In Seamless Mode every \(config.guestSystemWord) program with a window gets its own icon in the Dock and in Command-Tab. Choosing it brings the program’s window forward.")
                }
                Section("\(config.guestSystemWord) programs") {
                    if session.guestPrograms.isEmpty {
                        LabeledContent("Programs found", value: session.state.isActive ? "Waiting for the guest tools" : "Start the virtual machine to list them")
                    } else {
                        LabeledContent("Programs found", value: "\(session.guestPrograms.count)")
                    }
                    paneNote("Start one from the Dock menu or the menu bar icon: “\(config.guestSystemWord) Programs” under this virtual machine.")
                }
                Section("On the Mac") {
                    LabeledContent("Programs kept on the Mac", value: "\(session.macLaunchers.count)")
                    Button("Choose Programs…") { openWindow(id: "macapps", value: session.id) }
                    paneNote("A program kept on the Mac is a small app in your Applications folder (Tandem > \(config.name)). Pin it to the Dock, find it with Spotlight, or choose it under Open With in Finder for a file in a folder shared with this virtual machine. Opening it starts or resumes the virtual machine by itself. Choosing programs needs the virtual machine running, so that Windows can say which files each one opens.")
                }
            } else {
                Section {
                    paneNote("Showing a virtual machine’s programs on the Mac is available for Windows and Linux (QEMU) virtual machines. This one runs \(config.guestOS.label).")
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Options > Full Screen

struct FullScreenPane: View {
    @Binding var config: VMConfig

    private var drawsOwnScreen: Bool { config.engine == .qemu }

    var body: some View {
        let behavior = $config.behavior
        Form {
            Section {
                Toggle("Start in full screen", isOn: Binding(
                    get: { behavior.wrappedValue.startupView == .fullScreen },
                    set: { behavior.wrappedValue.startupView = $0 ? .fullScreen : .window }))
                Toggle("Keep the toolbar visible in full screen", isOn: behavior.toolbarAlwaysVisibleInFullScreen).accessibilityLabel("Keep the toolbar visible in full screen")
                paneNote("Without this the toolbar and the Mac’s menu bar appear when the pointer reaches the top of the screen. Enter and leave full screen with the green button in the window’s title bar.")
            }
            Section("Picture") {
                Picker("When the sizes differ", selection: behavior.scaling) {
                    Text("Scale to fit").tag(VMBehavior.Scaling.fit)
                    Text("Stretch to fill").tag(VMBehavior.Scaling.stretch)
                    Text("Show at actual size").tag(VMBehavior.Scaling.actualSize)
                }
                .disabled(!drawsOwnScreen)
                if drawsOwnScreen {
                    paneNote("Used in a window and in full screen whenever the virtual machine’s resolution is not the size of the space it has. With the guest tools running the virtual machine normally changes its resolution to match, and nothing is scaled.")
                } else {
                    paneNote("Not available for this virtual machine: its screen is drawn by macOS, which always scales it to fit.")
                }
            }
            Section("Seamless Mode") {
                Toggle("Retina resolution", isOn: behavior.seamlessRetina).disabled(!drawsOwnScreen || config.guestOS != .windows11arm).accessibilityLabel("Retina resolution")
                paneNote("Gives Windows one pixel per screen pixel and sets its scale to 200%, so text is sharp and keeps its size. Windows applies the scale at once; a few older programs keep their old size until they are reopened. Off uses half the pixels, which is lighter on the Mac.")
            }
            Section("Displays") {
                Toggle("Use all displays in full screen", isOn: .constant(false)).disabled(true).accessibilityLabel("Use all displays in full screen")
                paneNote("Not available: a virtual machine has one screen for now, on the display its window is on.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Options > Maintenance

struct MaintenancePane: View {
    @ObservedObject var session: VMSession
    @State private var usage: [DiskMaintenance.Usage] = []
    @State private var working = false
    @State private var result: String?
    @State private var failed = false

    private static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    private var canCompact: Bool {
        !working && !session.state.isActive && !session.isSuspended && usage.contains(where: \.canCompact)
    }

    var body: some View {
        Form {
            Section("Guest tools") {
                if let agent = session.agent {
                    LabeledContent("Status", value: "Running, version \(agent.agentVersion)")
                } else if let version = session.config.guestTools.installedVersion {
                    LabeledContent("Status", value: "Version \(version), last seen \(session.config.guestTools.lastSeen?.formatted(date: .abbreviated, time: .shortened) ?? "earlier")")
                } else {
                    LabeledContent("Status", value: "Not installed")
                }
                switch session.config.guestOS {
                case .windows11arm:
                    paneNote("The guest tools replace themselves with the copy inside this version of Tandem every time they connect, so there is nothing to reinstall. A virtual machine without them gets them from its installation: create it with “Install Windows automatically”, or import it from Parallels.")
                case .linux:
                    paneNote("Installed tools update themselves from this version of Tandem. To install them, open the “TANDEM_TOOLS” disc inside the virtual machine and run:  sudo sh install.sh")
                case .macos:
                    paneNote("There are no guest tools for macOS virtual machines yet.")
                }
            }
            Section("Disk space") {
                ForEach(usage, id: \.file) { disk in
                    LabeledContent(disk.file, value: "\(Self.size(disk.allocatedBytes)) on this Mac of \(Self.size(disk.virtualBytes))")
                }
                HStack {
                    Button(working ? "Freeing Up Space…" : "Free Up Disk Space") { compact() }.disabled(!canCompact)
                    if working { ProgressView().controlSize(.small) }
                    if let result { Text(result).foregroundStyle(failed ? .red : .secondary).textSelection(.enabled) }
                }
                if !usage.contains(where: \.canCompact) {
                    paneNote("This virtual machine’s disk is a plain image, which already gives back the space the system frees.")
                } else if session.state.isActive || session.isSuspended {
                    paneNote("Shut the virtual machine down to free up disk space.")
                } else {
                    paneNote("Rewrites the disk file without the space the system inside has freed. The new file is checked against the old one before it replaces it. This can take several minutes and needs room for a second copy while it runs.")
                }
            }
            Section("Troubleshooting") {
                HStack {
                    Button("Show Logs in Finder") { NSWorkspace.shared.open(session.bundle.logsDirectory) }
                    Button("Show Virtual Machine in Finder") { NSWorkspace.shared.activateFileViewerSelecting([session.bundle.url]) }
                }
                paneNote("The logs folder holds the guest tools’ log, the virtual machine’s console output and the engine’s own messages.")
            }
        }
        .formStyle(.grouped)
        .onAppear { usage = DiskMaintenance.usage(of: session.bundle) }
    }

    private func compact() {
        let bundle = session.bundle
        working = true
        result = nil
        Task.detached {
            // Under the VM's lease: refused while anything (vmctl, a clone) uses it.
            let outcome = Result {
                try BundleLease.with(bundle, purpose: "having its disk compacted") { _ in
                    try DiskMaintenance.compact(bundle: bundle, toolchain: try QEMUToolchain.locate())
                }
            }
            await MainActor.run {
                working = false
                usage = DiskMaintenance.usage(of: bundle)
                switch outcome {
                case .success(let freed):
                    failed = false
                    result = freed > 0 ? "Freed \(Self.size(freed))." : "Nothing to free: the disk is already compact."
                case .failure(let error):
                    failed = true
                    result = [error.localizedDescription, (error as? VMError)?.detail].compactMap { $0 }.joined(separator: " ")
                }
            }
        }
    }
}

// MARK: Hardware > Mouse & Keyboard

struct InputPane: View {
    @Binding var config: VMConfig

    private var handlesInput: Bool { config.engine == .qemu }

    var body: some View {
        let behavior = $config.behavior
        Form {
            if handlesInput {
                Section("Keyboard") {
                    Picker("Command key", selection: behavior.commandKey) {
                        Text(config.guestOS == .windows11arm ? "Is the Windows key" : "Is the Super key").tag(VMBehavior.CommandKey.windowsKey)
                        Text("Works as on the Mac").tag(VMBehavior.CommandKey.macShortcuts)
                    }
                    if behavior.wrappedValue.commandKey == .macShortcuts {
                        paneNote("Command with C, V, X, A, Z, S, F, W, N, O, P, T, B, I, U, Y, R, L or D is sent as Control with that letter, and Command-Q as Alt-F4. Command alone, or with any other key, is still the \(config.guestOS == .windows11arm ? "Windows" : "Super") key.")
                    } else {
                        paneNote("Command-C in the virtual machine is \(config.guestOS == .windows11arm ? "Windows" : "Super")-C; copy with Control-C as on a PC.")
                    }
                    Toggle("Send Command shortcuts to the virtual machine", isOn: behavior.commandShortcutsToGuest).accessibilityLabel("Send Command shortcuts to the virtual machine")
                    paneNote("Off: while the virtual machine has the keyboard, Command shortcuts go to Tandem’s own menus (Command-Q quits Tandem). Shortcuts macOS keeps for itself, such as Command-Tab and Command-Space, never reach the virtual machine; send Control-Alt-Delete and others from Devices > Keyboard.")
                }
                Section("Mouse") {
                    Toggle("Reverse the scrolling direction", isOn: behavior.invertScrolling).accessibilityLabel("Reverse the scrolling direction")
                    paneNote("The virtual machine scrolls the way the Mac does. Turn this on if it should scroll the other way.")
                }
            } else {
                Section {
                    paneNote("Not available for this virtual machine: macOS passes the keyboard and mouse to it directly, with Command as the Command key.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Hardware > Sound & Camera

struct SoundPane: View {
    @Binding var config: VMConfig
    let locked: Bool

    var body: some View {
        let sound = $config.sound
        Form {
            Section("Sound") {
                Toggle("Play the virtual machine’s sound on the Mac", isOn: sound.output).accessibilityLabel("Play the virtual machine’s sound on the Mac")
                Toggle("Let the virtual machine use the Mac’s microphone", isOn: sound.microphone).accessibilityLabel("Let the virtual machine use the Mac’s microphone")
                if sound.wrappedValue.microphone {
                    paneNote("macOS asks for permission to use the microphone the first time the virtual machine starts. If it was refused, allow Tandem under System Settings > Privacy & Security > Microphone.")
                }
                if !sound.wrappedValue.output && !sound.wrappedValue.microphone {
                    paneNote("With both off the virtual machine has no sound card.")
                }
            }
            .disabled(locked)
            Section("Camera") {
                Toggle("Share the Mac’s camera", isOn: .constant(false)).disabled(true).accessibilityLabel("Share the Mac’s camera")
                paneNote("Not available: the virtual machine has no camera device yet.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Hardware > Shared Printers

struct PrintersPane: View {
    var body: some View {
        Form {
            Section {
                Toggle("Share the Mac’s printers with the virtual machine", isOn: .constant(false)).disabled(true).accessibilityLabel("Share the Mac’s printers with the virtual machine")
                paneNote("Not available: there is no path yet from the virtual machine to the Mac’s printers. Until there is, print to a PDF file in a shared folder and print that from the Mac, or add a network printer inside the virtual machine.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Hardware > Boot Order

struct BootPane: View {
    @Binding var config: VMConfig
    let locked: Bool

    private static func title(_ device: BootDevice) -> String {
        switch device {
        case .hardDisk: return "Hard Disk"
        case .cd: return "CD/DVD"
        case .network: return "Network"
        }
    }

    private static func symbol(_ device: BootDevice) -> String {
        switch device {
        case .hardDisk: return "internaldrive"
        case .cd: return "opticaldisc"
        case .network: return "network"
        }
    }

    /// The devices in the chosen order, then the ones left out.
    private var rows: [BootDevice] {
        let order = config.bootOrDefault.order
        return order + BootDevice.allCases.filter { !order.contains($0) }
    }

    private func setUsed(_ device: BootDevice, _ used: Bool) {
        var order = config.bootOrDefault.order
        if used { if !order.contains(device) { order.append(device) } } else { order.removeAll { $0 == device } }
        $config.boot.wrappedValue.order = order
    }

    private func move(_ device: BootDevice, by offset: Int) {
        var order = config.bootOrDefault.order
        guard let index = order.firstIndex(of: device), order.indices.contains(index + offset) else { return }
        order.swapAt(index, index + offset)
        $config.boot.wrappedValue.order = order
    }

    var body: some View {
        Form {
            if config.engine == .qemu {
                Section("Start from") {
                    let order = config.bootOrDefault.order
                    ForEach(rows, id: \.self) { device in
                        HStack {
                            Toggle(isOn: Binding(get: { order.contains(device) }, set: { setUsed(device, $0) })) {
                                Label(Self.title(device), systemImage: Self.symbol(device))
                            }
                            .toggleStyle(.checkbox)
                            Spacer()
                            if let index = order.firstIndex(of: device) {
                                Button { move(device, by: -1) } label: { Image(systemName: "chevron.up") }
                                    .disabled(index == 0).help("Try earlier").accessibilityLabel("Move \(Self.title(device)) up")
                                Button { move(device, by: 1) } label: { Image(systemName: "chevron.down") }
                                    .disabled(index == order.count - 1).help("Try later").accessibilityLabel("Move \(Self.title(device)) down")
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                    if order.isEmpty {
                        paneNote("With nothing ticked the firmware chooses for itself, which usually means its own setup screen.")
                    } else {
                        paneNote("The virtual machine starts from the first device in this list that has a system on it. Devices that are not ticked are skipped.")
                    }
                }
                Section {
                    Toggle("Show the boot menu at start-up", isOn: $config.boot.menu).accessibilityLabel("Show the boot menu at start-up")
                    paneNote("The firmware waits five seconds at start-up. Press Escape in that time to choose a device or open the firmware’s settings.")
                }
            } else {
                Section {
                    paneNote("Not available for this virtual machine: macOS starts it from its own disk.")
                }
            }
        }
        .formStyle(.grouped)
        .disabled(locked)
    }
}
