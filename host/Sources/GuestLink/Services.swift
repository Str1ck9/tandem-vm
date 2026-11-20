import Foundation
import VMCore

/// Host clipboard access. The app supplies an `NSPasteboard` implementation; tests supply a stub.
public protocol ClipboardProvider: AnyObject, Sendable {
    func text() -> String?
    func setText(_ text: String)
}

public struct DisplayReport: Equatable, Sendable {
    public var width: UInt32, height: UInt32
    /// 0 applied, 1 unsupported mode, 2 failed.
    public var result: UInt32
}

/// What the guest needs to open the Mac's shared folders: `port` is where the host serves them
/// (0 when nothing is shared), reachable from the guest at 10.0.2.2.
public struct SharesInfo: Codable, Equatable, Sendable {
    /// How the folders reach the guest: `webdav` (served on `port`), `9p` (one device per folder, tags
    /// `tandem0`, `tandem1`, … in the order of `shares`) or `virtiofs` (one device, tag `tandem`).
    public var kind: String
    public var port: Int
    public var shares: [String]
    public init(kind: String = "webdav", port: Int = 0, shares: [String] = []) { self.kind = kind; self.port = port; self.shares = shares }
}

/// Everything the host offers to one VM's guest agent. Create one per VM and attach each guest stream to it.
public final class GuestLinkHost: @unchecked Sendable {
    public let dispatcher = LinkDispatcher()
    private let lock = NSLock()
    /// Commands run in the guest and waiting for their result (Exec.swift).
    let execs = ExecRegistry()
    private var _session: LinkSession?
    private var _lastDisplayReport: DisplayReport?

    public var clipboard: ClipboardProvider?
    /// Which way the clipboard may travel, asked on every use (`SharingPolicy.clipboard`). The host
    /// drops the direction that is not allowed, whatever the guest asks for.
    public var clipboardPolicy: @Sendable () -> ClipboardSharing = { .both }
    /// Guest log lines: level (0 debug … 3 error) and message.
    public var onLog: (@Sendable (UInt32, String) -> Void)?
    public var onHello: (@Sendable (LinkSession.Hello) -> Void)?
    public var onGuestInfo: (@Sendable (GuestInfo) -> Void)?
    public var onDisplayReport: (@Sendable (DisplayReport) -> Void)?
    /// The guest's windows changed (only while `watchWindows(true)` is in effect).
    public var onWindowReport: (@Sendable (GuestWindowList) -> Void)?
    /// The guest's installed programs, after `requestPrograms()`.
    public var onProgramList: (@Sendable ([GuestProgram]) -> Void)?
    /// The answer to `requestProgramInfo`, with the program's icon as a picture file's bytes (PNG) when
    /// the guest keeps it that way (store apps); empty otherwise.
    public var onProgramInfo: (@Sendable (GuestProgramInfo, Data) -> Void)?
    /// How much the guest is in use, every 20 s from agents with capability bit 12.
    public var onActivity: (@Sendable (GuestActivity) -> Void)?
    /// The outcome of `openDocuments`.
    public var onDocumentResult: (@Sendable (GuestDocumentResult) -> Void)?
    /// An icon asked for with `requestIcon`; empty when the guest found none.
    public var onIcon: (@Sendable (GuestIcon) -> Void)?
    /// Files dropped with `dropFiles`: how far the guest has got, then the outcome (FileDropLink.swift).
    public var onDropProgress: (@Sendable (GuestDropProgress) -> Void)?
    public var onDropResult: (@Sendable (GuestDropResult) -> Void)?
    /// The guest named the files selected where a drag out of a Windows window began.
    public var onDragOutItems: (@Sendable (GuestDragOutItems) -> Void)?
    public var onDisconnect: (@Sendable () -> Void)?
    /// Icons still to ask for, and the one being waited on. One at a time: queued events of one kind
    /// replace each other, so a second request would overwrite the first.
    private var iconQueue: [(key: GuestIconKey, size: Int)] = []
    private var iconInFlight: (key: GuestIconKey, token: Int)?
    private var iconToken = 0
    /// How long an icon may take before the next one is asked for.
    public var iconTimeout: TimeInterval = 4
    /// The folders shared with this VM right now.
    public var shares: @Sendable () -> SharesInfo = { SharesInfo() }
    /// The agent build this host carries for a guest operating system; nil when it has none.
    /// The agent replaces itself with it when the two differ.
    public var agentBinary: @Sendable (GuestOSKind?) -> URL? = { _ in nil }
    private var _agentData: (url: URL, modified: Date, data: Data)?
    /// Injectable clock, so tests are deterministic.
    public var now: @Sendable () -> Date = { Date() }
    public var utcOffsetSeconds: @Sendable () -> Int = { TimeZone.current.secondsFromGMT() }

