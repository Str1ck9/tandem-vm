import Foundation
import VMCore

/// Client for QEMU's built-in display server (RFB, the VNC protocol), used to show a QEMU guest's screen inside
/// the app. It talks to a unix socket that only this user can reach, so there is no authentication step.
///
/// The framebuffer is kept as 32-bit pixels in memory order B, G, R, X.
public final class RFBClient: @unchecked Sendable {
    public struct Size: Equatable, Sendable {
        public var width: Int
        public var height: Int
        public init(width: Int, height: Int) { self.width = width; self.height = height }
    }

    /// The guest's mouse pointer image: 32-bit R, G, B, A pixels (not premultiplied) and its hot spot.
    public struct Cursor: Equatable, Sendable {
        public var width: Int
        public var height: Int
        public var hotX: Int
        public var hotY: Int
        public var rgba: Data
    }

    /// Mouse buttons as RFB mask bits.
    public struct Buttons: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let left = Buttons(rawValue: 1)
        public static let middle = Buttons(rawValue: 2)
        public static let right = Buttons(rawValue: 4)
        public static let wheelUp = Buttons(rawValue: 8)
        public static let wheelDown = Buttons(rawValue: 16)
    }

    enum Encoding {
        static let raw: Int32 = 0
        static let copyRect: Int32 = 1
        static let desktopSize: Int32 = -223
        static let extendedDesktopSize: Int32 = -308
        static let richCursor: Int32 = -239
        static let extendedKeyEvent: Int32 = -258
    }

    /// Called on the reader thread when pixels changed. Coalesce before drawing.
    public var onUpdate: (@Sendable () -> Void)?
    /// Called on the reader thread when the guest changed its resolution.
    public var onResize: (@Sendable (Size) -> Void)?
    /// Called on the reader thread when the guest changed its mouse pointer image.
    public var onCursor: (@Sendable (Cursor) -> Void)?
    /// Called once when the connection ends, with the reason if it was an error.
    public var onClose: (@Sendable (String?) -> Void)?
    /// How keys, scrolling and scaling are handled for this VM. Set by the app from the VM's settings;
    /// read by every `GuestInput` and screen view on this connection.
    public var inputSettings: GuestInputSettings {
        get { stateLock.withLock { _inputSettings } }
        set { stateLock.withLock { _inputSettings = newValue } }
    }
    private var _inputSettings = GuestInputSettings()

    private let fd: Int32
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var pixels: [UInt8] = []
    private var currentSize = Size(width: 0, height: 0)
    private var closed = false
    private var extendedKeys = false
    private var extendedSize = false
    public private(set) var name = ""

    public var size: Size { stateLock.withLock { currentSize } }
    /// True once the server has confirmed it accepts hardware scancodes.
    public var supportsScancodes: Bool { stateLock.withLock { extendedKeys } }

    /// Takes ownership of a connected socket and performs the handshake.
    public init(fileDescriptor: Int32) throws {
        fd = fileDescriptor
        do { try handshake() }
        catch { Darwin.close(fd); throw error }
    }

    public static func connect(path: String, timeout: TimeInterval = 10) async throws -> RFBClient {
        try RFBClient(fileDescriptor: try await UnixSocket.connect(path: path, timeout: timeout))
    }

    /// Starts the reader thread. Set the callbacks first.
    public func start() {
        let thread = Thread { [self] in
            var reason: String? = nil
            do { try readLoop() } catch { reason = (error as? VMError)?.message ?? error.localizedDescription }
            let wasClosed = stateLock.withLock { () -> Bool in let c = closed; closed = true; return c }
            if !wasClosed { Darwin.close(fd) }
            onClose?(wasClosed ? nil : reason)
        }
        thread.name = "tandem.rfb"
        thread.start()
    }

    public func close() {
        let already = stateLock.withLock { () -> Bool in let c = closed; closed = true; return c }
        guard !already else { return }
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    /// Copies the current framebuffer. `pixels.count == size.width * size.height * 4`.
    public func snapshot() -> (size: Size, pixels: Data) {
        stateLock.withLock { (currentSize, Data(pixels)) }
    }

    // MARK: Input

    /// When a key press or pointer event was last sent to the guest; nil if none was. The idle timer reads it.
    public var lastInputAt: Date? { stateLock.withLock { _lastInputAt } }
    private var _lastInputAt: Date?

    public func sendPointer(x: Int, y: Int, buttons: Buttons) {
        let s = size
        guard s.width > 0, s.height > 0 else { return }
        stateLock.withLock { _lastInputAt = Date() }
        var m = Message(type: 5)
        m.u8(buttons.rawValue)
        m.u16(UInt16(clamping: min(max(x, 0), s.width - 1)))
        m.u16(UInt16(clamping: min(max(y, 0), s.height - 1)))
        send(m)
    }

    /// Sends a key by PC scancode (`KeyMap`). Ignored until the server has confirmed scancode support.
    public func sendKey(scancode: UInt8, down: Bool) {
        guard supportsScancodes else { return }
        stateLock.withLock { _lastInputAt = Date() }
        var m = Message(type: 255)
        m.u8(0) // QEMU extended key event
        m.u16(down ? 1 : 0)
        m.u32(0) // keysym: unused when a scancode is given
        m.u32(UInt32(scancode))
        send(m)
    }

    /// Asks the server to change the guest display to this size. The guest decides whether to follow.
    /// Ignored until the server has said it accepts such requests.
    public func requestDesktopSize(width: Int, height: Int) {
        guard supportsResizeRequests, width > 0, height > 0 else { return }
        var m = Message(type: 251)
        m.pad(1)
        m.u16(UInt16(clamping: width)); m.u16(UInt16(clamping: height))
        m.u8(1); m.pad(1) // one screen
        m.u32(0); m.u16(0); m.u16(0)
        m.u16(UInt16(clamping: width)); m.u16(UInt16(clamping: height))
        m.u32(0)
        send(m)
    }

    public var supportsResizeRequests: Bool { stateLock.withLock { extendedSize } }

    // MARK: Protocol

    private func handshake() throws {
        let version = try read(12)
        guard version.starts(with: Data("RFB 003.".utf8)) else { throw VMError("The display server sent an unexpected greeting.") }
        try write(Data("RFB 003.008\n".utf8))
        let count = Int(try read(1)[0])
        guard count > 0 else {
            let length = Int(try readU32())
            throw VMError("The display server refused the connection.", detail: String(decoding: try read(length), as: UTF8.self))
        }
        guard try read(count).contains(1) else { throw VMError("The display server requires a password, which is not supported.") }
        try write(Data([1])) // security type: none
        guard try readU32() == 0 else { throw VMError("The display server rejected the connection.") }
        try write(Data([1])) // shared session

        let width = Int(try readU16()), height = Int(try readU16())
        _ = try read(16) // server pixel format, replaced below
        name = String(decoding: try read(Int(try readU32())), as: UTF8.self)
        resize(to: Size(width: width, height: height))

        var format = Message(type: 0)
        format.pad(3)
        format.u8(32); format.u8(24); format.u8(0); format.u8(1) // bpp, depth, little-endian, true colour
        format.u16(255); format.u16(255); format.u16(255)        // max red, green, blue
        format.u8(16); format.u8(8); format.u8(0)                // shifts: red, green, blue
        format.pad(3)
        send(format)

        let encodings = [Encoding.copyRect, Encoding.raw, Encoding.extendedDesktopSize, Encoding.desktopSize, Encoding.extendedKeyEvent, Encoding.richCursor]
        var set = Message(type: 2)
        set.pad(1)
        set.u16(UInt16(encodings.count))
        for e in encodings { set.u32(UInt32(bitPattern: e)) }
        send(set)
        requestUpdate(incremental: false)
    }

    private func requestUpdate(incremental: Bool) {
        let s = size
        var m = Message(type: 3)
        m.u8(incremental ? 1 : 0)
        m.u16(0); m.u16(0); m.u16(UInt16(clamping: s.width)); m.u16(UInt16(clamping: s.height))
        send(m)
    }

    private func readLoop() throws {
        while true {
            switch try read(1)[0] {
            case 0:
                _ = try read(1)
                let rectangles = Int(try readU16())
                var changed = false
                for _ in 0..<rectangles {
                    let x = Int(try readU16()), y = Int(try readU16()), w = Int(try readU16()), h = Int(try readU16())
                    let encoding = Int32(bitPattern: try readU32())
                    switch encoding {
                    case Encoding.raw:
                        let data = try read(w * h * 4)
                        blit(data, x: x, y: y, width: w, height: h)
                        changed = true
                    case Encoding.copyRect:
                        let sx = Int(try readU16()), sy = Int(try readU16())
                        copy(fromX: sx, fromY: sy, toX: x, toY: y, width: w, height: h)
                        changed = true
                    case Encoding.desktopSize:
                        let new = Size(width: w, height: h)
                        resize(to: new)
                        onResize?(new)
                    case Encoding.extendedDesktopSize:
                        // x is the reason (0 server, 1 this client, 2 another client) and y the status (0 = done).
                        let screens = Int(try read(4)[0])
                        _ = try read(screens * 16)
                        stateLock.withLock { extendedSize = true }
                        if y == 0 {
                            let new = Size(width: w, height: h)
                            if new != size { resize(to: new); onResize?(new) }
                        }
                    case Encoding.extendedKeyEvent:
                        stateLock.withLock { extendedKeys = true }
                    case Encoding.richCursor:
                        // x, y carry the hot spot. Pixels are B,G,R,X; a 1-bit mask (rows padded to bytes) says which are visible.
                        let source = try read(w * h * 4)
                        let rowBytes = (w + 7) / 8
                        let mask = try read(rowBytes * h)
                        var rgba = Data(count: w * h * 4)
                        for py in 0..<h {
                            for px in 0..<w {
                                let i = (py * w + px) * 4
                                let visible = mask[mask.startIndex + py * rowBytes + px / 8] & (0x80 >> UInt8(px % 8)) != 0
                                rgba[i] = source[source.startIndex + i + 2]
                                rgba[i + 1] = source[source.startIndex + i + 1]
                                rgba[i + 2] = source[source.startIndex + i]
                                rgba[i + 3] = visible ? 255 : 0
                            }
                        }
                        onCursor?(Cursor(width: w, height: h, hotX: x, hotY: y, rgba: rgba))
                    default:
                        throw VMError("The display server used an encoding that was not requested (\(encoding)).")
                    }
                }
                if changed { onUpdate?() }
                requestUpdate(incremental: true)
            case 1: // colour map: not used with true colour, but skip it correctly
                _ = try read(3)
                let colours = Int(try readU16())
                _ = try read(colours * 6)
            case 2: break // bell
            case 3:
                _ = try read(3)
                _ = try read(Int(try readU32())) // server clipboard text; the guest agent handles clipboard
            case let other:
                throw VMError("The display server sent an unknown message (\(other)).")
            }
        }
    }

    // MARK: Framebuffer

    private func resize(to new: Size) {
        stateLock.withLock {
            currentSize = new
            pixels = [UInt8](repeating: 0, count: max(new.width * new.height * 4, 0))
        }
    }

    private func blit(_ data: Data, x: Int, y: Int, width: Int, height: Int) {
        stateLock.withLock {
            let s = currentSize
            guard x >= 0, y >= 0, width > 0, height > 0, x + width <= s.width, y + height <= s.height else { return }
            data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                pixels.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
                    for row in 0..<height {
                        let from = source.baseAddress! + row * width * 4
                        let to = target.baseAddress! + ((y + row) * s.width + x) * 4
                        to.copyMemory(from: from, byteCount: width * 4)
                    }
                }
            }
        }
    }

    private func copy(fromX sx: Int, fromY sy: Int, toX x: Int, toY y: Int, width: Int, height: Int) {
        stateLock.withLock {
            let s = currentSize
            guard width > 0, height > 0, sx >= 0, sy >= 0, x >= 0, y >= 0,
                  sx + width <= s.width, sy + height <= s.height, x + width <= s.width, y + height <= s.height else { return }
            pixels.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
                // Walk rows away from the overlap so a row is read before it is overwritten.
                let rows = sy < y ? Array((0..<height).reversed()) : Array(0..<height)
                for row in rows {
                    let from = buffer.baseAddress! + ((sy + row) * s.width + sx) * 4
                    let to = buffer.baseAddress! + ((y + row) * s.width + x) * 4
                    memmove(to, from, width * 4)
                }
            }
        }
    }

    // MARK: Socket I/O

    private struct Message {
        var bytes: [UInt8]
        init(type: UInt8) { bytes = [type] }
        mutating func u8(_ v: UInt8) { bytes.append(v) }
        mutating func u16(_ v: UInt16) { bytes.append(UInt8(v >> 8)); bytes.append(UInt8(v & 0xFF)) }
        mutating func u32(_ v: UInt32) { u16(UInt16(v >> 16)); u16(UInt16(v & 0xFFFF)) }
        mutating func pad(_ n: Int) { bytes.append(contentsOf: [UInt8](repeating: 0, count: n)) }
    }

    private func send(_ message: Message) { try? write(Data(message.bytes)) }

    private func write(_ data: Data) throws {
        try writeLock.withLock {
            try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw VMError("The display connection was lost.", detail: String(cString: strerror(errno)))
                    }
                    offset += n
                }
            }
        }
    }

    private func read(_ count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            var offset = 0
            while offset < count {
                let n = Darwin.read(fd, raw.baseAddress! + offset, count - offset)
                if n == 0 { throw VMError("The display connection closed.") }
                if n < 0 {
                    if errno == EINTR { continue }
                    throw VMError("The display connection was lost.", detail: String(cString: strerror(errno)))
                }
                offset += n
            }
        }
        return data
    }

    private func readU16() throws -> UInt16 { let d = try read(2); return UInt16(d[0]) << 8 | UInt16(d[1]) }
    private func readU32() throws -> UInt32 { let d = try read(4); return d.reduce(0) { $0 << 8 | UInt32($1) } }
}

