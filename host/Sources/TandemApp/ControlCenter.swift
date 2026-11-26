import AppKit
import Provisioning
import SwiftUI
import VMCore

extension VMState {
    /// Status text as shown under a VM's name.
    var label: String {
        switch self {
        case .stopped: return String(localized: "Stopped")
        case .starting: return String(localized: "Starting…")
        case .running: return String(localized: "Running")
        case .paused: return String(localized: "Paused")
        case .stopping: return String(localized: "Stopping…")
        case .error: return String(localized: "Error")
        }
    }
    var color: Color {
        switch self {
        case .running: return .green
        case .paused: return .yellow
        case .starting, .stopping: return .orange
        case .error: return .red
        case .stopped: return .secondary
        }
    }
}

/// Asks before a suspended VM's saved memory is thrown away.
@MainActor func confirmDiscard(_ session: VMSession) {
    let alert = NSAlert()
    alert.messageText = "Stop “\(session.config.name)”?"
    alert.informativeText = "It is suspended. Stopping it discards what it had open, as if its power had been cut. Unsaved work in the VM will be lost."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Stop")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true
    if alert.runModal() == .alertFirstButtonReturn { session.discardSuspendedState() }
}

extension Color {
    /// `#RRGGBB`. Nil for anything else.
    init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    var hex: String? {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
}

extension VMConfig {
    /// The stripe colour in Control Center: the user's choice, or one per kind of system.
    var stripeColor: Color {
        if let color, let chosen = Color(hex: color) { return chosen }
        switch guestOS {
        case .windows11arm: return .blue
        case .linux: return .green
        case .macos: return .pink
        }
    }
}

extension GuestOS {
    var label: String {
        switch self {
        case .windows11arm: return "Windows 11"
        case .linux: return "Linux"
        case .macos: return "macOS"
        }
    }
    var symbol: String {
        switch self {
        case .windows11arm: return "macwindow"
        case .linux: return "terminal"
        case .macos: return "apple.logo"
        }
    }
}

/// Which VM a configuration window is for, and where it opens ("tab" or "tab/pane").
struct ConfigurationTarget: Codable, Hashable {
    var id: UUID
    var place: String?
}

/// The list of virtual machines: a narrow window with one row per VM, in an expanded or a compact view.
struct ControlCenterView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @AppStorage("controlCenterCompact") private var compact = false
    @State private var showingNewVM = false
    @State private var importing: ParallelsVM?
    @State private var importError: String?
    @State private var removing: VMSession?
    @State private var cloning: VMSession?
    @State private var actionError: String?

