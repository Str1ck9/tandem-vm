import AppKit
import SwiftUI
import VMCore

/// Configuration > Options > Sharing: everything the VM shares with the Mac, in one panel.
///
/// Folders, clipboard direction, network exposure and USB access are one value (`SharingProfile`).
/// While the VM is stopped the panel edits the draft like every other pane, and Save writes it. While
/// the VM runs, a change is applied at once through the session (the same path `vmctl sharing` takes),
/// because taking access away must not wait for a shutdown.
struct SharingPane: View {
    @ObservedObject var session: VMSession
    @Binding var draft: VMConfig
    @State private var errorText: String?

    private var live: Bool { session.state.isActive }
    /// A suspended VM expects the same devices when it resumes, so nothing may change.
    private var frozen: Bool { session.isSuspended && !session.state.isActive }
    private var kind: String { draft.engine == .vz ? "virtiofs" : (draft.guestOS == .linux ? "9p" : "webdav") }
    /// Folders can be added and removed while this VM runs.
    private var foldersChangeLive: Bool { kind != "9p" }

    /// The profile shown. Writing it applies it at once when the VM runs.
    private var profile: Binding<SharingProfile> {
        Binding(get: { draft.sharing }, set: { new in
            guard new != draft.sharing else { return }
            draft.sharing = new
            guard live else { return }
            do { try session.setSharing(new); errorText = nil }
            catch { errorText = describe(error) }
        })
    }

