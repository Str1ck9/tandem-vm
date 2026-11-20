import FuzzSupport
import XCTest
@testable import Sharing
import VMCore

/// The WebDAV server answers the guest, which is not trusted: no request may crash it, stop it
/// answering, or touch anything outside the shared folders. Raw sockets, so malformed requests
/// reach the parser as sent.
final class WebDAVFuzzTests: XCTestCase {
    private var root: URL!
    private var server: WebDAVServer!
    private var port: UInt16 = 0

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("davfuzz-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("rw/sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("ro"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("outside"), withIntermediateDirectories: true)
        try Data("hello world".utf8).write(to: root.appendingPathComponent("rw/a.txt"))
        try Data().write(to: root.appendingPathComponent("rw/empty.txt"))
        try Data("keep".utf8).write(to: root.appendingPathComponent("ro/keep.txt"))
        try Data("secret".utf8).write(to: root.appendingPathComponent("outside/secret.txt"))
        try Data("secret".utf8).write(to: root.appendingPathComponent("rw-sibling.txt"))
        server = WebDAVServer(shares: [.init(name: "Files", root: root.appendingPathComponent("rw")),
                                       .init(name: "Fixed", root: root.appendingPathComponent("ro"), readOnly: true)], requiredHost: nil)
        port = try server.start()
    }