    var body: some View {
        Group {
            if let fatal = model.fatalError {
                ContentUnavailableView("The VM library could not be opened", systemImage: "exclamationmark.triangle", description: Text(fatal))
            } else if model.sessions.isEmpty {
                ContentUnavailableView {
                    Label("No Virtual Machines", systemImage: "square.stack.3d.up.slash")
                } description: {
                    Text("Create a virtual machine, or import one from Parallels.")
                } actions: {
                    Button("Create New…") { showingNewVM = true }
                    Button("Import from Parallels…") { chooseParallelsVM() }
                }
            } else {
                List(selection: $model.selection) {
                    ForEach(model.sessions) { session in
                        VMRow(session: session, compact: compact,
                              open: { open(session) }, configure: { configure(session, nil) })
                            .tag(session.id)
                            .listRowSeparator(.visible)
                            .listRowInsets(EdgeInsets(top: 0, leading: compact ? 8 : 0, bottom: 0, trailing: 0))
                    }
                }
                .listStyle(.inset)
                // The list owns clicks: a tap gesture on the rows would swallow single-click selection.
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if let session = model.sessions.first(where: { ids.contains($0.id) }) { contextMenu(for: session) }
                } primaryAction: { ids in
                    if let session = model.sessions.first(where: { ids.contains($0.id) }) { open(session) }
                }
            }
        }
        .frame(minWidth: 420, idealWidth: 480, minHeight: 240)
        .navigationTitle("Control Center")
        .focusedSceneValue(\.activeSession, model.selectedSession)
        .toolbar {
            ToolbarItem {
                Picker("View", selection: $compact) {
                    // A label shown as its picture only keeps its words for VoiceOver (a bare image loses its name
                    // inside a segmented control).
                    Image(nsImage: Self.viewIcon("rectangle.grid.1x2", "Expanded View")).tag(false)
                    Image(nsImage: Self.viewIcon("list.bullet", "Compact View")).tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("View")
                .help("Show virtual machines in expanded or compact view")
            }
            ToolbarItem {
                Menu {
                    Button("Create New…") { showingNewVM = true }
                    Button("Import from Parallels…") { chooseParallelsVM() }
                } label: { Label("Add", systemImage: "plus") }
                .help("Create or import a virtual machine")
                .accessibilityLabel("Add a virtual machine")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            let notes = [model.toolchainNote].compactMap { $0 } + model.loadFailures.map { "Could not load \($0)" }
            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(notes, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.callout) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.yellow.opacity(0.18))
            }
        }
        .sheet(isPresented: $showingNewVM) {
            InstallationAssistant(importExisting: { chooseParallelsVM() }).environmentObject(model)
        }
        .sheet(item: $importing) { vm in ImportSheet(vm: vm).environmentObject(model) }
        .confirmationDialog("Remove “\(removing?.config.name ?? "")”?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                guard let session = removing else { return }
                do { try model.delete(session) } catch { actionError = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The virtual machine, its disks and its snapshots go to the Trash. They take up disk space until you empty the Trash.")
        }
        .modifier(ErrorAlerts(model: model, actionError: $actionError, importError: $importError))
        .onReceive(NotificationCenter.default.publisher(for: .newVM)) { _ in showingNewVM = true }
        .onReceive(NotificationCenter.default.publisher(for: .importVM)) { _ in chooseParallelsVM() }
        .modifier(CloneHandling(cloning: $cloning))
        .onReceive(NotificationCenter.default.publisher(for: .removeVM)) { note in
            if let id = note.object as? UUID { removing = model.sessions.first { $0.id == id } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selfTestImport)) { note in
            if let path = note.object as? String { importing = try? ParallelsVM.inspect(URL(fileURLWithPath: path)) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selfTestOpen)) { note in
            // Self-test: open a window by name, for the selected VM where it needs one.
            guard let what = note.object as? String else { return }
            switch what {
            case "snapshots": if let id = model.selection { openWindow(id: "snapshots", value: id) }
            case "assistant": showingNewVM = true
            case "clone": cloning = model.selectedSession
            case "about": openWindow(id: "about")
            case "preferences": openSettings()
            default: openWindow(id: what) // "welcome", "uninstall"
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selfTestShow)) { note in
            if let id = note.object as? UUID { openWindow(id: "vm", value: id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selfTestSettings)) { note in
            // Only the first request opens the window; later ones switch tabs inside it.
            guard let session = model.selectedSession, !NSApp.windows.contains(where: { $0.title.hasSuffix("Configuration") && $0.isVisible }) else { return }
            configure(session, note.object as? String)
        }
    }

    /// Opening a VM shows its window and starts it if it is not running, as a double-click does in Finder.
    private func open(_ session: VMSession) {
        openWindow(id: "vm", value: session.id)
        if session.can(.start) { session.start() } else if session.can(.resume) { session.resume() }
    }

    private func configure(_ session: VMSession, _ place: String?) {
        openWindow(id: "configuration", value: ConfigurationTarget(id: session.id, place: place))
    }

    @ViewBuilder private func contextMenu(for session: VMSession) -> some View {
        if session.provisioning != nil {
            Button("Cancel Download") { session.cancelProvisioning?() }
            Button("Show Window") { openWindow(id: "vm", value: session.id) }
        }
        if session.can(.start) { Button(session.isSuspended ? "Resume" : "Start") { open(session) } }
        if session.can(.resume) { Button("Resume") { session.resume() } }
        if session.can(.pause) { Button("Pause") { session.pause() } }
        if session.canSuspend { Button("Suspend") { session.suspend() } }
        if session.can(.stop) { Button("Shut Down") { session.stop() } }
        if session.canRestart { Button("Restart") { session.restart() } }
        if session.can(.forceStop) { Button("Stop") { session.forceStop() } }
        if session.isSuspended && !session.state.isActive { Button("Stop…") { confirmDiscard(session) } }
        if session.state.isActive { Button("Show Window") { openWindow(id: "vm", value: session.id) } }
        Divider()
        Button("Manage Snapshots…") { openWindow(id: "snapshots", value: session.id) }
        Divider()
        Button("Configure…") { configure(session, nil) }
        Divider()
        Button("Clone…") { cloning = session }.disabled(session.state.isActive || session.provisioning != nil)
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([session.bundle.url]) }
        Button("Remove “\(session.config.name)”…") { removing = session }.disabled(session.state.isActive || session.provisioning != nil)
    }