    public init() {
        // Ranges from PROTOCOL.md §5. Registration cannot clash: the ranges are disjoint by construction.
        try! dispatcher.register(0x0000...0x00FF, name: "core") { [weak self] r, s in self?.core(r, s) }
        try! dispatcher.register(0x0100...0x01FF, name: "time") { [weak self] r, s in self?.time(r, s) }
        try! dispatcher.register(0x0200...0x02FF, name: "clipboard") { [weak self] r, s in self?.clipboardService(r, s) }
        try! dispatcher.register(0x0300...0x03FF, name: "display") { [weak self] r, s in self?.display(r, s) }
        try! dispatcher.register(0x0400...0x04FF, name: "sharing") { [weak self] r, s in self?.sharing(r, s) }
        try! dispatcher.register(0x0500...0x05FF, name: "update") { [weak self] r, s in self?.update(r, s) }
        try! dispatcher.register(0x0600...0x06FF, name: "windows") { [weak self] r, s in self?.windows(r, s) }
    }

    public var session: LinkSession? { lock.withLock { _session } }
    public var isAgentConnected: Bool { session?.isConnected ?? false }
    public var guestInfo: GuestInfo? { session?.guestInfo }
    public var hello: LinkSession.Hello? { session?.hello }
    public var lastDisplayReport: DisplayReport? { lock.withLock { _lastDisplayReport } }

    /// Starts serving a guest stream on its own thread.
    public func attach(_ stream: GuestStream) {
        let session = LinkSession(stream: stream, dispatcher: dispatcher)
        session.onHello = { [weak self] hello in self?.onHello?(hello) }
        session.onGuestInfo = { [weak self] info in self?.onGuestInfo?(info) }
        session.onClose = { [weak self, weak session] in
            guard let self else { return }
            let wasCurrent: Bool = self.lock.withLock {
                if self._session === session { self._session = nil; return true }
                return false
            }
            if wasCurrent { self.resetIconQueue(); self.onDisconnect?() }
        }
        let previous: LinkSession? = lock.withLock { let p = _session; _session = session; return p }
        previous?.close()
        let thread = Thread { session.run() }
        thread.name = "guestlink-session"
        thread.start()
    }

    public func detach() {
        let s: LinkSession? = lock.withLock { let s = _session; _session = nil; return s }
        resetIconQueue()
        s?.close()
    }

    // MARK: Host-initiated actions (delivered as events)

    public func notifyClipboardChanged(_ text: String) {
        guard clipboardPolicy().toGuest else { return }
        let data = Data(text.utf8)
        guard data.count <= GuestLinkConstants.maxClipboardBytes else { return }
        session?.post(LinkEvent(.clipboardChanged, data: data))
    }
    public func requestDisplayResize(width: Int, height: Int) {
        session?.post(LinkEvent(.displayResize, arg0: UInt32(width), arg1: UInt32(height)))
    }
    public func notifySharesChanged() { session?.post(LinkEvent(.sharesChanged)) }
    /// Asks an agent with capability bit 6 to start or stop reporting the guest's windows.
    public func watchWindows(_ on: Bool) { session?.post(LinkEvent(.windowWatch, arg0: on ? 1 : 0)) }
    /// Asks an agent with capability bit 15 to set the guest's display scale in percent; 0 puts back
    /// the scale the guest had before the first change.
    public func setDisplayScale(_ percent: Int) { session?.post(LinkEvent(.displayScale, arg0: UInt32(max(percent, 0)))) }
    /// Limits where the guest puts maximised windows (guest pixels), or nil to put back its own work area.
    /// For agents with capability bit 17.
    public func setWorkArea(_ rect: CGRect?) {
        var data = Data()
        if let r = rect?.integral {
            for v in [r.minX, r.minY, r.width, r.height] { data.appendLE(Int32(v)) }
        }
        session?.post(LinkEvent(.workArea, data: data))
    }
    public func windowAction(_ action: GuestWindowAction, window: UInt64) {
        var data = Data(); data.appendLE(window)
        session?.post(LinkEvent(.windowAction, arg0: action.rawValue, data: data))
    }
    /// Asks an agent with capability bit 7 for the guest's installed programs (`onProgramList`).
    public func requestPrograms() { session?.post(LinkEvent(.programsRequest)) }
    /// Starts a program from the guest's list.
    public func launchProgram(id: String) { session?.post(LinkEvent(.programLaunch, data: Data(id.utf8))) }

