import CoreGraphics
import FuzzSupport
import VMCore
import XCTest
@testable import GuestLink

/// Property and fuzz tests for everything the host reads from a guest: the frame decoder, every
/// service's request parsing, and the window geometry built from guest reports. The guest is not
/// trusted; nothing it sends may crash or hang the app. Short by default; TANDEM_FUZZ_SCALE=200 for long runs.
final class FrameFuzzTests: XCTestCase {
    private func randomFrame(_ rng: inout SeededRandom) -> Frame {
        let kind: Frame.Kind = rng.chance(0.5) ? .request : .reply
        var buffers: [LinkBuffer] = []
        for _ in 0..<rng.int(0...GuestLinkConstants.maxBuffers) {
            let flags = rng.pick([LinkBuffer.flagIn, LinkBuffer.flagOut, 0, 3, rng.interesting32()])
            let carries = flags & (kind == .reply ? LinkBuffer.flagOut : LinkBuffer.flagIn) != 0
            buffers.append(carries ? LinkBuffer(flags: flags, length: 0, data: rng.bytes(rng.int(0...300)))
                                   : LinkBuffer(flags: flags, length: rng.interesting32()))
        }
        var frame = Frame(requestId: rng.next(), kind: kind, opcode: UInt16(truncatingIfNeeded: rng.next()),
                          status: rng.interesting32(), inline: rng.bytes(rng.int(0...40)), buffers: buffers)
        // What decode gives back: a payload buffer's length is its data's size.
        for i in frame.buffers.indices where frame.buffers[i].data != nil {
            frame.buffers[i].length = UInt32(frame.buffers[i].data!.count)
        }
        return frame
    }

    /// Feeds `data` in random pieces, with the stall rule applied now and then.
    private func feedInPieces(_ data: Data, _ rng: inout SeededRandom, stalls: Bool = true) -> (frames: [Frame], decoder: FrameDecoder) {
        var decoder = FrameDecoder(); var frames: [Frame] = []; var at = 0
        while at < data.count {
            let n = min(data.count - at, rng.int(1...max(1, rng.chance(0.3) ? 7 : 4096)))
            frames += decoder.feed(data.subdata(in: at..<at + n))
            at += n
            if stalls, rng.chance(0.02) { frames += decoder.resyncAfterStall() }
        }
        return (frames, decoder)
    }

    func testRandomFramesRoundTripInAnyPieces() {
        Fuzz.cases(400) { rng, seed in
            let frames = (0..<rng.int(1...4)).map { _ in randomFrame(&rng) }
            let bytes = frames.reduce(Data()) { $0 + $1.encode() }
            let (decoded, decoder) = feedInPieces(bytes, &rng, stalls: false)
            XCTAssertEqual(decoded, frames, "seed \(seed)")
            XCTAssertEqual(decoder.discardedBytes, 0, "seed \(seed)")
            XCTAssertFalse(decoder.hasPartialFrame, "seed \(seed)")
        }
    }

    func testRandomBytesNeverCrashAndAreAccountedFor() {
        Fuzz.cases(300) { rng, seed in
            // Random bytes, sometimes seeded with the magic so the header checks are reached.
            var data = rng.bytes(rng.int(0...4000))
            for _ in 0..<rng.int(0...6) where data.count >= 4 {
                var magic = GuestLinkConstants.magic.littleEndian
                let at = rng.int(0...(data.count - 4))
                withUnsafeBytes(of: &magic) { data.replaceSubrange(at..<at + 4, with: $0) }
            }
            var (_, decoder) = feedInPieces(data, &rng)
            _ = decoder.resyncAfterStall()
            XCTAssertLessThanOrEqual(decoder.discardedBytes, data.count, "seed \(seed)")
        }
    }

