import XCTest
@testable import EngineQEMU

/// Drives `RFBClient` against a scripted server on a socket pair.
final class RFBClientTests: XCTestCase {
    final class FakeServer {
        let fd: Int32
        init(_ fd: Int32) { self.fd = fd }
        func send(_ bytes: [UInt8]) { _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) } }
        func read(_ n: Int) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: n); var got = 0
            while got < n {
                let r = out.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + got, n - got) }
                if r <= 0 { break }
                got += r
            }
            return Array(out[0..<got])
        }
        static func u16(_ v: Int) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
        static func s32(_ v: Int32) -> [UInt8] { let u = UInt32(bitPattern: v); return [UInt8(u >> 24), UInt8((u >> 16) & 0xFF), UInt8((u >> 8) & 0xFF), UInt8(u & 0xFF)] }
        func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ encoding: Int32) -> [UInt8] {
            Self.u16(x) + Self.u16(y) + Self.u16(w) + Self.u16(h) + Self.s32(encoding)
        }

        /// Server side of the handshake for a `width` x `height` screen. Returns what the client sent after ClientInit.
        func handshake(width: Int, height: Int) -> [UInt8] {
            send(Array("RFB 003.008\n".utf8))
            XCTAssertEqual(read(12), Array("RFB 003.008\n".utf8))
            send([1, 1])                    // one security type: none
            XCTAssertEqual(read(1), [1])
            send([0, 0, 0, 0])              // security result: ok
            XCTAssertEqual(read(1), [1])    // shared
            send(Self.u16(width) + Self.u16(height) + [UInt8](repeating: 0, count: 16) + [0, 0, 0, 4] + Array("test".utf8))
            // SetPixelFormat (20) + SetEncodings (4 + 4*4) + FramebufferUpdateRequest (10)
            return read(20 + 28 + 10)
        }
    }

    func makePair() -> (client: Int32, server: FakeServer) {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        return (fds[0], FakeServer(fds[1]))
    }

    func connect(width: Int, height: Int) throws -> (RFBClient, FakeServer, [UInt8]) {
        let (fd, server) = makePair()
        var setup: [UInt8] = []
        let done = expectation(description: "handshake")
        Thread.detachNewThread { setup = server.handshake(width: width, height: height); done.fulfill() }
        let client = try RFBClient(fileDescriptor: fd)
        wait(for: [done], timeout: 5)
        return (client, server, setup)
    }

    func testHandshakeRequestsLittleEndianBGRXAndScancodes() throws {
        let (client, server, setup) = try connect(width: 4, height: 2)
        defer { client.close(); Darwin.close(server.fd) }
        XCTAssertEqual(client.size, .init(width: 4, height: 2))
        XCTAssertEqual(client.name, "test")
        // SetPixelFormat: 32 bpp, depth 24, little-endian, true colour, shifts 16/8/0.
        XCTAssertEqual(Array(setup[0..<20]), [0, 0, 0, 0, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
        XCTAssertEqual(Array(setup[20..<24]), [2, 0, 0, 6])
        let encodings = Array(setup[24..<48]).chunked(4)
        XCTAssertTrue(encodings.contains(FakeServer.s32(-258)), "asks for extended key events")
        XCTAssertTrue(encodings.contains(FakeServer.s32(-239)), "asks for the cursor image")
        XCTAssertTrue(encodings.contains(FakeServer.s32(-308)), "asks to be told about, and to request, display size changes")
        XCTAssertEqual(Array(setup[48..<58]), [3, 0, 0, 0, 0, 0, 0, 4, 0, 2], "full update request")
    }

    func testRawCopyRectAndResize() throws {
        let (client, server, _) = try connect(width: 4, height: 2)
        defer { client.close(); Darwin.close(server.fd) }
        let updated = expectation(description: "update"); updated.assertForOverFulfill = false
        let resized = expectation(description: "resize")
        client.onUpdate = { updated.fulfill() }
        client.onResize = { size in XCTAssertEqual(size, .init(width: 2, height: 2)); resized.fulfill() }
        client.start()

        // One update: a raw 2x1 rectangle at (0,0), then copy it to (2,1).
        let pixelsA: [UInt8] = [1, 2, 3, 0, 4, 5, 6, 0]
        server.send([0, 0] + FakeServer.u16(2) + server.rect(0, 0, 2, 1, 0) + pixelsA + server.rect(2, 1, 2, 1, 1) + FakeServer.u16(0) + FakeServer.u16(0))
        wait(for: [updated], timeout: 5)
        XCTAssertEqual(server.read(10), [3, 1, 0, 0, 0, 0, 0, 4, 0, 2], "incremental request follows each update")
        let shot = client.snapshot()
        XCTAssertEqual(Array(shot.pixels[0..<8]), pixelsA)
        XCTAssertEqual(Array(shot.pixels[(1 * 4 + 2) * 4..<(1 * 4 + 4) * 4]), pixelsA, "copied to row 1, column 2")

        // Scancode support is acknowledged with a pseudo-rectangle; then keys are sent as extended key events.
        XCTAssertFalse(client.supportsScancodes)
        server.send([0, 0] + FakeServer.u16(2) + server.rect(0, 0, 0, 0, -258) + server.rect(0, 0, 2, 2, -223))
        wait(for: [resized], timeout: 5)
        XCTAssertEqual(server.read(10), [3, 1, 0, 0, 0, 0, 0, 2, 0, 2])
        XCTAssertTrue(client.supportsScancodes)
        XCTAssertEqual(client.snapshot().pixels.count, 2 * 2 * 4)

        client.sendKey(scancode: 0x1E, down: true)
        XCTAssertEqual(server.read(12), [255, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0x1E])
        client.sendPointer(x: 99, y: 1, buttons: [.left, .right])
        XCTAssertEqual(server.read(6), [5, 5, 0, 1, 0, 1], "pointer is clamped to the screen")
    }

    func testCursorImage() throws {
        let (client, server, _) = try connect(width: 4, height: 2)
        defer { client.close(); Darwin.close(server.fd) }
        let got = expectation(description: "cursor")
        client.onCursor = { cursor in
            XCTAssertEqual([cursor.width, cursor.height, cursor.hotX, cursor.hotY], [2, 1, 1, 0])
            // First pixel B=10 G=20 R=30 visible, second hidden by the mask.
            XCTAssertEqual(Array(cursor.rgba), [30, 20, 10, 255, 60, 50, 40, 0])
            got.fulfill()
        }
        client.start()
        server.send([0, 0] + FakeServer.u16(1) + server.rect(1, 0, 2, 1, -239) + [10, 20, 30, 0, 40, 50, 60, 0] + [0b1000_0000])
        wait(for: [got], timeout: 5)
    }

    func testCloseIsReported() throws {
        let (client, server, _) = try connect(width: 1, height: 1)
        let closed = expectation(description: "closed")
        client.onClose = { _ in closed.fulfill() }
        client.start()
        Darwin.close(server.fd)
        wait(for: [closed], timeout: 5)
    }

    func testKeyMap() {
        XCTAssertEqual(KeyMap.scancode(forMacKeyCode: 0x00), 0x1E)        // A
        XCTAssertEqual(KeyMap.scancode(forMacKeyCode: 0x24), 0x1C)        // Return
        XCTAssertEqual(KeyMap.scancode(forMacKeyCode: 0x37), 0x5B | 0x80) // Command = Windows key (E0 5B)
        XCTAssertEqual(KeyMap.scancode(forMacKeyCode: 0x7E), 0x48 | 0x80) // Up arrow (E0 48)
        XCTAssertNil(KeyMap.scancode(forMacKeyCode: 0x3F))                // Fn has no PC equivalent
        XCTAssertEqual(Set(KeyMap.table.values).count, KeyMap.table.count, "no two Mac keys share a scancode")
    }
}

private extension Array {
    func chunked(_ size: Int) -> [[Element]] { stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) } }
}
