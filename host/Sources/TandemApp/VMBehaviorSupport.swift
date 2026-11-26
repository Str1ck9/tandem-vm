import AppKit
import EngineQEMU
import ServiceManagement
import SwiftUI
import VMCore

// What the Startup and Shutdown, Full Screen and Mouse & Keyboard panes of the configuration window
// do at run time (the settings themselves are `VMBehavior` in VMCore).

extension VMSession {
    var behavior: VMBehavior { config.behaviorOrDefault }

    /// Saves behaviour settings. Unlike the rest of the configuration they do not touch the virtual
    /// hardware, so this works while the VM runs or is suspended.
    func applyBehavior(_ new: VMBehavior) throws {
        bundle.config.behavior = new == VMBehavior() ? nil : new
        try bundle.save()
        screen?.inputSettings = GuestInputSettings(new)
        LoginItem.sync(with: AppDelegate.shared?.model)
    }

    /// Called after every change of state, with the state before it.
    func behaviorStateChanged(from previous: VMState) {
        switch state {
        case .running where previous == .starting:
            StartupView.pending.insert(id)
        case .stopped, .error:
            StartupView.pending.remove(id)
            networkApplyResult = nil
            // "Quit Tandem" after a shutdown: only when the VM had been running and nothing else is.
            let ranBefore = previous == .stopping || previous == .running || previous == .paused
            if state == .stopped, ranBefore, !isSuspended, !isRestarting, behavior.afterShutdown == .quitTandem, !QuitCoordinator.isQuitting,
               AppDelegate.shared?.model?.runningCount == 0 {
                // A moment later, so the VM's own clean-up has finished.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
            }
        default: break
        }
    }

    /// Called when the guest tools connect: the earliest moment Seamless Mode can start.
    func behaviorAgentConnected() {
        guard behavior.startupView == .seamless, StartupView.pending.contains(id) else { return }
        // The guest's desktop needs a moment after the tools start before its windows can be listed.
        Task { @MainActor [weak self] in
            for _ in 0..<20 {
                guard let self, StartupView.pending.contains(self.id), self.state == .running else { return }
                if self.canSeamless {
                    StartupView.pending.remove(self.id)
                    self.enterSeamless()
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    /// The user closed the VM's window (not Tandem closing it after a shutdown or for Seamless Mode).
    func windowClosedByUser() {
        guard state == .running || state == .paused, !isSeamless, !isRestarting, busy == nil, !QuitCoordinator.isQuitting else { return }
        switch behavior.onWindowClose {
        case .keepRunning: break
        case .suspend: suspend()
        case .shutDown: stop()
        }
    }

    /// Ends the VM the way its "when Tandem quits" setting says, and returns when it has stopped.
    func endForQuit(_ action: VMBehavior.OnQuit) async {
        guard state.isActive else { return }
        switch action {
        case .suspend where canSuspend:
            suspend()
            await waitUntilStopped(seconds: 180)
        case .shutDown where can(.stop):
            stop()
            await waitUntilStopped(seconds: 90)
        default: break
        }
        // Whatever is still running after that is powered off: quitting must not hang.
        await forceStopAndWait()
    }

    private func waitUntilStopped(seconds: Int) async {
        for _ in 0..<(seconds * 4) where state.isActive || busy != nil {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }
}

/// VMs that have just started and still owe their "start in full screen / Seamless Mode" setting.
@MainActor
enum StartupView {
    static var pending: Set<UUID> = []
}

/// What happens to running VMs when Tandem quits.
@MainActor
enum QuitCoordinator {
    private(set) static var isQuitting = false

    static func shouldTerminate(_ model: AppModel?) -> NSApplication.TerminateReply {
        guard let model, model.runningCount > 0 else { return .terminateNow }
        let running = model.sessions.filter { $0.state.isActive }
        var actions: [UUID: VMBehavior.OnQuit] = [:]
        for session in running { actions[session.id] = session.behavior.onQuit }
        let asking = running.filter { actions[$0.id] == .ask }
        if !asking.isEmpty {
            // VMs with no standing answer: ask once for all of them.
            let names = asking.map { "“\($0.config.name)”" }.joined(separator: ", ")
            let alert = NSAlert()
            alert.messageText = asking.count == 1 ? "\(names) is still running." : "\(asking.count) virtual machines are still running."
            alert.informativeText = "Suspending saves \(asking.count == 1 ? "it" : "them: \(names),") exactly as \(asking.count == 1 ? "it is" : "they are") and continues next time. Stopping powers off immediately, and unsaved work inside is lost. A standing answer can be set per virtual machine under Configure > Options > Startup and Shutdown."
            alert.addButton(withTitle: "Suspend and Quit")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Stop and Quit")
            alert.alertStyle = .warning
            switch alert.runModal() {
            case .alertFirstButtonReturn: for session in asking { actions[session.id] = .suspend }
            case .alertThirdButtonReturn: for session in asking { actions[session.id] = .stop }
            default: return .terminateCancel
            }
        }
        isQuitting = true
        Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                for session in running {
                    let action = actions[session.id] ?? .stop
                    group.addTask { @MainActor in await session.endForQuit(action) }
                }
            }
            await model.stopEverything()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Starts the VMs set to start with Tandem, once, shortly after launch.
@MainActor
enum Autostart {
    private static var done = false

    static func run(_ model: AppModel) {
        // A self-test run leaves the user's VMs alone unless it asks for this.
        guard !done, SelfTest.directory == nil || ProcessInfo.processInfo.environment["TANDEM_SNAPSHOT_AUTOSTART"] != nil else { return }
        done = true
        LoginItem.sync(with: model)
        // After the first window is up, so the VM windows have something to open from.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            for session in model.sessions where session.behavior.autoStart != .never && session.can(.start) {
                if session.behavior.startupView != .seamless { AppDelegate.shared?.show("vm", session.id) }
                session.start()
            }
        }
    }
}

/// Tandem as a login item: on while any VM is set to start with the Mac.
@MainActor
enum LoginItem {
    static var isRegistered: Bool { SMAppService.mainApp.status == .enabled }

    /// A development build run from the build folder can register too, but macOS then opens that
    /// copy at login; say where the app is so the pane can warn about it.
    static var appIsInApplications: Bool { Bundle.main.bundlePath.hasPrefix("/Applications/") }

    /// Registers or removes the login item to match the VMs' settings. Returns an error text when macOS refuses.
    @discardableResult
    static func sync(with model: AppModel?) -> String? {
        guard let model, SelfTest.directory == nil else { return nil }
        let wanted = model.sessions.contains { $0.behavior.autoStart == .withMac }
        do {
            if wanted, !isRegistered { try SMAppService.mainApp.register() }
            if !wanted, isRegistered { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// Sits in the VM window to learn when the user closes it and to put it into full screen at start-up.
struct VMWindowBehavior: NSViewRepresentable {
    @ObservedObject var session: VMSession

    final class Coordinator {
        var observer: NSObjectProtocol?
        weak var window: NSWindow?
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let coordinator = context.coordinator
            if coordinator.window !== window {
                if let old = coordinator.observer { NotificationCenter.default.removeObserver(old) }
                coordinator.window = window
                coordinator.observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak session] _ in
                    MainActor.assumeIsolated { session?.windowClosedByUser() }
                }
            }
            // Start in full screen, once per start, when the guest's screen is showing.
            if session.behavior.startupView == .fullScreen, StartupView.pending.contains(session.id),
               session.state == .running, session.screen != nil || session.virtualMachine != nil {
                StartupView.pending.remove(session.id)
                if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            }
        }
    }
}