    /// Asks an agent with capability bit 8 where a program's file is and which file types it opens
    /// (`onProgramInfo`). One at a time: a second request replaces one the guest has not fetched yet.
    public func requestProgramInfo(id: String) { session?.post(LinkEvent(.programInfoRequest, data: Data(id.utf8))) }

    /// Asks an agent with capability bit 8 to open shared documents, each named `<share>/<path below
    /// it>`, in a program from its list; an empty id means each document's default program. The outcome
    /// arrives through `onDocumentResult` with the same request number. One at a time, as above.
    public func openDocuments(request: UInt32, program: String, documents: [String]) {
        let lines = ([program] + documents).joined(separator: "\n")
        session?.post(LinkEvent(.documentOpen, arg0: request, data: Data(lines.utf8)))
    }

    /// Asks for an icon (`onIcon`), `size` pixels square. Requests are sent one at a time, in order.
    /// `first` puts the request ahead of those waiting (the user is waiting for this one) and replaces
    /// a waiting request for the same icon, which may be for another size.
    public func requestIcon(_ key: GuestIconKey, size: Int, first: Bool = false) {
        lock.withLock {
            if first {
                iconQueue.removeAll { $0.key == key }
                iconQueue.insert((key, size), at: 0)
            } else {
                if iconInFlight?.key == key || iconQueue.contains(where: { $0.key == key }) { return }
                iconQueue.append((key, size))
            }
        }
        pumpIcons()
    }

    private func resetIconQueue() {
        lock.withLock { iconQueue.removeAll(); iconInFlight = nil }
    }

    private func pumpIcons() {
        guard let session else { return }
        let next: (key: GuestIconKey, size: Int, token: Int)? = lock.withLock {
            guard iconInFlight == nil, !iconQueue.isEmpty else { return nil }
            let item = iconQueue.removeFirst()
            iconToken += 1
            iconInFlight = (item.key, iconToken)
            return (item.key, item.size, iconToken)
        }
        guard let next else { return }
        session.post(LinkEvent(.iconRequest, arg0: next.key.kind, arg1: UInt32(min(max(next.size, 16), 256)), data: next.key.data))
        // A guest that never answers must not hold up the icons behind this one.
        DispatchQueue.global().asyncAfter(deadline: .now() + iconTimeout) { [weak self] in
            guard let self else { return }
            let expired: Bool = self.lock.withLock {
                guard self.iconInFlight?.token == next.token else { return false }
                self.iconInFlight = nil
                return true
            }
            if expired { self.pumpIcons() }
        }
    }

    public func requestTimeResync() { session?.post(LinkEvent(.timeResync)) }
    public func requestGuestShutdown() { session?.post(LinkEvent(.shutdownRequest)) }
    /// Only for agents that announce capability bit 5; older ones would power off instead.
    public func requestGuestRestart() { session?.post(LinkEvent(.shutdownRequest, arg0: 1)) }

    // MARK: Services

