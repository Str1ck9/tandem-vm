import CoreGraphics
import Foundation

/// Constants from protocol/PROTOCOL.md. Every number is our own; none is taken from Parallels.
public enum GuestLinkConstants {
    public static let protocolVersion: UInt32 = 1
    /// vsock port the guest agent connects to on the host (CID 2).
    public static let vsockPort: UInt32 = 7700
    /// Name of the virtio-serial port exposed to QEMU guests.
    public static let serialPortName = "guestlink.0"
    public static let magic: UInt32 = 0x4B4E_4C42
    public static let headerSize = 32
    public static let maxFrameSize = 16 << 20
    public static let maxBuffers = 16
    public static let maxClipboardBytes = 1 << 20
}

public enum LinkStatus {
    public static let ok: UInt32 = 0
    public static let pending: UInt32 = 0xFFFF_FFFF
    public static let unknownOpcode: UInt32 = 0xE000_0001
    public static let badRequest: UInt32 = 0xE000_0002
    public static let notSupported: UInt32 = 0xE000_0003
    public static let `internal`: UInt32 = 0xE000_0004
    public static let cancelled: UInt32 = 0xE000_0005
    public static let busy: UInt32 = 0xE000_0006
    public static let versionMismatch: UInt32 = 0xE000_0007
    public static func errno(_ value: Int32) -> UInt32 { 0xE001_0000 | UInt32(value & 0xFFFF) }
}

public enum LinkOp {
    public static let hello: UInt16 = 0x0001
    public static let waitEvent: UInt16 = 0x0002
    public static let guestInfo: UInt16 = 0x0003
    public static let log: UInt16 = 0x0004
    public static let echo: UInt16 = 0x0005
    public static let getHostTime: UInt16 = 0x0100
    public static let clipboardSetHost: UInt16 = 0x0200
    public static let clipboardGetHost: UInt16 = 0x0201
    public static let displayReport: UInt16 = 0x0300
    public static let shareList: UInt16 = 0x0400
    public static let agentUpdateInfo: UInt16 = 0x0500
    public static let agentUpdateRead: UInt16 = 0x0501
    public static let windowReport: UInt16 = 0x0600
    public static let icon: UInt16 = 0x0601
    public static let programList: UInt16 = 0x0602
    public static let documentResult: UInt16 = 0x0603
    public static let programInfo: UInt16 = 0x0604
    public static let activityReport: UInt16 = 0x0605
    public static let execResult: UInt16 = 0x0670
}

/// How much the guest is in use, as its agent reports every 20 s (capability bit 12).
public struct GuestActivity: Codable, Equatable, Sendable {
    /// Seconds since the guest's user last pressed a key or moved the pointer; nil where the guest cannot tell.
    public var idleSeconds: Int?
    /// Processor use over all the guest's cores since the previous report, 0–100.
    public var cpuPercent: Double?
    /// Who in the guest wants the VM to stay awake, in words for the user.
    public var keepAwake: [String]
    public init(idleSeconds: Int? = nil, cpuPercent: Double? = nil, keepAwake: [String] = []) {
        self.idleSeconds = idleSeconds; self.cpuPercent = cpuPercent; self.keepAwake = keepAwake
    }

    /// The same report with the guest's numbers held to what they can mean: idle for at most a year,
    /// 0–100 % processor use, a few short reasons.
    public func sanitized() -> GuestActivity {
        GuestActivity(idleSeconds: idleSeconds.map { min(max($0, 0), 366 * 86_400) },
                      cpuPercent: cpuPercent.map { min(max($0, 0), 100) },
                      keepAwake: keepAwake.prefix(16).map { String($0.prefix(200)) })
    }
}

public enum LinkEventKind: UInt32, Sendable {
    case clipboardChanged = 1, displayResize = 2, timeResync = 3, shutdownRequest = 4, none = 5, sharesChanged = 6, windowWatch = 7, windowAction = 8,
         iconRequest = 9, programsRequest = 10, programLaunch = 11, documentOpen = 12, programInfoRequest = 13,
         dropFiles = 32, displayScale = 36,
         execRequest = 40, workArea = 44, dragOutQuery = 45, dragOutFetch = 46
}