    /// Valid frames, damaged, then given a correct CRC again so the structural checks behind it are the
    /// ones that must hold. A frame that still decodes must be one the encoder could have written.
    func testMutatedFramesWithRepairedCRC() {
        Fuzz.cases(1500) { rng, seed in
            var bytes = randomFrame(&rng).encode()
            if rng.chance(0.5) {
                // Header fields to boundary values: total size, inline size, buffer count, kind.
                let field = rng.pick([4, 16, 24, 28])
                var v = rng.interesting32().littleEndian
                let width = field == 16 || field == 28 ? 2 : 4
                withUnsafeBytes(of: &v) { bytes.replaceSubrange(field..<field + width, with: $0.prefix(width)) }
            } else {
                bytes = Fuzz.mutate(bytes, using: &rng)
            }
            if bytes.count >= GuestLinkConstants.headerSize + 4, rng.chance(0.9) {
                let total = Int(bytes.readLE(UInt32.self, at: 4))
                if total >= GuestLinkConstants.headerSize + 4, total <= bytes.count {
                    var crc = Frame.crc32(bytes.prefix(total - 4)).littleEndian
                    withUnsafeBytes(of: &crc) { bytes.replaceSubrange(total - 4..<total, with: $0) }
                }
            }
            let (frames, _) = feedInPieces(bytes, &rng)
            for frame in frames {
                XCTAssertLessThanOrEqual(frame.buffers.count, GuestLinkConstants.maxBuffers, "seed \(seed)")
                var again = FrameDecoder()
                XCTAssertEqual(again.feed(frame.encode()), [frame], "seed \(seed): a decoded frame must re-encode to itself")
            }
        }
    }

    /// A header that claims the largest allowed frame keeps the decoder waiting, but never makes it hold
    /// more than one frame's worth of bytes, and the stall rule lets it go.
    func testLargestClaimedFrameIsBoundedAndAbandoned() {
        var header = Frame(requestId: 1, kind: .request, opcode: 1, status: 0).encode()
        header.replaceSubrange(4..<8, with: withUnsafeBytes(of: UInt32(GuestLinkConstants.maxFrameSize).littleEndian) { Data($0) })
        var decoder = FrameDecoder()
        XCTAssertTrue(decoder.feed(header).isEmpty)
        XCTAssertTrue(decoder.hasPartialFrame)
        let good = Frame(requestId: 2, kind: .request, opcode: 5, status: 0).encode()
        XCTAssertEqual(decoder.resyncAfterStall() + decoder.feed(good), [Frame(requestId: 2, kind: .request, opcode: 5, status: 0)])
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func add() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

private final class FuzzClipboard: ClipboardProvider, @unchecked Sendable {
    private let lock = NSLock(); private var value: String? = "mac text"
    func text() -> String? { lock.withLock { value } }
    func setText(_ text: String) { lock.withLock { value = text } }
}

/// Collects the host's replies on a thread of its own, so a host that writes a lot never blocks.
private final class ReplyReader: @unchecked Sendable {
    private let lock = NSLock()
    private var ids = Set<UInt64>()
    private var closed = false
    init(_ stream: FDStream) {
        Thread.detachNewThread { [self] in
            var decoder = FrameDecoder()
            while let data = try? stream.read(max: 1 << 16), !data.isEmpty {
                let frames = decoder.feed(data)
                lock.withLock { for f in frames { ids.insert(f.requestId) } }
            }
            lock.withLock { closed = true }
        }
    }
    func waitFor(_ id: UInt64, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if lock.withLock({ ids.contains(id) }) { return true }
            if lock.withLock({ closed }) { return false }
            usleep(5_000)
        }
        return false
    }
}

final class ServiceFuzzTests: XCTestCase {
    /// Every opcode the host serves, and the ranges around them.
    private static let opcodes: [UInt16] = [
        LinkOp.hello, LinkOp.waitEvent, LinkOp.guestInfo, LinkOp.log, LinkOp.echo, LinkOp.getHostTime,
        LinkOp.clipboardSetHost, LinkOp.clipboardGetHost, LinkOp.displayReport, LinkOp.shareList,
        LinkOp.agentUpdateInfo, LinkOp.agentUpdateRead, LinkOp.windowReport, LinkOp.icon, LinkOp.programList,
        LinkOp.documentResult, LinkOp.programInfo, LinkOp.activityReport, LinkOp.execResult,
    ] + Array(LinkOp.fileDropRange) + Array(LinkOp.dragOutRange) + [0x0000, 0x0006, 0x06FF, 0xFFFF]

