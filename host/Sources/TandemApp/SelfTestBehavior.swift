import AppKit
import EngineQEMU
import VMCore

/// Self-test of the Startup and Shutdown settings with a real VM (set `TANDEM_SNAPSHOT_BEHAVIOR` to its
/// name; a small Linux VM is enough). Prints one line per check and ends by quitting Tandem the way
/// the Quit command does, which must suspend the VM: the caller checks the bundle afterwards.
extension SelfTest {
    private static func wait(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    private static func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        for _ in 0..<Int(seconds * 4) { if condition() { return true }; await wait(0.25) }
        return condition()
    }

    private static func vmWindow(_ session: VMSession) -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.title == session.config.name }
    }

    private static func check(_ what: String, _ passed: Bool) {
        print("behavior: \(passed ? "ok  " : "FAIL") \(what)")
    }

    /// With `TANDEM_SNAPSHOT_AUTOSTART` set: a VM set to start with Tandem must start by itself, and one
    /// set to "quit Tandem after shutdown" must take Tandem with it when it stops.
    static func autostart(_ model: AppModel) async {
        setvbuf(stdout, nil, _IOLBF, 0)
        let wanted = model.sessions.filter { $0.behavior.autoStart != .never }
        print("behavior: VMs set to start automatically: \(wanted.map(\.config.name))")
        guard let session = wanted.first else { return }
        check("“\(session.config.name)” starts by itself when Tandem opens", await waitUntil(90) { session.state == .running })
        check("its window opened", await waitUntil(10) { vmWindow(session) != nil })
        await wait(6)
        guard session.behavior.afterShutdown == .quitTandem else { await session.forceStopAndWait(); return }
        print("behavior: stopping the VM (expect Tandem to quit by itself now)")
        session.forceStop()
        await wait(20)
        check("Tandem quits after the VM shuts down", false)
    }

    /// With `TANDEM_SNAPSHOT_STARTUPVIEW=<Windows VM>`: "start in Seamless Mode" must put the VM into
    /// Seamless Mode by itself once its guest tools connect.
    static func startInSeamless(_ model: AppModel, vm name: String) async {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard let session = model.sessions.first(where: { $0.config.name == name }) else { print("behavior: no VM named \(name)"); return }
        model.selection = session.id
        var behavior = session.behavior
        let before = behavior
        behavior.startupView = .seamless
        try? session.applyBehavior(behavior)
        AppDelegate.shared?.show("vm", session.id)
        session.start()
        check("the VM starts", await waitUntil(120) { session.state == .running })
        check("it changes to Seamless Mode by itself", await waitUntil(300) { session.isSeamless })
        await wait(8)
        check("its window has closed", vmWindow(session) == nil)
        session.exitSeamless()
        await wait(4)
        try? session.applyBehavior(before)
        session.stop()
        check("the VM shuts down", await waitUntil(120) { session.state == .stopped })
    }

    static func behavior(_ model: AppModel, vm name: String) async {
        setvbuf(stdout, nil, _IOLBF, 0) // so a log file shows each check as it happens
        guard let session = model.sessions.first(where: { $0.config.name == name }) else { print("behavior: no VM named \(name)"); return }
        model.selection = session.id
        func set(_ change: (inout VMBehavior) -> Void) {
            var behavior = session.behavior
            change(&behavior)
            do { try session.applyBehavior(behavior) } catch { print("behavior: FAIL saving: \(error.localizedDescription)") }
        }
        session.discardSuspendedState()
        set { $0 = VMBehavior(); $0.afterShutdown = .keepWindow; $0.onWindowClose = .suspend }

        // 1. Start in a window; change a setting while it runs.
        AppDelegate.shared?.show("vm", session.id)
        session.start()
        check("the VM starts", await waitUntil(60) { session.state == .running && session.screen != nil })
        await wait(8)
        set { $0.invertScrolling = true; $0.commandKey = .macShortcuts; $0.scaling = .stretch }
        let stored = (try? VMBundle.load(from: session.bundle.url))?.config.behaviorOrDefault
        check("settings saved while the VM runs", stored?.invertScrolling == true && stored?.commandKey == .macShortcuts)
        check("the running screen takes the new input settings",
              session.screen?.inputSettings == GuestInputSettings(commandKey: .macShortcuts, invertScrolling: true, scaling: .stretch))
        snapshotWindows(tag: "5-behavior-running")

        // 2. Closing the window suspends, because the setting says so.
        check("the VM window is open", vmWindow(session) != nil)
        vmWindow(session)?.performClose(nil)
        check("closing the window suspends the VM", await waitUntil(120) { session.state == .stopped && session.isSuspended && session.busy == nil })

        // 3. Resume straight into full screen; closing the window now leaves the VM running.
        set { $0.onWindowClose = .keepRunning; $0.startupView = .fullScreen; $0.scaling = .fit }
        AppDelegate.shared?.show("vm", session.id)
        session.start()
        check("the VM resumes", await waitUntil(90) { session.state == .running && session.screen != nil })
        check("it starts in full screen", await waitUntil(15) { vmWindow(session)?.styleMask.contains(.fullScreen) == true })
        await wait(3)
        if let window = vmWindow(session), window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        _ = await waitUntil(10) { vmWindow(session)?.styleMask.contains(.fullScreen) != true }
        await wait(2)
        vmWindow(session)?.performClose(nil)
        await wait(4)
        check("closing the window keeps the VM running when set to", session.state == .running && session.busy == nil)

        // 4. Shut down with "keep its window open": the window stays.
        AppDelegate.shared?.show("vm", session.id)
        await wait(2)
        set { $0.startupView = .window; $0.afterShutdown = .keepWindow; $0.onQuit = .suspend }
        session.forceStop()
        check("the VM stops", await waitUntil(30) { session.state == .stopped })
        await wait(2)
        check("its window stays open after shutdown", vmWindow(session) != nil)

        // 5. Start again, then quit Tandem: the VM must be suspended, not powered off.
        session.start()
        check("the VM starts again", await waitUntil(60) { session.state == .running && session.screen != nil })
        await wait(8)
        print("behavior: quitting Tandem with the VM running (expect it suspended on disk afterwards)")
        // From the run loop itself, as the Quit command does: inside this task or a main-queue block the
        // main actor could not run while AppKit waits, and the VMs would never be ended.
        RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        await wait(600)
    }
}