/// What a guest program is, for making a Mac-side launcher: where its program file is (empty for a
/// store app) and the file name extensions it opens, each with its leading dot.
public struct GuestProgramInfo: Codable, Equatable, Sendable {
    public var id: String
    public var target: String
    public var extensions: [String]
    public init(id: String, target: String = "", extensions: [String] = []) {
        self.id = id; self.target = target; self.extensions = extensions
    }
}

/// The guest's answer to a request to open shared documents in a program.
public struct GuestDocumentResult: Equatable, Sendable {
    public enum Status: UInt32, Sendable { case ok = 0, unreachable = 1, failed = 2, unknownProgram = 3, notSupported = 4 }
    public var request: UInt32
    public var status: Status
    /// For the user, when the status is not `ok`.
    public var message: String
    public init(request: UInt32, status: Status, message: String = "") {
        self.request = request; self.status = status; self.message = message
    }
}

public struct LinkEvent: Equatable, Sendable {
    public var kind: LinkEventKind
    public var arg0: UInt32
    public var arg1: UInt32
    public var data: Data
    public init(_ kind: LinkEventKind, arg0: UInt32 = 0, arg1: UInt32 = 0, data: Data = Data()) {
        self.kind = kind; self.arg0 = arg0; self.arg1 = arg1; self.data = data
    }
}

public enum GuestOSKind: UInt32, Sendable { case linux = 1, windows = 2, macos = 3 }

/// What the guest reports about itself (`GUEST_INFO`).
public struct GuestInfo: Codable, Equatable, Sendable {
    public var hostname: String?
    public var osName: String?
    public var osVersion: String?
    public var kernel: String?
    public var ipAddresses: [String]?
    /// The guest's time zone, in seconds east of UTC, when the agent reports it (Windows).
    public var utcOffsetSeconds: Int?
}

/// One top-level window of the guest's desktop, in physical pixels of the guest's screen.
public struct GuestWindow: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case app, popup, taskbar }
    public enum State: String, Codable, Sendable { case normal, minimized, maximized }
    public var id: UInt64
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public var pid: UInt32
    public var kind: Kind
    public var state: State
    public var active: Bool
    public var title: String
    /// The window class, for telling system windows apart.
    public var `class`: String
    /// File name of the program that owns the window, for example `notepad.exe`.
    public var app: String
}

/// The guest's desktop size and its windows, front-most first.
public struct GuestWindowList: Codable, Equatable, Sendable {
    public var desktop: [Int]
    public var windows: [GuestWindow]
    /// The window the user is dragging, as it was when the drag began (agents with capability bit 15).
    public var moving: GuestWindowMove?
    public init(desktop: [Int], windows: [GuestWindow], moving: GuestWindowMove? = nil) {
        self.desktop = desktop; self.windows = windows; self.moving = moving
    }
}

extension GuestWindowList {
    /// The largest coordinate or size taken from a guest's report. Real desktops are a few thousand
    /// pixels; clamping keeps the integer arithmetic of window geometry far from overflowing (a report
    /// with Int.max in it used to trap the app).
    public static let coordinateLimit = 1 << 20

    /// The same report with every number clamped to what a real desktop can hold.
    public func sanitized() -> GuestWindowList {
        var out = self
        out.desktop = desktop.map(Self.size)
        out.windows = windows.map { window in
            var w = window
            w.x = Self.coordinate(w.x); w.y = Self.coordinate(w.y)
            w.width = Self.size(w.width); w.height = Self.size(w.height)
            return w
        }
        out.moving = moving?.sanitized()
        return out
    }

    static func coordinate(_ v: Int) -> Int { min(max(v, -coordinateLimit), coordinateLimit) }
    static func size(_ v: Int) -> Int { min(max(v, 0), coordinateLimit) }
}

extension GuestWindowMove {
    /// The same move with every number clamped (`GuestWindowList.coordinateLimit`).
    public func sanitized() -> GuestWindowMove {
        var m = self
        m.x = GuestWindowList.coordinate(x); m.y = GuestWindowList.coordinate(y)
        m.width = GuestWindowList.size(width); m.height = GuestWindowList.size(height)
        m.pointerX = GuestWindowList.coordinate(pointerX); m.pointerY = GuestWindowList.coordinate(pointerY)
        return m
    }
}

