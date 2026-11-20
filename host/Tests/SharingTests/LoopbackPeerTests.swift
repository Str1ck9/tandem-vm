import XCTest
@testable import Sharing
import VMCore

/// A VM's share server answers that VM's processes only (security review 2026-11-16): any other process
/// on the Mac, another user's included, could otherwise read and write the shared folders.
final class LoopbackPeerTests: XCTestCase {
    private var root: URL!
    private var server: WebDAVServer!
    private var port: UInt16 = 0

    override func setUpWithError() throws {
        signal(SIGPIPE, SIG_IGN)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("peer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: root.appendingPathComponent("a.txt"))
        server = WebDAVServer(shares: [.init(name: "Files", root: root)], requiredHost: nil)
    }

    override func tearDown() {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    /// Only connections held by `pid` or a direct child of it are served.
    private func restrict(to pid: pid_t) throws {
        server.acceptPeer = { [weak server] peerPort in
            guard let server else { return false }
            return LoopbackPeer.connection(fromPort: peerPort, toPort: server.port, isHeldByProcessOrChildOf: pid)
        }
        port = try server.start()
    }

    /// Fetches a.txt through `nc`, started directly or through a shell (then nc is a grandchild).
    private func fetchWithNC(throughShell: Bool, path: String = "/Files/a.txt") throws -> String {
        let process = Process()
        if throughShell {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "/usr/bin/nc 127.0.0.1 \(port); true"]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
            process.arguments = ["127.0.0.1", "\(port)"]
        }
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Give nc time to connect before the request goes in, then let the server answer and close.
        usleep(300_000)
        // A refused connection has already ended nc, so the write may find the pipe closed.
        try? input.fileHandleForWriting.write(contentsOf: Data("GET \(path) HTTP/1.0\r\nHost: x\r\n\r\n".utf8))
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline { usleep(100_000) }
        if process.isRunning { process.terminate() }
        try? input.fileHandleForWriting.close()
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    func testTheVMsOwnProcessIsServed() throws {
        try restrict(to: getpid())
        let request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/Files/a.txt")!)
        let done = expectation(description: "served")
        var status = 0
        URLSession.shared.dataTask(with: request) { _, response, _ in status = (response as? HTTPURLResponse)?.statusCode ?? 0; done.fulfill() }.resume()
        wait(for: [done], timeout: 10)
        XCTAssertEqual(status, 200, "a connection this process holds is served")
    }

    func testAChildOfTheVMProcessIsServed() throws {
        // QEMU's guestfwd runs one `nc` per guest connection.
        try restrict(to: getpid())
        XCTAssertTrue(try fetchWithNC(throughShell: false).contains("hello"))
    }

    func testAnyOtherProcessIsTurnedAway() throws {
        try restrict(to: getpid())
        // curl under a shell is neither the "VM", nor its child, nor an nc forwarder: it stands for any
        // other program on the Mac.
        let curl = Process()
        curl.executableURL = URL(fileURLWithPath: "/bin/sh")
        curl.arguments = ["-c", "/usr/bin/curl -s -m 3 -H 'Host: 10.0.2.2' http://127.0.0.1:\(port)/Files/a.txt; true"]
        let output = Pipe()
        curl.standardOutput = output
        curl.standardError = FileHandle.nullDevice
        try curl.run()
        let answer = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        curl.waitUntilExit()
        XCTAssertFalse(answer.contains("hello"), "another process gets nothing: \(answer)")
        // An nc that is a grandchild through a still-running process counts (GLib's intermediate child).
        XCTAssertTrue(try fetchWithNC(throughShell: true).contains("hello"))
    }

    func testAnNCLeftToLaunchdIsServed() throws {
        // What libslirp's guestfwd really does: GLib starts nc through an intermediate process that exits.
        try restrict(to: getpid())
        let request = root.appendingPathComponent("request"), answer = root.appendingPathComponent("answer")
        try Data("GET /Files/a.txt HTTP/1.0\r\nHost: x\r\n\r\n".utf8).write(to: request)
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "(sleep 0.3; exec /usr/bin/nc 127.0.0.1 \(port) < '\(request.path)' > '\(answer.path)') & exit 0"]
        try shell.run()
        shell.waitUntilExit()
        let deadline = Date().addingTimeInterval(5)
        var text = ""
        while Date() < deadline {
            usleep(200_000)
            text = (try? String(contentsOf: answer, encoding: .utf8)) ?? ""
            if text.contains("hello") { break }
        }
        XCTAssertTrue(text.contains("hello"), "an orphaned nc of this user is the VM's forwarder: \(text)")
    }

    func testNothingIsServedBeforeTheVMProcessIsKnown() throws {
        let folders = SharedFolderService()
        folders.onlyVMProcess = true
        var config = VMConfig(name: "w", guestOS: .windows11arm, cpuCount: 1, memoryMiB: 1024)
        config.sharedFolders = [SharedFolder(hostPath: root.path, name: "Files", readOnly: true)]
        try folders.start(config: config)
        defer { folders.stop() }
        port = UInt16(folders.port)
        XCTAssertFalse(try fetchWithNC(throughShell: false).contains("HTTP/1.1"), "no VM process yet: nobody is answered")
        folders.setVMProcess(getpid())
        // The real server also checks the Host header (the guest addresses it as 10.0.2.2): 403 means it answered.
        XCTAssertTrue(try fetchWithNC(throughShell: false).contains("HTTP/1.1 403"), "the VM's process is answered once known")
    }

    func testOwnershipLookupMatchesBothPorts() throws {
        try restrict(to: getpid())
        XCTAssertFalse(LoopbackPeer.connection(fromPort: 1, toPort: port, isHeldByProcessOrChildOf: getpid()))
        XCTAssertFalse(LoopbackPeer.connection(fromPort: 1, toPort: port, isHeldByProcessOrChildOf: 0))
    }
}