    /// Parallels bundles are packages, so the open panel has to be told to treat them as files.
    /// A symbol that carries its spoken name with it: a segment of a segmented control is named from its image.
    static func viewIcon(_ symbol: String, _ name: String) -> NSImage {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: name) ?? NSImage()
        image.isTemplate = true
        return image
    }

    func chooseParallelsVM() {
        let panel = NSOpenPanel()
        panel.title = "Import from Parallels"
        panel.message = "Choose a Parallels virtual machine (.pvm or .macvm). It will not be modified."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        let parallels = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Parallels")
        if FileManager.default.fileExists(atPath: parallels.path) { panel.directoryURL = parallels }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { importing = try ParallelsVM.inspect(url) } catch { importError = error.localizedDescription }
    }
}

extension ParallelsVM: Identifiable {
    public var id: String { url.path }
}

/// The picture of a VM: its last screen when there is one, otherwise a glyph for its operating system,
/// with a play or pause mark over it when the VM is not running.
struct VMThumbnail: View {
    @ObservedObject var session: VMSession
    var width: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: width > 60 ? 0 : 3).fill(Color(white: 0.13))
            if let image = session.thumbnail {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .opacity(session.state == .running ? 1 : 0.5)
                // A mark over the picture says why it is dimmed.
                if width > 60, let mark = overlay {
                    Image(systemName: mark).font(.system(size: width * 0.22)).foregroundStyle(.white).shadow(radius: 3)
                }
            } else {
                Image(systemName: session.state == .error ? "exclamationmark.triangle.fill" : session.config.guestOS.symbol)
                    .font(.system(size: width * 0.3)).foregroundStyle(.white.opacity(0.6))
            }
            if session.state == .starting || session.state == .stopping { ProgressView().controlSize(.small) }
        }
        .frame(width: width, height: width * 0.625)
        .clipShape(RoundedRectangle(cornerRadius: width > 60 ? 0 : 3))
        .accessibilityHidden(true)
    }

    private var overlay: String? {
        switch session.state {
        case .stopped: return "play.circle.fill"
        case .paused: return "pause.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        default: return nil
        }
    }
}

struct VMRow: View {
    @ObservedObject var session: VMSession
    var compact: Bool
    var open: () -> Void
    var configure: () -> Void
    @State private var hovering = false
    @State private var showingError = false

