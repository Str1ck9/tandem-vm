import AppKit
import EngineVZ
import NetHelperClient
import GuestLink
import SwiftUI
import VMCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    /// The delegate itself; `NSApp.delegate` is SwiftUI's wrapper around it.
    static private(set) weak var shared: AppDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Release test (SoftwareUpdate): the copy started after an update says which version it is and quits.
        if let probe = ProcessInfo.processInfo.environment["TANDEM_UPDATE_RELAUNCH_PROBE"] {
            let info = Bundle.main.infoDictionary ?? [:]
            let text = "\(info["CFBundleShortVersionString"] as? String ?? "?") \(info["CFBundleVersion"] as? String ?? "?") \(Bundle.main.bundlePath)\n"
            try? Data(text.utf8).write(to: URL(fileURLWithPath: probe))
            exit(0)
        }
        Self.shared = self
        NetHelper.appHelperAdvice = HelperService.isAvailable
        MacOSRestoreImages.register() // "Download macOS" lives with the engine it needs
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        shutDownOnTerminationSignal()
    }

    private var terminationSignal: DispatchSourceSignal?

    /// `kill <pid>` (and a system that is shutting down) ends the app without asking. The VMs would be
    /// cut off with it, so they are shut down first: asked nicely, then powered off after a minute and a half.
    private func shutDownOnTerminationSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let model = self?.model else { exit(0) }
                for session in model.sessions where session.can(.stop) { session.stop() }
                let deadline = Date().addingTimeInterval(90)
                while model.runningCount > 0, Date() < deadline { try? await Task.sleep(nanoseconds: 500_000_000) }
                await model.stopEverything()
                exit(0)
            }
        }
        source.resume()
        terminationSignal = source
    }

    /// VMs run inside this process (VZ) or as its children (QEMU), so quitting ends them: each the way
    /// its own setting says (suspend, shut down, stop), or after asking.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        QuitCoordinator.shouldTerminate(model)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// A `.tandemvm` opened in Finder: add it to the library if it lives elsewhere, then show and start it.
    func application(_ application: NSApplication, open urls: [URL]) {
        let bundles = urls.filter { $0.pathExtension == VMBundle.pathExtension }
        guard !bundles.isEmpty else { return }
        // At launch the model may not be connected yet; try again a moment later.
        guard let model else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.application(application, open: bundles) }
            return
        }
        for url in bundles {
            do {
                let session = try model.openBundle(at: url)
                show("vm", session.id)
                if session.can(.start) { session.start() } else if session.can(.resume) { session.resume() }
            } catch {
                let alert = NSAlert()
                alert.messageText = "“\(url.deletingPathExtension().lastPathComponent)” could not be opened."
                alert.informativeText = [error.localizedDescription, (error as? VMError)?.detail].compactMap { $0 }.joined(separator: "\n")
                alert.runModal()
            }
        }
    }

    // MARK: Dock menu

    /// Opens SwiftUI windows from AppKit code. Captured from the first window, valid for the app's lifetime.
    var openWindow: OpenWindowAction?

    /// Right-click on the Dock icon: each virtual machine with its actions, then Control Center and New.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let model else { return nil }
        let menu = NSMenu()
        // In Seamless Mode the guest's program windows come first, as an app's own windows would.
        for session in model.sessions where session.isSeamless {
            for window in session.openGuestWindows {
                let item = dockItem(Self.menuTitle(window.title)) { session.activateGuestWindow(window.id) }
                item.image = session.image(session.icon(for: window))
                menu.addItem(item)
            }
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        for session in model.sessions {
            let item = NSMenuItem(title: "\(session.config.name) — \(session.statusLabel)", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            if session.can(.start) {
                sub.addItem(dockItem(session.isSuspended ? "Resume" : "Start") { [weak self] in self?.show("vm", session.id); session.start() })
            }
            if session.can(.resume) { sub.addItem(dockItem("Resume") { session.resume() }) }
            if session.can(.pause) { sub.addItem(dockItem("Pause") { session.pause() }) }
            if session.canSuspend { sub.addItem(dockItem("Suspend") { session.suspend() }) }
            if session.can(.stop) { sub.addItem(dockItem("Shut Down") { session.stop() }) }
            if session.state.isActive {
                let keepAwake = dockItem("Keep Awake") { session.toggleKeepAwake() }
                keepAwake.state = session.power.keepAwake ? .on : .off
                sub.addItem(keepAwake)
                if let summary = session.powerSummary {
                    let note = NSMenuItem(title: Self.menuTitle(summary), action: nil, keyEquivalent: "")
                    note.isEnabled = false
                    sub.addItem(note)
                }
            }
            if session.canRestart { sub.addItem(dockItem("Restart") { session.restart() }) }
            if session.isSeamless { sub.addItem(dockItem("Exit Seamless Mode") { session.exitSeamless() }) }
            else if session.canSeamless { sub.addItem(dockItem("Enter Seamless Mode") { session.enterSeamless() }) }
            if session.state.isActive, !session.isSeamless { sub.addItem(dockItem("Show Window") { [weak self] in self?.show("vm", session.id) }) }
            if !session.guestPrograms.isEmpty, session.state == .running {
                let programs = NSMenuItem(title: "Windows Programs", action: nil, keyEquivalent: "")
                let list = NSMenu()
                list.addItem(dockItem("Keep Programs on the Mac…") { [weak self] in self?.show("macapps", session.id) })
                list.addItem(.separator())
                for program in session.guestPrograms {
                    let item = dockItem(Self.menuTitle(program.name)) { session.launch(program) }
                    item.image = session.image(session.icon(for: program))
                    list.addItem(item)
                }
                programs.submenu = list
                sub.addItem(programs)
            }
            sub.addItem(.separator())
            sub.addItem(dockItem("Configure…") { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.openWindow?(id: "configuration", value: ConfigurationTarget(id: session.id, place: nil))
            })
            if !session.state.isActive {
                sub.addItem(dockItem("Clone…") { [weak self] in
                    self?.show("library", nil)
                    NotificationCenter.default.post(name: .cloneVM, object: session.id)
                })
            }
            item.submenu = sub
            menu.addItem(item)
        }
        if !model.sessions.isEmpty { menu.addItem(.separator()) }
        menu.addItem(dockItem("Control Center") { [weak self] in self?.show("library", nil) })
        menu.addItem(dockItem("Resource Monitor") { [weak self] in self?.show("resources", nil) })
        menu.addItem(dockItem("New…") { [weak self] in
            self?.show("library", nil)
            NotificationCenter.default.post(name: .newVM, object: nil)
        })
        return menu
    }

    /// Window titles can be as long as a document path; menus should not be.
    static func menuTitle(_ title: String) -> String {
        title.count > 60 ? String(title.prefix(59)) + "…" : title
    }

    func show(_ id: String, _ vm: UUID?) {
        NSApp.activate(ignoringOtherApps: true)
        if let vm { openWindow?(id: id, value: vm) } else { openWindow?(id: id) }
    }

    private func dockItem(_ title: String, _ action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runDockAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = DockAction(run: action)
        return item
    }

    @objc private func runDockAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? DockAction else { return }
        MainActor.assumeIsolated { action.run() }
    }
}

