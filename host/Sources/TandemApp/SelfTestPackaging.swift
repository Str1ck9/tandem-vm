import AppKit
import VMCore

/// Packaging trial, driven from a shell:
///   TANDEM_SNAPSHOT_PACKAGING="welcome;network;uninstall"
///     welcome    open the welcome window, print its checks, snapshot it
///     network    open Settings on the Network tab (also set TANDEM_SNAPSHOT_PREFS_TAB=network), snapshot it
///     uninstall  open the Uninstall window, snapshot it, print the plan and what an uninstall would do,
///                with and without the VM library. Nothing is removed: the trial only uses the dry run.
@MainActor
enum SelfTestPackaging {
    static func run(_ model: AppModel, spec: String) async {
        for what in spec.split(separator: ";").map(String.init) {
            switch what {
            case "welcome":
                NotificationCenter.default.post(name: .selfTestOpen, object: "welcome")
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                let health = await Task.detached { HelperHealth.read() }.value
                print("selftest: welcome mode=\(health.mode) tools=\(health.tools) helper=\(health.helper) fullDiskAccess=\(health.fullDiskAccess) service=\(health.serviceStatus.map { "\($0.rawValue)" } ?? "n/a") legacy=\(health.legacyInstalled) status=\(health.status.map { "v\($0.version) \($0.features) fda=\($0.fullDiskAccess ?? "nil") fromBundle=\($0.fromBundle.map { "\($0)" } ?? "nil")" } ?? "none")")
                SelfTest.snapshotWindows(tag: "pkg-welcome")
                for window in NSApp.windows where window.title == "Welcome to Tandem" { window.close() }
            case "network":
                NotificationCenter.default.post(name: .selfTestOpen, object: "preferences")
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                SelfTest.snapshotWindows(tag: "pkg-network")
            case "uninstall":
                NotificationCenter.default.post(name: .selfTestOpen, object: "uninstall")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                SelfTest.snapshotWindows(tag: "pkg-uninstall")
                guard let plan = Uninstaller.plan(model: model) else { print("selftest: uninstall: no plan"); continue }
                print("selftest: uninstall plan test=\(plan.isTestLibrary) root=\(plan.libraryRoot.path)")
                for item in plan.items {
                    print("selftest: uninstall item [\(item.group.rawValue)] \(item.title) — \(item.path) size=\(item.size.map(String.init) ?? "-")\(item.needsAdministrator ? " admin" : "")\(item.toTrash ? " trash" : "")")
                }
                for (caches, library) in [(true, false), (true, true)] {
                    for line in Uninstaller.perform(plan, caches: caches, library: library, dryRun: true) {
                        print("selftest: uninstall dry(caches=\(caches),library=\(library)) \(line)")
                    }
                }
            default:
                print("selftest: packaging: unknown step \(what)")
            }
        }
    }
}