/// Mac virtual key codes to PC (XT set 1) scancodes. Keys that need the `E0` prefix have bit 7 set, which is
/// how QEMU's extended key event encodes them.
public enum KeyMap {
    public static func scancode(forMacKeyCode code: UInt16) -> UInt8? { table[code] }

    private static func e0(_ code: UInt8) -> UInt8 { code | 0x80 }

    static let table: [UInt16: UInt8] = [
        0x00: 0x1E, 0x01: 0x1F, 0x02: 0x20, 0x03: 0x21, 0x04: 0x23, 0x05: 0x22, 0x06: 0x2C, 0x07: 0x2D,
        0x08: 0x2E, 0x09: 0x2F, 0x0A: 0x56, 0x0B: 0x30, 0x0C: 0x10, 0x0D: 0x11, 0x0E: 0x12, 0x0F: 0x13,
        0x10: 0x15, 0x11: 0x14, 0x12: 0x02, 0x13: 0x03, 0x14: 0x04, 0x15: 0x05, 0x16: 0x07, 0x17: 0x06,
        0x18: 0x0D, 0x19: 0x0A, 0x1A: 0x08, 0x1B: 0x0C, 0x1C: 0x09, 0x1D: 0x0B, 0x1E: 0x1B, 0x1F: 0x18,
        0x20: 0x16, 0x21: 0x1A, 0x22: 0x17, 0x23: 0x19, 0x24: 0x1C, 0x25: 0x26, 0x26: 0x24, 0x27: 0x28,
        0x28: 0x25, 0x29: 0x27, 0x2A: 0x2B, 0x2B: 0x33, 0x2C: 0x35, 0x2D: 0x31, 0x2E: 0x32, 0x2F: 0x34,
        0x30: 0x0F, 0x31: 0x39, 0x32: 0x29, 0x33: 0x0E, 0x35: 0x01,
        // Modifiers: Command is the Windows key, Option is Alt.
        0x36: e0(0x5C), 0x37: e0(0x5B), 0x38: 0x2A, 0x39: 0x3A, 0x3A: 0x38, 0x3B: 0x1D,
        0x3C: 0x36, 0x3D: e0(0x38), 0x3E: e0(0x1D),
        // Keypad
        0x41: 0x53, 0x43: 0x37, 0x45: 0x4E, 0x47: 0x45, 0x4B: e0(0x35), 0x4C: e0(0x1C), 0x4E: 0x4A, 0x51: 0x59,
        0x52: 0x52, 0x53: 0x4F, 0x54: 0x50, 0x55: 0x51, 0x56: 0x4B, 0x57: 0x4C, 0x58: 0x4D, 0x59: 0x47,
        0x5B: 0x48, 0x5C: 0x49,
        // Function keys
        0x7A: 0x3B, 0x78: 0x3C, 0x63: 0x3D, 0x76: 0x3E, 0x60: 0x3F, 0x61: 0x40, 0x62: 0x41, 0x64: 0x42,
        0x65: 0x43, 0x6D: 0x44, 0x67: 0x57, 0x6F: 0x58,
        // Navigation
        0x72: e0(0x52), 0x73: e0(0x47), 0x74: e0(0x49), 0x75: e0(0x53), 0x77: e0(0x4F), 0x79: e0(0x51),
        0x7B: e0(0x4B), 0x7C: e0(0x4D), 0x7D: e0(0x50), 0x7E: e0(0x48),
    ]
}
