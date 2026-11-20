import Foundation
import CoreGraphics
import VMCore

/// Turns host keyboard and mouse activity into guest input over an `RFBClient`.
/// Kept apart from the view so the mapping can be tested and driven from the command line.
public final class GuestInput: @unchecked Sendable {
    private let client: RFBClient
    private let lock = NSLock()
    /// Keys the user holds, by Mac key code.
    private var pressedKeys = Set<UInt16>()
    /// Keys down in the guest, by Mac key code. Differs from `pressedKeys` where a profile translates.
    private var sentKeys = Set<UInt16>()
    private var translator = KeyTranslator()
    private var buttons: RFBClient.Buttons = []
    private var position = (x: 0, y: 0)

    public init(client: RFBClient) { self.client = client }

    /// Where the pointer was last sent, in guest pixels, and whether the left button is held.
    public var pointer: (x: Int, y: Int, leftDown: Bool) {
        lock.withLock { (position.x, position.y, buttons.contains(.left)) }
    }

    /// Where the left button last went down, in guest pixels. A window the user drags keeps this
    /// point under the pointer, so it says where the window goes.
    public var leftPressedAt: (x: Int, y: Int)? { lock.withLock { leftPress } }
    private var leftPress: (x: Int, y: Int)?

    /// Where the guest screen is drawn inside a view of `viewSize`. `.fit`: scaled to fit, centred, aspect
    /// kept. `.stretch`: the whole view. `.actualSize`: one guest pixel per point, centred, scaled down
    /// only when the view is smaller than the guest's screen.
    public static func screenRect(viewSize: CGSize, framebuffer: RFBClient.Size, scaling: VMBehavior.Scaling = .fit) -> CGRect {
        guard framebuffer.width > 0, framebuffer.height > 0, viewSize.width > 0, viewSize.height > 0 else { return .zero }
        if scaling == .stretch { return CGRect(origin: .zero, size: viewSize) }
        var scale = min(viewSize.width / CGFloat(framebuffer.width), viewSize.height / CGFloat(framebuffer.height))
        if scaling == .actualSize { scale = min(scale, 1) }
        let size = CGSize(width: CGFloat(framebuffer.width) * scale, height: CGFloat(framebuffer.height) * scale)
        return CGRect(x: (viewSize.width - size.width) / 2, y: (viewSize.height - size.height) / 2, width: size.width, height: size.height)
    }

    /// Guest pixel under a point in the view (origin top-left). Points outside the picture clamp to its edge.
    public static func framebufferPoint(viewPoint: CGPoint, viewSize: CGSize, framebuffer: RFBClient.Size,
                                        scaling: VMBehavior.Scaling = .fit) -> (x: Int, y: Int)? {
        let rect = screenRect(viewSize: viewSize, framebuffer: framebuffer, scaling: scaling)
        guard rect.width > 0, rect.height > 0 else { return nil }
        let x = Int(((viewPoint.x - rect.minX) / rect.width * CGFloat(framebuffer.width)).rounded(.down))
        let y = Int(((viewPoint.y - rect.minY) / rect.height * CGFloat(framebuffer.height)).rounded(.down))
        return (min(max(x, 0), framebuffer.width - 1), min(max(y, 0), framebuffer.height - 1))
    }

    public func movePointer(toX x: Int, y: Int) {
        let mask = lock.withLock { () -> RFBClient.Buttons in position = (x, y); return buttons }
        client.sendPointer(x: x, y: y, buttons: mask)
    }

    public func setButton(_ button: RFBClient.Buttons, down: Bool) {
        let (mask, p) = lock.withLock { () -> (RFBClient.Buttons, (x: Int, y: Int)) in
            if down { buttons.insert(button) } else { buttons.remove(button) }
            if button == .left, down { leftPress = position }
            return (buttons, position)
        }
        client.sendPointer(x: p.x, y: p.y, buttons: mask)
    }

    /// One wheel notch per call: RFB sends the wheel as a button press and release.
    public func scroll(up: Bool) {
        let (mask, p) = lock.withLock { (buttons, position) }
        client.sendPointer(x: p.x, y: p.y, buttons: mask.union(up ? .wheelUp : .wheelDown))
        client.sendPointer(x: p.x, y: p.y, buttons: mask)
    }

    /// The VM's input settings, kept on the display connection so every view of the VM shares them.
    public var settings: GuestInputSettings { client.inputSettings }

    /// Returns false when the key has no PC equivalent.
    @discardableResult
    public func key(macKeyCode code: UInt16, down: Bool) -> Bool {
        guard KeyMap.scancode(forMacKeyCode: code) != nil else { return false }
        let keys = lock.withLock { () -> [KeyTranslator.Key] in
            // A key-up for a key that is not down is dropped; a repeated key-down is passed on (auto-repeat).
            if down { pressedKeys.insert(code) } else if pressedKeys.remove(code) == nil { return [] }
            translator.profile = client.inputSettings.commandKey
            let keys = translator.translate(code: code, down: down)
            for key in keys { if key.down { sentKeys.insert(key.code) } else { sentKeys.remove(key.code) } }
            return keys
        }
        for key in keys {
            if let scancode = KeyMap.scancode(forMacKeyCode: key.code) { client.sendKey(scancode: scancode, down: key.down) }
        }
        return true
    }

    public func isDown(macKeyCode code: UInt16) -> Bool { lock.withLock { pressedKeys.contains(code) } }

    /// Releases everything still held. Call when the view loses focus, or keys stick down in the guest.
    public func releaseAll() {
        let (keys, mask, p) = lock.withLock { () -> (Set<UInt16>, RFBClient.Buttons, (x: Int, y: Int)) in
            let k = sentKeys, b = buttons
            pressedKeys.removeAll(); sentKeys.removeAll(); buttons = []
            translator.forgetHeldKeys()
            return (k, b, position)
        }
        for code in keys { if let s = KeyMap.scancode(forMacKeyCode: code) { client.sendKey(scancode: s, down: false) } }
        if !mask.isEmpty { client.sendPointer(x: p.x, y: p.y, buttons: []) }
    }
}

extension KeyMap {
    /// Mac key code and whether Shift is needed to type a character on a US keyboard. For scripted input.
    public static func keystroke(for character: Character) -> (code: UInt16, shift: Bool)? {
        let plain: [Character: UInt16] = [
            "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09,
            "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14,
            "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18, "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E,
            "o": 0x1F, "u": 0x20, "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29,
            "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, " ": 0x31, "`": 0x32, "\n": 0x24, "\t": 0x30,
        ]
        let shifted: [Character: Character] = [
            "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
            "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
        ]
        if let code = plain[character] { return (code, false) }
        if let base = shifted[character], let code = plain[base] { return (code, true) }
        if character.isUppercase, let lower = character.lowercased().first, let code = plain[lower] { return (code, true) }
        return nil
    }
}