    private func core(_ request: LinkRequest, _ session: LinkSession) {
        switch request.opcode {
        case LinkOp.hello:
            guard request.inline.count >= 12 else { request.reply(status: LinkStatus.badRequest); return }
            let version = request.inline.readLE(UInt32.self, at: 0)
            var replyInline = Data()
            replyInline.appendLE(GuestLinkConstants.protocolVersion); replyInline.appendLE(UInt32(0))
            guard version == GuestLinkConstants.protocolVersion else {
                request.reply(status: LinkStatus.versionMismatch, inline: replyInline); return
            }
            let hello = LinkSession.Hello(
                protocolVersion: version,
                os: GuestOSKind(rawValue: request.inline.readLE(UInt32.self, at: 4)),
                capabilities: request.inline.readLE(UInt32.self, at: 8),
                agentVersion: String(decoding: request.input(0) ?? Data(), as: UTF8.self))
            let generation = session.beginSession(hello, request: request)
            // The HELLO request itself belongs to the session it starts.
            LinkRequest(frame: request.frame, session: session, generation: generation).reply(inline: replyInline)
        case LinkOp.waitEvent:
            guard request.outputCapacity(0) != nil else { request.reply(status: LinkStatus.badRequest); return }
            session.park(waiter: request)
        case LinkOp.guestInfo:
            guard let data = request.input(0), let info = try? JSONDecoder().decode(GuestInfo.self, from: data) else {
                request.reply(status: LinkStatus.badRequest); return
            }
            session.setGuestInfo(info)
            request.reply()
        case LinkOp.log:
            guard request.inline.count >= 4, let data = request.input(0) else { request.reply(status: LinkStatus.badRequest); return }
            onLog?(request.inline.readLE(UInt32.self, at: 0), String(decoding: data, as: UTF8.self))
            request.reply()
        case LinkOp.echo:
            guard let data = request.input(0), let capacity = request.outputCapacity(1), capacity >= data.count else {
                request.reply(status: LinkStatus.badRequest); return
            }
            request.reply(outputs: [1: data])
        default:
            request.reply(status: LinkStatus.unknownOpcode)
        }
    }

    private func time(_ request: LinkRequest, _ session: LinkSession) {
        guard request.opcode == LinkOp.getHostTime else { request.reply(status: LinkStatus.unknownOpcode); return }
        let t = now().timeIntervalSince1970
        let seconds = Int64(t.rounded(.down))
        var inline = Data()
        inline.appendLE(seconds)
        inline.appendLE(UInt32((t - Double(seconds)) * 1_000_000_000))
        inline.appendLE(Int32(utcOffsetSeconds()))
        request.reply(inline: inline)
    }

    private func clipboardService(_ request: LinkRequest, _ session: LinkSession) {
        guard let clipboard else { request.reply(status: LinkStatus.notSupported); return }
        let allowed = clipboardPolicy()
        switch request.opcode {
        case LinkOp.clipboardSetHost:
            // Guest to Mac. Refused before the text is even decoded.
            guard allowed.toMac else { request.reply(status: LinkStatus.notSupported); return }
            guard let data = request.input(0), data.count <= GuestLinkConstants.maxClipboardBytes,
                  let text = String(data: data, encoding: .utf8) else { request.reply(status: LinkStatus.badRequest); return }
            clipboard.setText(text)
            request.reply()
        case LinkOp.clipboardGetHost:
            // Mac to guest.
            guard allowed.toGuest else { request.reply(status: LinkStatus.notSupported); return }
            guard let capacity = request.outputCapacity(0) else { request.reply(status: LinkStatus.badRequest); return }
            let data = Data((clipboard.text() ?? "").utf8)
            guard data.count <= min(capacity, GuestLinkConstants.maxClipboardBytes) else { request.reply(status: LinkStatus.badRequest); return }
            request.reply(outputs: [0: data])
        default:
            request.reply(status: LinkStatus.unknownOpcode)
        }
    }

    private func sharing(_ request: LinkRequest, _ session: LinkSession) {
        guard request.opcode == LinkOp.shareList else { request.reply(status: LinkStatus.unknownOpcode); return }
        guard let capacity = request.outputCapacity(0), let data = try? JSONEncoder().encode(shares()), data.count <= capacity else {
            request.reply(status: LinkStatus.badRequest); return
        }
        request.reply(outputs: [0: data])
    }

