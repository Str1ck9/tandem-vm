import XCTest
import VMCore
@testable import GuestLink

private func hex(_ s: String) -> Data {
    var d = Data(); var i = s.startIndex
    while i < s.endIndex { let j = s.index(i, offsetBy: 2); d.append(UInt8(s[i..<j], radix: 16)!); i = j }
    return d
}

/// The shared vectors in protocol/vectors.json, produced by the Python reference encoder.
private func loadVectors() throws -> [(name: String, frame: Frame, bytes: Data)] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("protocol/vectors.json")
    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
    return raw.map { v in
        let f = v["frame"] as! [String: Any]
        let kind = Frame.Kind(rawValue: UInt16(f["kind"] as! Int))!
        let payloadFlag = kind == .reply ? LinkBuffer.flagOut : LinkBuffer.flagIn
        let buffers = (f["buffers"] as! [[String: Any]]).map { b -> LinkBuffer in
            let flags = UInt32(b["flags"] as! Int)
            let present = flags & payloadFlag != 0
            return LinkBuffer(flags: flags, length: UInt32(b["length"] as! Int),
                              data: present ? hex(b["data"] as? String ?? "") : nil)
        }
        let frame = Frame(requestId: (f["requestId"] as! NSNumber).uint64Value, kind: kind, opcode: UInt16(f["opcode"] as! Int),
                          status: (f["status"] as! NSNumber).uint32Value, inline: hex(f["inline"] as! String), buffers: buffers)
        return (v["name"] as! String, frame, hex(v["hex"] as! String))
    }
}

final class FrameTests: XCTestCase {
    func testEncodeMatchesGoldenVectors() throws {
        let vectors = try loadVectors()
        XCTAssertEqual(vectors.count, 12)
        for v in vectors { XCTAssertEqual(v.frame.encode(), v.bytes, v.name) }
    }

    func testDecodeMatchesGoldenVectors() throws {
        for v in try loadVectors() {
            var decoder = FrameDecoder()
            XCTAssertEqual(decoder.feed(v.bytes), [v.frame], v.name)
            XCTAssertEqual(decoder.discardedBytes, 0)
        }
    }

    func testDecodeByteAtATimeAndConcatenated() throws {
        let vectors = try loadVectors()
        let all = vectors.reduce(Data()) { $0 + $1.bytes }
        var oneShot = FrameDecoder()
        XCTAssertEqual(oneShot.feed(all), vectors.map(\.frame))
        var trickle = FrameDecoder(); var frames: [Frame] = []
        for byte in all { frames += trickle.feed(Data([byte])) }
        XCTAssertEqual(frames, vectors.map(\.frame))
    }

