import Foundation
import VMCore

/// A request received from the guest, with the means to answer it now or later.
public final class LinkRequest: @unchecked Sendable {
    public let frame: Frame
    private weak var session: LinkSession?
    private let lock = NSLock()
    private var answered = false
    let generation: Int

    init(frame: Frame, session: LinkSession, generation: Int) {
        self.frame = frame; self.session = session; self.generation = generation
    }

    public var opcode: UInt16 { frame.opcode }
    public var inline: Data { frame.inline }

    /// Payload of buffer `index` if the guest sent one.
    public func input(_ index: Int) -> Data? {
        guard index < frame.buffers.count, frame.buffers[index].flags & LinkBuffer.flagIn != 0 else { return nil }
        return frame.buffers[index].data ?? Data()
    }

    /// Capacity the guest offered for output buffer `index`, or nil if it is not an output buffer.
    public func outputCapacity(_ index: Int) -> Int? {
        guard index < frame.buffers.count, frame.buffers[index].flags & LinkBuffer.flagOut != 0 else { return nil }
        return Int(frame.buffers[index].length)
    }

    /// Sends the reply. `outputs` maps buffer index to returned bytes. A second call is ignored.
    public func reply(status: UInt32 = LinkStatus.ok, inline: Data = Data(), outputs: [Int: Data] = [:]) {
        let first: Bool = lock.withLock { let f = !answered; answered = true; return f }
        guard first, let session else { return }
        var buffers = frame.buffers.map { LinkBuffer(flags: $0.flags, length: $0.length) }
        for (index, data) in outputs where index < buffers.count && buffers[index].flags & LinkBuffer.flagOut != 0 {
            buffers[index].data = data.prefix(Int(frame.buffers[index].length))
        }
        for i in buffers.indices where buffers[i].flags & LinkBuffer.flagOut != 0 && buffers[i].data == nil {
            buffers[i].data = Data()
        }
        session.send(Frame(requestId: frame.requestId, kind: .reply, opcode: frame.opcode, status: status,
                           inline: inline, buffers: buffers), generation: generation)
    }
}

/// One guest agent connection: reads frames, hands requests to the dispatcher, delivers events by long-poll.
public final class LinkSession: @unchecked Sendable {
    private let stream: GuestStream
    private let dispatcher: LinkDispatcher
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var generation = 0
    private var waiter: LinkRequest?
    private var queuedEvents: [LinkEvent] = []
    private var _hello: Hello?
    private var _guestInfo: GuestInfo?

    public struct Hello: Equatable, Sendable {
        public var protocolVersion: UInt32
        public var os: GuestOSKind?
        public var capabilities: UInt32
        public var agentVersion: String
    }

    public var onHello: (@Sendable (Hello) -> Void)?
    public var onGuestInfo: (@Sendable (GuestInfo) -> Void)?
    public var onClose: (@Sendable () -> Void)?

    public init(stream: GuestStream, dispatcher: LinkDispatcher) {
        self.stream = stream; self.dispatcher = dispatcher
    }

    public var hello: Hello? { lock.withLock { _hello } }
    public var guestInfo: GuestInfo? { lock.withLock { _guestInfo } }
    public var isConnected: Bool { hello != nil }

    /// Reads until the stream ends. Call on a dedicated thread.
    public func run() {
        var decoder = FrameDecoder()
        while true {
            let frames: [Frame]
            if decoder.hasPartialFrame {
                // Stall rule: an incomplete frame that stops growing is abandoned.
                let result: Data?
                do { result = try stream.read(max: 65536, timeout: 1.0) } catch { break }
                if let data = result {
                    if data.isEmpty { break }
                    frames = decoder.feed(data)
                } else {
                    frames = decoder.resyncAfterStall()
                }
            } else {
                guard let data = try? stream.read(max: 65536), !data.isEmpty else { break }
                frames = decoder.feed(data)
            }
            for frame in frames where frame.kind == .request {
                let request = LinkRequest(frame: frame, session: self, generation: lock.withLock { generation })
                dispatcher.dispatch(request, session: self)
            }
        }
        lock.withLock { _hello = nil; waiter = nil; queuedEvents.removeAll() }
        onClose?()
    }

    public func close() { stream.close() }

