import AppKit
import GuestLink
import VMCore

/// Self-test for the idle timer and Keep Awake (see `PowerMonitor.swift`, `IdlePolicy`).
///
///   TANDEM_SNAPSHOT_IDLE          name of a Windows VM (a disposable one: it is started, suspended and shut down)
///   TANDEM_IDLE_MINUTE_SECONDS    the length of a "minute" for the timer; the trial expects 20
///
/// With the timer at 2 "minutes" the trial checks, in a real guest: a job that asked to stay awake keeps
/// the VM running past the timer; once the job ends the VM is suspended and its memory given back;
/// closing the VM's window does not suspend it; a launch from the Mac side resumes it; the Keep Awake
/// switch holds it.
extension SelfTest {
    private static func nap(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    private static func waitFor(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() { if Date() > deadline { return false }; await nap(0.5) }
        return true
    }

    /// PC scancodes for the characters the trial types (US layout); the second value says whether Shift is held.
    private static let scancodes: [Character: (UInt8, Bool)] = {
        var map: [Character: (UInt8, Bool)] = [" ": (0x39, false), "-": (0x0C, false), ".": (0x34, false), "/": (0x35, false),
                                               "\\": (0x2B, false), ":": (0x27, true), "\"": (0x28, true)]
        for (index, letter) in "qwertyuiop".enumerated() { map[letter] = (UInt8(0x10 + index), false) }
        for (index, letter) in "asdfghjkl".enumerated() { map[letter] = (UInt8(0x1E + index), false) }
        for (index, letter) in "zxcvbnm".enumerated() { map[letter] = (UInt8(0x2C + index), false) }
        for (index, digit) in "1234567890".enumerated() { map[digit] = (UInt8(0x02 + index), false) }
        return map
    }()

    /// Types text into the guest through its virtual keyboard, as a user would.
    private static func type(_ session: VMSession, _ text: String) async {
        for character in text.lowercased() {
            guard let (code, shift) = scancodes[character] else { continue }
            session.sendKeys(shift ? [0x2A, code] : [code])
            await nap(0.06)
        }
    }

    private static func line(_ session: VMSession) -> String {
        guard let usage = session.usage else { return "\(session.statusLabel); no reading (\(session.powerSummary ?? "-"))" }
        return "\(session.statusLabel); host \(ResourceMonitorWindow.percent(usage.hostCPUPercent)) of a core, guest \(ResourceMonitorWindow.percent(usage.guestCPUPercent)), memory \(ResourceMonitorWindow.memory(usage.memoryBytes)); idle \(Int(usage.idleFor)) s; suspend in \(usage.suspendIn.map { "\(Int($0)) s" } ?? "-"); held by \(usage.heldAwakeBy)"
    }

    static func idleTrial(_ model: AppModel, vm name: String) async {
        guard let session = model.sessions.first(where: { $0.config.name == name }) else { print("idle: no VM named \(name)"); return }
        guard let root = model.vmLibrary?.rootDirectory else { return }
        let minute = VMSession.idleMinute
        print("idle: a timer minute is \(Int(minute)) s")
        let share = root.appendingPathComponent("share", isDirectory: true)
        try? FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
        let document = share.appendingPathComponent("idle note.txt")
        try? Data("Opened to resume the VM.\r\n".utf8).write(to: document)
        do { try session.share(folder: share) } catch { print("idle: share failed: \(error.localizedDescription)") }
        model.selection = session.id
        session.setPower(PowerSettings(idleSuspendMinutes: 2, keepAwake: false))
        let limit = 2 * minute

        session.start()
        guard await waitFor(VMSession.guestToolsTimeout, { session.powerState.guest != nil && !session.guestPrograms.isEmpty }) else {
            print("idle: no activity report from the guest (capabilities \(session.agent?.capabilities ?? 0))")
            session.setPower(PowerSettings()); await session.forceStopAndWait(); return
        }
        let notepad = session.guestPrograms.first { $0.name == "Notepad" }
        print("idle: guest tools capabilities \(session.agent?.capabilities ?? 0); first report \(String(describing: session.powerState.guest?.activity))")

        // A. A protected job keeps the VM running past the timer. It is started the way a user would:
        // Windows' Run box (Win+R), with a command that asks to stay awake for as long as it runs, about 75 s.
        await nap(8)
        session.sendKeys([0xDB, 0x13]); await nap(3)
        await type(session, "\"c:\\program files\\tandem\\tandem-agent.exe\" keep-awake --reason selftest-job -- ping -n 75 127.0.0.1")
        await nap(0.5)
        session.sendKeys([0x1C])
        print("idle[job]: typed the keep-awake command into the guest")
        let jobBegan = Date()
        _ = await waitFor(30) { session.usage?.heldAwakeBy.contains { $0.contains("selftest-job") } == true }
        print("idle[job]: \(line(session))")
        await nap(max(0, limit + 15 - Date().timeIntervalSince(jobBegan)))
        print("idle[job]: \(Int(Date().timeIntervalSince(jobBegan))) s in, timer is \(Int(limit)) s: \(line(session))")
        let survived = session.state == .running

        // B. The job ends; nothing else happens; the VM is suspended and its memory given back.
        _ = await waitFor(120) { session.usage?.heldAwakeBy.isEmpty == true || !session.state.isActive }
        let released = Date()
        print("idle[after job]: \(Int(released.timeIntervalSince(jobBegan))) s in: \(line(session))")
        let memoryBefore = session.usage?.memoryBytes
        let suspended = await waitFor(limit + 90) { !session.state.isActive && session.isSuspended && session.statusLabel == "Suspended" }
        print("idle[suspend]: protected job kept it running=\(survived); suspended by the timer=\(suspended) \(Int(Date().timeIntervalSince(released))) s after the job ended; memory before \(ResourceMonitorWindow.memory(memoryBefore)), now \(session.processIdentifier == nil ? "no VM process" : "still a process"); \(session.powerSummary ?? "-")")
        if let log = try? String(contentsOf: session.bundle.logsDirectory.appendingPathComponent("power.log"), encoding: .utf8) {
            print("idle: power.log: \(log.split(separator: "\n").suffix(2).joined(separator: " | "))")
        }

        // C. A launch from the Mac side resumes it.
        if let notepad {
            let began = Date()
            session.launches.lastError = "not started"
            session.enqueueLaunch(programID: notepad.id, name: notepad.name, documents: [document])
            _ = await waitFor(VMSession.guestToolsTimeout + 200) { session.launches.lastError != "not started" && session.launchStatus == nil }
            print("idle[launch]: resumed by a Mac-side launch in \(Int(Date().timeIntervalSince(began))) s: error=\(session.launches.lastError ?? "none") windows=\(session.openGuestWindows.map(\.title)); \(line(session))")
        } else {
            session.start()
            _ = await waitFor(120) { session.agent != nil }
        }

        // D. Closing the VM's window does not suspend it: the timer only starts counting.
        session.exitSeamless()
        await nap(4)
        let window = NSApp.windows.first { $0.isVisible && $0.title == session.config.name && !($0 is SeamlessWindow) }
        print("idle[window]: VM window open=\(window != nil)")
        window?.close()
        await nap(6)
        print("idle[window]: 6 s after closing it: \(line(session))")
        let afterClose = session.state == .running

        // E. Keep Awake holds it for longer than the timer.
        session.toggleKeepAwake()
        await nap(limit + 25)
        print("idle[keep awake]: closing the window left it running=\(afterClose); after \(Int(limit + 25)) s with Keep Awake on: \(line(session))")
        session.setPower(PowerSettings())

        for window in session.openGuestWindows { session.link.windowAction(.close, window: window.id); await nap(0.4) }
        session.sendKeys([0x38, 0x3E]); await nap(2)   // Alt+F4 for Notepad, which is in front
        session.stop()
        _ = await waitFor(240) { !session.state.isActive }
        if session.state.isActive { await session.forceStopAndWait() }
        print("idle: final state=\(session.state.rawValue)")
    }
}
