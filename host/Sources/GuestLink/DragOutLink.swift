import Foundation

// Files dragged out of a Windows window onto the Mac (capability bit 17; PROTOCOL.md "drag out").
//
// The host notices a drag that started in an Explorer window leaving every seamless window, cancels it
// in the guest, and asks the guest which files are selected where the drag began (`DRAG_OUT_QUERY`).
// The guest answers with their paths (`DRAG_OUT_ITEMS`). The Mac then carries on the drag itself with
// file promises; when the user drops them, the host asks the guest to upload them (`DRAG_OUT_FETCH`)
// into the hidden inbox share that "Send to > Mac" also uses, and moves them to where they were dropped.

extension LinkOp {
    /// Guest → host: buffer 0 JSON `GuestDragOutItems`.
    public static let dragOutItems: UInt16 = 0x0680
    static let dragOutRange: ClosedRange<UInt16> = 0x0680...0x068F
}

extension GuestCapability {
    /// The agent sets the work area (`WORK_AREA`), names the edge of a resize, and answers drag-outs.
    public static let seamlessExtras: UInt32 = 1 << 17
}

/// What is selected where a drag began, in the guest.
public struct GuestDragOutItems: Codable, Equatable, Sendable {
    /// The guest pixel the host asked about, so a late answer to an older drag can be told apart.
    public var x: Int
    public var y: Int
    /// Full Windows paths of the selected files and folders; empty when nothing usable was selected.
    public var paths: [String]
    public var message: String?
    public init(x: Int, y: Int, paths: [String], message: String? = nil) {
        self.x = x; self.y = y; self.paths = paths; self.message = message
    }

    /// The name a path has on the Mac: its last component ("file" when that is no usable name).
    public static func fileName(_ windowsPath: String) -> String {
        let last = windowsPath.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? ""
        return isPlainName(last) ? last : "file"
    }

    /// A single file name, nothing that leads elsewhere: not empty, not "." or "..", no "/" and no NUL.
    /// Names that come from the guest are checked with this before the Mac uses them in a path.
    public static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
}

/// The request to upload files for a drop on the Mac.
public struct GuestDragOutFetch: Codable, Equatable, Sendable {
    /// Inbox upload id; starts with `dragout-` so the inbox does not deliver it to Downloads.
    public var id: String
    public var paths: [String]
    public init(id: String, paths: [String]) { self.id = id; self.paths = paths }

    public static let idPrefix = "dragout-"

    /// What the guest gets: the id, then one path per line.
    public var guestText: String { ([id] + paths.filter { !$0.contains("\n") }).joined(separator: "\n") + "\n" }
}

extension GuestLinkHost {
    /// Asks the guest which files are selected in the Explorer window at a guest pixel.
    public func queryDragOut(x: Int, y: Int) {
        session?.post(LinkEvent(.dragOutQuery, arg0: UInt32(max(0, x)), arg1: UInt32(max(0, y))))
    }

    /// Asks the guest to upload files into the inbox under `fetch.id`. The data is text: the id, then one
    /// path per line (UTF-8), which the agent reads without a JSON parser.
    public func fetchDragOut(_ fetch: GuestDragOutFetch) {
        session?.post(LinkEvent(.dragOutFetch, data: Data(fetch.guestText.utf8)))
    }

    func dragOut(_ request: LinkRequest) {
        guard request.opcode == LinkOp.dragOutItems else { request.reply(status: LinkStatus.unknownOpcode); return }
        guard let data = request.input(0), let items = try? JSONDecoder().decode(GuestDragOutItems.self, from: data) else {
            request.reply(status: LinkStatus.badRequest); return
        }
        onDragOutItems?(items)
        request.reply()
    }
}
