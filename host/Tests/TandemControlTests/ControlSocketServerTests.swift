import XCTest
@testable import TandemControl

/// R18: the control socket's connection budget and idle deadline.
final class ControlSocketServerTests: XCTestCase {
    private var root: URL!
    private var path: String { ControlProtocol.socketURL(libraryRoot: root).path }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tcs-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func server(max: Int = 32, idle: TimeInterval = 600) -> ControlSocketServer {
        ControlSocketServer(path: path, maxConnections: max, idleTimeout: idle) { request in
            .success(request.id, .string("pong"))
        }
    }

    private func wait(until condition: () -> Bool, seconds: TimeInterval = 5) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if condition() { return true }; usleep(20_000) }
        return condition()
    }

    private func connect() throws -> ControlConnection {
        let fd = try XCTUnwrap(ControlSocket.connect(path: path), "could not connect to the test control socket")
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return ControlConnection(fd: fd, client: .cli)
    }

    func testRequestsAreAnswered() throws {
        let server = server()
        try server.start()
        defer { server.stop() }
        XCTAssertEqual(try connect().send(.list), .string("pong"))
    }

    func testConnectionsOverTheBudgetAreToldBusyAndPlacesComeBack() throws {
        let server = server(max: 2)
        try server.start()
        defer { server.stop() }
        var held = [try connect(), try connect()]
        for connection in held { _ = try connection.send(.list) }
        XCTAssertTrue(wait { server.activeConnections == 2 })
        XCTAssertThrowsError(try connect().send(.list)) { error in
            XCTAssertEqual((error as? ControlError)?.code, "busy", "\(error)")
        }
        XCTAssertEqual(server.activeConnections, 2)
        held.removeFirst()   // closes it
        XCTAssertTrue(wait { server.activeConnections == 1 })
        XCTAssertEqual(try connect().send(.list), .string("pong"))
        held.removeAll()
        XCTAssertTrue(wait { server.activeConnections == 0 })
    }

    func testAnIdleConnectionIsClosedAndTheClientCanComeBack() throws {
        let server = server(idle: 1)
        try server.start()
        defer { server.stop() }
        let connection = try connect()
        XCTAssertEqual(try connection.send(.list), .string("pong"))
        XCTAssertTrue(wait(until: { server.activeConnections == 0 }, seconds: 4), "closed after a second without a request")
        XCTAssertThrowsError(try connection.send(.list)) { error in
            XCTAssertEqual((error as? ControlError)?.code, "unavailable", "the client sees a lost connection and reconnects")
        }
        XCTAssertEqual(try connect().send(.list), .string("pong"))
    }
}