    func testResyncAfterGarbage() throws {
        let vectors = try loadVectors()
        var decoder = FrameDecoder()
        let junk = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x42, 0x4C])   // ends in a partial magic
        XCTAssertEqual(decoder.feed(junk + vectors[1].bytes + junk + vectors[2].bytes), [vectors[1].frame, vectors[2].frame])
        XCTAssertEqual(decoder.discardedBytes, 12)
    }

    /// An agent died mid-frame and a new one started on the same stream. The dead frame claims more
    /// bytes than the new session's first frames supply, so only the stall rule can recover.
    func testTruncatedFrameRecoversByStallRule() throws {
        let vectors = try loadVectors()
        var decoder = FrameDecoder()
        XCTAssertTrue(decoder.feed(vectors[6].bytes.prefix(40) + vectors[1].bytes).isEmpty)
        XCTAssertTrue(decoder.hasPartialFrame)
        XCTAssertEqual(decoder.resyncAfterStall(), [vectors[1].frame])
        XCTAssertFalse(decoder.hasPartialFrame)
    }

    /// Same crash, but enough new bytes arrive to fill the dead frame's claimed size. The CRC catches it.
    func testTruncatedFrameRecoversByCRC() throws {
        let vectors = try loadVectors()
        var decoder = FrameDecoder()
        let stream = vectors[1].bytes.prefix(40) + vectors[2].bytes + vectors[3].bytes
        XCTAssertEqual(decoder.feed(stream), [vectors[2].frame, vectors[3].frame])
    }

    func testCorruptedByteIsRejected() throws {
        let vectors = try loadVectors()
        var bytes = vectors[5].bytes
        bytes[bytes.count - 6] ^= 0x01
        var decoder = FrameDecoder()
        XCTAssertEqual(decoder.feed(bytes + vectors[0].bytes), [vectors[0].frame])
    }

    func testRejectsOversizeAndInconsistentFrames() {
        var huge = Frame(requestId: 1, kind: .request, opcode: 1, status: 0).encode()
        huge.replaceSubrange(4..<8, with: [0x01, 0x00, 0x00, 0x01]) // totalSize = 16 MiB + 1
        var d1 = FrameDecoder()
        XCTAssertTrue(d1.feed(huge).isEmpty)
        XCTAssertGreaterThan(d1.discardedBytes, 0)

        var lying = Frame(requestId: 1, kind: .request, opcode: 1, status: 0, buffers: [.input(Data([1, 2, 3]))]).encode()
        lying.replaceSubrange(32..<36, with: [0xFF, 0x00, 0x00, 0x00]) // descriptor claims 255 bytes
        var d2 = FrameDecoder()
        XCTAssertTrue(d2.feed(lying).isEmpty)

        var badKind = Frame(requestId: 1, kind: .request, opcode: 1, status: 0).encode()
        badKind[16] = 9
        var d3 = FrameDecoder()
        XCTAssertTrue(d3.feed(badKind).isEmpty)
    }
}

/// Test double for the guest agent, talking to a `GuestLinkHost` over a socketpair.
private final class TestGuest {
    let stream: FDStream
    private var decoder = FrameDecoder()
    private var backlog: [Frame] = []
    private var nextID: UInt64 = 1

    init(host: GuestLinkHost) {
        var fds: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        stream = FDStream(fileDescriptor: fds[0])
        host.attach(FDStream(fileDescriptor: fds[1]))
    }

    @discardableResult
    func send(_ opcode: UInt16, inline: Data = Data(), buffers: [LinkBuffer] = []) throws -> UInt64 {
        let id = nextID; nextID += 1
        try stream.write(Frame(requestId: id, kind: .request, opcode: opcode, status: LinkStatus.pending, inline: inline, buffers: buffers).encode())
        return id
    }

    func reply(to id: UInt64) throws -> Frame {
        while true {
            if let i = backlog.firstIndex(where: { $0.requestId == id }) { return backlog.remove(at: i) }
            backlog += decoder.feed(try stream.read(max: 65536))
        }
    }

    /// True when a reply to this request has already been read off the stream.
    func hasReply(to id: UInt64) -> Bool { backlog.contains { $0.requestId == id } }

    func call(_ opcode: UInt16, inline: Data = Data(), buffers: [LinkBuffer] = []) throws -> Frame {
        try reply(to: try send(opcode, inline: inline, buffers: buffers))
    }

    func hello(version: UInt32 = 1) throws -> Frame {
        var inline = Data(); inline.appendLE(version); inline.appendLE(UInt32(1)); inline.appendLE(UInt32(0b111))
        return try call(LinkOp.hello, inline: inline, buffers: [.input(Data("0.1.0".utf8))])
    }
}

private final class StubClipboard: ClipboardProvider, @unchecked Sendable {
    private let lock = NSLock(); private var value: String?
    init(_ v: String? = nil) { value = v }
    func text() -> String? { lock.withLock { value } }
    func setText(_ text: String) { lock.withLock { value = text } }
}

final class SessionTests: XCTestCase {
    func testHelloEstablishesSession() throws {
        let host = GuestLinkHost(); let guest = TestGuest(host: host)
        XCTAssertFalse(host.isAgentConnected)
        let reply = try guest.hello()
        XCTAssertEqual(reply.status, LinkStatus.ok)
        XCTAssertEqual(reply.inline.readLE(UInt32.self, at: 0), 1)
        XCTAssertEqual(host.hello?.agentVersion, "0.1.0")
        XCTAssertEqual(host.hello?.os, .linux)
        XCTAssertTrue(host.isAgentConnected)
    }