    /// Well-formed JSON for each JSON-carrying request, for the mutator to start from.
    private static let jsonSamples: [String] = [
        #"{"hostname":"vm","osName":"Windows","osVersion":"11","kernel":"26100","ipAddresses":["10.0.2.15"],"utcOffsetSeconds":-18000}"#,
        #"{"desktop":[1920,1080],"windows":[{"id":7,"x":10,"y":20,"width":800,"height":600,"pid":42,"kind":"app","state":"normal","active":true,"title":"Notepad","class":"Notepad","app":"notepad.exe"}],"moving":{"id":7,"x":10,"y":20,"width":800,"height":600,"pointerX":100,"pointerY":30,"edge":"bottomRight"}}"#,
        #"{"programs":[{"name":"Notepad","id":"app:notepad"}]}"#,
        #"{"id":"app:notepad","target":"C:\\Windows\\notepad.exe","extensions":[".txt"]}"#,
        #"{"idleSeconds":12,"cpuPercent":3.5,"keepAwake":["video"]}"#,
        #"{"id":"d1","bytes":100,"total":200}"#,
        #"{"id":"d1","ok":true,"message":"done","written":["a.txt"]}"#,
        #"{"x":5,"y":6,"paths":["C:\\Users\\u\\a.txt"],"message":null}"#,
    ]

    /// The sample each JSON-carrying request starts from (index into `jsonSamples`).
    private static let jsonFor: [UInt16: Int] = [
        LinkOp.guestInfo: 0, LinkOp.windowReport: 1, LinkOp.programList: 2, LinkOp.programInfo: 3, LinkOp.activityReport: 4,
        LinkOp.fileDropRange.lowerBound: 5, LinkOp.fileDropRange.lowerBound + 1: 6, LinkOp.fileDropRange.lowerBound + 2: 6,
        LinkOp.dragOutRange.lowerBound: 7, LinkOp.dragOutRange.lowerBound + 1: 7,
    ]

    private func randomRequest(_ rng: inout SeededRandom, id: UInt64) -> Frame {
        // Half the time a JSON-carrying request with its own document, mutated: that reaches the decoders
        // and what the app does with the decoded values.
        let opcode = rng.chance(0.5) ? rng.pick(Array(Self.jsonFor.keys).sorted())
            : rng.chance(0.95) ? rng.pick(Self.opcodes) : UInt16(truncatingIfNeeded: rng.next())
        var inline = Data()
        for _ in 0..<rng.pick([0, 1, 2, 3, 4, rng.int(0...10)]) { inline.appendLE(rng.interesting32()) }
        if rng.chance(0.1) { inline.append(rng.bytes(rng.int(1...7))) }
        var buffers: [LinkBuffer] = []
        if let sample = Self.jsonFor[opcode], rng.chance(0.85) {
            buffers.append(.input(Fuzz.mutatedJSONData(Data(Self.jsonSamples[sample].utf8), using: &rng)))
        }
        for _ in 0..<rng.int(0...4) {
            switch rng.int(0..<4) {
            case 0:
                let sample = Data(rng.pick(Self.jsonSamples).utf8)
                buffers.append(.input(Fuzz.mutatedJSONData(sample, using: &rng)))
            case 1: buffers.append(.input(rng.bytes(rng.pick([0, 1, 8, 64, rng.int(0...2048)]))))
            case 2: buffers.append(.output(capacity: Int(rng.pick([0, 1, 4096, 65536, 1 << 20, 0xFFFF_FFFF] as [UInt32]))))
            default: buffers.append(LinkBuffer(flags: rng.interesting32(), length: rng.interesting32()))
            }
        }
        return Frame(requestId: id, kind: .request, opcode: opcode, status: LinkStatus.pending, inline: inline, buffers: buffers)
    }

    private func hello(_ id: UInt64) -> Frame {
        var inline = Data(); inline.appendLE(GuestLinkConstants.protocolVersion); inline.appendLE(UInt32(2)); inline.appendLE(UInt32.max)
        return Frame(requestId: id, kind: .request, opcode: LinkOp.hello, status: LinkStatus.pending, inline: inline,
                     buffers: [.input(Data("fuzz".utf8))])
    }