/// A move or resize of a guest window by the user: its frame and the pointer when it began.
public struct GuestWindowMove: Codable, Equatable, Sendable {
    public var id: UInt64
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public var pointerX: Int
    public var pointerY: Int
    /// Which edge or corner the user grabbed when this is a resize; nil for a move (and from older agents).
    public var edge: Edge?
    public enum Edge: String, Codable, Sendable {
        case left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight
        var movesLeft: Bool { self == .left || self == .topLeft || self == .bottomLeft }
        var movesRight: Bool { self == .right || self == .topRight || self == .bottomRight }
        var movesTop: Bool { self == .top || self == .topLeft || self == .topRight }
        var movesBottom: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }
    }
    public init(id: UInt64, x: Int, y: Int, width: Int, height: Int, pointerX: Int, pointerY: Int, edge: Edge? = nil) {
        self.id = id; self.x = x; self.y = y; self.width = width; self.height = height; self.pointerX = pointerX; self.pointerY = pointerY
        self.edge = edge
    }
    private enum CodingKeys: String, CodingKey { case id, x, y, width, height, pointerX, pointerY, edge }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UInt64.self, forKey: .id)
        x = try c.decode(Int.self, forKey: .x); y = try c.decode(Int.self, forKey: .y)
        width = try c.decode(Int.self, forKey: .width); height = try c.decode(Int.self, forKey: .height)
        pointerX = try c.decode(Int.self, forKey: .pointerX); pointerY = try c.decode(Int.self, forKey: .pointerY)
        // An edge this host does not know is treated as a move rather than failing the whole report.
        edge = (try? c.decodeIfPresent(String.self, forKey: .edge)).flatMap { $0.flatMap(Edge.init(rawValue:)) }
    }
}

/// A program the guest's user can start, as its Start menu lists it. `id` is opaque: it goes back to
/// the guest unchanged to start the program or to ask for its icon.
public struct GuestProgram: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var name: String
    public var id: String
    public init(name: String, id: String) { self.name = name; self.id = id }
}

public struct GuestProgramList: Codable, Equatable, Sendable {
    public var programs: [GuestProgram]
}

/// What an icon is asked for: the program behind a window, or a program from the list.
public enum GuestIconKey: Hashable, Sendable {
    case window(UInt64)
    case program(String)

    var kind: UInt32 { switch self { case .window: 1; case .program: 2 } }
    var data: Data {
        switch self {
        case .window(let id): var d = Data(); d.appendLE(id); return d
        case .program(let id): return Data(id.utf8)
        }
    }

    init?(kind: UInt32, data: Data) {
        switch kind {
        case 1: guard data.count >= 8 else { return nil }; self = .window(data.readLE(UInt64.self, at: 0))
        case 2: guard let id = String(data: data, encoding: .utf8) else { return nil }; self = .program(id)
        default: return nil
        }
    }
}

/// An icon from the guest: 32-bit BGRA pixels, top row first, colour premultiplied by opacity.
/// `width` and `height` are 0 when the guest found no icon.
public struct GuestIcon: Equatable, Sendable {
    public var key: GuestIconKey
    public var width: Int
    public var height: Int
    public var pixels: Data

    public var isEmpty: Bool { width == 0 || height == 0 }

    public var cgImage: CGImage? {
        guard width > 0, height > 0, pixels.count == width * height * 4, let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

public enum GuestWindowAction: UInt32, Sendable { case activate = 1, close = 2, minimize = 3, restore = 4 }

// MARK: Little-endian helpers

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
    /// Reads an integer at `offset` from the start of this data (not from `startIndex` of a slice's parent).
    func readLE<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        var value: T = 0
        let start = startIndex + offset
        _ = Swift.withUnsafeMutableBytes(of: &value) { copyBytes(to: $0, from: start..<start + MemoryLayout<T>.size) }
        return T(littleEndian: value)
    }
}