    /// FNV-1a, 64 bit: the checksum the agent compares its own file against.
    public static func fnv1a64(_ data: Data) -> UInt64 {
        data.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01b3 }
    }

    /// The host's agent build for this session's guest, read once and kept until the file changes.
    private func agentData(for session: LinkSession) -> Data? {
        guard let url = agentBinary(session.hello?.os) else { return nil }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        return lock.withLock {
            if let cached = _agentData, cached.url == url, cached.modified == modified { return cached.data }
            guard let data = try? Data(contentsOf: url), !data.isEmpty, data.count <= 64 << 20 else { return nil }
            _agentData = (url, modified, data)
            return data
        }
    }

    private func update(_ request: LinkRequest, _ session: LinkSession) {
        guard let data = agentData(for: session) else { request.reply(status: LinkStatus.notSupported); return }
        switch request.opcode {
        case LinkOp.agentUpdateInfo:
            var inline = Data()
            inline.appendLE(UInt32(data.count)); inline.appendLE(Self.fnv1a64(data))
            request.reply(inline: inline)
        case LinkOp.agentUpdateRead:
            guard request.inline.count >= 4, let capacity = request.outputCapacity(0) else { request.reply(status: LinkStatus.badRequest); return }
            let offset = Int(request.inline.readLE(UInt32.self, at: 0))
            guard offset <= data.count else { request.reply(status: LinkStatus.badRequest); return }
            request.reply(outputs: [0: data.subdata(in: offset..<min(offset + capacity, data.count))])
        default:
            request.reply(status: LinkStatus.unknownOpcode)
        }
    }

    private func windows(_ request: LinkRequest, _ session: LinkSession) {
        if LinkOp.fileDropRange.contains(request.opcode) { fileDrop(request); return }
        if LinkOp.dragOutRange.contains(request.opcode) { dragOut(request); return }
        switch request.opcode {
        case LinkOp.windowReport:
            guard let data = request.input(0), let list = try? JSONDecoder().decode(GuestWindowList.self, from: data), list.desktop.count == 2 else {
                request.reply(status: LinkStatus.badRequest); return
            }
            // Guest numbers are clamped here, at the edge, before any geometry is built from them.
            onWindowReport?(list.sanitized())
            request.reply()
        case LinkOp.programList:
            guard let data = request.input(0), let list = try? JSONDecoder().decode(GuestProgramList.self, from: data) else {
                request.reply(status: LinkStatus.badRequest); return
            }
            onProgramList?(list.programs)
            request.reply()
        case LinkOp.programInfo:
            guard let data = request.input(0), let info = try? JSONDecoder().decode(GuestProgramInfo.self, from: data) else {
                request.reply(status: LinkStatus.badRequest); return
            }
            onProgramInfo?(info, request.input(1) ?? Data())
            request.reply()
        case LinkOp.execResult: execResultArrived(request)
        case LinkOp.activityReport:
            guard let data = request.input(0), let activity = try? JSONDecoder().decode(GuestActivity.self, from: data) else {
                request.reply(status: LinkStatus.badRequest); return
            }
            onActivity?(activity.sanitized())
            request.reply()
        case LinkOp.documentResult:
            guard request.inline.count >= 8 else { request.reply(status: LinkStatus.badRequest); return }
            let status = GuestDocumentResult.Status(rawValue: request.inline.readLE(UInt32.self, at: 4)) ?? .failed
            let message = request.input(0).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            onDocumentResult?(GuestDocumentResult(request: request.inline.readLE(UInt32.self, at: 0), status: status, message: message))
            request.reply()
        case LinkOp.icon:
            guard request.inline.count >= 12, let keyData = request.input(0),
                  let key = GuestIconKey(kind: request.inline.readLE(UInt32.self, at: 0), data: keyData) else {
                request.reply(status: LinkStatus.badRequest); return
            }
            let width = Int(request.inline.readLE(UInt32.self, at: 4)), height = Int(request.inline.readLE(UInt32.self, at: 8))
            let pixels = request.input(1) ?? Data()
            guard width <= 256, height <= 256, pixels.count == width * height * 4 else { request.reply(status: LinkStatus.badRequest); return }
            // Whatever this answers, the guest is free for the next request.
            lock.withLock { iconInFlight = nil }
            onIcon?(GuestIcon(key: key, width: width, height: height, pixels: pixels))
            request.reply()
            pumpIcons()
        default:
            request.reply(status: LinkStatus.unknownOpcode)
        }
    }

    private func display(_ request: LinkRequest, _ session: LinkSession) {
        guard request.opcode == LinkOp.displayReport else { request.reply(status: LinkStatus.unknownOpcode); return }
        guard request.inline.count >= 12 else { request.reply(status: LinkStatus.badRequest); return }
        let report = DisplayReport(width: request.inline.readLE(UInt32.self, at: 0),
                                   height: request.inline.readLE(UInt32.self, at: 4),
                                   result: request.inline.readLE(UInt32.self, at: 8))
        lock.withLock { _lastDisplayReport = report }
        onDisplayReport?(report)
        request.reply()
    }
}