    /// Thousands of random and mutated requests at a live host with every callback doing what the app's
    /// does with the data. The host must answer an echo afterwards.
    func testHostSurvivesRandomRequests() throws {
        let host = GuestLinkHost()
        host.clipboard = FuzzClipboard()
        let screen = CGRect(x: 0, y: 25, width: 1512, height: 920)
        let reports = Counter()
        host.onWindowReport = { list in
            reports.add()
            let layout = GuestWindowLayout(desktop: CGSize(width: list.desktop[0], height: list.desktop[1]), area: screen)
            for window in layout.shown(list.windows) {
                if let rect = layout.visibleRect(of: window) { _ = layout.macFrame(forGuestRect: rect); _ = layout.unitRect(forGuestRect: rect) }
            }
            _ = layout.guestPoint(forMacPoint: CGPoint(x: 700, y: 400))
            if let move = list.moving {
                _ = GuestWindowLayout.draggedRect(move, pointer: (move.pointerX, move.pointerY), pressedAt: (0, 0))
                _ = GuestWindowLayout.draggedRect(move, pointer: (1000, 1000))
            }
        }
        host.onActivity = { a in _ = (a.idleSeconds.map(TimeInterval.init) ?? 0) + (a.cpuPercent ?? 0) }
        host.onGuestInfo = { info in _ = info.utcOffsetSeconds.map(TimeInterval.init) }
        host.onDropProgress = { p in _ = p.total > 0 ? Double(p.bytes) / Double(p.total) : 0 }

        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let guest = FDStream(fileDescriptor: fds[0])
        host.attach(FDStream(fileDescriptor: fds[1]))
        let replies = ReplyReader(guest)
        var nextID: UInt64 = 1
        try guest.write(hello(nextID).encode())
        XCTAssertTrue(replies.waitFor(nextID, timeout: 10))

        try Fuzz.cases(2500) { rng, _ in
            nextID += 1
            let frame = rng.chance(0.01) ? hello(nextID) : randomRequest(&rng, id: nextID)
            try guest.write(frame.encode())
            // Now and then a damaged frame on the stream as well; the decoder must resynchronise.
            if rng.chance(0.03) { try guest.write(Fuzz.mutate(randomRequest(&rng, id: 0).encode(), using: &rng)) }
        }
        // The stall rule may need a second to drop a damaged frame's tail.
        nextID += 1
        try guest.write(hello(nextID).encode())
        let helloID = nextID
        var answered = replies.waitFor(helloID, timeout: 5)
        if !answered {
            // A damaged frame claimed more bytes than followed; the stall rule frees the stream after a second.
            nextID += 1
            try guest.write(hello(nextID).encode())
            answered = replies.waitFor(nextID, timeout: 10)
        }
        XCTAssertTrue(answered, "the host stopped answering")
        nextID += 1
        try guest.write(Frame(requestId: nextID, kind: .request, opcode: LinkOp.echo, status: LinkStatus.pending,
                              buffers: [.input(Data("still here".utf8)), .output(capacity: 64)]).encode())
        XCTAssertTrue(replies.waitFor(nextID, timeout: 10), "the host stopped answering")
        XCTAssertGreaterThan(reports.value, 5, "few mutated window reports decoded: the fuzzer is not reaching the app's geometry")
        guest.close()
    }
}

extension ServiceFuzzTests {
    /// Regression (found by the fuzzer at TANDEM_FUZZ_SCALE=50): a window report with Int.max in it
    /// reached Seamless Mode's drag prediction, whose sums overflowed and trapped the app.
    func testWindowReportWithExtremeNumbersArrivesClamped() throws {
        let host = GuestLinkHost()
        let received = Box()
        host.onWindowReport = { list in received.set(list) }
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let guest = FDStream(fileDescriptor: fds[0])
        host.attach(FDStream(fileDescriptor: fds[1]))
        let replies = ReplyReader(guest)
        try guest.write(hello(1).encode())
        XCTAssertTrue(replies.waitFor(1, timeout: 10))
        let max = Int.max, min = Int.min
        let json = #"{"desktop":[\#(max),\#(max)],"windows":[{"id":1,"x":\#(max),"y":\#(min),"width":\#(max),"height":-5,"pid":1,"kind":"app","state":"normal","active":true,"title":"","class":"","app":""}],"moving":{"id":1,"x":\#(max),"y":\#(max),"width":\#(max),"height":\#(max),"pointerX":\#(min),"pointerY":\#(max),"edge":"bottomRight"}}"#
        try guest.write(Frame(requestId: 2, kind: .request, opcode: LinkOp.windowReport, status: LinkStatus.pending,
                              buffers: [.input(Data(json.utf8))]).encode())
        XCTAssertTrue(replies.waitFor(2, timeout: 10))
        let list = try XCTUnwrap(received.value)
        let limit = GuestWindowList.coordinateLimit
        XCTAssertEqual(list.desktop, [limit, limit])
        XCTAssertEqual(list.windows[0].x, limit); XCTAssertEqual(list.windows[0].y, -limit); XCTAssertEqual(list.windows[0].height, 0)
        let move = try XCTUnwrap(list.moving)
        XCTAssertEqual(move.pointerX, -limit)
        _ = GuestWindowLayout.draggedRect(move, pointer: (max, min), pressedAt: (min, max))
        guest.close()
    }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock(); private var list: GuestWindowList?
    func set(_ l: GuestWindowList) { lock.withLock { list = l } }
    var value: GuestWindowList? { lock.withLock { list } }
}

/// Window reports carry guest-chosen numbers; the geometry built from them must never trap.
final class WindowGeometryFuzzTests: XCTestCase {
    private func extreme(_ rng: inout SeededRandom) -> Int { rng.chance(0.6) ? rng.interestingInt() : rng.int(-5000...5000) }

