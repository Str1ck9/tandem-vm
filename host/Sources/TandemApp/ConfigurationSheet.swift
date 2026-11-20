import AppKit
import SwiftUI
import NetHelperClient
import UniformTypeIdentifiers
import VMCore

/// The VM configuration window: five tabs across the top, and a list of panes down the left of the
/// Options and Hardware tabs. Panes for features that do not exist yet are listed and greyed out, so the
/// layout stays stable as they arrive.
struct ConfigurationSheet: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general, options, hardware, security, backup
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .general: return "switch.2"
            case .options: return "slider.horizontal.3"
            case .hardware: return "cpu"
            case .security: return "lock"
            case .backup: return "clock.arrow.circlepath"
            }
        }
    }

    struct Pane: Identifiable, Hashable {
        let id: String
        let title: String
        let symbol: String
        var available = true
    }

    static let optionPanes = [
        Pane(id: "sharing", title: "Sharing", symbol: "folder.badge.person.crop"),
        Pane(id: "startup", title: "Startup and Shutdown", symbol: "power"),
        Pane(id: "applications", title: "Applications", symbol: "square.grid.2x2"),
        Pane(id: "fullscreen", title: "Full Screen", symbol: "arrow.up.left.and.arrow.down.right"),
        Pane(id: "maintenance", title: "Maintenance", symbol: "wrench.and.screwdriver"),
    ]

    static let hardwarePanes = [
        Pane(id: "cpu", title: "CPU & Memory", symbol: "memorychip"),
        Pane(id: "graphics", title: "Graphics", symbol: "display"),
        Pane(id: "network", title: "Network", symbol: "network"),
        Pane(id: "disk", title: "Hard Disk", symbol: "internaldrive"),
        Pane(id: "cd", title: "CD/DVD", symbol: "opticaldisc"),
        Pane(id: "tpm", title: "TPM Chip", symbol: "lock.shield"),
        Pane(id: "input", title: "Mouse & Keyboard", symbol: "keyboard"),
        Pane(id: "sound", title: "Sound & Camera", symbol: "speaker.wave.2"),
        Pane(id: "usb", title: "USB & Bluetooth", symbol: "cable.connector"),
        Pane(id: "printers", title: "Shared Printers", symbol: "printer", available: false),
        Pane(id: "boot", title: "Boot Order", symbol: "list.number"),
    ]

    private static let resolutions = ["1024x768", "1280x800", "1440x900", "1680x1050", "1920x1080", "1920x1200", "2560x1440"]
    private static let hostCPUs = ProcessInfo.processInfo.processorCount
    private static let hostMemoryMiB = Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)

    @ObservedObject var session: VMSession
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab
    @State private var optionPane: String
    @State private var hardwarePane: String
    @State private var draft: VMConfig
    @State private var forwards: String
    @State private var errorText: String?
    @State private var helperInstalled = NetHelper.isInstalled
    @State private var bridgeInterfaces: [String] = (try? NetHelper.interfaces()) ?? []
    @State private var installingHelper = false
    @State private var snapshotName = ""
    @State private var snapshotNote = ""
    @State private var namingSnapshot = false
    @State private var revertTarget: VMSnapshot?
    @State private var deleteTarget: VMSnapshot?
    private let original: VMConfig

    /// `initial` is "tab" or "tab/pane", for example "hardware/network".
    init(session: VMSession, initial: String? = nil) {
        self.session = session
        let c = session.config
        original = c
        _draft = State(initialValue: c)
        _forwards = State(initialValue: c.network.portForwards.map { "\($0.hostPort):\($0.guestPort)" }.joined(separator: ", "))
        let parts = (initial ?? "").split(separator: "/").map(String.init)
        let tab = parts.first.flatMap(Tab.init(rawValue:)) ?? .general
        let pane = parts.count > 1 ? parts[1] : nil
        _tab = State(initialValue: tab)
        _optionPane = State(initialValue: tab == .options ? pane ?? "sharing" : "sharing")
        _hardwarePane = State(initialValue: tab == .hardware ? pane ?? "cpu" : "cpu")
    }

    /// Nothing to save, or the VM is running and the change is to more than its behaviour settings.
    private var canSave: Bool {
        let forwardsChanged = forwards != Self.text(original.network.portForwards)
        if session.isLocked { return !forwardsChanged && draft.differsOnlyInBehavior(from: original) }
        return draft != original || forwardsChanged
    }

    private var isWindows: Bool { draft.guestOS == .windows11arm }
    private var isQEMU: Bool { draft.engine == .qemu }
    private var originalDiskGiB: Int { original.disks.first?.sizeGiB ?? 64 }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            Group {
                switch tab {
                case .general: generalTab
                case .options: split(Self.optionPanes, selection: $optionPane) { optionsDetail }
                case .hardware: split(Self.hardwarePanes, selection: $hardwarePane) { hardwareDetail }
                case .security: securityTab
                case .backup: backupTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                if let errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).lineLimit(2).textSelection(.enabled)
                } else if session.state.isActive, tab == .options, optionPane == "sharing" {
                    // The Sharing pane applies its changes to a running VM by itself.
                    EmptyView()
                } else if session.state.isActive {
                    Label("Shut down the virtual machine to change its hardware and sharing. Startup, keyboard and screen behaviour can be changed now.", systemImage: "lock")
                        .foregroundStyle(.secondary).font(.callout)
                } else if session.isSuspended {
                    Label("The virtual machine is suspended. Resume it and shut it down to change its hardware and sharing. Startup, keyboard and screen behaviour can be changed now.", systemImage: "lock")
                        .foregroundStyle(.secondary).font(.callout)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
            .padding(14)
        }
        .frame(width: 720, height: 540)
        .navigationTitle("“\(original.name)” Configuration")
        .focusedSceneValue(\.activeSession, session)
        .onReceive(NotificationCenter.default.publisher(for: .selfTestSettings)) { note in
            let parts = ((note.object as? String) ?? "").split(separator: "/").map(String.init)
            guard let first = parts.first, let target = Tab(rawValue: first) else { return }
            tab = target
            if parts.count > 1 { if target == .options { optionPane = parts[1] } else { hardwarePane = parts[1] } }
        }
    }

    // MARK: Layout

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases) { item in
                Button { tab = item } label: {
                    VStack(spacing: 4) {
                        Image(systemName: item.symbol).font(.system(size: 20)).frame(height: 24)
                        Text(item.title).font(.caption)
                    }
                    .frame(width: 78, height: 50)
                    .foregroundStyle(tab == item ? Color.accentColor : Color.secondary)
                    .background(tab == item ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(tab == item ? .isSelected : [])
            }
        }
        .padding(.vertical, 10)
    }

    private func split<Detail: View>(_ panes: [Pane], selection: Binding<String>, @ViewBuilder detail: () -> Detail) -> some View {
        HStack(spacing: 0) {
            List(panes, selection: selection) { pane in
                Label(pane.title, systemImage: pane.symbol)
                    .foregroundStyle(pane.available ? .primary : .secondary)
                    .tag(pane.id)
            }
            .listStyle(.sidebar)
            .frame(width: 210)
            Divider()
            detail().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func page<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Form { content() }.formStyle(.grouped)
    }

    /// Runs the helper's installer; macOS asks for the administrator password.
    private func installHelper() {
        installingHelper = true
        Task.detached {
            let result = Result { try NetHelperInstaller.install() }
            await MainActor.run {
                installingHelper = false
                helperInstalled = NetHelper.isInstalled
                bridgeInterfaces = (try? NetHelper.interfaces()) ?? []
                if case .failure(let error) = result {
                    errorText = [error.localizedDescription, (error as? VMError)?.detail].compactMap { $0 }.joined(separator: "\n")
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func comingLater(_ title: String, symbol: String, _ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(.tertiary)
            Text(title).font(.title3)
            Text("Not available yet").font(.callout.weight(.medium)).foregroundStyle(.secondary)
            Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: General

    private var generalTab: some View {
        page {
            Section {
                TextField("Name", text: $draft.name)
                TextField("Description", text: Binding(get: { draft.notes ?? "" }, set: { draft.notes = $0.isEmpty ? nil : $0 }), axis: .vertical)
                    .lineLimit(2...4)
            }
            Section {
                ColorPicker("Colour in Control Center", selection: Binding(
                    get: { draft.stripeColor }, set: { draft.color = $0.hex }), supportsOpacity: false)
                LabeledContent("Operating system", value: draft.guestOS.label)
                LabeledContent("Engine", value: isQEMU ? "QEMU (Hypervisor.framework)" : "Apple Virtualization")
                LabeledContent("Space used on this Mac", value: Self.spaceUsed(session.bundle.url))
                LabeledContent("Location") {
                    HStack {
                        Text(session.bundle.url.deletingLastPathComponent().path).lineLimit(1).truncationMode(.head)
                            .foregroundStyle(.secondary)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([session.bundle.url]) }
                    }
                }
            }
            Section("Guest tools") {
                if let agent = session.agent {
                    LabeledContent("Status", value: "Connected, version \(agent.agentVersion)")
                    if let info = session.guestInfo {
                        LabeledContent("Guest", value: [info.osName, info.osVersion].compactMap { $0 }.joined(separator: " "))
                        LabeledContent("IP address", value: info.ipAddresses?.joined(separator: ", ") ?? "—")
                    }
                } else if let version = original.guestTools.installedVersion {
                    LabeledContent("Status", value: "Version \(version), last seen \(original.guestTools.lastSeen?.formatted(date: .abbreviated, time: .shortened) ?? "earlier")")
                } else {
                    LabeledContent("Status", value: "Not installed")
                }
            }
            if let backing = original.disks.first?.backing {
                Section {
                    note("This VM was imported without copying. Its disk still depends on the original file, which must stay where it is and must not be started in its old app:\n\(backing.path)")
                }
            }
        }
    }

    // MARK: Options

    @ViewBuilder private var optionsDetail: some View {
        switch optionPane {
        case "sharing":
            // Folders, clipboard, network exposure and USB in one panel (SharingPane.swift).
            SharingPane(session: session, draft: $draft)
        case "startup": StartupPane(config: $draft, session: session)
        case "applications": ApplicationsPane(config: $draft, session: session)
        case "fullscreen": FullScreenPane(config: $draft)
        default: MaintenancePane(session: session)
        }
    }

    // MARK: Hardware

    @ViewBuilder private var hardwareDetail: some View {
        switch hardwarePane {
        case "cpu":
            page {
                Stepper("Processors: \(draft.cpuCount)", value: $draft.cpuCount, in: 1...Self.hostCPUs)
                Stepper("Memory: \(draft.memoryMiB / 1024) GiB", value: $draft.memoryMiB,
                        in: 1024...max(1024, Self.hostMemoryMiB - 2048), step: 1024)
                note("This Mac has \(Self.hostCPUs) processor cores and \(Self.hostMemoryMiB / 1024) GiB of memory. Leave at least half of each for macOS.")
            }
        case "graphics":
            page {
                Picker("Resolution", selection: resolution) {
                    ForEach(resolutionChoices, id: \.self) { Text($0.replacingOccurrences(of: "x", with: " × ")).tag($0) }
                }
                if isWindows && original.display.virtioGPU != true {
                    note("This Windows VM has no display driver yet, so it stays at 800 × 600 until one is installed.")
                }
                if draft.guestOS == .linux && draft.engine == .qemu {
                    Toggle("3D acceleration (Linux, experimental)", isOn: Binding(
                        get: { draft.display.accelerated3D == true },
                        set: { draft.display.accelerated3D = $0 ? true : nil }))
                    note(Graphics3D.note(installed: Graphics3D.isInstalled))
                } else if draft.guestOS == .windows11arm && draft.engine == .qemu {
                    // Turning it on is all the user does: Tandem fetches the signed driver and the guest tools
                    // install it at the next start (SessionWindows3D).
                    Toggle("3D acceleration (Windows, experimental)", isOn: Binding(
                        get: { draft.display.accelerated3D == true },
                        set: { draft.display.accelerated3D = $0 ? true : nil }))
                        .disabled(!Graphics3D.isWindowsInstalled && draft.display.accelerated3D != true)
                    note(Graphics3D.windowsNote(installed: Graphics3D.isWindowsInstalled,
                                                driver: session.config.display.windows3DDriver))
                } else {
                    LabeledContent("3D acceleration", value: "Not available")
                    note("3D acceleration is available for Linux and Windows virtual machines on the QEMU engine.")
                }
                note("The VM’s screen is scaled to fit its window. With the guest tools running, the VM also changes its resolution to match.")
            }
        case "network":
            page {
                if draft.install.passwordless == true && (draft.network.mode == .bridged || !(draft.publishedServices ?? []).isEmpty) {
                    Label("This virtual machine’s account has no password. On a bridged network, or with published services, other devices could reach it. Give the account a password inside the guest first.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Picker("Source", selection: $draft.network.mode) {
                    Text("Shared Network (Recommended)").tag(NetworkMode.nat)
                    Text("Bridged Network").tag(NetworkMode.bridged)
                }
                if draft.network.mode == .bridged {
                    if helperInstalled {
                        Picker("Bridge to", selection: Binding(get: { draft.network.bridgedInterface ?? "" },
                                                               set: { draft.network.bridgedInterface = $0.isEmpty ? nil : $0 })) {
                            Text("Default Adapter").tag("")
                            ForEach(bridgeInterfaces, id: \.self) { Text(NetHelperInstaller.displayName(of: $0)).tag($0) }
                        }
                        note("The VM gets its own address on the Mac’s network, so other devices can reach it.")
                    } else {
                        note("Bridged Network needs the Tandem network helper: a small background service, installed once with your administrator password. Until then this VM will not start in this mode.")
                        Button(installingHelper ? "Installing…" : "Install Network Helper…") { installHelper() }.disabled(installingHelper)
                    }
                } else {
                    note("The VM shares the Mac’s network connection and is reachable from this Mac only.")
                }
                LabeledContent("MAC address") {
                    HStack {
                        TextField("", text: $draft.network.mac).labelsHidden().font(.body.monospaced()).frame(width: 170)
                        Button("Generate") { draft.network.mac = NetworkConfig.randomMAC() }
                    }
                }
                if isQEMU {
                    TextField("Port forwarding", text: $forwards, prompt: Text("2222:22, 8080:80"))
                    note("Mac port : VM port, separated by commas. The ports are reachable from this Mac only.")
                }
                PublishedServicesSection(draft: $draft, session: session)
            }
        case "disk":
            page {
                if let disk = draft.disks.first {
                    LabeledContent("File", value: disk.file)
                    LabeledContent("Connection", value: disk.bus == .nvme ? "NVMe" : "VirtIO")
                    Stepper("Size: \(disk.sizeGiB) GiB", value: $draft.disks[0].sizeGiB, in: originalDiskGiB...2048, step: 8)
                    if disk.sizeGiB > originalDiskGiB {
                        note("The disk grows to \(disk.sizeGiB) GiB. The VM must then extend its own partition to use the new space. A disk cannot be made smaller afterwards.")
                    } else {
                        note("The disk file only takes up the space the VM has actually used.")
                    }
                }
            }
        case "cd":
            page {
                LabeledContent("Disc image") {
                    HStack {
                        Text(isoPath.isEmpty ? "None" : URL(fileURLWithPath: isoPath).lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { chooseISO() }
                        if !isoPath.isEmpty { Button("Remove") { setISO("") } }
                    }
                }
                note("The VM starts from this disc if it has one. Remove it once the operating system is installed.")
            }
        case "tpm":
            if isQEMU {
                page {
                    Toggle("TPM 2.0 chip", isOn: $draft.tpm)
                    if isWindows && !draft.tpm { note("Windows 11 expects a TPM. Without it, BitLocker and Windows Hello stop working.") }
                }
            } else {
                comingLater("TPM Chip", symbol: "lock.shield", "A TPM is only offered for Windows VMs.")
            }
        case "input": InputPane(config: $draft)
        case "sound": SoundPane(config: $draft, locked: session.isLocked)
        case "usb":
            page {
                note("Connect a USB device while the VM runs from the menu bar: Devices > USB.\(isQEMU ? "" : " This VM’s engine cannot take USB devices yet.")")
                note("macOS only hands over devices it is not using itself. Disks, keyboards, mice and cameras the Mac has claimed cannot be connected yet. Bluetooth devices cannot be connected.")
            }
        case "printers": PrintersPane()
        default: BootPane(config: $draft, locked: session.isLocked)
        }
    }

    // MARK: Security and Backup

    private var securityTab: some View {
        page {
            Section {
                Toggle("Isolate the VM from the Mac", isOn: Binding(get: { draft.sharing.preset == .restricted },
                                                                      set: { draft.sharing = $0 ? .restricted : .default }))
                    .disabled(session.isLocked)
                note("Stops sharing everything: folders, the clipboard, USB devices, and connections into the VM. The same as the Restricted preset under Options > Sharing, where each part can be set by itself.")
            }
            Section {
                Toggle("Encrypt the VM with a password", isOn: .constant(false)).disabled(true)
                Toggle("Require a password to change its configuration", isOn: .constant(false)).disabled(true)
                note("Encryption and password protection are not available yet.")
            }
        }
    }

    private var backupTab: some View {
        page {
            Section {
                HStack {
                    note("A snapshot saves the VM exactly as it is now, so you can come back to it. It is taken instantly and only uses space as the VM changes afterwards.")
                    Spacer()
                    Button("New Snapshot…") { snapshotName = ""; snapshotNote = ""; namingSnapshot = true }
                }
            }
            Section("Snapshots") {
                let snapshots = session.snapshots
                if snapshots.isEmpty { Text("No snapshots yet").foregroundStyle(.secondary) }
                ForEach(snapshots) { snapshot in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snapshot.name)
                            if let text = snapshot.note { Text(text).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                            Text(snapshot.created.formatted(date: .abbreviated, time: .shortened) + " · " + Self.sizeText(session.snapshotSize(snapshot))
                                 + (session.snapshotIncludesRunningState(snapshot) ? " · taken while running" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Go Back to This…") { revertTarget = snapshot }
                        Button(role: .destructive) { deleteTarget = snapshot } label: { Image(systemName: "trash") }
                            .help("Delete this snapshot").accessibilityLabel("Delete snapshot \(snapshot.name)")
                    }
                }
            }
        }
        .sheet(isPresented: $namingSnapshot) {
            VStack(alignment: .leading, spacing: 12) {
                Text("New Snapshot").font(.headline)
                TextField("Name", text: $snapshotName, prompt: Text("Snapshot"))
                TextField("Description (optional)", text: $snapshotNote, axis: .vertical).lineLimit(3...5)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { namingSnapshot = false }.keyboardShortcut(.cancelAction)
                    Button("Take Snapshot") {
                        let (name, note) = (snapshotName, snapshotNote)
                        namingSnapshot = false
                        Task {
                            do { try await session.takeSnapshot(named: name, note: note); errorText = nil }
                            catch { errorText = error.localizedDescription }
                        }
                    }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding(20)
            .frame(width: 420)
        }
        .confirmationDialog("Delete the snapshot “\(deleteTarget?.name ?? "")”?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }), titleVisibility: .visible) {
            Button("Delete Snapshot", role: .destructive) {
                guard let target = deleteTarget else { return }
                attemptAsync { try await session.deleteSnapshot(target) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will no longer be able to go back to this point. The VM itself is not changed. This cannot be undone.")
        }
        .confirmationDialog("Go back to “\(revertTarget?.name ?? "")”?", isPresented: Binding(get: { revertTarget != nil }, set: { if !$0 { revertTarget = nil } }), titleVisibility: .visible) {
            Button("Go Back and Lose Current State", role: .destructive) {
                guard let target = revertTarget else { return }
                attemptAsync { try await session.revert(to: target); dismiss() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything in the VM since this snapshot is lost, including changes to its configuration. Take a new snapshot first if you may want the current state back.")
        }
    }

    /// "2.7 GB · 310 MB extra on disk": the snapshot's contents, then what deleting it would free.
    private static func sizeText(_ size: (total: Int64, exclusive: Int64)) -> String {
        let f = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        return "\(f(size.total)) · \(f(size.exclusive)) extra on disk"
    }

    private func attempt(_ work: () throws -> Void) {
        do { try work(); errorText = nil } catch { errorText = error.localizedDescription }
    }

    private func attemptAsync(_ work: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do { try await work(); errorText = nil } catch { errorText = error.localizedDescription }
        }
    }

    // MARK: Values

    private var resolution: Binding<String> {
        Binding(get: { "\(draft.display.width)x\(draft.display.height)" }, set: { value in
            let size = value.split(separator: "x").compactMap { Int($0) }
            if size.count == 2 { draft.display.width = size[0]; draft.display.height = size[1] }
        })
    }

    private var resolutionChoices: [String] {
        let current = "\(draft.display.width)x\(draft.display.height)"
        return Self.resolutions.contains(current) ? Self.resolutions : [current] + Self.resolutions
    }

    private static let homePath = FileManager.default.homeDirectoryForCurrentUser.path
    private var homeShareIndex: Int? { draft.sharedFolders.firstIndex { $0.hostPath == Self.homePath } }

    private func setHomeShare(_ on: Bool) {
        if let index = homeShareIndex { if !on { draft.sharedFolders.remove(at: index) } }
        else if on { draft.sharedFolders.insert(SharedFolder(hostPath: Self.homePath, name: uniqueShareName("Home")), at: 0) }
    }

    private func uniqueShareName(_ wanted: String) -> String {
        // The name becomes a folder name in the guest, so keep it to characters every system accepts.
        let cleaned = String(wanted.map { $0.isLetter || $0.isNumber || " -_.".contains($0) ? $0 : "-" }).trimmingCharacters(in: .whitespaces)
        let base = cleaned.isEmpty ? "Folder" : cleaned
        let taken = Set(draft.sharedFolders.map { $0.name.lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        return (2...99).lazy.map { "\(base) \($0)" }.first { !taken.contains($0.lowercased()) } ?? base
    }

    private func addSharedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Share"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !draft.sharedFolders.contains(where: { $0.hostPath == url.path }) {
            draft.sharedFolders.append(SharedFolder(hostPath: url.path, name: uniqueShareName(url.lastPathComponent)))
        }
    }

    private var isoPath: String { draft.removableMedia.first { $0.kind == .installerISO }?.file ?? "" }

    private func setISO(_ path: String) {
        draft.removableMedia.removeAll { $0.kind == .installerISO }
        if !path.isEmpty { draft.removableMedia.insert(RemovableMedia(file: path, kind: .installerISO), at: 0) }
    }

    private func chooseISO() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .diskImage, .diskImage]
        if panel.runModal() == .OK, let url = panel.url { setISO(url.path) }
    }

    private static func text(_ forwards: [PortForward]) -> String {
        forwards.map { "\($0.hostPort):\($0.guestPort)" }.joined(separator: ", ")
    }

    /// Space the bundle really occupies (sparse and copy-on-write files count only what they hold).
    private static func spaceUsed(_ url: URL) -> String {
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        if let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) {
            for case let file as URL in files {
                let values = try? file.resourceValues(forKeys: Set(keys))
                if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
            }
        }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private func fail(_ message: String, tab: Tab, pane: String? = nil) {
        errorText = message
        self.tab = tab
        if let pane { hardwarePane = pane }
    }

    private func save() {
        if session.isLocked {
            // Only behaviour settings can change while the VM runs or is suspended.
            do { try session.applyBehavior(draft.behaviorOrDefault); dismiss() }
            catch { errorText = error.localizedDescription }
            return
        }
        var config = draft
        config.name = config.name.trimmingCharacters(in: .whitespaces)
        config.network.mac = config.network.mac.trimmingCharacters(in: .whitespaces).lowercased()
        guard config.network.mac.range(of: "^([0-9a-f]{2}:){5}[0-9a-f]{2}$", options: .regularExpression) != nil else {
            return fail("The MAC address must look like 02:1c:42:a0:0c:16.", tab: .hardware, pane: "network")
        }
        var parsed: [PortForward] = []
        for item in forwards.split(separator: ",") {
            let parts = item.trimmingCharacters(in: .whitespaces).split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2, (1...65535).contains(parts[0]), (1...65535).contains(parts[1]) else {
                return fail("Port forwarding must look like 2222:22, 8080:80.", tab: .hardware, pane: "network")
            }
            parsed.append(PortForward(hostPort: parts[0], guestPort: parts[1]))
        }
        config.network.portForwards = parsed
        do {
            try session.apply(config)
            if let problem = LoginItem.sync(with: AppDelegate.shared?.model), config.behaviorOrDefault.autoStart == .withMac {
                errorText = "Saved, but Tandem could not be added to the Mac’s login items: \(problem)"
                return
            }
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
