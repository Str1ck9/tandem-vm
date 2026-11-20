import AppKit
import GuestLink
import VMCore

/// What a running VM is using and whether it is idle, as the Resource Monitor and the idle timer see it.
struct VMUsage: Equatable {
    /// Percent of one Mac processor core the VM's process uses (QEMU engine). Above 100 on several cores.
    var hostCPUPercent: Double?
    /// The memory the Mac charges the VM's process: what suspending it gives back.
    var memoryBytes: UInt64?
    /// Processor use inside the guest over all its cores, from the guest tools.
    var guestCPUPercent: Double?
    /// What keeps the VM awake right now; empty when nothing does.
    var heldAwakeBy: [String]
    /// How long nothing has happened in the VM.
    var idleFor: TimeInterval
    /// Time until the idle timer suspends the VM; nil when the timer is off or something holds the VM awake.
    var suspendIn: TimeInterval?
}

/// The moments the idle timer goes by, kept per VM between samples. Main actor only.
final class PowerState {
    var runningSince = Date()
    var lastFocused: Date?
    var lastLaunch: Date?
    var lastHeldAwake: Date?
    var guest: (activity: GuestActivity, at: Date)?
    var lastSample: (usage: ProcessUsage, at: Date)?
    /// When the idle timer last suspended the VM, for the status line; cleared when it runs again.
    var suspendedWhenIdle: Date?
    /// Set once the timer has asked for a suspend, so it asks once.
    var suspending = false

    func reset() {
        runningSince = Date()
        lastFocused = nil; lastLaunch = nil; lastHeldAwake = nil; guest = nil; lastSample = nil; suspending = false
    }
}

extension VMSession {
    var power: PowerSettings { config.power ?? PowerSettings() }

    /// The idle timer and Keep Awake can be changed while the VM runs: they are the Mac's business, not the guest's hardware.
    func setPower(_ settings: PowerSettings) {
        bundle.config.power = settings == PowerSettings() ? nil : settings
        try? bundle.save()
        samplePower()
    }

    func toggleKeepAwake() {
        var settings = power
        settings.keepAwake.toggle()
        setPower(settings)
    }

    /// The length of a minute for the idle timer. A trial sets `TANDEM_IDLE_MINUTE_SECONDS` to make it short.
    static let idleMinute: TimeInterval = ProcessInfo.processInfo.environment["TANDEM_IDLE_MINUTE_SECONDS"].flatMap(Double.init) ?? 60

    /// True while one of this VM's windows is the window the user is in.
    private var hasFocus: Bool {
        guard NSApp.isActive, let key = NSApp.keyWindow else { return false }
        if let seamless, seamless.owns(key) { return true }
        // The VM's own window carries the VM's name as its title.
        return !(key is SeamlessWindow) && key.title == config.name && state.isActive
    }

    func guestActivityArrived(_ activity: GuestActivity) {
        powerState.guest = (activity, Date())
        // A keep-awake request that has just been made or dropped shows at once, not at the next sample.
        samplePower()
    }

    func noteLaunchFromMac() { powerState.lastLaunch = Date() }

    /// Takes a reading of what the VM uses, works out whether it is idle, and suspends it when the
    /// idle timer says so. Called every few seconds for every VM.
    func samplePower(now: Date = Date()) {
        guard state == .running || state == .paused else {
            if usage != nil { usage = nil }
            powerState.lastSample = nil
            return
        }
        let p = powerState
        var hostCPU: Double?
        var memory: UInt64?
        if let pid = processIdentifier, let reading = ProcessUsage.of(pid: pid) {
            memory = reading.footprintBytes
            if let last = p.lastSample { hostCPU = ProcessUsage.cpuPercent(from: last.usage, to: reading, over: now.timeIntervalSince(last.at)) }
            // Readings a moment apart say little; keep the older one until a few seconds have passed.
            if p.lastSample == nil || now.timeIntervalSince(p.lastSample!.at) >= 3 { p.lastSample = (reading, now) }
            else { hostCPU = usage?.hostCPUPercent }
        }
        if hasFocus { p.lastFocused = now }
        let work: String? = busy ?? (isInstalling ? statusLabel : launchStatus)
        let signals = IdlePolicy.Signals(
            now: now, runningSince: p.runningSince, lastHostInput: screen?.lastInputAt, lastFocused: p.lastFocused, lastLaunch: p.lastLaunch,
            lastHeldAwake: p.lastHeldAwake, guestReportAt: p.guest?.at, guestIdleSeconds: p.guest?.activity.idleSeconds,
            guestCPUPercent: p.guest?.activity.cpuPercent, guestKeepAwake: p.guest?.activity.keepAwake ?? [], hostCPUPercent: hostCPU, work: work)
        let verdict = IdlePolicy.evaluate(power, signals, minute: Self.idleMinute)
        if !verdict.heldAwakeBy.isEmpty { p.lastHeldAwake = now }
        let fresh = p.guest.map { now.timeIntervalSince($0.at) < IdlePolicy.reportLifetime } ?? false
        let reading = VMUsage(hostCPUPercent: hostCPU, memoryBytes: memory, guestCPUPercent: fresh ? p.guest?.activity.cpuPercent : nil,
                              heldAwakeBy: verdict.heldAwakeBy, idleFor: verdict.idleFor, suspendIn: verdict.suspendIn)
        if usage != reading { usage = reading }
        if verdict.shouldSuspend, state == .running, canSuspend, !p.suspending {
            p.suspending = true
            p.suspendedWhenIdle = now
            appendPowerLog("idle for \(IdlePolicy.describe(verdict.idleFor)): suspending")
            suspend()
        }
    }

    /// One line per event in the VM's `logs/power.log`: why it was suspended, what held it awake.
    func appendPowerLog(_ message: String) {
        let url = bundle.logsDirectory.appendingPathComponent("power.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }

    /// One line for menus and lists: what the idle timer is doing with this VM.
    var powerSummary: String? {
        if state == .stopped, isSuspended, let at = powerState.suspendedWhenIdle {
            return "Suspended when idle at \(at.formatted(date: .omitted, time: .shortened))"
        }
        guard let usage, state == .running else { return nil }
        if !usage.heldAwakeBy.isEmpty { return "Kept awake: " + usage.heldAwakeBy.joined(separator: "; ") }
        if let left = usage.suspendIn { return "Idle for \(IdlePolicy.describe(usage.idleFor)), suspends in \(IdlePolicy.describe(left))" }
        return nil
    }
}

extension AppModel {
    /// Samples every VM every few seconds: usage for the Resource Monitor, and the idle timer.
    func startPowerMonitor() {
        powerTimer?.invalidate()
        powerTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                for session in self.sessions { session.samplePower() }
            }
        }
    }
}
