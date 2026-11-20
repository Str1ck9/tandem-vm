import AppKit
import VMCore

/// Update trial, driven from scripts/test-update.sh with a feed of its own (TANDEM_UPDATE_FEED):
///   TANDEM_SNAPSHOT_UPDATE="settings;check;download;install"
///     settings  open Settings on the General tab, snapshot it
///     check     Tandem > Check for Updates…, print the answer, snapshot the window
///     download  download the offered update, print the answer, snapshot
///     install   install it in place of this copy and start the new one, which (with
///               TANDEM_UPDATE_TEST_PROBE, passed on as TANDEM_UPDATE_RELAUNCH_PROBE) writes its version
///               to that file and quits
@MainActor
enum SelfTestUpdate {
    static func run(_ model: AppModel, spec: String) async {
        let updates = SoftwareUpdate.shared
        for what in spec.split(separator: ";").map(String.init) {
            switch what {
            case "settings":
                NotificationCenter.default.post(name: .selfTestOpen, object: "preferences")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                SelfTest.snapshotWindows(tag: "upd-settings")
                for window in NSApp.windows where window.title.contains("General") || window.title.contains("Settings") { window.close() }
            case "check":
                updates.check(userInitiated: true)
                await settle { if case .checking = $0 { return false }; return true }
                print("selftest: update check phase=\(describe(updates.phase)) feed=\(updates.feedURL.absoluteString) current=\(updates.currentVersion)")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                SelfTest.snapshotWindows(tag: "upd-check")
            case "download":
                updates.download()
                await settle { if case .downloading = $0 { return false }; if case .available = $0 { return false }; return true }
                print("selftest: update download phase=\(describe(updates.phase))")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                SelfTest.snapshotWindows(tag: "upd-ready")
            case "install":
                print("selftest: update install from \(Bundle.main.bundlePath)")
                updates.install()
                // On success this process exits from SoftwareUpdate.relaunch.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await settle(seconds: 300) { if case .failed = $0 { return true }; if case .ready = $0 { return true }; return false }
                print("selftest: update install phase=\(describe(updates.phase))")
                SelfTest.snapshotWindows(tag: "upd-install")
            default:
                print("selftest: update: unknown step \(what)")
            }
        }
    }

    private static func settle(seconds: Double = 120, _ done: (SoftwareUpdate.Phase) -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !done(SoftwareUpdate.shared.phase) { try? await Task.sleep(nanoseconds: 200_000_000) }
    }

    static func describe(_ phase: SoftwareUpdate.Phase) -> String {
        switch phase {
        case .idle: return "idle"
        case .checking: return "checking"
        case .upToDate: return "upToDate"
        case .available(let r): return "available \(r.appVersion)"
        case .downloading(let r, let f): return "downloading \(r.appVersion) \(Int(f * 100))%"
        case .ready(let r, let url): return "ready \(r.appVersion) \(url.path)"
        case .installing(let r, let step): return "installing \(r.appVersion) \(step)"
        case .failed(let message): return "failed: \(message.replacingOccurrences(of: "\n", with: " | "))"
        }
    }
}
