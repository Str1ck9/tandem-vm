import AppKit
import ServiceManagement
import SwiftUI
import VMCore

/// Tandem > Uninstall Tandem…: shows what goes (with sizes) and does it. The VM library stays unless the
/// user switches it on and confirms a second time with its path in front of them; VMs go to the Trash.
@MainActor
enum Uninstaller {
    static func plan(model: AppModel) -> UninstallPlan? {
        guard let library = model.vmLibrary else { return nil }
        let testLibrary = ProcessInfo.processInfo.environment["TANDEM_HOME"] != nil
        let app = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL : nil
        return UninstallPlan.make(.init(
            libraryRoot: library.rootDirectory, vmsDirectory: library.vmsDirectory,
            bundles: model.sessions.map { $0.bundle.url }, isTestLibrary: testLibrary,
            home: FileManager.default.homeDirectoryForCurrentUser,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? TandemIdentity.app,
            app: app, commandLineLink: ControlAPI.installedLink, macAppsFolder: MacApps.root))
    }

    /// Carries the plan out (or, with `dryRun`, only says what it would do). Returns one line per step.
    /// The app itself goes last; the caller quits afterwards.
    static func perform(_ plan: UninstallPlan, caches: Bool, library: Bool, dryRun: Bool) -> [String] {
        var log: [String] = []
        let fm = FileManager.default
        func step(_ text: String, _ work: () throws -> Void) {
            if dryRun { log.append("would: " + text); return }
            do { try work(); log.append("done: " + text) } catch { log.append("failed: \(text): \(error.localizedDescription)") }
        }
        let size = { (item: UninstallPlan.Item) in item.size.map { " (" + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) + ")" } ?? "" }

        // 1. The helper and everything outside the library (not for a test library).
        let system = plan.items(in: .system)
        if system.contains(where: { $0.path == "launchd:system/\(TandemIdentity.helper)" }) {
            if HelperService.isAvailable, HelperService.service.status != .notRegistered {
                step("unregister the in-app helper (SMAppService)") { try HelperService.unregister() }
            } else {
                log.append("skip: the in-app helper is not registered from this copy")
            }
        }
        let rootOwned = system.filter(\.needsAdministrator)
        if !rootOwned.isEmpty {
            let paths = rootOwned.map(\.path)
            step("remove with your administrator password: launchd job \(TandemIdentity.scriptHelper), " + paths.joined(separator: ", ")) {
                try removeAsAdministrator(paths)
            }
        }
        for item in system where !item.needsAdministrator && !item.toTrash && !item.path.hasPrefix("launchd:") {
            step("remove \(item.title): \(item.path)\(size(item))") {
                if item.title == "Settings", let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
                if fm.fileExists(atPath: item.path) || (try? fm.destinationOfSymbolicLink(atPath: item.path)) != nil { try fm.removeItem(atPath: item.path) }
            }
        }

        // 2. Caches.
        if caches {
            for item in plan.items(in: .caches) { step("remove \(item.title): \(item.path)\(size(item))") { try fm.removeItem(atPath: item.path) } }
        } else {
            log.append("keep: downloads and caches (\(ByteCountFormatter.string(fromByteCount: plan.size(of: .caches), countStyle: .file)))")
        }

        // 3. The VM library, only when asked.
        if library {
            for item in plan.items(in: .library) {
                if item.toTrash {
                    step("move \(item.title) to the Trash: \(item.path)\(size(item))") { try fm.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil) }
                } else {
                    step("remove \(item.title): \(item.path)") { try fm.removeItem(atPath: item.path) }
                }
            }
            for folder in plan.vmsDirectories + [plan.libraryRoot] {
                step("remove \(folder.path) if empty") {
                    let left = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0 != ".DS_Store" }
                    if left.isEmpty, fm.fileExists(atPath: folder.path) { try fm.removeItem(at: folder) }
                }
            }
        } else {
            let vms = plan.items(in: .library).filter(\.toTrash)
            log.append("keep: the VM library, \(vms.count) VMs in \(plan.vmsDirectories.map(\.path).joined(separator: " and "))")
        }
        for path in plan.keptVMs { log.append("keep: VM outside the library: \(path)") }

        // 4. The app.
        if let app = system.first(where: \.toTrash) {
            step("move the app to the Trash: \(app.path)") { try fm.trashItem(at: URL(fileURLWithPath: app.path), resultingItemURL: nil) }
        }
        return log
    }

    /// One administrator prompt: stops the older script helper and removes root-owned files.
    private static func removeAsAdministrator(_ paths: [String]) throws {
        func shellQuoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = [TandemIdentity.scriptHelper, TandemIdentity.helper].map { "launchctl bootout system/\($0) 2>/dev/null; " }.joined() + "rm -rf "
            + paths.map(shellQuoted).joined(separator: " ")
        let source = "do shell script \"\(command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with prompt \"Tandem wants to remove its helper's files.\" with administrator privileges"
        let result = try ToolRun.run(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", source],
                                     timeout: ToolRun.Limit.userPrompt, output: .discard)
        let text = result.errorText
        guard result.succeeded else {
            throw VMError(text.contains("-128") ? "Cancelled." : "Could not remove the helper's files.", detail: text)
        }
    }
}