    var body: some View {
        HStack(spacing: compact ? 8 : 12) {
            VMThumbnail(session: session, width: compact ? 32 : 150)
                .padding(.vertical, compact ? 1 : 0)
            VStack(alignment: .leading, spacing: compact ? 2 : 4) {
                Text(session.config.name).font(compact ? .body : .system(size: 20, weight: .light)).lineLimit(1)
                if !compact {
                    // The user's description when there is one, otherwise the kind of system.
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 8) {
                    if !compact {
                        // Always visible, as in the list this is modelled on: power, then settings.
                        if session.can(.start) || session.can(.resume) {
                            Button(action: open) { Image(systemName: "power") }
                                .help(session.can(.resume) ? "Resume" : "Start").accessibilityLabel("Start \(session.config.name)")
                        } else {
                            Button { session.stop() } label: { Image(systemName: "power") }
                                // Green means running; a VM still being downloaded is neither on nor startable.
                                .foregroundStyle(session.state.isActive ? Color.green : Color.secondary.opacity(0.5))
                                .disabled(!session.can(.stop))
                                .help("Shut Down").accessibilityLabel("Shut down \(session.config.name)")
                        }
                        Divider().frame(height: 14)
                        Button(action: configure) { Image(systemName: "gearshape") }
                            .help("Configure").accessibilityLabel("Configure \(session.config.name)")
                        Divider().frame(height: 14)
                    }
                    Circle().fill(session.state.color).frame(width: 7, height: 7).accessibilityHidden(true)
                    Text(session.statusLabel).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    if let provisioning = session.provisioning {
                        // A system being downloaded: how far along, and a way to stop.
                        ProgressView(value: provisioning.fraction).progressViewStyle(.linear).frame(width: compact ? 60 : 110)
                            .accessibilityLabel("Download progress")
                            .accessibilityValue(provisioning.fraction.map { "\(Int($0 * 100)) percent" } ?? "starting")
                        Button { session.cancelProvisioning?() } label: { Image(systemName: "xmark.circle.fill") }
                            .help("Cancel the download and remove this virtual machine").accessibilityLabel("Cancel download of \(session.config.name)")
                    }
                    if session.errorMessage != nil {
                        Button { showingError = true } label: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow) }
                            .help("This VM reported a problem").accessibilityLabel("Show the problem")
                            .popover(isPresented: $showingError) { errorPopover }
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: compact ? 12 : 15))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if compact {
                // The compact list keeps Finder-style controls that appear under the pointer.
                HStack(spacing: 6) {
                    Button(action: configure) { Image(systemName: "gearshape") }
                        .help("Configure").accessibilityLabel("Configure \(session.config.name)")
                    if session.can(.start) || session.can(.resume) {
                        Button(action: open) { Image(systemName: "play.fill") }
                            .help(session.can(.resume) ? "Resume" : "Start").accessibilityLabel("Start \(session.config.name)")
                    } else if session.can(.stop) {
                        Button { session.stop() } label: { Image(systemName: "power") }
                            .help("Shut Down").accessibilityLabel("Shut down \(session.config.name)")
                    }
                }
                .buttonStyle(.borderless)
                .opacity(hovering ? 1 : 0)
            }
            // The VM's colour, down the right-hand edge of its row.
            Rectangle().fill(session.config.stripeColor).frame(width: compact ? 4 : 7)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // One row for VoiceOver: the name and what it is doing, with its buttons inside.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(session.config.name), \(session.config.guestOS.label), \(session.statusLabel)")
    }

    private var subtitle: String {
        let notes = (session.config.notes ?? "").split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return notes.isEmpty ? session.config.guestOS.label : notes
    }

    private var errorPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("The VM reported a problem", systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red).bold()
            Text(session.errorMessage ?? "").font(.callout.monospaced()).textSelection(.enabled)
            HStack {
                Button("Show Logs in Finder") { NSWorkspace.shared.open(session.bundle.logsDirectory) }
                Button("Dismiss") { session.errorMessage = nil; showingError = false }
            }
        }
        .padding(14)
        .frame(width: 420)
    }
}


/// The three error alerts of the library window, apart from its body so that the compiler can type-check
/// the long chain of modifiers in time on slower machines.
private struct ErrorAlerts: ViewModifier {
    @ObservedObject var model: AppModel
    @Binding var actionError: String?
    @Binding var importError: String?

    private func binding(_ value: Binding<String?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }

    func body(content: Content) -> some View {
        let provisioning: Binding<String?> = Binding(get: { model.provisioningError }, set: { model.provisioningError = $0 })
        content
            .alert("That didn’t work", isPresented: binding($actionError)) {
                Button("OK") { actionError = nil }
            } message: { Text(actionError ?? "") }
            .alert("The system could not be set up", isPresented: binding(provisioning)) {
                Button("OK") { model.provisioningError = nil }
            } message: { Text(model.provisioningError ?? "") }
            .alert("That can’t be imported", isPresented: binding($importError)) {
                Button("OK") { importError = nil }
            } message: { Text(importError ?? "") }
    }
}
