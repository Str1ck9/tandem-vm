import Foundation

/// Per-VM power settings: the opt-in idle timer and the Keep Awake switch.
public struct PowerSettings: Codable, Equatable, Sendable {
    /// Minutes without activity after which the running VM is suspended. Nil: never (the default).
    public var idleSuspendMinutes: Int?
    /// The user's Keep Awake switch: while on, the idle timer does not suspend the VM.
    public var keepAwake: Bool

    public init(idleSuspendMinutes: Int? = nil, keepAwake: Bool = false) {
        self.idleSuspendMinutes = idleSuspendMinutes; self.keepAwake = keepAwake
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        idleSuspendMinutes = try c.decodeIfPresent(Int.self, forKey: .idleSuspendMinutes)
        keepAwake = try c.decodeIfPresent(Bool.self, forKey: .keepAwake) ?? false
    }

    /// The choices the settings offer.
    public static let idleChoices = [5, 10, 15, 30, 60, 120]
}

/// Decides when an idle VM may be suspended. Pure: everything it needs is handed in, so the rules can
/// be tested without a VM.
///
/// The rules, in the order they matter to the user:
///
/// * The timer is opt-in. Without it nothing is ever suspended.
/// * A VM is never suspended while something says it is in use *now*: the Keep Awake switch, a
///   keep-awake request from inside the guest, a busy processor, or Tandem's own work on the VM
///   (installing, taking a snapshot).
/// * Otherwise it is suspended once nothing has happened for the chosen time. "Something happening"
///   is input from the Mac, input the guest itself saw, one of the VM's windows being the window the
///   user is in, a launch from the Mac side, or any of the reasons above having held until then.
/// * Closing the VM's window is not a reason to suspend. It only stops counting as "the user is in
///   this window", and the timer starts from that moment in full.
public enum IdlePolicy {
    /// Processor use, as the guest reports it over all its cores, at or above which the VM counts as busy.
    public static let guestBusyPercent = 10.0
    /// The same for the host's figure (percent of one Mac core used by the VM's process), used only
    /// when the guest reports nothing. A Windows guest that does nothing still uses a few percent.
    public static let hostBusyPercent = 40.0
    /// A guest report older than this says nothing about now.
    public static let reportLifetime: TimeInterval = 75

    public struct Signals: Equatable, Sendable {
        public var now: Date
        /// When the VM was started or resumed.
        public var runningSince: Date
        /// The last key press or pointer movement sent to the guest from the Mac.
        public var lastHostInput: Date?
        /// The last moment one of the VM's windows was the window the user was in (`now` if one is).
        public var lastFocused: Date?
        /// The last program or document opened in the VM from the Mac side.
        public var lastLaunch: Date?
        /// The last moment anything counted as "in use now" (kept by the caller from earlier verdicts).
        public var lastHeldAwake: Date?
        /// When the guest's last activity report arrived, and what it said.
        public var guestReportAt: Date?
        public var guestIdleSeconds: Int?
        public var guestCPUPercent: Double?
        public var guestKeepAwake: [String]
        /// Percent of one Mac core the VM's process is using.
        public var hostCPUPercent: Double?
        /// Tandem's own work on the VM, in words ("Installing Windows 11…"); nil when there is none.
        public var work: String?

        public init(now: Date, runningSince: Date, lastHostInput: Date? = nil, lastFocused: Date? = nil, lastLaunch: Date? = nil,
                    lastHeldAwake: Date? = nil, guestReportAt: Date? = nil, guestIdleSeconds: Int? = nil, guestCPUPercent: Double? = nil,
                    guestKeepAwake: [String] = [], hostCPUPercent: Double? = nil, work: String? = nil) {
            self.now = now; self.runningSince = runningSince; self.lastHostInput = lastHostInput; self.lastFocused = lastFocused
            self.lastLaunch = lastLaunch; self.lastHeldAwake = lastHeldAwake; self.guestReportAt = guestReportAt
            self.guestIdleSeconds = guestIdleSeconds; self.guestCPUPercent = guestCPUPercent; self.guestKeepAwake = guestKeepAwake
            self.hostCPUPercent = hostCPUPercent; self.work = work
        }
    }

    public struct Verdict: Equatable, Sendable {
        /// What keeps the VM awake right now, in words for the user. Empty: nothing does.
        public var heldAwakeBy: [String]
        /// How long nothing has happened.
        public var idleFor: TimeInterval
        /// Time left until the VM is suspended; nil when the timer is off or something holds the VM awake.
        public var suspendIn: TimeInterval?
        public var shouldSuspend: Bool { suspendIn == 0 }
    }

    /// A share for the status line. Clamped first: the guest reports it, and `Int(1e300)` traps.
    static func percent(_ value: Double) -> Int { Int(min(max(value, 0), 10_000).rounded()) }

    /// `minute` is the length of a minute in seconds; tests shorten it.
    public static func evaluate(_ settings: PowerSettings, _ s: Signals, minute: TimeInterval = 60) -> Verdict {
        var held: [String] = []
        if settings.keepAwake { held.append("Keep Awake is on") }
        if let work = s.work { held.append(work) }
        let reportIsFresh = s.guestReportAt.map { s.now.timeIntervalSince($0) < reportLifetime } ?? false
        if reportIsFresh {
            for reason in s.guestKeepAwake { held.append("In the VM: \(reason)") }
            if let cpu = s.guestCPUPercent, cpu >= guestBusyPercent { held.append("The VM is busy (\(percent(cpu))% processor use)") }
        } else if let cpu = s.hostCPUPercent, cpu >= hostBusyPercent {
            held.append("The VM is busy (\(percent(cpu))% of a Mac processor core)")
        }

        var last = s.runningSince
        for moment in [s.lastHostInput, s.lastFocused, s.lastLaunch, s.lastHeldAwake] {
            if let moment, moment > last { last = moment }
        }
        // The guest's own view of when its user last did something (it also sees input the Mac sent).
        if let at = s.guestReportAt, let idle = s.guestIdleSeconds {
            let moment = at.addingTimeInterval(-TimeInterval(idle))
            if moment > last { last = moment }
        }
        if !held.isEmpty { last = s.now }
        let idleFor = max(0, s.now.timeIntervalSince(last))

        guard let minutes = settings.idleSuspendMinutes, minutes > 0, held.isEmpty else {
            return Verdict(heldAwakeBy: held, idleFor: idleFor, suspendIn: nil)
        }
        return Verdict(heldAwakeBy: held, idleFor: idleFor, suspendIn: max(0, TimeInterval(minutes) * minute - idleFor))
    }

    /// "12 min", "45 s": for the status line.
    public static func describe(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
        if seconds < 90 { return "\(seconds) s" }
        if seconds < 90 * 60 { return "\(Int((Double(seconds) / 60).rounded())) min" }
        return String(format: "%.1f h", Double(seconds) / 3600)
    }
}
