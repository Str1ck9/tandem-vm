import AppKit
import GuestLink
import SwiftUI
import VMCore

/// "Windows Applications on the Mac": the guest's programs, each with a switch that keeps a launcher
/// for it in the Mac's Applications folder (Dock, Spotlight, Finder's Open With).
/// Self-contained, so a configuration pane can show the same view.
struct MacAppsView: View {
    @ObservedObject var session: VMSession
    @State private var search = ""
    @State private var working: Set<String> = []
    @State private var errorText: String?

    private var programs: [GuestProgram] {
        let all = session.guestPrograms
        guard !search.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    /// Launchers whose program the running guest no longer lists, or all of them while the VM is off.
    private var orphans: [(id: String, url: URL)] {
        let listed = Set(session.guestPrograms.map(\.id))
        return session.macLaunchers.filter { !listed.contains($0.key) }.map { ($0.key, $0.value) }
            .sorted { $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keep a Windows program on the Mac to pin it to the Dock, find it with Spotlight, and choose it under Open With in Finder. Opening it starts or resumes “\(session.config.name)” by itself.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if session.guestPrograms.isEmpty {
                Text(session.state == .running ? "Waiting for Windows to list its programs…" : "Start “\(session.config.name)” to choose from its programs.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 8)
            } else {
                TextField("Search", text: $search).textFieldStyle(.roundedBorder)
            }
            List {
                ForEach(programs) { program in row(program) }
                if !orphans.isEmpty {
                    Section(session.guestPrograms.isEmpty ? "On the Mac" : "On the Mac, no longer in Windows") {
                        ForEach(orphans, id: \.id) { orphan in
                            HStack {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: orphan.url.path)).resizable().frame(width: 20, height: 20)
                                Text(orphan.url.deletingPathExtension().lastPathComponent)
                                Spacer()
                                Button("Remove") { session.removeFromMac(programID: orphan.id) }
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 220)
            if let errorText { Text(errorText).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Text("\(session.macLaunchers.count) on the Mac").foregroundStyle(.secondary)
                Spacer()
                Button("Show in Finder") {
                    let folder = MacApps.directory(vmName: session.config.name)
                    NSWorkspace.shared.open(FileManager.default.fileExists(atPath: folder.path) ? folder : MacApps.root)
                }
                .disabled(session.macLaunchers.isEmpty)
            }
        }
        .onAppear { session.refreshMacLaunchers() }
    }

    private func row(_ program: GuestProgram) -> some View {
        HStack {
            if let icon = session.image(session.icon(for: program), points: 20) { Image(nsImage: icon) }
            else { Image(systemName: "app").frame(width: 20, height: 20) }
            Text(program.name).lineLimit(1)
            Spacer()
            if working.contains(program.id) { ProgressView().controlSize(.small) }
            Toggle("On the Mac", isOn: Binding(
                get: { session.macLaunchers[program.id] != nil },
                set: { on in set(program, on) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .disabled(working.contains(program.id))
                .accessibilityLabel("Keep \(program.name) on the Mac")
        }
    }

    private func set(_ program: GuestProgram, _ on: Bool) {
        errorText = nil
        guard on else { session.removeFromMac(programID: program.id); return }
        working.insert(program.id)
        Task {
            do { try await session.addToMac(program) }
            catch { errorText = [error.localizedDescription, (error as? VMError)?.detail].compactMap { $0 }.joined(separator: " ") }
            working.remove(program.id)
        }
    }
}

struct MacAppsWindow: View {
    @ObservedObject var session: VMSession
    var body: some View {
        MacAppsView(session: session)
            .padding(16)
            .frame(minWidth: 460, idealWidth: 520, minHeight: 420, idealHeight: 560)
            .navigationTitle("Windows Applications on the Mac — \(session.config.name)")
    }
}
