import XCTest
@testable import Sharing
@testable import VMCore

final class PublishedServiceModelTests: XCTestCase {
    private func config(_ name: String = "My Linux") -> VMConfig { VMConfig(name: name, guestOS: .linux, cpuCount: 1, memoryMiB: 1024) }

    func testHostNamesAreStableAndSafe() {
        XCTAssertEqual(PublishedServices.hostName(forVMNamed: "My Linux"), "my-linux.tandem.test")
        XCTAssertEqual(PublishedServices.hostName(forVMNamed: "Test Win 11 (DEL ME)"), "test-win-11-del-me.tandem.test")
        XCTAssertEqual(PublishedServices.hostName(forVMNamed: "Café_Ünïx"), "cafe-unix.tandem.test")
        XCTAssertEqual(PublishedServices.hostName(forVMNamed: "***"), "vm.tandem.test")
        XCTAssertEqual(PublishedServices.loopbackName(forVMNamed: "My Linux"), "my-linux.localhost")
        XCTAssertLessThanOrEqual(PublishedServices.hostLabel(forVMNamed: String(repeating: "a", count: 200)).count, 63)
    }

    func testPortChoice() throws {
        let allFree: (Int) -> Bool = { _ in true }
        // The guest's own port number when it is free and not privileged.
        XCTAssertEqual(try PublishedServices.choosePort(wanted: nil, guestPort: 8080, taken: [], isFree: allFree), 8080)
        // A privileged guest port, a port in use, or one another service has: the first free one from 20000.
        XCTAssertEqual(try PublishedServices.choosePort(wanted: nil, guestPort: 80, taken: [], isFree: allFree), 20000)
        XCTAssertEqual(try PublishedServices.choosePort(wanted: nil, guestPort: 8080, taken: [8080, 20000], isFree: allFree), 20001)
        XCTAssertEqual(try PublishedServices.choosePort(wanted: nil, guestPort: 8080, taken: [], isFree: { $0 != 8080 && $0 != 20000 }), 20001)
        // An explicit port is never silently changed.
        XCTAssertEqual(try PublishedServices.choosePort(wanted: 9000, guestPort: 80, taken: [], isFree: allFree), 9000)
        XCTAssertThrowsError(try PublishedServices.choosePort(wanted: 9000, guestPort: 80, taken: [9000], isFree: allFree))
        XCTAssertThrowsError(try PublishedServices.choosePort(wanted: 9000, guestPort: 80, taken: [], isFree: { _ in false }))
    }

    func testPublishKeepsThePortOfAServiceThatIsPublishedAgain() throws {
        var c = config()
        let first = try PublishedServices.publish(name: "web", guestPort: 80, hostPort: nil, scope: .mac, in: &c, takenElsewhere: [20000], isFree: { _ in true })
        XCTAssertEqual(first.hostPort, 20001, "20000 belongs to another VM")
        // The same name again, now open to the network: the address must not move, even though the port now looks taken.
        let again = try PublishedServices.publish(name: "web", guestPort: 80, hostPort: nil, scope: .lan, in: &c, takenElsewhere: [20000], isFree: { _ in false })
        XCTAssertEqual(again.hostPort, 20001)
        XCTAssertEqual(c.publishedServices, [PublishedService(name: "web", guestPort: 80, hostPort: 20001, scope: .lan)])
        // A second service cannot take the first one's port.
        XCTAssertThrowsError(try PublishedServices.publish(name: "db", guestPort: 5432, hostPort: 20001, scope: .mac, in: &c, takenElsewhere: [], isFree: { _ in true }))
        XCTAssertTrue(PublishedServices.unpublish(name: "web", in: &c))
        XCTAssertNil(c.publishedServices, "no services is stored as no field at all")
        XCTAssertFalse(PublishedServices.unpublish(name: "web", in: &c))
    }

    func testValidation() {
        XCTAssertTrue(PublishedServices.validate(name: "web-1", guestPort: 80, hostPort: nil).isEmpty)
        XCTAssertFalse(PublishedServices.validate(name: "has space", guestPort: 80, hostPort: nil).isEmpty)
        XCTAssertFalse(PublishedServices.validate(name: "web", guestPort: 0, hostPort: nil).isEmpty)
        XCTAssertFalse(PublishedServices.validate(name: "web", guestPort: 80, hostPort: 80).isEmpty, "ports below 1024 need root")
    }

