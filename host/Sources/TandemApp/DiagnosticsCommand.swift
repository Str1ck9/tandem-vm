import AppKit
import EngineQEMU
import NetHelperClient
import VMCore

/// Help > Collect Diagnostics…: one zip for support, saved where the user chooses (the Desktop by default).
@MainActor
enum DiagnosticsCommand {
    /// Facts only the app knows, for system.txt.
    nonisolated static func extraInfo() -> [String: String] {
        let info = Bundle.main.infoDictionary ?? [:]
        var extra: [String: String] = [:]
        extra["Tandem"] = "\(info["CFBundleShortVersionString"] as? String ?? "?") (build \(info["CFBundleVersion"] as? String ?? "?"), \(info["TandemCommit"] as? String ?? "?"))"
        extra["QEMU"] = (try? QEMUToolchain.locate()).map { $0.qemuVersion + ($0.isPatchedBuild ? " (Tandem build)" : "") } ?? "not found"
        if NetHelper.isInstalled, let helper = try? NetHelper.info() {
            extra["Helper"] = "protocol \(helper.version), \(helper.features.joined(separator: ", "))"
        } else {
            extra["Helper"] = "not installed"
        }
        return extra
    }

    /// `then` gets the zip once it is written and shown in Finder (the crash-report prompt opens the
    /// report page then). Not called when the user cancels or collecting fails.
    static func run(library: VMLibrary?, then: ((URL) -> Void)? = nil) {
        guard let library else { return }
        let panel = NSSavePanel()
        panel.title = "Collect Diagnostics"
        panel.message = Diagnostics.contentsDescription
        panel.prompt = "Collect"
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH.mm"
        panel.nameFieldStringValue = "Tandem Diagnostics \(formatter.string(from: Date())).zip"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task.detached {
            let result = Result { try Diagnostics.collect(library: library, extraInfo: extraInfo(), to: url) }
            await MainActor.run {
                switch result {
                case .success(let zip):
                    NSWorkspace.shared.activateFileViewerSelecting([zip])
                    then?(zip)
                case .failure(let error):
                    let alert = NSAlert()
                    alert.messageText = "The diagnostics could not be collected."
                    alert.informativeText = [error.localizedDescription, (error as? VMError)?.detail].compactMap { $0 }.joined(separator: "\n")
                    alert.runModal()
                }
            }
        }
    }
}