    func testVersionMismatchIsRefused() throws {
        let host = GuestLinkHost(); let guest = TestGuest(host: host)
        XCTAssertEqual(try guest.hello(version: 99).status, LinkStatus.versionMismatch)
        XCTAssertFalse(host.isAgentConnected)
    }

    func testEchoAndUnknownOpcode() throws {
        let host = GuestLinkHost(); let guest = TestGuest(host: host); _ = try guest.hello()
        let payload = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0) })
        let reply = try guest.call(LinkOp.echo, buffers: [.input(payload), .output(capacity: payload.count)])
        XCTAssertEqual(reply.status, LinkStatus.ok)
        XCTAssertEqual(reply.buffers[1].data, payload)
        XCTAssertEqual(try guest.call(0x0999).status, LinkStatus.unknownOpcode)
        XCTAssertEqual(try guest.call(LinkOp.echo, buffers: [.input(payload), .output(capacity: 10)]).status, LinkStatus.badRequest)
    }

    func testHostTime() throws {
        let host = GuestLinkHost()
        host.now = { Date(timeIntervalSince1970: 1_794_623_447.25) }
        host.utcOffsetSeconds = { -18000 }
        let guest = TestGuest(host: host); _ = try guest.hello()
        let reply = try guest.call(LinkOp.getHostTime)
        XCTAssertEqual(reply.inline.readLE(Int64.self, at: 0), 1_794_623_447)
        XCTAssertEqual(reply.inline.readLE(UInt32.self, at: 8), 250_000_000)
        XCTAssertEqual(reply.inline.readLE(Int32.self, at: 12), -18000)
    }

    func testClipboardBothDirections() throws {
        let host = GuestLinkHost(); let clip = StubClipboard("from mac"); host.clipboard = clip
        let guest = TestGuest(host: host); _ = try guest.hello()
        let got = try guest.call(LinkOp.clipboardGetHost, buffers: [.output(capacity: 4096)])
        XCTAssertEqual(got.buffers[0].data, Data("from mac".utf8))
        XCTAssertEqual(try guest.call(LinkOp.clipboardSetHost, buffers: [.input(Data("from guest ✓".utf8))]).status, LinkStatus.ok)
        XCTAssertEqual(clip.text(), "from guest ✓")
        XCTAssertEqual(try guest.call(LinkOp.clipboardSetHost, buffers: [.input(Data([0xFF, 0xFE]))]).status, LinkStatus.badRequest)
    }

    /// The host drops the direction the sharing policy forbids, whatever the guest asks for, and a
    /// change of policy applies to the very next request.
    func testClipboardDirectionIsEnforcedOnTheHost() throws {
        final class Policy: @unchecked Sendable {
            private let lock = NSLock(); private var value = ClipboardSharing.both
            var current: ClipboardSharing { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
        }
        let policy = Policy()
        let host = GuestLinkHost(); let clip = StubClipboard("mac secret"); host.clipboard = clip
        host.clipboardPolicy = { policy.current }
        let guest = TestGuest(host: host); _ = try guest.hello()
        func get() throws -> (UInt32, String) {
            let reply = try guest.call(LinkOp.clipboardGetHost, buffers: [.output(capacity: 4096)])
            return (reply.status, String(decoding: (reply.buffers.first?.data ?? nil) ?? Data(), as: UTF8.self))
        }
        func set(_ text: String) throws -> UInt32 { try guest.call(LinkOp.clipboardSetHost, buffers: [.input(Data(text.utf8))]).status }

        policy.current = .macToGuest
        XCTAssertEqual(try get().1, "mac secret")
        XCTAssertEqual(try set("from guest"), LinkStatus.notSupported)
        XCTAssertEqual(clip.text(), "mac secret", "the Mac clipboard must be untouched")

        policy.current = .guestToMac
        let refused = try get()
        XCTAssertEqual(refused.0, LinkStatus.notSupported)
        XCTAssertEqual(refused.1, "", "nothing of the Mac's clipboard may leave")
        XCTAssertEqual(try set("from guest"), LinkStatus.ok)
        XCTAssertEqual(clip.text(), "from guest")

        // Revoked altogether while the session is up.
        policy.current = .off
        XCTAssertEqual(try get().0, LinkStatus.notSupported)
        XCTAssertEqual(try set("again"), LinkStatus.notSupported)
        XCTAssertEqual(clip.text(), "from guest")

        // Mac to guest also travels as an event; that one is dropped before it is queued.
        let id = try guest.send(LinkOp.waitEvent, buffers: [.output(capacity: 65536)])
        _ = try guest.call(LinkOp.echo, buffers: [.input(Data([1])), .output(capacity: 1)]) // the waiter is parked
        host.notifyClipboardChanged("must not arrive")
        policy.current = .both
        host.notifyClipboardChanged("allowed again")
        let event = try guest.reply(to: id)
        XCTAssertEqual(event.inline.readLE(UInt32.self, at: 0), LinkEventKind.clipboardChanged.rawValue)
        XCTAssertEqual(String(decoding: event.buffers[0].data ?? Data(), as: UTF8.self), "allowed again")
    }

    func testClipboardWithoutProviderIsNotSupported() throws {
        let host = GuestLinkHost(); let guest = TestGuest(host: host); _ = try guest.hello()
        XCTAssertEqual(try guest.call(LinkOp.clipboardGetHost, buffers: [.output(capacity: 16)]).status, LinkStatus.notSupported)
    }

    func testEventDeliveredToWaitingGuest() throws {
        let host = GuestLinkHost(); let guest = TestGuest(host: host); _ = try guest.hello()
        let id = try guest.send(LinkOp.waitEvent, buffers: [.output(capacity: 65536)])
        _ = try guest.call(LinkOp.echo, buffers: [.input(Data([1])), .output(capacity: 1)]) // proves the waiter is parked
        host.requestDisplayResize(width: 1920, height: 1080)
        let event = try guest.reply(to: id)
        XCTAssertEqual(event.inline.readLE(UInt32.self, at: 0), LinkEventKind.displayResize.rawValue)
        XCTAssertEqual(event.inline.readLE(UInt32.self, at: 4), 1920)
        XCTAssertEqual(event.inline.readLE(UInt32.self, at: 8), 1080)
    }

    func testEventsQueueAndCoalesceWhileGuestIsBusy() throws {
        let host = GuestLinkHost(); let guest = TestGuest(host: host); _ = try guest.hello()
        host.requestDisplayResize(width: 800, height: 600)
        host.notifyClipboardChanged("hello")
        host.requestDisplayResize(width: 1024, height: 768) // replaces the first resize
        let first = try guest.call(LinkOp.waitEvent, buffers: [.output(capacity: 65536)])
        let second = try guest.call(LinkOp.waitEvent, buffers: [.output(capacity: 65536)])
        XCTAssertEqual(first.inline.readLE(UInt32.self, at: 0), LinkEventKind.clipboardChanged.rawValue)
        XCTAssertEqual(first.buffers[0].data, Data("hello".utf8))
        XCTAssertEqual(second.inline.readLE(UInt32.self, at: 4), 1024)
    }

    func testSecondHelloResetsSession() throws {
        let host = GuestLinkHost(); let guest = TestGuest(host: host); _ = try guest.hello()
        let stale = try guest.send(LinkOp.waitEvent, buffers: [.output(capacity: 64)])
        host.notifyClipboardChanged("queued before restart")
        _ = try guest.reply(to: stale)
        host.requestTimeResync()                      // queued, then discarded by the new HELLO
        _ = try guest.hello()
        let id = try guest.send(LinkOp.waitEvent, buffers: [.output(capacity: 64)])
        _ = try guest.call(LinkOp.echo, buffers: [.input(Data([1])), .output(capacity: 1)])
        host.requestGuestShutdown()
        XCTAssertEqual(try guest.reply(to: id).inline.readLE(UInt32.self, at: 0), LinkEventKind.shutdownRequest.rawValue)
    }

    func testGuestInfoLogAndDisplayReport() throws {
        let host = GuestLinkHost(); let guest = TestGuest(host: host); _ = try guest.hello()
        let logged = Captured()
        host.onLog = { level, message in logged.set("\(level):\(message)") }
        let info = #"{"hostname":"alp","osName":"Alpine","ipAddresses":["192.168.64.5"]}"#
        XCTAssertEqual(try guest.call(LinkOp.guestInfo, buffers: [.input(Data(info.utf8))]).status, LinkStatus.ok)
        XCTAssertEqual(host.guestInfo?.ipAddresses, ["192.168.64.5"])
        var level = Data(); level.appendLE(UInt32(2))
        _ = try guest.call(LinkOp.log, inline: level, buffers: [.input(Data("careful".utf8))])
        XCTAssertEqual(logged.get(), "2:careful")
        var report = Data(); report.appendLE(UInt32(1280)); report.appendLE(UInt32(800)); report.appendLE(UInt32(0))
        _ = try guest.call(LinkOp.displayReport, inline: report)
        XCTAssertEqual(host.lastDisplayReport, DisplayReport(width: 1280, height: 800, result: 0))
        XCTAssertEqual(try guest.call(LinkOp.guestInfo, buffers: [.input(Data("not json".utf8))]).status, LinkStatus.badRequest)
    }

    func testProgramListIsDecodedAndLaunchCarriesTheId() throws {
        let host = GuestLinkHost(); let guest = TestGuest(host: host); _ = try guest.hello()
        let names = Captured()
        host.onProgramList = { programs in names.set(programs.map { "\($0.name)=\($0.id)" }.joined(separator: ";")) }
        let json = #"{"programs":[{"name":"Calculator","id":"Microsoft.WindowsCalculator_8wekyb3d8bbwe!App"},{"name":"Tool","id":"C:\\Start\\Tool.lnk"}]}"#
        XCTAssertEqual(try guest.call(LinkOp.programList, buffers: [.input(Data(json.utf8))]).status, LinkStatus.ok)
        XCTAssertEqual(names.get(), #"Calculator=Microsoft.WindowsCalculator_8wekyb3d8bbwe!App;Tool=C:\Start\Tool.lnk"#)
        XCTAssertEqual(try guest.call(LinkOp.programList, buffers: [.input(Data("nope".utf8))]).status, LinkStatus.badRequest)
        host.launchProgram(id: #"C:\Start\Tool.lnk"#)
        let event = try guest.call(LinkOp.waitEvent, buffers: [.output(capacity: 65536)])
        XCTAssertEqual(event.inline.readLE(UInt32.self, at: 0), LinkEventKind.programLaunch.rawValue)
        XCTAssertEqual(event.buffers[0].data, Data(#"C:\Start\Tool.lnk"#.utf8))
    }

    func testAWaitBeforeHelloIsLeftUnansweredSoTheAgentSaysHelloAgain() throws {
        // A resumed VM's agent may send a wait to a host process that has never heard its HELLO.
        let previous = LinkSession.keepAliveInterval
        LinkSession.keepAliveInterval = 0.1
        defer { LinkSession.keepAliveInterval = previous }
        let host = GuestLinkHost(); let guest = TestGuest(host: host)
        let stale = try guest.send(LinkOp.waitEvent, buffers: [.output(capacity: 64)])
        Thread.sleep(forTimeInterval: 0.4)   // several keep-alive periods
        // Other requests are still served, and the stale wait has had no answer: the echo's reply comes first.
        let echo = try guest.send(LinkOp.echo, buffers: [.input(Data([7])), .output(capacity: 1)])
        XCTAssertEqual(try guest.reply(to: echo).status, LinkStatus.ok)
        XCTAssertFalse(guest.hasReply(to: stale), "a wait before HELLO must stay unanswered")
        // After HELLO, waiting works as usual.
        _ = try guest.hello()
        XCTAssertEqual(try guest.call(LinkOp.waitEvent, buffers: [.output(capacity: 64)]).inline.readLE(UInt32.self, at: 0), LinkEventKind.none.rawValue)
    }

    func testActivityReportsAreDecodedWithWhatTheGuestCouldTell() throws {
        let host = GuestLinkHost(); let guest = TestGuest(host: host); _ = try guest.hello()
        let got = Captured()
        host.onActivity = { a in got.set("\(a.idleSeconds.map(String.init) ?? "-")|\(a.cpuPercent.map { String($0) } ?? "-")|\(a.keepAwake.joined(separator: ","))") }
        let full = #"{"idleSeconds":125,"cpuPercent":3.3,"keepAwake":["Nightly backup","player.exe (Playing video)"]}"#
        XCTAssertEqual(try guest.call(LinkOp.activityReport, buffers: [.input(Data(full.utf8))]).status, LinkStatus.ok)
        XCTAssertEqual(got.get(), "125|3.3|Nightly backup,player.exe (Playing video)")
        // A guest that cannot tell its idle time or processor use leaves them out.
        XCTAssertEqual(try guest.call(LinkOp.activityReport, buffers: [.input(Data(#"{"keepAwake":[]}"#.utf8))]).status, LinkStatus.ok)
        XCTAssertEqual(got.get(), "-|-|")
        XCTAssertEqual(try guest.call(LinkOp.activityReport, buffers: [.input(Data("x".utf8))]).status, LinkStatus.badRequest)
    }

    func testDocumentOpenCarriesProgramAndPathsAndItsResultComesBack() throws {
        let host = GuestLinkHost(); let guest = TestGuest(host: host); _ = try guest.hello()
        let got = Captured()
        host.onDocumentResult = { result in got.set("\(result.request):\(result.status):\(result.message)") }
        host.openDocuments(request: 41, program: "Microsoft.WindowsNotepad_8wekyb3d8bbwe!App", documents: ["Home/notes/a b.txt", "Home/c.txt"])
        let event = try guest.call(LinkOp.waitEvent, buffers: [.output(capacity: 65536)])
        XCTAssertEqual(event.inline.readLE(UInt32.self, at: 0), LinkEventKind.documentOpen.rawValue)
        XCTAssertEqual(event.inline.readLE(UInt32.self, at: 4), 41)
        XCTAssertEqual(event.buffers[0].data, Data("Microsoft.WindowsNotepad_8wekyb3d8bbwe!App\nHome/notes/a b.txt\nHome/c.txt".utf8))
        var inline = Data(); inline.appendLE(UInt32(41)); inline.appendLE(UInt32(1))
        XCTAssertEqual(try guest.call(LinkOp.documentResult, inline: inline, buffers: [.input(Data("Windows cannot reach Z:\\Home\\c.txt.".utf8))]).status, LinkStatus.ok)
        XCTAssertEqual(got.get(), "41:unreachable:Windows cannot reach Z:\\Home\\c.txt.")
        // The default program: an empty first line.
        host.openDocuments(request: 42, program: "", documents: ["Home/c.txt"])
        let second = try guest.call(LinkOp.waitEvent, buffers: [.output(capacity: 65536)])
        XCTAssertEqual(second.buffers[0].data, Data("\nHome/c.txt".utf8))
        XCTAssertEqual(try guest.call(LinkOp.documentResult, inline: Data([1, 2]), buffers: []).status, LinkStatus.badRequest)
    }

    func testProgramInfoBringsExtensionsAndTheIconFile() throws {
        let host = GuestLinkHost(); let guest = TestGuest(host: host); _ = try guest.hello()
        let got = Captured()
        host.onProgramInfo = { info, logo in got.set("\(info.id)|\(info.target)|\(info.extensions.joined(separator: ","))|\(logo.count)") }
        host.requestProgramInfo(id: "X!App")
        let event = try guest.call(LinkOp.waitEvent, buffers: [.output(capacity: 65536)])
        XCTAssertEqual(event.inline.readLE(UInt32.self, at: 0), LinkEventKind.programInfoRequest.rawValue)
        XCTAssertEqual(event.buffers[0].data, Data("X!App".utf8))
        let json = #"{"id":"X!App","target":"C:\\Program Files\\X\\x.exe","extensions":[".log",".txt"]}"#
        XCTAssertEqual(try guest.call(LinkOp.programInfo, buffers: [.input(Data(json.utf8)), .input(Data([0x89, 0x50, 0x4E]))]).status, LinkStatus.ok)
        XCTAssertEqual(got.get(), #"X!App|C:\Program Files\X\x.exe|.log,.txt|3"#)
        XCTAssertEqual(try guest.call(LinkOp.programInfo, buffers: [.input(Data("{}".utf8))]).status, LinkStatus.badRequest)
    }

    func testIconsAreAskedForOneAtATime() throws {
        let host = GuestLinkHost(); let guest = TestGuest(host: host); _ = try guest.hello()
        let got = Captured()
        host.onIcon = { icon in got.set(got.get() + "\(icon.key):\(icon.width)x\(icon.height):\(icon.cgImage != nil);") }
        host.requestIcon(.program("calc"), size: 32)
        host.requestIcon(.window(7), size: 128)
        host.requestIcon(.program("calc"), size: 32)   // already waiting: not asked twice
        let first = try guest.call(LinkOp.waitEvent, buffers: [.output(capacity: 65536)])
        XCTAssertEqual(first.inline.readLE(UInt32.self, at: 0), LinkEventKind.iconRequest.rawValue)
        XCTAssertEqual(first.inline.readLE(UInt32.self, at: 4), 2)
        XCTAssertEqual(first.inline.readLE(UInt32.self, at: 8), 32)
        XCTAssertEqual(first.buffers[0].data, Data("calc".utf8))
        // The second request is held back until the first is answered: nothing is waiting for the guest.
        let parked = try guest.send(LinkOp.waitEvent, buffers: [.output(capacity: 65536)])
        _ = try guest.call(LinkOp.echo, buffers: [.input(Data([1])), .output(capacity: 1)])
        // A 1 x 1 icon: one half-transparent blue pixel (B, G, R, A).
        var inline = Data(); inline.appendLE(UInt32(2)); inline.appendLE(UInt32(1)); inline.appendLE(UInt32(1))
        XCTAssertEqual(try guest.call(LinkOp.icon, inline: inline, buffers: [.input(Data("calc".utf8)), .input(Data([128, 0, 0, 128]))]).status, LinkStatus.ok)
        let second = try guest.reply(to: parked)
        XCTAssertEqual(second.inline.readLE(UInt32.self, at: 4), 1)
        XCTAssertEqual(second.inline.readLE(UInt32.self, at: 8), 128)
        XCTAssertEqual(second.buffers[0].data?.readLE(UInt64.self, at: 0), 7)
        // No icon found: size 0 and no pixels.
        var none = Data(); none.appendLE(UInt32(1)); none.appendLE(UInt32(0)); none.appendLE(UInt32(0))
        var key = Data(); key.appendLE(UInt64(7))
        XCTAssertEqual(try guest.call(LinkOp.icon, inline: none, buffers: [.input(key), .input(Data())]).status, LinkStatus.ok)
        XCTAssertEqual(got.get(), "program(\"calc\"):1x1:true;window(7):0x0:false;")
        // Pixels that do not match the stated size are refused.
        XCTAssertEqual(try guest.call(LinkOp.icon, inline: inline, buffers: [.input(Data("calc".utf8)), .input(Data([1, 2, 3]))]).status, LinkStatus.badRequest)
    }

    func testAnIconThatNeverComesDoesNotHoldUpTheNext() throws {
        let host = GuestLinkHost(); host.iconTimeout = 0.2
        let guest = TestGuest(host: host); _ = try guest.hello()
        host.requestIcon(.program("slow"), size: 32)
        host.requestIcon(.program("next"), size: 32)
        let first = try guest.call(LinkOp.waitEvent, buffers: [.output(capacity: 65536)])
        XCTAssertEqual(first.buffers[0].data, Data("slow".utf8))
        let second = try guest.call(LinkOp.waitEvent, buffers: [.output(capacity: 65536)])   // arrives after the timeout
        XCTAssertEqual(second.buffers[0].data, Data("next".utf8))
    }

    func testAgentUpdateIsServedInChunks() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-agent-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let binary = Data((0..<5000).map { UInt8($0 % 251) })
        try binary.write(to: file)
        let host = GuestLinkHost(); let guest = TestGuest(host: host); _ = try guest.hello()
        XCTAssertEqual(try guest.call(LinkOp.agentUpdateInfo).status, LinkStatus.notSupported, "no build for this guest")
        host.agentBinary = { os in os == .linux ? file : nil }
        let info = try guest.call(LinkOp.agentUpdateInfo)
        XCTAssertEqual(info.inline.readLE(UInt32.self, at: 0), 5000)
        XCTAssertEqual(info.inline.readLE(UInt64.self, at: 4), GuestLinkHost.fnv1a64(binary))
        var received = Data()
        while received.count < 5000 {
            var offset = Data(); offset.appendLE(UInt32(received.count))
            let chunk = try guest.call(LinkOp.agentUpdateRead, inline: offset, buffers: [.output(capacity: 2048)])
            XCTAssertEqual(chunk.status, LinkStatus.ok)
            received.append(chunk.buffers[0].data ?? Data())
        }
        XCTAssertEqual(received, binary)
        var past = Data(); past.appendLE(UInt32(5001))
        XCTAssertEqual(try guest.call(LinkOp.agentUpdateRead, inline: past, buffers: [.output(capacity: 16)]).status, LinkStatus.badRequest)
        // The same reference values as the agent's own test.
        XCTAssertEqual(GuestLinkHost.fnv1a64(Data("foobar".utf8)), 0x85944171f73967e8)
    }

    func testSharesCarryTheirTransport() throws {
        let host = GuestLinkHost(); let guest = TestGuest(host: host); _ = try guest.hello()
        host.shares = { SharesInfo(kind: "9p", shares: ["Docs"]) }
        let reply = try guest.call(LinkOp.shareList, buffers: [.output(capacity: 4096)])
        XCTAssertEqual(try JSONDecoder().decode(SharesInfo.self, from: reply.buffers[0].data ?? Data()), SharesInfo(kind: "9p", port: 0, shares: ["Docs"]))
    }

    func testDisconnectClearsState() throws {
        let host = GuestLinkHost(); let guest = TestGuest(host: host); _ = try guest.hello()
        let closed = expectation(description: "disconnect")
        host.onDisconnect = { closed.fulfill() }
        guest.stream.close()
        wait(for: [closed], timeout: 5)
        XCTAssertFalse(host.isAgentConnected)
    }

    /// End to end through a live session: a dead agent's half-frame, then a new agent says HELLO.
    func testSessionRecoversFromHalfFrameWithinStallWindow() throws {
        let host = GuestLinkHost(); let guest = TestGuest(host: host); _ = try guest.hello()
        let half = Frame(requestId: 77, kind: .request, opcode: LinkOp.echo, status: LinkStatus.pending,
                         buffers: [.input(Data(count: 5000)), .output(capacity: 5000)]).encode().prefix(100)
        try guest.stream.write(Data(half))
        let started = Date()
        XCTAssertEqual(try guest.hello().status, LinkStatus.ok)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3.0)
        XCTAssertTrue(host.isAgentConnected)
    }

    func testOverlappingRangesAreRejected() {
        let d = LinkDispatcher()
        XCTAssertNoThrow(try d.register(0x0100...0x01FF, name: "a") { _, _ in })
        XCTAssertThrowsError(try d.register(0x01FF...0x0200, name: "b") { _, _ in })
        XCTAssertEqual(d.serviceName(for: 0x0150), "a")
        XCTAssertNil(d.serviceName(for: 0x0200))
    }
}

private final class Captured: @unchecked Sendable {
    private let lock = NSLock(); private var value = ""
    func set(_ v: String) { lock.withLock { value = v } }
    func get() -> String { lock.withLock { value } }
}
