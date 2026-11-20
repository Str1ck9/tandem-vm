import Foundation
import VMCore

/// Input settings of one VM, shared by every view that sends it keys and pointer movement.
public struct GuestInputSettings: Equatable, Sendable {
    public var commandKey: VMBehavior.CommandKey
    public var invertScrolling: Bool
    public var scaling: VMBehavior.Scaling
    /// Command shortcuts go to the guest while its screen has the keyboard; off leaves them to the Mac's menus.
    public var commandShortcutsToGuest: Bool

    public init(commandKey: VMBehavior.CommandKey = .windowsKey, invertScrolling: Bool = false,
                scaling: VMBehavior.Scaling = .fit, commandShortcutsToGuest: Bool = true) {
        self.commandKey = commandKey; self.invertScrolling = invertScrolling; self.scaling = scaling
        self.commandShortcutsToGuest = commandShortcutsToGuest
    }

    public init(_ behavior: VMBehavior) {
        self.init(commandKey: behavior.commandKey, invertScrolling: behavior.invertScrolling, scaling: behavior.scaling,
                  commandShortcutsToGuest: behavior.commandShortcutsToGuest)
    }
}

/// Turns the Mac keys a user presses into the keys the guest should see, as Mac key codes.
///
/// With `.windowsKey` every key passes through, and Command is the Windows key. With `.macShortcuts`
/// Command plus one of the usual letters becomes Control plus that letter (Command-C copies), Command-Q
/// becomes Alt-F4, Command with any other key is still the Windows key with that key, and Command
/// pressed and released alone is a tap of the Windows key, which opens the Start menu.
///
/// Command cannot be passed on when it goes down: a Windows key that is later released without
/// another key opens the Start menu, which would happen after every Command-C. So in that profile
/// Command is held back until the next key says what it was for.
public struct KeyTranslator: Sendable {
    public struct Key: Equatable, Sendable {
        public var code: UInt16
        public var down: Bool
        public init(_ code: UInt16, _ down: Bool) { self.code = code; self.down = down }
    }

    public var profile: VMBehavior.CommandKey

    static let leftCommand: UInt16 = 0x37, rightCommand: UInt16 = 0x36
    static let leftControl: UInt16 = 0x3B, rightControl: UInt16 = 0x3E
    static let leftOption: UInt16 = 0x3A, f4: UInt16 = 0x76, q: UInt16 = 0x0C
    /// A S D F Z X C V B W R Y T O U I P L N: the letters whose Command shortcut on the Mac is the
    /// Control shortcut on Windows and Linux.
    static let controlLetters: Set<UInt16> = [0x00, 0x01, 0x02, 0x03, 0x06, 0x07, 0x08, 0x09, 0x0B, 0x0D, 0x0F,
                                              0x10, 0x11, 0x1F, 0x20, 0x22, 0x23, 0x25, 0x2D]

    private var commandHeld: Set<UInt16> = []
    /// The Command press has been used with another key, so its release is not a tap.
    private var commandUsed = false
    /// The Windows key is down in the guest on Command's behalf.
    private var windowsKeySent = false
    /// The user is holding a real Control key.
    private var controlHeld: Set<UInt16> = []
    /// Keys currently down in the guest as Control+key, and whether Alt+F4 is.
    private var controlCombos: Set<UInt16> = []
    private var closeComboDown = false

    public init(profile: VMBehavior.CommandKey = .windowsKey) { self.profile = profile }

    /// Forget everything held, after the guest's keys were all released.
    public mutating func forgetHeldKeys() { self = KeyTranslator(profile: profile) }

    public mutating func translate(code: UInt16, down: Bool) -> [Key] {
        guard profile == .macShortcuts else { return [Key(code, down)] }
        if code == Self.leftCommand || code == Self.rightCommand { return command(code, down) }
        if code == Self.leftControl || code == Self.rightControl {
            if down { controlHeld.insert(code) } else { controlHeld.remove(code) }
            return [Key(code, down)]
        }
        if down {
            guard !commandHeld.isEmpty else { return [Key(code, true)] }
            commandUsed = true
            if code == Self.q {
                guard !closeComboDown else { return [] }
                closeComboDown = true
                return [Key(Self.leftOption, true), Key(Self.f4, true)]
            }
            if Self.controlLetters.contains(code) {
                var keys: [Key] = []
                if controlCombos.isEmpty && controlHeld.isEmpty { keys.append(Key(Self.leftControl, true)) }
                controlCombos.insert(code)
                return keys + [Key(code, true)]
            }
            var keys: [Key] = []
            if !windowsKeySent { windowsKeySent = true; keys.append(Key(Self.leftCommand, true)) }
            return keys + [Key(code, true)]
        }
        if code == Self.q, closeComboDown {
            closeComboDown = false
            return [Key(Self.f4, false), Key(Self.leftOption, false)]
        }
        if controlCombos.remove(code) != nil {
            var keys = [Key(code, false)]
            if controlCombos.isEmpty && controlHeld.isEmpty { keys.append(Key(Self.leftControl, false)) }
            return keys
        }
        return [Key(code, false)]
    }

    private mutating func command(_ code: UInt16, _ down: Bool) -> [Key] {
        if down {
            if commandHeld.isEmpty { commandUsed = false }
            commandHeld.insert(code)
            return []
        }
        guard commandHeld.remove(code) != nil, commandHeld.isEmpty else { return [] }
        var keys: [Key] = []
        if windowsKeySent {
            windowsKeySent = false
            keys.append(Key(Self.leftCommand, false))
        } else if !commandUsed {
            keys += [Key(Self.leftCommand, true), Key(Self.leftCommand, false)]
        }
        return keys
    }
}