    func testConfigRoundTripAndOldConfigsStillLoad() throws {
        var c = config()
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(c), as: UTF8.self).contains("publishedServices"))
        c.publishedServices = [PublishedService(name: "web", guestPort: 80, hostPort: 20000, scope: .lan)]
        XCTAssertEqual(try JSONDecoder().decode(VMConfig.self, from: JSONEncoder().encode(c)).publishedServices, c.publishedServices)
    }
}

final class LocalNamesTests: XCTestCase {
    /// A DNS question: id 0x1234, recursion desired, one question.
    private func question(_ name: String, type: UInt16 = 1) -> Data {
        var d = Data([0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0])
        for label in name.split(separator: ".") { d.append(UInt8(label.utf8.count)); d.append(contentsOf: label.utf8) }
        d.append(contentsOf: [0, UInt8(type >> 8), UInt8(type & 0xFF), 0, 1])
        return d
    }

    func testNamesUnderTheDomainGetLoopback() throws {
        let q = question("My-Linux.Tandem.TEST")
        let r = [UInt8](try XCTUnwrap(LocalNames.response(to: q)))
        XCTAssertEqual(Array(r[0..<2]), [0x12, 0x34], "same id")
        XCTAssertEqual(r[2] & 0x80, 0x80, "a response")
        XCTAssertEqual(r[3] & 0x0F, 0, "no error")
        XCTAssertEqual(Array(r[4..<8]), [0, 1, 0, 1], "one question, one answer")
        XCTAssertEqual(Array(r.suffix(4)), [127, 0, 0, 1])
        XCTAssertEqual(Array(r[12..<q.count]), Array([UInt8](q)[12...]), "the question is repeated")
    }

    func testOtherKindsAndOtherNames() throws {
        // IPv6 address of one of our names: exists, but no such record.
        let v6 = [UInt8](try XCTUnwrap(LocalNames.response(to: question("web.tandem.test", type: 28))))
        XCTAssertEqual(v6[3] & 0x0F, 0); XCTAssertEqual(Array(v6[6..<8]), [0, 0])
        // Not our domain: refused, so the system asks its normal servers.
        let other = [UInt8](try XCTUnwrap(LocalNames.response(to: question("example.com"))))
        XCTAssertEqual(other[3] & 0x0F, 5); XCTAssertEqual(Array(other[6..<8]), [0, 0])
        XCTAssertEqual([UInt8](try XCTUnwrap(LocalNames.response(to: question("nottandem.test"))))[3] & 0x0F, 5)
        // Rubbish and responses are ignored.
        XCTAssertNil(LocalNames.response(to: Data([1, 2, 3])))
        var response = question("web.tandem.test"); response[2] |= 0x80
        XCTAssertNil(LocalNames.response(to: response))
    }

    func testResolverFileAndAddresses() {
        XCTAssertTrue(LocalNames.resolverFileContents.contains("nameserver 127.0.0.1\nport \(LocalNames.port)\n"))
        XCTAssertTrue(LocalNames.installCommand.contains("/etc/resolver/tandem.test"))
        let service = PublishedService(name: "web", guestPort: 80, hostPort: 20000)
        XCTAssertEqual(LocalNames.address(for: service, vmName: "My Linux", namesInstalled: true), "my-linux.tandem.test:20000")
        XCTAssertEqual(LocalNames.address(for: service, vmName: "My Linux", namesInstalled: false), "my-linux.localhost:20000")
    }
}

final class ServiceRelayTests: XCTestCase {
    /// A server on a loopback port that answers every connection with `text` and closes.
    private final class Server {
        let fd: Int32
        let port: Int
        init(_ text: String) {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
            Darwin.listen(fd, 8)
            self.fd = fd
            self.port = Int(UInt16(bigEndian: address.sin_port))
            Thread.detachNewThread {
                while true {
                    let client = Darwin.accept(fd, nil, nil)
                    guard client >= 0 else { return }
                    // Read what the caller sent until it stops sending, then answer with it appended.
                    var received = [UInt8]()
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while true { let n = read(client, &buffer, buffer.count); if n <= 0 { break }; received += buffer[0..<n] }
                    let reply = Array(text.utf8) + received
                    _ = reply.withUnsafeBytes { write(client, $0.baseAddress, reply.count) }
                    close(client)
                }
            }
        }
        func stop() { shutdown(fd, SHUT_RDWR); close(fd) }
    }

