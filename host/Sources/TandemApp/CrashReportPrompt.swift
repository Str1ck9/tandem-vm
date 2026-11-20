import AppKit
import VMCore

/// At launch after a crash: "Tandem quit unexpectedly last time. Send a report?" once per crash, while
/// Settings > Advanced > "Offer to send crash reports" is on. Sending is always the user's own act:
/// Tandem collects the diagnostics zip (Help > Collect Diagnostics), shows it in Finder, and opens a
/// pre-filled GitHub issue or e-mail for the user to attach it to. Nothing is uploaded by Tandem.
@MainActor
enum CrashReportPrompt {
    static var defaults: UserDefaults { .standard }

    static var offers: Bool {
        defaults.object(forKey: CrashReports.offerKey) as? Bool ?? true
    }

    static var repository: String {
        let custom = defaults.string(forKey: CrashReports.repositoryKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return custom.isEmpty ? CrashReports.defaultRepository : custom
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (build \(info["CFBundleVersion"] as? String ?? "?"))"
    }

    /// Called once at launch, a moment after the main window is up.
    static func offerIfNeeded(model: AppModel) {
        // Self-tests must never stop at a dialog (unless one points the prompt at a folder of its own).
        let env = ProcessInfo.processInfo.environment
        guard offers, SelfTest.directory == nil || env["TANDEM_CRASH_REPORTS"] != nil else { return }
        let lastSeen = defaults.object(forKey: CrashReports.lastSeenKey) as? Date
        let pending = CrashReports.pending(lastSeen: lastSeen)
        guard let newest = pending.first else {
            if lastSeen == nil { defaults.set(Date(), forKey: CrashReports.lastSeenKey) }
            return
        }
        // Asked once per crash, whatever the answer.
        defaults.set(newest.date, forKey: CrashReports.lastSeenKey)
        let summary = CrashReports.summary(of: newest)

        let alert = NSAlert()
        alert.messageText = "Tandem quit unexpectedly last time. Send a report?"
        var text = "Nothing is sent by itself. Tandem collects its diagnostics (logs and crash reports, without passwords, disks or your files), shows the file in Finder, and opens a report for you to attach it to and send."
        if let summary { text += "\n\nCrash: \(summary.exception)" + (pending.count > 1 ? " (and \(pending.count - 1) more since you last saw this)" : "") }
        alert.informativeText = text
        alert.addButton(withTitle: "Report on GitHub…")
        alert.addButton(withTitle: "Report by E-mail…")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t ask again"
        NSApp.activate(ignoringOtherApps: true)
        let answer = alert.runModal()
        if alert.suppressionButton?.state == .on { defaults.set(false, forKey: CrashReports.offerKey) }
        switch answer {
        case .alertFirstButtonReturn:
            send(model: model) { CrashReports.issueURL(repository: repository, summary: summary, appVersion: appVersion) }
        case .alertSecondButtonReturn:
            send(model: model) { CrashReports.mailURL(summary: summary, appVersion: appVersion) }
        default:
            break
        }
    }

    /// Collects the diagnostics (the user picks where, as with Help > Collect Diagnostics), then opens the
    /// page or e-mail. Without a library, only the page.
    private static func send(model: AppModel, url: @escaping () -> URL?) {
        let open = {
            guard let target = url() else {
                let alert = NSAlert()
                alert.messageText = "The report page could not be opened."
                alert.informativeText = "Check the repository address under Settings > Advanced: \(repository)"
                alert.runModal()
                return
            }
            NSWorkspace.shared.open(target)
        }
        guard let library = model.vmLibrary else { open(); return }
        DiagnosticsCommand.run(library: library, then: { _ in open() })
    }
}
