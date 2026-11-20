import AppKit
import VMCore

/// Stands in the Dock for one program of a guest (see `GuestAppBundle`). It has no windows.
///
/// As a Dock tile, started by Tandem while the program has windows in Seamless Mode: choosing it asks
/// Tandem to bring the program forward; quitting it asks Tandem to close the program's windows; it ends
/// when Tandem tells it to or when Tandem itself is gone.
///
/// As a launcher, kept by the user (Dock, Spotlight, Finder's Open With): opening it, or opening
/// documents with it, leaves a launch request for Tandem and starts Tandem if it is not running. Tandem
/// starts or resumes the VM, opens the program and documents, and from then on treats the launcher as
/// the program's Dock tile.
final class StandIn: NSObject, NSApplicationDelegate {
    private let info = Bundle.main.infoDictionary ?? [:]
    private var vm: String { info[GuestAppBundle.vmKey] as? String ?? "" }
    private var program: String { info[GuestAppBundle.programKey] as? String ?? "" }
    private var name: String { info["CFBundleName"] as? String ?? "Program" }
    private var isLauncher: Bool { info[GuestAppBundle.launcherKey] as? Bool ?? false }
    /// Tandem.app where it was when the launcher was made; if it has been moved since, wherever the system knows it to be.
    private lazy var hostURL: URL? = {
        let recorded = (info[GuestAppBundle.hostKey] as? String).map { URL(fileURLWithPath: $0) }
        if let recorded, FileManager.default.fileExists(atPath: recorded.path) { return recorded }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: GuestAppBundle.hostBundleIdentifier) ?? recorded
    }()
    private var libraryRoot: URL? { (info[GuestAppBundle.libraryKey] as? String).map { URL(fileURLWithPath: $0, isDirectory: true) } }
    /// Tandem's process, given on the command line when Tandem started this stand-in as a tile.
    private let hostPID: pid_t = CommandLine.arguments.dropFirst().compactMap { pid_t($0) }.first ?? 0
    private var watchdog: Timer?
    private let center = DistributedNotificationCenter.default()
    /// Launcher: a request has gone out since this launch (documents arrive before or after launching ends).
    private var requested = false
    /// Launcher: when Tandem was last seen running, and whether it ever was.
    private var hostLastSeen = Date()
    private var hostWasSeen = false

    private var hostIsAlive: Bool {
        if hostPID > 0 { return kill(hostPID, 0) == 0 }
        guard let hostURL else { return false }
        let wanted = hostURL.standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.standardizedFileURL.path == wanted }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let bundleID = Bundle.main.bundleIdentifier, isLauncher || hostIsAlive else { NSApp.terminate(nil); return }
        center.addObserver(forName: Notification.Name(GuestAppBundle.quitNotification), object: bundleID, queue: .main) { _ in
            NSApp.terminate(nil)
        }
        watchdog = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.checkHost() }
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let quit = NSMenuItem(title: "Quit \(name)", action: #selector(closeProgram), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        menu.addItem(appItem)
        NSApp.mainMenu = menu
        // Opened by the user with no document: ask for the program itself. Documents, when there are
        // any, are delivered around this moment, so give them a beat to arrive first.
        if isLauncher, hostPID == 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, !self.requested else { return }
                self.request(documents: [])
            }
        }
    }

    /// A tile goes when Tandem goes. A launcher waits for Tandem to come up (it may be starting a VM for
    /// minutes), and goes when Tandem has been gone for a while.
    private func checkHost() {
        if hostIsAlive {
            hostWasSeen = true; hostLastSeen = Date()
            if owesActivation { yieldToHost() }
            return
        }
        if !isLauncher || hostPID > 0 { NSApp.terminate(nil); return }
        if Date().timeIntervalSince(hostLastSeen) > (hostWasSeen ? 6 : 45) { NSApp.terminate(nil) }
    }

    /// Launcher: Tandem was not running yet when the user chose this app, so it could not be handed the front.
    private var owesActivation = false

    private var hostApplication: NSRunningApplication? {
        if hostPID > 0 { return NSRunningApplication(processIdentifier: hostPID) }
        guard let wanted = hostURL?.standardizedFileURL.path else { return nil }
        return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL.path == wanted }
    }

    /// The user chose this app, so the system lets it be in front; the window they want is Tandem's.
    /// Handing the front on is what allows Tandem to bring that window forward.
    private func yieldToHost() {
        guard let host = hostApplication else { owesActivation = true; return }
        owesActivation = false
        NSApp.yieldActivation(to: host)
    }

    private func post(_ name: String) {
        if name == GuestAppBundle.activateNotification { yieldToHost() }
        center.postNotificationName(Notification.Name(name), object: Bundle.main.bundleIdentifier,
                                    userInfo: ["vm": vm, "program": program], deliverImmediately: true)
    }

    /// Leaves a launch request where Tandem looks for them, then tells Tandem, starting it if need be.
    private func request(documents: [String]) {
        requested = true
        guard let id = UUID(uuidString: vm) else { return }
        let root = libraryRoot ?? VMLibrary.defaultRoot()
        do {
            try GuestAppBundle.leave(GuestAppBundle.LaunchRequest(vm: id, program: program, name: name, documents: documents), root: root)
        } catch {
            fail("The request could not be left for Tandem.", error.localizedDescription)
            return
        }
        yieldToHost()
        if hostIsAlive {
            center.postNotificationName(Notification.Name(GuestAppBundle.launchNotification), object: nil, userInfo: nil, deliverImmediately: true)
            return
        }
        guard let hostURL, FileManager.default.fileExists(atPath: hostURL.path) else {
            fail("Tandem could not be found.", "This launcher was made by a copy of Tandem at \(hostURL?.path ?? "an unknown place"), which is no longer there. Open Tandem and add the program to the Mac again.")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        // No Tandem is running from that place (checked above). Another copy of Tandem running from
        // somewhere else must not be taken for it.
        configuration.createsNewApplicationInstance = true
        if let libraryRoot { configuration.environment = ["TANDEM_HOME": libraryRoot.path] }
        hostLastSeen = Date()
        NSWorkspace.shared.openApplication(at: hostURL, configuration: configuration) { [weak self] _, error in
            guard let error else { return }
            DispatchQueue.main.async { self?.fail("Tandem could not be started.", error.localizedDescription) }
        }
    }

    private func fail(_ message: String, _ detail: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
        NSApp.terminate(nil)
    }

    /// Finder's Open With, a document dropped on the Dock tile, `open -a`.
    func application(_ application: NSApplication, open urls: [URL]) {
        let documents = urls.filter(\.isFileURL).map(\.path)
        guard !documents.isEmpty else { return }
        request(documents: documents)
    }

    /// The user chose this program (Dock tile or Command-Tab): its window is Tandem's to bring forward.
    func applicationDidBecomeActive(_ notification: Notification) { post(GuestAppBundle.activateNotification) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // A launcher asks again: Tandem brings the program's window forward, or starts the program if it has none.
        if isLauncher { request(documents: []) } else { post(GuestAppBundle.activateNotification) }
        return false
    }

    /// Quit means "close this program". Tandem closes its windows and then tells this stand-in to go;
    /// if the program keeps a window open (unsaved work), the stand-in rightly stays. With no Tandem
    /// there is nothing to close.
    @objc private func closeProgram() {
        if hostIsAlive { post(GuestAppBundle.closeNotification) } else { NSApp.terminate(nil) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateNow }
}

let app = NSApplication.shared
let delegate = StandIn()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