    private func describe(_ error: Error) -> String {
        [error.localizedDescription, (error as? VMError)?.detail].compactMap { $0 }.joined(separator: " ")
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    var body: some View {
        Form {
            Section {
                presetRow
                if live {
                    Label("The virtual machine is running: changes here apply immediately.", systemImage: "bolt.fill")
                        .font(.callout).foregroundStyle(.secondary)
                } else if frozen {
                    Label("The virtual machine is suspended. Resume it to change what it shares.", systemImage: "lock")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let errorText { Text(errorText).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                if let pending = session.sharingNote, live { Label(pending, systemImage: "arrow.clockwise").font(.callout).foregroundStyle(.orange) }
            }
            Section("Mac folders") {
                Toggle("Share my home folder", isOn: Binding(get: { homeIndex != nil }, set: { setHome($0) }))
                ForEach(Array(profile.wrappedValue.folders.enumerated()), id: \.offset) { index, folder in
                    if folder.hostPath != Self.homePath { folderRow(folder, index: index) }
                }
                ForEach(temporaryFolders, id: \.name) { item in temporaryRow(item.folder) }
                HStack {
                    Button("Add Folder…") { addFolders(temporary: false) }
                        .disabled(live && !foldersChangeLive)
                    Button("Share Until Shutdown…") { addFolders(temporary: true) }
                        .disabled(!live || !foldersChangeLive)
                        .help("Share a folder that stops being shared when the virtual machine shuts down")
                }
                note(folderNote)
            }
            Section("Clipboard") {
                Picker("Copy and paste:", selection: profile.clipboard) {
                    ForEach(ClipboardSharing.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                note("Text, and files dragged onto the virtual machine’s windows or sent back with Send to > Mac (Windows). Needs the guest tools running in the virtual machine.")
            }
            Section("Network") {
                Toggle("Allow network access", isOn: profile.network.outbound)
                Toggle("Allow connections to the virtual machine", isOn: profile.network.inbound)
                Toggle("Allow bridged networking", isOn: profile.network.bridged)
                ForEach(SharingPolicy(profile: profile.wrappedValue).networkNotes(for: draft.network), id: \.self) { line in
                    Label(line, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                }
                note("Network access lets the virtual machine reach the Internet, this Mac and its network. Connections to it are port forwards and published services. Bridged networking makes it a device of its own on the Mac’s network. Changes take effect the next time the virtual machine starts.")
            }
            Section("USB") {
                Toggle("Allow Mac USB devices to be connected", isOn: profile.usb)
                note(draft.engine == .qemu
                     ? "Devices are handed over one at a time from Devices > USB. Turning this off takes them back at once."
                     : "USB devices cannot be connected to this kind of virtual machine.")
            }
            Section("Commands from the Mac") {
                Picker("Who may run commands:", selection: profile.commands) {
                    ForEach(CommandAccess.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                note("The `tandem exec` command and the AI tool “guest_exec” run commands inside this virtual machine through its guest tools. AI tools also need “Allow AI tools (MCP) to control Tandem” in Tandem’s settings, and an AI level of Operate or Full below.")
            }
            Section("AI tools (MCP)") {
                Picker("AI level:", selection: profile.aiTier) {
                    ForEach(AITier.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                note(profile.wrappedValue.aiTier.summary + " Deleting snapshots is never offered to AI tools. Every call an AI tool makes is listed under Tandem > Settings > Advanced > AI activity.")
                if profile.wrappedValue.aiTier == .full {
                    Label("Full lets an AI tool revert snapshots, clone, power off and reset this virtual machine, and share folders it can change. Mark a baseline snapshot in Snapshot Manager so that it can only go back to that one.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(frozen)
        // Changes made elsewhere (vmctl) while the VM runs show up here.
        .onChange(of: session.sharingPolicy.profile) { _, new in if live, draft.sharing != new { draft.sharing = new } }
    }

    // MARK: Presets

    private var presetRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                switch profile.wrappedValue.preset {
                case .restricted:
                    Label("Restricted", systemImage: "lock.shield.fill").font(.headline)
                    note("For a disposable virtual machine: no folders, no clipboard, no USB, no connections in. It keeps Internet access.")
                case .default:
                    Label("Nothing shared yet", systemImage: "circle.dashed").font(.headline)
                    note("Everything is allowed and no folders are shared.")
                case nil:
                    Label("Custom", systemImage: "slider.horizontal.3").font(.headline)
                    note("\(profile.wrappedValue.folders.count) folder\(profile.wrappedValue.folders.count == 1 ? "" : "s") shared; clipboard: \(profile.wrappedValue.clipboard.label).")
                }
            }
            Spacer()
            if profile.wrappedValue.preset != .restricted {
                Button("Restrict…") { confirmRestrict() }.help("Stop sharing everything with this virtual machine")
            } else {
                Button("Allow Sharing") { profile.wrappedValue = .default }.help("Allow the clipboard, USB devices and connections again")
            }
        }
    }

    private func confirmRestrict() {
        let alert = NSAlert()
        alert.messageText = "Restrict “\(draft.name)”?"
        alert.informativeText = "Its shared folders are removed from the list, and the clipboard, USB devices, port forwards, published services and bridged networking are turned off."
            + (live ? " This takes effect now, while it is running." : "")
        alert.addButton(withTitle: "Restrict")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { profile.wrappedValue = .restricted }
    }

    // MARK: Folders

    private static let homePath = FileManager.default.homeDirectoryForCurrentUser.path
    private var homeIndex: Int? { profile.wrappedValue.folders.firstIndex { $0.hostPath == Self.homePath } }
    private var temporaryFolders: [SharingPolicy.Folder] { live ? session.sharingPolicy.folders.filter(\.temporary) : [] }

    private var folderNote: String {
        switch kind {
        case "webdav": return "Folders appear in Windows as drive Z: (“Mac”). A read-only folder cannot be changed from the virtual machine, whatever it tries. Needs the guest tools."
        case "9p": return "Folders appear in the virtual machine under /media/mac. They are attached when it starts: adding one needs a restart; taking one away while it runs removes it at once and disconnects the others until then."
        default: return draft.guestOS == .macos
            ? "Folders appear in the Finder of the virtual machine under “My Shared Files”."
            : "Folders appear in the virtual machine under /media/mac. Needs the guest tools."
        }
    }

    private func setHome(_ on: Bool) {
        var new = profile.wrappedValue
        if let index = homeIndex { if !on { new.folders.remove(at: index) } }
        else if on { new.folders.insert(SharedFolder(hostPath: Self.homePath, name: SharingEdit.uniqueName("Home", taken: new.folders.map(\.name))), at: 0) }
        profile.wrappedValue = new
    }

    private func folderRow(_ folder: SharedFolder, index: Int) -> some View {
        HStack {
            Image(systemName: "folder")
            VStack(alignment: .leading, spacing: 1) {
                Text(folder.name)
                Text(folder.hostPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Picker("Access", selection: Binding(get: { profile.wrappedValue.folders[safe: index]?.readOnly ?? true },
                                                 set: { value in
                var new = profile.wrappedValue
                guard new.folders.indices.contains(index) else { return }
                new.folders[index].readOnly = value
                profile.wrappedValue = new
            })) {
                Text("Read & Write").tag(false)
                Text("Read only").tag(true)
            }
            .labelsHidden().fixedSize()
            Button {
                var new = profile.wrappedValue
                guard new.folders.indices.contains(index) else { return }
                new.folders.remove(at: index)
                profile.wrappedValue = new
            } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless).help("Stop sharing this folder").accessibilityLabel("Stop sharing \(folder.name)")
        }
    }

    private func temporaryRow(_ folder: SharedFolder) -> some View {
        HStack {
            Image(systemName: "folder.badge.gearshape")
            VStack(alignment: .leading, spacing: 1) {
                Text(folder.name)
                Text(folder.hostPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(folder.readOnly ? "Read only" : "Read & Write").foregroundStyle(.secondary)
            Text("Until shutdown").font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                .background(.orange.opacity(0.2), in: Capsule())
            Button {
                do { try session.unshare(folder.name); errorText = nil } catch { errorText = describe(error) }
            } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless).help("Stop sharing this folder now").accessibilityLabel("Stop sharing \(folder.name)")
        }
    }

    private func addFolders(temporary: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = temporary ? "Share Until Shutdown" : "Share"
        let readOnly = NSButton(checkboxWithTitle: "Read only", target: nil, action: nil)
        panel.accessoryView = readOnly
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK else { return }
        var new = profile.wrappedValue
        for url in panel.urls where !session.sharingPolicy.folders.contains(where: { $0.folder.hostPath == url.path })
            && !new.folders.contains(where: { $0.hostPath == url.path }) {
            if temporary {
                do { try session.shareTemporarily(path: url.path, readOnly: readOnly.state == .on); errorText = nil }
                catch { errorText = describe(error) }
            } else {
                let taken = new.folders.map(\.name) + session.sharingPolicy.folders.map(\.name)
                new.folders.append(SharedFolder(hostPath: url.path, name: SharingEdit.uniqueName(url.lastPathComponent, taken: taken), readOnly: readOnly.state == .on))
            }
        }
        if !temporary { profile.wrappedValue = new }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