    private func ask(port: Int, host: String = "127.0.0.1", send: String = "") -> String? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port)).bigEndian; address.sin_addr.s_addr = inet_addr(host)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard withUnsafePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0 else { return nil }
        _ = Array(send.utf8).withUnsafeBytes { write(fd, $0.baseAddress, send.utf8.count) }
        shutdown(fd, SHUT_WR)
        var out = [UInt8](), buffer = [UInt8](repeating: 0, count: 4096)
        while true { let n = read(fd, &buffer, buffer.count); if n <= 0 { break }; out += buffer[0..<n] }
        return String(decoding: out, as: UTF8.self)
    }

    /// Fails the test clearly (instead of crashing the whole test run) when no port can be had.
    private func freePort() throws -> Int {
        try XCTUnwrap(ServicePublisher.freeLoopbackPort(), "no free loopback port could be found (is binding sockets allowed here?)")
    }

    func testConnectionsArePassedOnBothWaysAndFollowAMovingTarget() throws {
        let a = Server("A:"), b = Server("B:")
        defer { a.stop(); b.stop() }
        let lock = NSLock()
        nonisolated(unsafe) var current: Int? = a.port
        let port = try freePort()
        let relay = ServiceRelay(bindAddress: "127.0.0.1", port: port) { lock.withLock { current.map { ("127.0.0.1", $0) } } }
        try relay.start()
        defer { relay.stop() }
        // The caller's bytes reach the service and the answer comes back after the caller stops sending.
        XCTAssertEqual(ask(port: port, send: "hello"), "A:hello")
        // The guest "moved": the next connection goes to the new place, with the relay untouched.
        lock.withLock { current = b.port }
        XCTAssertEqual(ask(port: port, send: "x"), "B:x")
        // The guest is away: the caller is turned down at once instead of hanging.
        lock.withLock { current = nil }
        XCTAssertEqual(ask(port: port), "")
        lock.withLock { current = a.port }
        XCTAssertEqual(ask(port: port), "A:")
        XCTAssertEqual(relay.connectionCount, 3)
    }

    func testAPortInUseIsReportedAndStoppingFreesThePort() throws {
        let port = try freePort()
        let relay = ServiceRelay(bindAddress: "127.0.0.1", port: port) { nil }
        XCTAssertTrue(ServiceRelay.portIsFree(port))
        try relay.start()
        XCTAssertFalse(ServiceRelay.portIsFree(port))
        // Asking for every interface while a loopback listener has the port must be refused too.
        XCTAssertThrowsError(try ServiceRelay(bindAddress: "0.0.0.0", port: port) { nil }.start()) { error in
            XCTAssertTrue(error.localizedDescription.contains("in use"), error.localizedDescription)
        }
        relay.stop()
        XCTAssertNil(ask(port: port), "nothing listens after stop")
        XCTAssertTrue(ServiceRelay.portIsFree(port))
    }

    func testPublisherReportsEachServiceAndCleansUp() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-published-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = Server("ok")
        defer { server.stop() }
        let good = try freePort(), taken = try freePort()
        let blocker = ServiceRelay(bindAddress: "127.0.0.1", port: taken) { nil }
        try blocker.start()
        defer { blocker.stop() }
        var config = VMConfig(name: "Svc Test", guestOS: .linux, cpuCount: 1, memoryMiB: 1024)
        config.publishedServices = [PublishedService(name: "web", guestPort: 80, hostPort: good),
                                    PublishedService(name: "db", guestPort: 5432, hostPort: taken)]
        let publisher = ServicePublisher(statusDirectory: directory)
        let serverPort = server.port
        let statuses = publisher.start(config: config) { guestPort in guestPort == 80 ? ("127.0.0.1", serverPort) : nil }
        XCTAssertEqual(statuses.map(\.isListening), [true, false], "one service failing does not stop the other")
        XCTAssertTrue(statuses[1].error?.contains("in use") == true)
        XCTAssertEqual(ask(port: good), "ok")
        // Another process would read this.
        let records = ServicePublisher.active(in: directory, knownVMs: [config.id])
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.hostName, "svc-test.tandem.test")
        XCTAssertEqual(records.first?.services, statuses)
        publisher.stop()
        XCTAssertNil(ask(port: good))
        XCTAssertTrue(ServicePublisher.active(in: directory).isEmpty)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.count, 0)
    }

    func testStaleStatusFilesAreRemoved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-published-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func write(_ record: ServicePublisher.Record) throws {
            try JSONEncoder().encode(record).write(to: directory.appendingPathComponent(record.vmID.uuidString.lowercased() + ".json"))
        }
        let live = UUID(), dead = UUID(), deleted = UUID()
        try write(.init(vmID: live, vmName: "live", hostName: "live.tandem.test", pid: getpid(), services: []))
        // A process id that cannot exist stands for a Tandem that crashed.
        try write(.init(vmID: dead, vmName: "dead", hostName: "dead.tandem.test", pid: 0x3FFF_FFFF, services: []))
        try write(.init(vmID: deleted, vmName: "deleted", hostName: "deleted.tandem.test", pid: getpid(), services: []))
        try Data("not json".utf8).write(to: directory.appendingPathComponent("junk.json"))
        XCTAssertEqual(ServicePublisher.active(in: directory, knownVMs: [live, dead]).map(\.vmName), ["live"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [live.uuidString.lowercased() + ".json"])
    }

    func testWhereAGuestPortIsReached() {
        var nat = VMConfig(name: "n", guestOS: .linux, engine: .qemu, cpuCount: 1, memoryMiB: 1024)
        nat.publishedServices = [PublishedService(name: "web", guestPort: 80, hostPort: 20000)]
        XCTAssertTrue(ServicePublisher.needsBackends(nat))
        let viaForward = ServicePublisher.target(config: nat, backends: [80: 40123]) { ["10.0.2.15"] }
        XCTAssertEqual(viaForward(80)?.host, "127.0.0.1"); XCTAssertEqual(viaForward(80)?.port, 40123)
        XCTAssertNil(viaForward(81))
        // A guest with an address of its own is reached there, and a new address is used at once.
        var direct = nat; direct.engine = .vz
        XCTAssertFalse(ServicePublisher.needsBackends(direct))
        let lock = NSLock()
        nonisolated(unsafe) var addresses = ["127.0.0.1", "192.168.64.5"]
        let viaAddress = ServicePublisher.target(config: direct, backends: [:]) { lock.withLock { addresses } }
        XCTAssertEqual(viaAddress(80)?.host, "192.168.64.5"); XCTAssertEqual(viaAddress(80)?.port, 80)
        lock.withLock { addresses = ["192.168.64.9"] }
        XCTAssertEqual(viaAddress(80)?.host, "192.168.64.9")
    }

    func testGuestAddressFromTheMacsAddressTable() {
        let table = """
        ? (10.1.2.1) at 3c:37:86:aa:bb:cc on en0 ifscope [ethernet]
        ? (192.168.64.5) at 5e:a5:65:7c:4e:c on bridge100 ifscope [bridge]
        ? (192.168.64.7) at (incomplete) on bridge100 ifscope [bridge]
        """
        XCTAssertEqual(GuestAddress.address(forMAC: "5E:A5:65:7C:4E:0C", inARPTable: table), "192.168.64.5", "arp drops leading zeros")
        XCTAssertNil(GuestAddress.address(forMAC: "5e:a5:65:7c:4e:dd", inARPTable: table))
        XCTAssertEqual(GuestAddress.first(of: ["127.0.0.1", "169.254.3.4", "fe80::1", "10.1.2.61"]), "10.1.2.61")
        XCTAssertNil(GuestAddress.first(of: []))
    }
}

