import Foundation

// Files dropped from the Mac onto a guest window (capability bit 14; PROTOCOL.md "file drop").

extension LinkOp {
    /// Guest → host while a drop is copied: buffer 0 JSON `{"id":…,"bytes":…,"total":…}`.
    public static let dropProgress: UInt16 = 0x0650
    /// Guest → host when a drop is done: buffer 0 JSON `GuestDropResult`.
    public static let dropResult: UInt16 = 0x0651
    static let fileDropRange: ClosedRange<UInt16> = 0x0650...0x065F
}

public enum GuestCapability {
    /// The agent takes files dropped on a guest window (`DROP_FILES`) and can send files to the Mac.
    public static let fileDrop: UInt32 = 1 << 14
}

public struct GuestDropProgress: Codable, Equatable, Sendable {
    public var id: String
    public var bytes: UInt64
    public var total: UInt64
    public init(id: String, bytes: UInt64, total: UInt64) { self.id = id; self.bytes = bytes; self.total = total }
}

public struct GuestDropResult: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// Copied into the folder under the pointer (an Explorer window or the desktop).
        case copied
        /// Nothing that holds files was under the pointer: copied into the user's Downloads folder.
        case fallback
        case failed
    }
    public var id: String
    public var status: Status
    /// The Windows folder the files went to.
    public var folder: String
    /// Files copied (folders not counted).
    public var files: Int
    /// For the user, when the status is `failed`.
    public var message: String?
    public init(id: String, status: Status, folder: String = "", files: Int = 0, message: String? = nil) {
        self.id = id; self.status = status; self.folder = folder; self.files = files; self.message = message
    }
}

extension GuestLinkHost {
    /// The largest manifest an agent can take in one event (its event buffer).
    public static let maxDropManifestBytes = 1 << 20

    /// Asks an agent with `GuestCapability.fileDrop` to fetch dropped files. `x`, `y`: the guest pixel
    /// the files were dropped on; `manifest`: `FileDrop.Manifest.guestText`. One drop at a time: a second
    /// one replaces a drop the guest has not picked up yet.
    public func dropFiles(manifest: Data, x: Int, y: Int) {
        session?.post(LinkEvent(.dropFiles, arg0: UInt32(max(0, x)), arg1: UInt32(max(0, y)), data: manifest))
    }

    func fileDrop(_ request: LinkRequest) {
        switch request.opcode {
        case LinkOp.dropProgress:
            guard let data = request.input(0), let progress = try? JSONDecoder().decode(GuestDropProgress.self, from: data) else {
                request.reply(status: LinkStatus.badRequest); return
            }
            onDropProgress?(progress)
            request.reply()
        case LinkOp.dropResult:
            guard let data = request.input(0), let result = try? JSONDecoder().decode(GuestDropResult.self, from: data) else {
                request.reply(status: LinkStatus.badRequest); return
            }
            onDropResult?(result)
            request.reply()
        default:
            request.reply(status: LinkStatus.unknownOpcode)
        }
    }
}
