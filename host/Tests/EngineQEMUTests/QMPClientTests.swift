import XCTest
@testable import EngineQEMU
import VMCore

/// The QMP client against a fake QEMU monitor (review R13): deadlines, cancellation, closing, concurrent
/// writers, oversized lines.
final class QMPClientTests: XCTestCase {
    private var path = ""
    private var listener: Int32 = -1

    override func setUpWithError() throws {
        path = "/tmp/tqmp-\(getpid())-\(UInt16.random(in: 0...UInt16.max)).sock"
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: path.utf8.prefix($0.count - 1)) }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0, String(cString: strerror(errno)))
        XCTAssertEqual(Darwin.listen(listener, 4), 0)
    }

    override func tearDown() {
        Darwin.close(listener)
        unlink(path)
    }

    /// Accepts one connection on a thread and hands it to `script` (which owns and closes it).
    private func serve(_ script: @escaping @Sendable (FakeMonitor) -> Void) {
        let fd = listener
        Thread.detachNewThread {
            let client = Darwin.accept(fd, nil, nil)
            guard client >= 0 else { return }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let monitor = FakeMonitor(fd: client)
            monitor.send(#"{"QMP": {"version": {}, "capabilities": []}}"#)
            script(monitor)
        }
    }

    func testCapabilityNegotiationHasADeadline() async throws {
        serve { monitor in _ = monitor.readLine(); usleep(3_000_000); monitor.close() }
        let started = Date()
        do {
            _ = try await QMPClient.connect(path: path, timeout: 1)
            XCTFail("a monitor that never answers must not be connected")
        } catch {
            XCTAssertTrue("\(error)".contains("did not answer"), "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5)
    }

    func testACommandWithoutReplyTimesOut() async throws {
        serve { monitor in
            monitor.answerCapabilities()
            _ = monitor.readLine()          // the command, never answered
            usleep(3_000_000)
            monitor.close()
        }
        let qmp = try await QMPClient.connect(path: path, timeout: 5)
        let started = Date()
        do {
            try await qmp.execute("query-status", timeout: 0.3)
            XCTFail("no reply, so it must time out")
        } catch {
            XCTAssertTrue("\(error)".contains("did not answer “query-status”"), "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        qmp.close()
    }

    func testCancellationEndsTheWait() async throws {
        serve { monitor in monitor.answerCapabilities(); _ = monitor.readLine(); usleep(3_000_000); monitor.close() }
        let qmp = try await QMPClient.connect(path: path, timeout: 5)
        let waiting = Task { try await qmp.execute("query-status", timeout: 60) }
        try await Task.sleep(nanoseconds: 200_000_000)
        let started = Date()
        waiting.cancel()
        do { _ = try await waiting.value; XCTFail("cancelled") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        qmp.close()
    }

    func testClosingFailsWaitersAndLaterCommandsAtOnce() async throws {
        serve { monitor in monitor.answerCapabilities(); _ = monitor.readLine(); usleep(200_000); monitor.close() }
        let qmp = try await QMPClient.connect(path: path, timeout: 5)
        do { try await qmp.execute("query-status", timeout: 10); XCTFail("closed") }
        catch { XCTAssertTrue("\(error)".contains("closed"), "\(error)") }
        let started = Date()
        do { try await qmp.execute("cont", timeout: 10); XCTFail("closed") }
        catch { XCTAssertTrue("\(error)".contains("closed"), "\(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "a command after the close fails at once")
    }

    func testConcurrentCommandsAreWrittenWholeAndAnsweredOnce() async throws {
        let count = 40
        serve { monitor in
            monitor.answerCapabilities()
            // Echoes each command's payload back; a line that is not one whole command ends the test.
            for _ in 0..<count {
                guard let line = monitor.readLine(),
                      let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      let id = object["id"] as? Int,
                      let arguments = object["arguments"] as? [String: Any] else { break }
                let reply = try! JSONSerialization.data(withJSONObject: ["return": arguments, "id": id])
                monitor.send(String(decoding: reply, as: UTF8.self))
            }
            usleep(500_000)
            monitor.close()
        }
        let qmp = try await QMPClient.connect(path: path, timeout: 5)
        let big = String(repeating: "x", count: 200_000)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                group.addTask {
                    let reply = try await qmp.execute("echo", arguments: ["n": i, "pad": big], timeout: 20)
                    XCTAssertEqual(reply["n"] as? Int, i)
                }
            }
            try await group.waitForAll()
        }
        qmp.close()
    }

    func testAnEndlessLineEndsTheConnection() async throws {
        serve { monitor in
            monitor.answerCapabilities()
            _ = monitor.readLine()
            let chunk = String(repeating: "y", count: 1 << 20)
            for _ in 0..<40 { if !monitor.send(chunk, newline: false) { break } }
            usleep(500_000)
            monitor.close()
        }
        let qmp = try await QMPClient.connect(path: path, timeout: 5)
        do { try await qmp.execute("query-status", timeout: 20); XCTFail("the connection must end") }
        catch { XCTAssertTrue("\(error)".contains("closed"), "\(error)") }
    }
}

/// The far end of a QMP connection, driven by a test.
final class FakeMonitor: @unchecked Sendable {
    let fd: Int32
    private var pending = Data()
    init(fd: Int32) { self.fd = fd }

    func readLine() -> Data? {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            if let newline = pending.firstIndex(of: 0x0A) {
                let line = pending.subdata(in: pending.startIndex..<newline)
                pending.removeSubrange(pending.startIndex...newline)
                return line
            }
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n <= 0 { return nil }
            pending.append(contentsOf: buffer[0..<n])
        }
    }

    @discardableResult
    func send(_ text: String, newline: Bool = true) -> Bool {
        var data = Data(text.utf8)
        if newline { data.append(0x0A) }
        return data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
    }

    func answerCapabilities() {
        guard let line = readLine(), let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let id = object["id"] as? Int else { return }
        send(#"{"return": {}, "id": \#(id)}"#)
    }

    func close() { Darwin.close(fd) }
}