/// R18: what one relay, and all of them together, will hold.
final class ServiceRelayBudgetTests: XCTestCase {
    /// A guest service that accepts and then only reads (never answers), holding every connection.
    private final class Holder {
        let fd: Int32, port: Int
        init() {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
            Darwin.listen(fd, 16)
            self.fd = fd; self.port = Int(UInt16(bigEndian: address.sin_port))
            Thread.detachNewThread {
                while true {
                    let client = Darwin.accept(fd, nil, nil)
                    guard client >= 0 else { return }
                    Thread.detachNewThread {
                        var buffer = [UInt8](repeating: 0, count: 1024)
                        while read(client, &buffer, buffer.count) > 0 {}
                        close(client)
                    }
                }
            }
        }
        func stop() { shutdown(fd, SHUT_RDWR); close(fd) }
    }

    private func port() throws -> Int {
        try XCTUnwrap(ServicePublisher.freeLoopbackPort(), "no free loopback port could be found (is binding sockets allowed here?)")
    }

    private func dial(_ port: Int) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port)).bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// True when the relay closed the connection (end of stream) within the read timeout.
    private func closedByRelay(_ fd: Int32) -> Bool {
        var byte: UInt8 = 0
        return read(fd, &byte, 1) == 0
    }

    private func wait(until condition: () -> Bool, seconds: TimeInterval = 5) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if condition() { return true }; usleep(20_000) }
        return condition()
    }

    func testConnectionsOverTheBudgetAreClosedAndPlacesComeBack() throws {
        let guest = Holder()
        defer { guest.stop() }
        let port = try port()
        let relay = ServiceRelay(bindAddress: "127.0.0.1", port: port, maxConnections: 2, idleTimeout: 60) { ("127.0.0.1", guest.port) }
        try relay.start()
        defer { relay.stop() }
        let a = dial(port), b = dial(port)
        XCTAssertTrue(wait { relay.activeConnections == 2 })
        let c = dial(port)
        XCTAssertTrue(closedByRelay(c), "a third connection is closed at once")
        XCTAssertEqual(relay.refusedCount, 1)
        XCTAssertEqual(relay.activeConnections, 2)
        close(c)
        // A caller hangs up: its place is given back and the next caller gets through.
        close(a)
        XCTAssertTrue(wait { relay.activeConnections == 1 })
        let d = dial(port)
        XCTAssertTrue(wait { relay.activeConnections == 2 })
        close(b); close(d)
        XCTAssertTrue(wait { relay.activeConnections == 0 })
        XCTAssertTrue(wait { ServiceRelay.globalActiveConnections == 0 }, "the shared budget is given back too")
    }

    func testAnIdleConnectionIsClosed() throws {
        let guest = Holder()
        defer { guest.stop() }
        let port = try port()
        let relay = ServiceRelay(bindAddress: "127.0.0.1", port: port, idleTimeout: 0.4) { ("127.0.0.1", guest.port) }
        try relay.start()
        defer { relay.stop() }
        let started = Date()
        let fd = dial(port)
        defer { close(fd) }
        XCTAssertTrue(closedByRelay(fd), "a connection on which nothing moves is closed")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.3)
        XCTAssertTrue(wait { relay.activeConnections == 0 })
    }

    func testAConnectionThatKeepsTalkingStaysOpen() throws {
        let guest = Holder()
        defer { guest.stop() }
        let port = try port()
        let relay = ServiceRelay(bindAddress: "127.0.0.1", port: port, idleTimeout: 0.5) { ("127.0.0.1", guest.port) }
        try relay.start()
        defer { relay.stop() }
        let fd = dial(port)
        defer { close(fd) }
        // Only the caller sends (the guest never answers): one quiet direction alone is not idleness.
        for _ in 0..<8 {
            var byte: UInt8 = 0x41
            XCTAssertEqual(write(fd, &byte, 1), 1)
            usleep(200_000)
        }
        XCTAssertEqual(relay.activeConnections, 1, "still open after 1.6 s of traffic with a 0.5 s idle limit")
    }

    func testStopEndsConnectionsStillReachingTheGuest() throws {
        let port = try port()
        // A target that takes its time: the relay must still be able to stop.
        let relay = ServiceRelay(bindAddress: "127.0.0.1", port: port) { usleep(300_000); return nil }
        try relay.start()
        let fd = dial(port)
        defer { close(fd) }
        XCTAssertTrue(wait { relay.activeConnections == 1 })
        relay.stop()
        XCTAssertTrue(closedByRelay(fd))
        XCTAssertTrue(wait { relay.activeConnections == 0 })
    }
}