private final class DockAction {
    let run: @MainActor () -> Void
    init(run: @escaping @MainActor () -> Void) { self.run = run }
}

/// Hands the app delegate the means to open windows, which only SwiftUI views can reach.
private struct WindowOpenerCapture: ViewModifier {
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content.onAppear { delegate.openWindow = openWindow }
    }
}

@main
struct TandemApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    var body: some Scene {
        Window("Control Center", id: "library") {
            ControlCenterView()
                .environmentObject(model)
                .onAppear {
                    delegate.model = model; SelfTest.run(model: model); Autostart.run(model); ControlAPI.start(model)
                    SoftwareUpdate.shared.start(model: model)
                    // After a crash: offer, once, to send a report. A moment later, so the window is up first.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { CrashReportPrompt.offerIfNeeded(model: model) }
                }
                .modifier(WindowOpenerCapture(delegate: delegate))
                .modifier(RecoveryNoticeModifier(model: model))
                .modifier(FirstRunWelcome())
        }
        .defaultSize(width: 480, height: 560)
        .defaultLaunchBehavior(.presented)
        .commands { TandemCommands(model: model, revision: model.menuRevision) }

        WindowGroup("Virtual Machine", id: "vm", for: UUID.self) { $id in
            if let id, let session = model.sessions.first(where: { $0.id == id }) {
                VMDisplayWindow(session: session)
            } else {
                StaleVMWindow()
            }
        }
        .defaultSize(width: 1440, height: 900)
        // VM windows belong to a running session; never bring them back on the next launch.
        .restorationBehavior(.disabled)

        WindowGroup("Configuration", id: "configuration", for: ConfigurationTarget.self) { $target in
            if let target, let session = model.sessions.first(where: { $0.id == target.id }) {
                ConfigurationSheet(session: session, initial: target.place)
            } else {
                StaleVMWindow()
            }
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)

        WindowGroup("Snapshot Manager", id: "snapshots", for: UUID.self) { $id in
            if let id, let session = model.sessions.first(where: { $0.id == id }) {
                SnapshotManagerWindow(session: session)
            } else {
                StaleVMWindow()
            }
        }
        .defaultSize(width: 720, height: 460)
        .restorationBehavior(.disabled)

        Window("Resource Monitor", id: "resources") {
            ResourceMonitorWindow().environmentObject(model)
        }
        .defaultSize(width: 640, height: 420)
        .restorationBehavior(.disabled)

        WindowGroup("Windows Applications on the Mac", id: "macapps", for: UUID.self) { $id in
            if let id, let session = model.sessions.first(where: { $0.id == id }) {
                MacAppsWindow(session: session)
            } else {
                StaleVMWindow()
            }
        }
        .defaultSize(width: 520, height: 560)
        .restorationBehavior(.disabled)

        Window("Welcome to Tandem", id: "welcome") { WelcomeView().environmentObject(model) }
            .windowResizability(.contentSize)
            .restorationBehavior(.disabled)

        Window("Uninstall Tandem", id: "uninstall") { UninstallView().environmentObject(model) }
            .windowResizability(.contentSize)
            .restorationBehavior(.disabled)

        Window("Software Update", id: "update") { SoftwareUpdateView().environmentObject(model) }
            .windowResizability(.contentSize)
            .restorationBehavior(.disabled)

        Window("About Tandem", id: "about") { AboutView() }
            .windowResizability(.contentSize)
            .restorationBehavior(.disabled)

        Settings { PreferencesView().environmentObject(model) }

        MenuBarExtra("Tandem", systemImage: "rectangle.on.rectangle", isInserted: $showMenuBarIcon) {
            StatusMenu().environmentObject(model)
        }
    }
}

/// Shown only if a window outlives its VM (for example one restored by the system). Closes itself.
private struct StaleVMWindow: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Text("This virtual machine is no longer in the library.")
            .padding(40)
            .onAppear { dismiss() }
    }
}