    func send(_ frame: Frame, generation requestGeneration: Int) {
        // A reply to a request from before the last HELLO belongs to a dead session: drop it.
        guard lock.withLock({ requestGeneration == generation }) else { return }
        let data = frame.encode()
        writeLock.withLock { try? stream.write(data) }
    }

    // MARK: Called by the core service

    /// `HELLO` starts a new session on the same stream: forget everything older.
    func beginSession(_ hello: Hello, request: LinkRequest) -> Int {
        let newGeneration: Int = lock.withLock {
            generation += 1
            waiter = nil
            queuedEvents.removeAll()
            _hello = hello
            _guestInfo = nil
            return generation
        }
        onHello?(hello)
        return newGeneration
    }

    func setGuestInfo(_ info: GuestInfo) {
        lock.withLock { _guestInfo = info }
        onGuestInfo?(info)
    }

    func park(waiter request: LinkRequest) {
        // A wait from an agent that has not said HELLO to this host is left unanswered on purpose. It
        // comes from an agent that was talking to another host process when its VM was suspended; the
        // silence is what tells it to say HELLO again. Answering would keep it waiting for ever on a
        // session this host knows nothing about (seen 2026-11-15: a resumed VM whose agent never came back).
        guard lock.withLock({ _hello != nil }) else { return }
        let (event, previous): (LinkEvent?, LinkRequest?) = lock.withLock {
            if !queuedEvents.isEmpty { return (queuedEvents.removeFirst(), nil) }
            let old = waiter
            waiter = request
            return (nil, old)
        }
        previous?.reply(status: LinkStatus.cancelled)
        if let event { deliver(event, to: request); return }
        // Keep-alive: a wait is answered with NONE after a few seconds. An agent whose wait goes
        // unanswered for longer knows the host lost it (a resumed VM talks to a new host process)
        // and says HELLO again.
        let id = request.frame.requestId
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.keepAliveInterval) { [weak self] in
            guard let self else { return }
            let expired: LinkRequest? = self.lock.withLock {
                guard let w = self.waiter, w.frame.requestId == id, w === request else { return nil }
                self.waiter = nil
                return w
            }
            if let expired { self.deliver(LinkEvent(.none), to: expired) }
        }
    }

    /// How long a `WAIT_EVENT` stays unanswered when there is nothing to report.
    nonisolated(unsafe) public static var keepAliveInterval: TimeInterval = 5

    // MARK: Events

    /// Sends an event to the guest now if it is waiting, otherwise queues it (bounded).
    public func post(_ event: LinkEvent) {
        let request: LinkRequest? = lock.withLock {
            guard _hello != nil else { return nil }
            if let w = waiter { waiter = nil; return w }
            // Coalesce: only the latest event of each kind matters.
            queuedEvents.removeAll { $0.kind == event.kind }
            queuedEvents.append(event)
            return nil
        }
        if let request { deliver(event, to: request) }
    }

    private func deliver(_ event: LinkEvent, to request: LinkRequest) {
        var inline = Data()
        inline.appendLE(event.kind.rawValue); inline.appendLE(event.arg0); inline.appendLE(event.arg1)
        request.reply(inline: inline, outputs: [0: event.data])
    }
}

/// Routes requests to services by opcode range.
public final class LinkDispatcher: @unchecked Sendable {
    public typealias Handler = @Sendable (LinkRequest, LinkSession) -> Void
    private struct Entry { var range: ClosedRange<UInt16>; var name: String; var handler: Handler }
    private var entries: [Entry] = []
    private let lock = NSLock()

    public init() {}

    /// Registers a service. Throws if the range overlaps one already registered.
    public func register(_ range: ClosedRange<UInt16>, name: String, handler: @escaping Handler) throws {
        try lock.withLock {
            if let clash = entries.first(where: { $0.range.overlaps(range) }) {
                throw VMError("Opcode range of “\(name)” overlaps “\(clash.name)”.")
            }
            entries.append(Entry(range: range, name: name, handler: handler))
        }
    }

    public func serviceName(for opcode: UInt16) -> String? {
        lock.withLock { entries.first { $0.range.contains(opcode) }?.name }
    }

    func dispatch(_ request: LinkRequest, session: LinkSession) {
        let handler = lock.withLock { entries.first { $0.range.contains(request.opcode) }?.handler }
        guard let handler else { request.reply(status: LinkStatus.unknownOpcode); return }
        handler(request, session)
    }
}