struct UninstallView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var plan: UninstallPlan?
    @State private var removeCaches = true
    @State private var removeLibrary = false
    @State private var confirmingLibrary = false
    @State private var confirmingUninstall = false
    @State private var log: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Uninstall Tandem").font(.title.weight(.semibold))
            if let plan {
                if plan.isTestLibrary {
                    Text("A test library is in use (TANDEM_HOME), so only its folder is considered; the helper, settings and app are left alone.")
                        .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                section("Always removed", items: plan.items(in: .system), note: "The helper is switched off and unregistered; files owned by the system need your administrator password once. The app goes to the Trash.")
                Toggle(isOn: $removeCaches) { Text("Downloads and caches — \(bytes(plan.size(of: .caches)))").font(.headline) }
                list(plan.items(in: .caches))
                Toggle(isOn: Binding(get: { removeLibrary }, set: { on in if on { confirmingLibrary = true } else { removeLibrary = false } })) {
                    Text("Also move my virtual machines to the Trash — \(bytes(plan.size(of: .library)))").font(.headline)
                }
                Text("Off: your VMs stay in \(plan.vmsDirectories.map(\.path).joined(separator: " and ")) and a later Tandem finds them again.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if removeLibrary { list(plan.items(in: .library)) }
                if !plan.keptVMs.isEmpty {
                    Text("Kept in any case (outside the library): " + plan.keptVMs.joined(separator: ", ")).font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Text("The VM library could not be read.")
            }
            if !log.isEmpty {
                ScrollView { Text(log.joined(separator: "\n")).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(height: 120)
            }
            if model.runningCount > 0 {
                Text("Shut down the running virtual machines first.").foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismissWindow(id: "uninstall") }.keyboardShortcut(.cancelAction)
                Button("Uninstall…", role: .destructive) { confirmingUninstall = true }
                    .disabled(plan == nil || model.runningCount > 0)
            }
        }
        .padding(22)
        .frame(width: 620)
        .onAppear { plan = Uninstaller.plan(model: model) }
        .alert("Move your virtual machines to the Trash?", isPresented: $confirmingLibrary) {
            Button("Move VMs to the Trash Too", role: .destructive) { removeLibrary = true }
            Button("Keep My VMs", role: .cancel) { removeLibrary = false }
        } message: {
            let vms = plan?.items(in: .library).filter(\.toTrash) ?? []
            Text("\(vms.count) virtual machines (\(bytes(plan?.size(of: .library) ?? 0))) in:\n\(plan?.vmsDirectories.map(\.path).joined(separator: "\n") ?? "")\n\nTheir disks, snapshots and settings go to the Trash with them. Empty the Trash only when you are sure.")
        }
        .alert("Uninstall Tandem?", isPresented: $confirmingUninstall) {
            Button("Uninstall", role: .destructive) { uninstall() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removeLibrary ? "The helper, settings, caches, the app and your virtual machines are removed." : "The helper, settings\(removeCaches ? ", caches" : "") and the app are removed. Your virtual machines stay.")
        }
    }

    private func uninstall() {
        guard let plan, model.runningCount == 0 else { return }
        log = Uninstaller.perform(plan, caches: removeCaches, library: removeLibrary, dryRun: false)
        if !plan.isTestLibrary, plan.items(in: .system).contains(where: \.toTrash) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSApp.terminate(nil) }
        }
    }

    private func section(_ title: String, items: [UninstallPlan.Item], note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            if items.isEmpty { Text("Nothing for this library.").font(.callout).foregroundStyle(.secondary) }
            list(items)
            Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func list(_ items: [UninstallPlan.Item]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title).lineLimit(1)
                    Spacer()
                    if let size = item.size { Text(bytes(size)).monospacedDigit().foregroundStyle(.secondary) }
                }
                .font(.callout)
                .help(item.path)
            }
        }
        .padding(.leading, 20)
    }

    private func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
}
