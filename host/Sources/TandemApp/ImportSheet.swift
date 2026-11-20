import AppKit
import EngineQEMU
import Migration
import Provisioning
import SwiftUI
import UniformTypeIdentifiers
import VMCore

/// Remembered between imports, so the Windows installer and driver discs are chosen once.
enum ImportDefaults {
    static let windowsISOKey = "import.windowsISO"
    static let virtioISOKey = "import.virtioISO"

    static func existingPath(_ key: String) -> String {
        if let path = UserDefaults.standard.string(forKey: key), FileManager.default.fileExists(atPath: path) { return path }
        return guess(key) ?? ""
    }

    /// First-time guess, so the common case needs no file picking: look in the usual folders for a matching disc image.
    static func guess(_ key: String) -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Tandem")
        let folders = [support, home.appendingPathComponent("ISOs"), home.appendingPathComponent("Downloads")]
        let matches: (String) -> Bool = key == windowsISOKey
            ? { $0.contains("win") && $0.contains("arm64") }
            : { $0.contains("virtio-win") }
        for folder in folders {
            let names = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
            if let name = names.first(where: { $0.lowercased().hasSuffix(".iso") && matches($0.lowercased()) }) {
                return folder.appendingPathComponent(name).path
            }
        }
        return nil
    }
}

struct ImportSheet: View {
    let vm: ParallelsVM
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var fullCopy = false
    @State private var windowsISO = ImportDefaults.existingPath(ImportDefaults.windowsISOKey)
    @State private var virtioISO = ImportDefaults.existingPath(ImportDefaults.virtioISOKey)
    @State private var running = false
    @State private var progress = ""
    @State private var errorText: String?
    @State private var notes: [String]?
    @State private var host: HostFacts?

    /// What this Mac can do for the VM as it will be imported (engine as the importer chooses it).
    private var compatibility: CompatibilityReport? {
        guard let host, let os = vm.guestOS else { return nil }
        return Compatibility.evaluate(host: host, request: CompatibilityRequest(
            guestOS: os, engine: vm.kind == .macvm ? .vz : .qemu, memoryMiB: vm.memoryMiB, cpuCount: vm.cpuCount,
            neededDiskGiB: fullCopy ? Int(diskFileBytes >> 30) + 1 : nil))
    }

    private var isWindows: Bool { vm.guestOS == .windows11arm }
    private var disk: ParallelsVM.Disk? { vm.disks.first }
    private var diskFileBytes: UInt64 {
        (disk?.images ?? []).reduce(0) { $0 + (((try? FileManager.default.attributesOfItem(atPath: $1.path))?[.size] as? UInt64) ?? 0) }
    }
    private var canImport: Bool {
        vm.blockers.isEmpty && !running && (!isWindows || !windowsISO.isEmpty) && compatibility?.canProceed != false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: vm.guestOS?.symbol ?? "questionmark.square").font(.system(size: 30)).frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(notes == nil ? "Import “\(vm.name)”" : "Imported “\(name.isEmpty ? vm.name : name)”").font(.title2).bold()
                    Text(summary).foregroundStyle(.secondary)
                }
            }

            if let notes {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(notes, id: \.self) { Label($0, systemImage: "info.circle").font(.callout) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if !vm.blockers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("This VM cannot be imported yet", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).bold()
                    ForEach(vm.blockers, id: \.self) { Text($0).font(.callout) }
                }
            } else {
                Form {
                    TextField("Name", text: $name, prompt: Text(vm.name))
                    Picker("Disk", selection: $fullCopy) {
                        Text(vm.kind == .macvm ? "Clone (instant, no extra space)" : "Use the original (instant, no extra space)").tag(false)
                        Text(String(format: "Full copy (%.0f GB, independent)", Double(diskFileBytes) / 1e9)).tag(true)
                    }
                    if !fullCopy && vm.kind == .pvm {
                        Text("The Parallels VM must stay where it is and must not be started in Parallels again.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let compatibility { CompatibilityRow(report: compatibility, title: "Compatibility") }
                    if isWindows {
                        isoRow("Windows 11 ARM installer", path: $windowsISO, key: ImportDefaults.windowsISOKey, required: true)
                        isoRow("Driver disc (virtio-win)", path: $virtioISO, key: ImportDefaults.virtioISOKey, required: false)
                        Text("Windows was installed for Parallels’ hardware. The installer disc is used once to adjust its drivers; nothing is reinstalled. Without the driver disc Windows has no network and a small fixed screen.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                // Tall enough for every row; a grouped form does not grow by itself inside a stack.
                .frame(minHeight: isWindows ? 350 : (!fullCopy && vm.kind == .pvm ? 215 : 170))
                .disabled(running)
            }

            if running {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(progress.isEmpty ? "Starting…" : progress) }
            }
            if notes == nil, let compatibility { CompatibilityBlockers(report: compatibility).font(.callout) }
            if let errorText {
                Text(errorText).font(.callout).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                if notes != nil {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(running)
                    Button("Import") { startImport() }.keyboardShortcut(.defaultAction).disabled(!canImport)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .interactiveDismissDisabled(running)
        .onAppear { if host == nil { host = model.hostFacts() } }
    }

    private var summary: String {
        var parts = [vm.guestOS?.label ?? "Unsupported guest", "\(vm.cpuCount) processors", "\(vm.memoryMiB / 1024) GB memory"]
        if let disk { parts.append(String(format: "%.0f GB disk", Double(disk.sizeBytes) / 1_073_741_824)) }
        return parts.joined(separator: " · ")
    }

    private func isoRow(_ title: String, path: Binding<String>, key: String, required: Bool) -> some View {
        LabeledContent(title) {
            HStack {
                Text(path.wrappedValue.isEmpty ? (required ? "Required" : "None") : URL(fileURLWithPath: path.wrappedValue).lastPathComponent)
                    .foregroundStyle(path.wrappedValue.isEmpty ? (required ? .red : .secondary) : .primary)
                    .lineLimit(1).truncationMode(.middle)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .data]
                    panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url {
                        path.wrappedValue = url.path
                        UserDefaults.standard.set(url.path, forKey: key)
                    }
                }
            }
        }
    }

    private func startImport() {
        guard let library = model.vmLibrary else { errorText = "The VM library is not available."; return }
        errorText = nil
        running = true
        let options = ParallelsImporter.Options(
            name: name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name.trimmingCharacters(in: .whitespaces),
            copy: fullCopy,
            windowsISO: isWindows && !windowsISO.isEmpty ? URL(fileURLWithPath: windowsISO) : nil,
            virtioISO: isWindows && !virtioISO.isEmpty ? URL(fileURLWithPath: virtioISO) : nil)
        let vm = vm
        // The import blocks for seconds to minutes, so it runs off the main thread.
        Task.detached(priority: .userInitiated) {
            do {
                let result = try await ParallelsImporter.run(vm, options: options, library: library) { message in
                    Task { @MainActor in progress = message }
                }
                await MainActor.run {
                    running = false
                    notes = result.notes
                    model.imported(result.bundle)
                }
            } catch {
                await MainActor.run {
                    running = false
                    errorText = error.localizedDescription
                }
            }
        }
    }
}