    override func tearDown() {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    /// Sends `request` on a new connection, half-closes it, and returns the status of the first response
    /// (0 when none came before the server closed).
    private func send(_ request: Data) -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return -1 }
        _ = request.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        shutdown(fd, SHUT_WR)
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { break }
            received.append(contentsOf: buffer[0..<n])
            if received.count > 4 << 20 { break }
        }
        let line = String(decoding: received.prefix(32), as: UTF8.self)
        guard line.hasPrefix("HTTP/1.1 ") else { return 0 }
        return Int(line.dropFirst(9).prefix(3)) ?? 0
    }

    private func randomPath(_ rng: inout SeededRandom) -> String {
        var parts: [String] = []
        for _ in 0..<rng.int(0...4) {
            parts.append(rng.pick(["Files", "Fixed", "files", "sub", "a.txt", "empty.txt", "keep.txt", "new.txt", "..", "%2e%2e", "%2E%2E",
                                   ".", "%00", "a%00b", "%2F", "%5C..%5C", "..%2Fsecret.txt", "outside", "rw-sibling.txt", "%",
                                   "%zz", "~", "日本", "x y", "?q=1", "#frag", rng.awkwardString(maxLength: 12)]))
        }
        var path = "/" + parts.joined(separator: rng.chance(0.9) ? "/" : "//")
        if rng.chance(0.1) { path = "http://10.0.2.2" + path }
        if rng.chance(0.03) { path = String(repeating: "/Files", count: rng.int(100...3000)) }
        return path.replacingOccurrences(of: " ", with: rng.chance(0.5) ? "%20" : " ")
    }

    private func randomRequest(_ rng: inout SeededRandom) -> Data {
        let method = rng.pick(["GET", "HEAD", "PUT", "DELETE", "MKCOL", "COPY", "MOVE", "PROPFIND", "PROPPATCH", "LOCK", "UNLOCK",
                               "OPTIONS", "get", "TRACE", "", rng.awkwardString(maxLength: 8)])
        var headers: [String] = []
        if rng.chance(0.8) { headers.append("Host: 10.0.2.2") }
        if rng.chance(0.4) {
            let a = rng.pick(["", "0", "5", "10", "11", "100", "18446744073709551615", "-1", "abc", "99999999999999999999"])
            let b = rng.pick(["", "0", "3", "10", "1", "18446744073709551615", "-", "x"])
            headers.append("Range: " + rng.pick(["bytes=\(a)-\(b)", "bytes=\(a)", "bytes=\(a)-\(b),0-1", "items=0-1", "bytes=--\(b)"]))
        }
        if rng.chance(0.3) { headers.append("Depth: " + rng.pick(["0", "1", "infinity", "-1", ""])) }
        if rng.chance(0.4) { headers.append("Destination: " + rng.pick(["http://10.0.2.2", ""]) + randomPath(&rng)) }
        if rng.chance(0.2) { headers.append("Overwrite: " + rng.pick(["T", "F", "x"])) }
        if rng.chance(0.1) { headers.append("Expect: 100-continue") }
        if rng.chance(0.1) { headers.append(rng.awkwardString(maxLength: 40)) }
        if rng.chance(0.02) { headers.append("X-Long: " + String(repeating: "a", count: rng.int(1000...70_000))) }
        var body = Data()
        if rng.chance(0.3) {
            // Chunked, with sizes that lie.
            headers.append("Transfer-Encoding: chunked")
            for _ in 0..<rng.int(0...3) {
                let piece = rng.bytes(rng.int(0...64))
                let size = rng.pick([String(piece.count, radix: 16), "-1", "-10", "ffffffffffffffff", "7fffffffffffffff", "zz", "", "0", "10;ext=1"])
                body += Data("\(size)\r\n".utf8) + piece + Data("\r\n".utf8)
            }
            if rng.chance(0.7) { body += Data("0\r\n\r\n".utf8) }
        } else if rng.chance(0.5) {
            let payload = rng.chance(0.3)
                ? Data(#"<?xml version="1.0"?><D:propertyupdate xmlns:D="DAV:"><D:set><D:prop><Z:Win32LastModifiedTime xmlns:Z="urn:schemas-microsoft-com:">\#(rng.awkwardString(maxLength: 40))</Z:Win32LastModifiedTime></D:prop></D:set></D:propertyupdate>"#.utf8)
                : rng.bytes(rng.int(0...512))
            let length = rng.chance(0.8) ? String(payload.count)
                : rng.pick(["-1", "-100", "0", "99999999", "9223372036854775807", "abc", String(payload.count + 10)])
            headers.append("Content-Length: \(length)")
            body = payload
        }
        if rng.chance(0.7) { headers.append("Connection: close") }
        var text = "\(method) \(randomPath(&rng)) \(rng.pick(["HTTP/1.1", "HTTP/1.0", "", "HTTP/9"]))\r\n"
        text += headers.joined(separator: "\r\n") + "\r\n\r\n"
        var request = Data(text.utf8) + body
        if rng.chance(0.1) { request = Fuzz.mutate(request, using: &rng) }
        // Sometimes a second request on the same connection, to exercise keep-alive parsing.
        if rng.chance(0.15) { request += Data("OPTIONS / HTTP/1.1\r\nHost: 10.0.2.2\r\nConnection: close\r\n\r\n".utf8) }
        return request
    }

    /// What must not change: everything under `root` outside the writable share.
    private func protectedState() throws -> [String: Data] {
        var state: [String: Data] = [:]
        let rw = root.appendingPathComponent("rw").standardizedFileURL.path
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            let path = url.standardizedFileURL.path
            if path == rw || path.hasPrefix(rw + "/") { continue }
            state[path] = (try? Data(contentsOf: url)) ?? Data("<dir>".utf8)
        }
        return state
    }

    func testRandomRequestsNeitherCrashNorEscapeTheShares() throws {
        let before = try protectedState()
        var statuses: [Int: Int] = [:]
        Fuzz.cases(700) { rng, seed in
            let status = send(randomRequest(&rng))
            XCTAssertGreaterThanOrEqual(status, 0, "seed \(seed): could not connect, the server is gone")
            statuses[status, default: 0] += 1
        }
        XCTAssertEqual(send(Data("OPTIONS / HTTP/1.1\r\nHost: 10.0.2.2\r\nConnection: close\r\n\r\n".utf8)), 200, "the server must still answer")
        XCTAssertEqual(try protectedState(), before, "a request changed something outside the writable share")
        XCTAssertGreaterThan(statuses.filter { (200..<300).contains($0.key) }.values.reduce(0, +), 20, "too few requests got past the parser: \(statuses)")
    }

    // MARK: Regressions found by the fuzzer

    /// "bytes=10-3": the last byte before the first built a backwards Range and trapped.
    func testBackwardsRangeIsIgnored() {
        XCTAssertEqual(send(Data("GET /Files/a.txt HTTP/1.1\r\nRange: bytes=10-3\r\nConnection: close\r\n\r\n".utf8)), 200)
        XCTAssertEqual(send(Data("GET /Files/a.txt HTTP/1.1\r\nRange: bytes=0-18446744073709551615\r\nConnection: close\r\n\r\n".utf8)), 206)
    }

    /// A suffix range of an empty file counted down from 0 in Content-Range and trapped.
    func testSuffixRangeOfEmptyFileIsUnsatisfiable() {
        XCTAssertEqual(send(Data("GET /Files/empty.txt HTTP/1.1\r\nRange: bytes=-5\r\nConnection: close\r\n\r\n".utf8)), 416)
    }

    /// A negative chunk size reached `prefix(-1)` and trapped.
    func testNegativeChunkSizeClosesTheConnection() {
        let request = "PUT /Files/n.txt HTTP/1.1\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n-1\r\nabc\r\n0\r\n\r\n"
        // The body cannot be read to its end, so the server closes the connection (with or without a 507).
        XCTAssertTrue([0, 507].contains(send(Data(request.utf8))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("rw/n.txt").path))
        XCTAssertEqual(send(Data("OPTIONS / HTTP/1.1\r\nConnection: close\r\n\r\n".utf8)), 200)
    }

    func testNegativeContentLengthClosesTheConnection() {
        XCTAssertEqual(send(Data("PUT /Files/m.txt HTTP/1.1\r\nContent-Length: -5\r\nConnection: close\r\n\r\nabc".utf8)), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("rw/m.txt").path))
    }

    /// Regression (fuzzer): a guest reporting a UTC offset of Int.min overflowed the clock-skew sum.
    func testAbsurdGuestUTCOffsetIsIgnored() throws {
        let service = SharedFolderService()
        try service.start(config: VMConfig(name: "w", guestOS: .windows11arm), policy: SharingPolicy(profile: .default))
        defer { service.stop() }
        for offset in [Int.min, Int.max, -86_401, 1 << 40] { service.setGuestUTCOffset(offset, hostOffset: 3600) }
        service.setGuestUTCOffset(-18_000, hostOffset: 3600)
    }

    /// Whatever the path, a location it resolves to is inside its share.
    func testResolveNeverLeavesTheShare() {
        Fuzz.cases(1500) { rng, seed in
            let path = rng.chance(0.5) ? randomPath(&rng) : "/" + rng.awkwardString(maxLength: 40)
            guard case .item(let share, let url)? = server.resolve(path) else { return }
            let inside = url.standardizedFileURL.path, top = share.root.standardizedFileURL.path
            XCTAssertTrue(inside == top || inside.hasPrefix(top + "/"), "seed \(seed): \(path) resolved to \(inside)")
        }
    }
}