    func testSanitizedReportsKeepGeometryFinite() {
        Fuzz.cases(3000) { rng, seed in
            let windows = (0..<rng.int(0...4)).map { i in
                GuestWindow(id: UInt64(i), x: extreme(&rng), y: extreme(&rng), width: extreme(&rng), height: extreme(&rng), pid: 1,
                            kind: rng.pick([.app, .popup, .taskbar]), state: rng.pick([.normal, .minimized, .maximized]),
                            active: rng.chance(0.5), title: rng.awkwardString(maxLength: 10), class: "", app: "")
            }
            let move = rng.chance(0.7) ? GuestWindowMove(id: 1, x: extreme(&rng), y: extreme(&rng), width: extreme(&rng),
                                                         height: extreme(&rng), pointerX: extreme(&rng), pointerY: extreme(&rng),
                                                         edge: rng.chance(0.5) ? nil : rng.pick([.left, .right, .top, .bottom, .topLeft, .bottomRight]))
                                        : nil
            let list = GuestWindowList(desktop: [extreme(&rng), extreme(&rng)], windows: windows, moving: move).sanitized()
            let area = rng.pick([CGRect(x: 0, y: 25, width: 1512, height: 920), CGRect(x: -1920, y: 0, width: 3432, height: 1080), .zero])
            let layout = GuestWindowLayout(desktop: CGSize(width: list.desktop[0], height: list.desktop[1]), area: area)
            for window in layout.shown(list.windows) {
                guard let rect = layout.visibleRect(of: window) else { continue }
                let frame = layout.macFrame(forGuestRect: rect)
                XCTAssertTrue(frame.minX.isFinite && frame.height.isFinite, "seed \(seed)")
            }
            let point = layout.guestPoint(forMacPoint: CGPoint(x: CGFloat(extreme(&rng)), y: CGFloat(extreme(&rng))))
            XCTAssertGreaterThanOrEqual(point.x, 0, "seed \(seed)")
            if let move = list.moving {
                let pointer = (rng.int(-100_000...100_000), rng.int(-100_000...100_000))
                let dragged = GuestWindowLayout.draggedRect(move, pointer: pointer, pressedAt: rng.chance(0.5) ? nil : (extreme(&rng), extreme(&rng)))
                XCTAssertFalse(dragged.isNull, "seed \(seed)")
            }
        }
    }

    func testSanitizedKeepsOrdinaryReportsUnchanged() throws {
        let list = GuestWindowList(desktop: [3024, 1890], windows: [
            GuestWindow(id: 1, x: -8, y: 0, width: 1200, height: 800, pid: 4, kind: .app, state: .normal, active: true, title: "t", class: "c", app: "a"),
        ], moving: GuestWindowMove(id: 1, x: -8, y: 0, width: 1200, height: 800, pointerX: 300, pointerY: 10, edge: .left))
        XCTAssertEqual(list.sanitized(), list)
    }

    /// A pointer far outside the desktop, or a desktop of absurd size, clamps instead of trapping.
    func testGuestPointClampsAbsurdInput() {
        let huge = GuestWindowLayout(desktop: CGSize(width: 9.3e18, height: 9.3e18), area: CGRect(x: 0, y: 0, width: 100, height: 100))
        let p = huge.guestPoint(forMacPoint: CGPoint(x: 50, y: 50))
        XCTAssertGreaterThan(p.x, 0)
        let flat = GuestWindowLayout(desktop: CGSize(width: 1920, height: 1080), area: .zero)
        XCTAssertEqual(flat.guestPoint(forMacPoint: CGPoint(x: 1e300, y: -1e300)).x, 1919)
    }
}
