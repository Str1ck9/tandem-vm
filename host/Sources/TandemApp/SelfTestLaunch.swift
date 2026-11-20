import AppKit
import GuestLink
import VMCore

/// Self-test for launching Windows programs from the Mac (see `LaunchPipeline.swift`).
///
///   TANDEM_SNAPSHOT_LAUNCH           name of a Windows VM (a disposable one: it is started, suspended and shut down)
///   TANDEM_SNAPSHOT_LAUNCH_PROGRAMS  "Notepad;LibreOffice Writer": programs to make launchers for (default "Notepad")
///   TANDEM_SNAPSHOT_LAUNCH_SHARE     Mac folder to share with the VM; it gets test documents (default <library>/share)
///   TANDEM_SNAPSHOT_LAUNCH_KEEP      "launchers": keep the launchers; "running": also leave the VM running in Seamless Mode
///
/// The trial uses the real entry point, `open -a <launcher> <document>`, three times: with the VM shut
/// down (cold start), with it suspended (resume), and with a document outside the shared folder (error).
extension SelfTest {
    private static func wait(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    private static func until(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() { if Date() > deadline { return false }; await wait(0.25) }
        return true
    }

    /// Runs `/usr/bin/open` the way Finder's Open With does.
    private static func open(_ session: VMSession, _ launcher: URL, _ documents: [URL]) -> Int32 {
        session.launches.lastError = "not started"
        let result = try? ToolRun.run(URL(fileURLWithPath: "/usr/bin/open"), ["-a", launcher.path] + documents.map(\.path),
                                      timeout: ToolRun.Limit.quick, output: .discard, errors: .discard)
        return result?.status ?? -1
    }

    /// Waits for the launch that `open` set off to start and to finish; returns how long it took.
    private static func finishLaunch(_ session: VMSession, began: Date) async -> Int {
        // The pipeline replaces "not started" with nil or the failure when it is done.
        _ = await until(VMSession.guestToolsTimeout + 400) { session.launches.lastError != "not started" && session.launchStatus == nil }
        await wait(1)
        return Int(Date().timeIntervalSince(began))
    }

    private static func report(_ session: VMSession, _ tag: String) {
        let windows = session.openGuestWindows.map { "“\($0.title)”\($0.active ? "*" : "")" }.joined(separator: ", ")
        let key = NSApp.keyWindow
        print("launch[\(tag)]: state=\(session.state.rawValue) seamless=\(session.isSeamless) error=\(session.launches.lastError ?? "none") windows=[\(windows)] keyWindow=\(key.map { "\(type(of: $0)) “\($0.title)”" } ?? "none") appActive=\(NSApp.isActive)")
        session.seamless?.debugDump(to: directory, tag: "launch-" + tag).forEach { print($0) }
    }

    private static func memory(_ session: VMSession) -> String {
        let text = (try? ToolRun.run(URL(fileURLWithPath: "/bin/ps"), ["-axo", "rss=,command="], timeout: ToolRun.Limit.quick))?.outputText ?? ""
        let marker = session.bundle.url.lastPathComponent
        let rss = text.split(separator: "\n").filter { $0.contains("qemu-system") && $0.contains(marker) }
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") }.reduce(0, +)
        return rss == 0 ? "no QEMU process" : "QEMU \(rss / 1024) MiB"
    }

    static func launchTrial(_ model: AppModel, vm name: String) async {
        let env = ProcessInfo.processInfo.environment
        guard let session = model.sessions.first(where: { $0.config.name == name }) else { print("launch: no VM named \(name)"); return }
        guard let root = model.vmLibrary?.rootDirectory else { return }
        let share = URL(fileURLWithPath: env["TANDEM_SNAPSHOT_LAUNCH_SHARE"] ?? root.appendingPathComponent("share").path, isDirectory: true)
        let wanted = (env["TANDEM_SNAPSHOT_LAUNCH_PROGRAMS"] ?? "Notepad").split(separator: ";").map(String.init)
        let fm = FileManager.default
        try? fm.createDirectory(at: share.appendingPathComponent("sub"), withIntermediateDirectories: true)
        // New names every run: Notepad remembers what it had open, and would ask about a file that changed under it.
        let run = String(UUID().uuidString.prefix(4)).lowercased()
        let documents = ["cold start \(run).txt", "after resume \(run).txt", "third \(run).txt"].map { share.appendingPathComponent("sub").appendingPathComponent($0) }
        for document in documents { try? Data("Opened from the Mac: \(document.lastPathComponent)\r\n".utf8).write(to: document) }
        let outside = fm.temporaryDirectory.appendingPathComponent("tandem-not-shared-\(UUID().uuidString.prefix(6)).txt")
        try? Data("not shared\r\n".utf8).write(to: outside)
        defer { try? fm.removeItem(at: outside) }
        model.selection = session.id

        // 0. Share the folder (the VM is off) and make the launchers, which needs the guest once.
        do { try session.share(folder: share) } catch { print("launch: share failed: \(error.localizedDescription)") }
        print("launch: shared folders \(session.config.sharedFolders.map { "\($0.name)=\($0.hostPath)" })")
        session.start()
        guard await until(VMSession.guestToolsTimeout, { !session.guestPrograms.isEmpty }) else { print("launch: the guest never listed its programs"); await session.forceStopAndWait(); return }
        print("launch: guest tools capabilities \(session.agent?.capabilities ?? 0), \(session.guestPrograms.count) programs")
        var launchers: [(program: GuestProgram, url: URL)] = []
        for programName in wanted {
            guard let program = session.guestPrograms.first(where: { $0.name.caseInsensitiveCompare(programName) == .orderedSame }) else { print("launch: no program named \(programName)"); continue }
            do {
                let url = try await session.addToMac(program)
                let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
                let types = ((info["CFBundleDocumentTypes"] as? [[String: Any]])?.first?["CFBundleTypeExtensions"] as? [String]) ?? []
                let icon = url.appendingPathComponent("Contents/Resources/icon.icns")
                print("launch: launcher \(url.path) id=\(info["CFBundleIdentifier"] ?? "?") types=\(types.count) [\(types.prefix(12).joined(separator: " "))] icon=\((try? fm.attributesOfItem(atPath: icon.path)[.size] as? Int) ?? 0) bytes")
                launchers.append((program, url))
            } catch { print("launch: could not make a launcher for \(programName): \(error.localizedDescription)") }
        }
        guard let first = launchers.first else { await session.forceStopAndWait(); return }
        // What Finder's Open With would offer for a text file: the launchers that claim its type.
        let offered = NSWorkspace.shared.urlsForApplications(toOpen: documents[0]).filter { $0.path.hasPrefix(MacApps.root.path) }.map(\.lastPathComponent)
        print("launch: Open With for \(documents[0].lastPathComponent) offers these launchers: \(offered)")
        session.stop()
        _ = await until(180) { !session.state.isActive }
        print("launch: VM is \(session.statusLabel); \(memory(session))")
        await wait(3)

        // 1. Cold start: the VM is shut down.
        var began = Date()
        print("launch[cold]: open exit \(open(session, first.url, [documents[0]]))")
        print("launch[cold]: took \(await finishLaunch(session, began: began)) s; \(memory(session))")
        report(session, "cold")
        // Keyboard and a dialog: Ctrl+O must reach the window that came forward and bring Notepad's Open
        // dialog, a window of its own; Escape closes it. (Nothing is typed into the document: Notepad
        // would keep the change and ask about it when Windows shuts down.)
        await wait(2)
        session.sendKeys([0x1D, 0x18]); await wait(4)
        report(session, "dialog")
        session.sendKeys([0x01]); await wait(1.5)

        // 2. Resume: suspend the VM (its windows go), then open another document.
        session.suspend()
        _ = await until(120) { !session.state.isActive && session.isSuspended && session.statusLabel == "Suspended" }
        print("launch: VM is \(session.statusLabel); \(memory(session))")
        await wait(3)
        began = Date()
        print("launch[resume]: open exit \(open(session, first.url, [documents[1]]))")
        print("launch[resume]: took \(await finishLaunch(session, began: began)) s; \(memory(session))")
        report(session, "resume")

        // 3. A document that is not shared: a clear error, nothing opened.
        began = Date()
        print("launch[unshared]: open exit \(open(session, first.url, [outside]))")
        print("launch[unshared]: took \(await finishLaunch(session, began: began)) s")
        report(session, "unshared")

        // 4. Every other launcher: once with no document, once with the third document.
        for launcher in launchers.dropFirst() {
            began = Date()
            print("launch[\(launcher.program.name)]: open exit \(open(session, launcher.url, []))")
            print("launch[\(launcher.program.name)]: took \(await finishLaunch(session, began: began)) s")
            await wait(4)
            report(session, launcher.program.name)
            began = Date()
            print("launch[\(launcher.program.name) + document]: open exit \(open(session, launcher.url, [documents[2]]))")
            print("launch[\(launcher.program.name) + document]: took \(await finishLaunch(session, began: began)) s")
            await wait(4)
            report(session, launcher.program.name + "-document")
        }
        print("launch: launchers running: \(NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier?.hasPrefix(TandemIdentity.guestApp + ".") == true }.compactMap(\.localizedName))")

        // Spotlight: has the system indexed the launchers? (It does not index hidden folders, such as a test library in .cache.)
        let found = (try? await ToolRun.run(URL(fileURLWithPath: "/usr/bin/mdfind"),
                                      ["-onlyin", MacApps.root.path, "kMDItemContentType == 'com.apple.application-bundle'"],
                                      timeout: ToolRun.Limit.quick))?.outputText ?? ""
        let listed = found.split(separator: "\n").map { URL(fileURLWithPath: String($0)).lastPathComponent }
        print("launch: Spotlight lists under \(MacApps.root.path): \(listed)")

        let keep = env["TANDEM_SNAPSHOT_LAUNCH_KEEP"]
        if keep == "running" { print("launch: leaving the VM running"); return }
        if keep == nil { for launcher in launchers { session.removeFromMac(programID: launcher.program.id) } }
        else { print("launch: keeping the launchers") }
        // Close what the trial opened, then shut down.
        for window in session.openGuestWindows { session.link.windowAction(.close, window: window.id); await wait(0.4) }
        await wait(2)
        session.stop()
        _ = await until(240) { !session.state.isActive }
        if session.state.isActive { await session.forceStopAndWait() }
        print("launch: final state=\(session.state.rawValue)")
    }
}
