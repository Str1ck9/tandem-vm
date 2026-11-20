import Foundation

// Settings added with the Options and Hardware panes of the configuration window. Every field has a
// default, and decoding fills in whatever a config written earlier does not have.

/// How the VM behaves around starting, stopping, its window, the keyboard and the screen. None of this
/// changes the virtual hardware, so it can be changed while the VM runs.
public struct VMBehavior: Codable, Equatable, Sendable {
    public enum AutoStart: String, Codable, Sendable, CaseIterable {
        case never
        /// Start the VM whenever Tandem is opened.
        case withTandem
        /// Open Tandem when the user logs in to the Mac, and start the VM then.
        case withMac
    }
    public enum StartupView: String, Codable, Sendable, CaseIterable { case window, fullScreen, seamless }
    public enum AfterShutdown: String, Codable, Sendable, CaseIterable { case closeWindow, keepWindow, quitTandem }
    public enum OnQuit: String, Codable, Sendable, CaseIterable { case ask, suspend, shutDown, stop }
    public enum OnWindowClose: String, Codable, Sendable, CaseIterable { case keepRunning, suspend, shutDown }
    /// What the Mac's Command key is in the guest.
    public enum CommandKey: String, Codable, Sendable, CaseIterable {
        /// Command is the Windows key (Super on Linux), as the key's position suggests.
        case windowsKey
        /// Command with a letter is Control with that letter, so Mac habits (Command-C, Command-V) work.
        case macShortcuts
    }
    public enum Scaling: String, Codable, Sendable, CaseIterable {
        /// Scaled to fit, proportions kept.
        case fit
        /// Stretched to fill the whole window or screen.
        case stretch
        /// One guest pixel per point, centred; never scaled up.
        case actualSize
    }

    public var autoStart: AutoStart = .never
    public var startupView: StartupView = .window
    public var afterShutdown: AfterShutdown = .closeWindow
    public var onQuit: OnQuit = .ask
    public var onWindowClose: OnWindowClose = .keepRunning
    /// A Dock tile for each of the VM's programs in Seamless Mode. Nil follows the app-wide preference.
    public var dockTiles: Bool? = nil
    public var commandKey: CommandKey = .windowsKey
    /// Command shortcuts go to the VM while its screen has the keyboard. Off leaves them to the Mac's menus.
    public var commandShortcutsToGuest: Bool = true
    /// Scroll the other way round from the Mac's own setting.
    public var invertScrolling: Bool = false
    public var scaling: Scaling = .fit
    /// In full screen: true keeps the window's toolbar visible, false shows it when the pointer reaches the top.
    public var toolbarAlwaysVisibleInFullScreen: Bool = false
    /// Seamless Mode gives the guest one pixel per screen pixel (twice as many on a Retina display) and
    /// sets the guest's scale to match, so text keeps its size and becomes sharp.
    public var seamlessRetina: Bool = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoStart = try c.decodeIfPresent(AutoStart.self, forKey: .autoStart) ?? .never
        startupView = try c.decodeIfPresent(StartupView.self, forKey: .startupView) ?? .window
        afterShutdown = try c.decodeIfPresent(AfterShutdown.self, forKey: .afterShutdown) ?? .closeWindow
        onQuit = try c.decodeIfPresent(OnQuit.self, forKey: .onQuit) ?? .ask
        onWindowClose = try c.decodeIfPresent(OnWindowClose.self, forKey: .onWindowClose) ?? .keepRunning
        dockTiles = try c.decodeIfPresent(Bool.self, forKey: .dockTiles)
        commandKey = try c.decodeIfPresent(CommandKey.self, forKey: .commandKey) ?? .windowsKey
        commandShortcutsToGuest = try c.decodeIfPresent(Bool.self, forKey: .commandShortcutsToGuest) ?? true
        invertScrolling = try c.decodeIfPresent(Bool.self, forKey: .invertScrolling) ?? false
        scaling = try c.decodeIfPresent(Scaling.self, forKey: .scaling) ?? .fit
        toolbarAlwaysVisibleInFullScreen = try c.decodeIfPresent(Bool.self, forKey: .toolbarAlwaysVisibleInFullScreen) ?? false
        seamlessRetina = try c.decodeIfPresent(Bool.self, forKey: .seamlessRetina) ?? true
    }
}

/// The VM's sound card (QEMU engine). Changing it needs the VM stopped.
public struct SoundConfig: Codable, Equatable, Sendable {
    /// The VM plays sound through the Mac's output device.
    public var output: Bool = true
    /// The VM hears the Mac's microphone. macOS asks for permission the first time.
    public var microphone: Bool = false

    public init(output: Bool = true, microphone: Bool = false) { self.output = output; self.microphone = microphone }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        output = try c.decodeIfPresent(Bool.self, forKey: .output) ?? true
        microphone = try c.decodeIfPresent(Bool.self, forKey: .microphone) ?? false
    }
}

public enum BootDevice: String, Codable, Sendable, CaseIterable {
    case hardDisk, cd, network
}

/// Which device the firmware tries first (QEMU engine). Changing it needs the VM stopped.
public struct BootConfig: Codable, Equatable, Sendable {
    /// Devices in the order they are tried. A device left out is not started from.
    public var order: [BootDevice] = BootConfig.defaultOrder
    /// Wait a few seconds at start-up so a key press can open the firmware's boot menu.
    public var menu: Bool = false

    public static let defaultOrder: [BootDevice] = [.hardDisk, .cd]

    public init(order: [BootDevice] = BootConfig.defaultOrder, menu: Bool = false) { self.order = order; self.menu = menu }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try c.decodeIfPresent([BootDevice].self, forKey: .order) ?? BootConfig.defaultOrder
        // Each device once, in the order first named.
        var seen = Set<BootDevice>()
        order = stored.filter { seen.insert($0).inserted }
        menu = try c.decodeIfPresent(Bool.self, forKey: .menu) ?? false
    }
}

extension VMConfig {
    /// The behaviour settings, with defaults for a VM that has none stored.
    public var behaviorOrDefault: VMBehavior { behavior ?? VMBehavior() }
    public var soundOrDefault: SoundConfig { sound ?? SoundConfig() }
    public var bootOrDefault: BootConfig { boot ?? BootConfig() }

    /// True when `other` differs from this configuration in behaviour settings only, which may be
    /// saved while the VM runs.
    public func differsOnlyInBehavior(from other: VMConfig) -> Bool {
        var copy = other
        copy.behavior = behavior
        return copy == self && other.behavior != behavior
    }
}
