import XCTest
import VMCore
@testable import Sharing

/// Revoked permissions must stop granting access. These tests talk to the real server over HTTP, the way
/// a Windows guest does, and change the policy through the same calls the app and `vmctl` use.
final class SharingPolicyEnforcementTests: XCTestCase {
    private var root: URL!
    private var bundle: VMBundle!
    private let service = SharedFolderService()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("policy-\(UUID().uuidString)").standardizedFileURL
        for name in ["docs", "scratch", "later"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
            try Data("contents of \(name)".utf8).write(to: root.appendingPathComponent("\(name)/file.txt"))
        }
        let library = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        var config = VMConfig(name: "win", guestOS: .windows11arm, cpuCount: 1, memoryMiB: 1024)
        config.sharing.folders = [SharedFolder(hostPath: path("docs"), name: "Docs", readOnly: true),
                                  SharedFolder(hostPath: path("scratch"), name: "Scratch")]
        bundle = try VMBundle.create(config: config, in: library)
    }

    override func tearDown() {
        service.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private func path(_ name: String) -> String { root.appendingPathComponent(name).path }

    /// One request to the folder server, as the guest would send it.
    private func status(_ method: String, _ path: String, body: Data? = nil, headers: [String: String] = [:]) throws -> Int {
        // A plain socket, because the server only answers requests addressed to 10.0.2.2 (the name the
        // guest knows the Mac by) and URLSession will not send a Host header of the caller's choosing.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(service.port)).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard connected == 0 else { throw XCTSkip("the folder server is not listening on port \(service.port)") }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var head = "\(method) \(path) HTTP/1.1\r\nHost: 10.0.2.2:\(service.port)\r\nConnection: close\r\nContent-Length: \(body?.count ?? 0)\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        var message = Data((head + "\r\n").utf8)
        if let body { message.append(body) }
        let sent = message.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        XCTAssertEqual(sent, message.count)
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !reply.contains(0x0A) {
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            reply.append(contentsOf: buffer[..<count])
        }
        // "HTTP/1.1 207 Multi-Status"
        let line = String(decoding: reply.prefix(while: { $0 != 0x0D && $0 != 0x0A }), as: UTF8.self).split(separator: " ")
        return try XCTUnwrap(line.count > 1 ? Int(line[1]) : nil, "no answer to \(method) \(path)")
    }

    // MARK: Read-only

    func testAReadOnlyFolderRefusesEveryKindOfWrite() throws {
        try service.start(config: bundle.config)
        XCTAssertEqual(try status("GET", "/Docs/file.txt"), 200)
        XCTAssertEqual(try status("PUT", "/Docs/new.txt", body: Data("x".utf8)), 403)
        XCTAssertEqual(try status("PUT", "/Docs/file.txt", body: Data("overwritten".utf8)), 403)
        XCTAssertEqual(try status("DELETE", "/Docs/file.txt"), 403)
        XCTAssertEqual(try status("MKCOL", "/Docs/folder"), 403)
        XCTAssertEqual(try status("MOVE", "/Docs/file.txt", headers: ["Destination": "http://10.0.2.2/Docs/renamed.txt"]), 403)
        XCTAssertEqual(try status("MOVE", "/Docs/file.txt", headers: ["Destination": "http://10.0.2.2/Scratch/stolen.txt"]), 403, "moving out of a read-only folder would delete from it")
        XCTAssertEqual(try status("COPY", "/Scratch/file.txt", headers: ["Destination": "http://10.0.2.2/Docs/copied.txt"]), 403, "nothing may be copied into it either")
        XCTAssertEqual(try status("PROPPATCH", "/Docs/file.txt", body: Data("<D:propertyupdate xmlns:D=\"DAV:\"/>".utf8)), 403)
        XCTAssertEqual(try status("LOCK", "/Docs/not-there.txt", body: Data()), 403, "locking a missing file would create it")
        XCTAssertEqual(try String(contentsOfFile: path("docs/file.txt"), encoding: .utf8), "contents of docs")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: path("docs")), ["file.txt"])
        // The folder beside it is writable, so the refusals above are the policy, not a broken server.
        XCTAssertEqual(try status("PUT", "/Scratch/new.txt", body: Data("x".utf8)), 201)
    }

    func testMakingAFolderReadOnlyWhileTheVMRunsStopsWritesAtOnce() throws {
        try service.start(config: bundle.config)
        XCTAssertEqual(try status("PUT", "/Scratch/one.txt", body: Data("1".utf8)), 201)
        var profile = bundle.config.sharing
        profile.folders[1].readOnly = true
        XCTAssertTrue(service.apply(SharingPolicy(profile: profile)).announce)
        XCTAssertEqual(try status("PUT", "/Scratch/two.txt", body: Data("2".utf8)), 403)
        XCTAssertEqual(try status("DELETE", "/Scratch/one.txt"), 403)
        XCTAssertEqual(try status("GET", "/Scratch/one.txt"), 200)
    }

    // MARK: Revocation

    func testARevokedFolderStopsBeingServed() throws {
        try service.start(config: bundle.config)
        XCTAssertEqual(try status("GET", "/Scratch/file.txt"), 200)
        XCTAssertEqual(try status("PROPFIND", "/Scratch", headers: ["Depth": "1"]), 207)

        var profile = bundle.config.sharing
        profile.folders.removeAll { $0.name == "Scratch" }
        let change = service.apply(SharingPolicy(profile: profile))
        XCTAssertTrue(change.announce, "the guest must be told to let go of the folder")
        XCTAssertNil(change.deferred)
        XCTAssertEqual(service.names, ["Docs"])

        XCTAssertEqual(try status("GET", "/Scratch/file.txt"), 404)
        XCTAssertEqual(try status("PROPFIND", "/Scratch", headers: ["Depth": "1"]), 404)
        XCTAssertEqual(try status("PUT", "/Scratch/after.txt", body: Data("x".utf8)), 404)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("scratch/after.txt")))
        XCTAssertEqual(try status("GET", "/Docs/file.txt"), 200, "the folder that is still shared keeps working")
    }

    func testTheRestrictedPresetAppliedToARunningVMClosesEveryFolder() throws {
        try service.start(config: bundle.config)
        XCTAssertEqual(try status("GET", "/Docs/file.txt"), 200)
        service.apply(SharingPolicy(profile: .restricted))
        XCTAssertEqual(try status("GET", "/Docs/file.txt"), 404)
        XCTAssertEqual(try status("GET", "/Scratch/file.txt"), 404)
        XCTAssertTrue(service.names.isEmpty)
    }

    func testAFolderCanBeSharedAfterTheVMStartedWithNone() throws {
        var config = bundle.config
        config.sharing = .default
        try service.start(config: config)
        XCTAssertNotEqual(service.port, 0, "the server runs even with nothing shared, so a folder can be added later")
        XCTAssertEqual(try status("GET", "/Later/file.txt"), 404)
        let granted = SharingPolicy(config, temporary: TemporaryGrants(folders: [SharedFolder(hostPath: path("later"), name: "Later", readOnly: true)]))
        XCTAssertTrue(service.apply(granted).announce)
        XCTAssertEqual(try status("GET", "/Later/file.txt"), 200)
        XCTAssertEqual(try status("PUT", "/Later/x.txt", body: Data("x".utf8)), 403)
    }

    // MARK: Folders that are devices (Linux guests)

    func testDeviceFoldersAreDisconnectedTogetherWhenOneIsTakenAway() throws {
        var config = bundle.config
        config.guestOS = .linux; config.tpm = false
        try service.start(config: config)
        XCTAssertEqual(service.kind, "9p")
        XCTAssertNotEqual(service.port, 0, "no folder goes through it, but drops and sends do")
        XCTAssertEqual(service.names, ["Docs", "Scratch"])
        XCTAssertFalse(service.changesApplyLive)

        // Adding waits for a restart and changes nothing now.
        var more = config.sharing
        more.folders.append(SharedFolder(hostPath: path("later"), name: "Later"))
        var change = service.apply(SharingPolicy(profile: more))
        XCTAssertFalse(change.announce)
        XCTAssertNotNil(change.deferred)
        XCTAssertEqual(service.names, ["Docs", "Scratch"])
        // `tandem share` prints the summary: the restart note must be in it, last, not only in the app.
        let printed = SharedFolderService.summaryLines(["Folders: Docs, Scratch, Later"], pendingNote: change.deferred)
        XCTAssertEqual(printed.count, 2)
        XCTAssertTrue(printed[1].hasPrefix("Note: ") && printed[1].contains("restart"))
        XCTAssertEqual(SharedFolderService.summaryLines(["x"], pendingNote: nil), ["x"])
        XCTAssertEqual(SharedFolderService.summaryLines(["x"], pendingNote: "  "), ["x"])

        // Taking one away: the guest finds folders by position, so all go, and the guest is told.
        var fewer = config.sharing
        fewer.folders.removeFirst()
        change = service.apply(SharingPolicy(profile: fewer))
        XCTAssertTrue(change.announce)
        XCTAssertNotNil(change.deferred)
        XCTAssertTrue(service.names.isEmpty)
        XCTAssertEqual(change.revokedDevices, [0], "the engine is told which device to pull out of the running guest")

        // An engine that can swap its device's folders (VZ) applies the same change in full.
        change = service.apply(SharingPolicy(profile: fewer), devicesUpdated: true)
        XCTAssertNil(change.deferred)
        XCTAssertEqual(service.names, ["Scratch"])
    }

    // MARK: The same change through the store and the runtime (what the app and vmctl call)

    private func waitForPolicy(_ runtime: SharingRuntime, _ description: String, _ condition: @escaping (SharingPolicy) -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition(runtime.policy) { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail("the running VM never saw: \(description)")
    }

    func testChangesMadeOnDiskReachTheRunningVMAndTemporaryAccessEndsWithIt() throws {
        // Before the VM runs there is nobody to give temporary access to.
        XCTAssertThrowsError(try SharingStore.share(path: path("later"), temporary: true, bundleURL: bundle.url))

        let runtime = SharingRuntime(bundle: bundle)
        let changes = expectation(description: "policy changes")
        changes.assertForOverFulfill = false
        runtime.onChange = { [service] _, new in
            service.apply(new)
            changes.fulfill()
        }
        runtime.start()
        defer { runtime.stop() }
        try service.start(config: bundle.config, policy: runtime.policy)
        XCTAssertEqual(try status("GET", "/Later/file.txt"), 404)

        // Temporary access, as `vmctl share --temporary` gives it.
        let folder = try SharingStore.share(path: path("later"), readOnly: true, temporary: true, bundleURL: bundle.url)
        XCTAssertEqual(folder.name, "later")
        runtime.refresh()
        wait(for: [changes], timeout: 5)
        XCTAssertEqual(runtime.policy.folders.map(\.name), ["Docs", "Scratch", "later"])
        XCTAssertEqual(runtime.policy.folders.last?.temporary, true)
        XCTAssertEqual(try status("GET", "/later/file.txt"), 200)
        XCTAssertFalse(try String(contentsOf: bundle.url.appendingPathComponent("config.json"), encoding: .utf8).contains("later"),
                       "temporary access is never written to the configuration")
        XCTAssertThrowsError(try SharingStore.share(path: path("later"), temporary: false, bundleURL: bundle.url), "already shared")

        // A permanent folder revoked on disk, without telling the runtime: it notices by itself.
        XCTAssertEqual(try SharingStore.unshare("Scratch", bundleURL: bundle.url), 1)
        waitForPolicy(runtime, "Scratch revoked") { !$0.folders.contains { $0.name == "Scratch" } }
        Thread.sleep(forTimeInterval: 0.2)   // the change handler runs right after the policy is swapped
        XCTAssertEqual(try status("GET", "/Scratch/file.txt"), 404)

        // The restricted preset on disk: everything closes, access given until shutdown included.
        try SharingStore.setProfile(.restricted, bundleURL: bundle.url)
        runtime.refresh()
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(try status("GET", "/Docs/file.txt"), 404)
        XCTAssertEqual(try status("GET", "/later/file.txt"), 404)
        XCTAssertTrue(runtime.policy.folders.isEmpty)
        XCTAssertEqual(runtime.policy.clipboard, .off)
        XCTAssertFalse(runtime.policy.usbAllowed)

        // Access can still be given to a restricted VM until it shuts down, and taken away again.
        try SharingStore.setTemporary(clipboard: .some(.guestToMac), usb: .some(true), bundleURL: bundle.url)
        XCTAssertEqual(runtime.refresh().clipboard, .guestToMac)
        XCTAssertTrue(runtime.policy.usbAllowed)
        try SharingStore.share(path: path("later"), readOnly: true, temporary: true, bundleURL: bundle.url)
        runtime.refresh()
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(try status("GET", "/later/file.txt"), 200)
        XCTAssertEqual(try SharingStore.unshare("later", bundleURL: bundle.url), 1)
        runtime.refresh()
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(try status("GET", "/later/file.txt"), 404)

        // Shutdown: every temporary grant is gone, on disk and in the policy.
        runtime.stop()
        XCTAssertEqual(runtime.policy.clipboard, .off)
        XCTAssertFalse(runtime.policy.usbAllowed)
        XCTAssertTrue(TemporarySharingFile.load(bundle).isEmpty)
        XCTAssertFalse(TemporarySharingFile.hasLiveOwner(bundle))
        XCTAssertEqual(try VMBundle.load(from: bundle.url).config.sharing, .restricted)
    }

    func testGrantsLeftByACrashedRunAreDroppedAtTheNextStart() throws {
        try TemporarySharingFile.save(TemporaryGrants(folders: [SharedFolder(hostPath: path("later"), name: "Leftover")], usb: true), bundle)
        let runtime = SharingRuntime(bundle: bundle)
        runtime.start()
        defer { runtime.stop() }
        XCTAssertEqual(runtime.policy.folders.map(\.name), ["Docs", "Scratch"])
        XCTAssertTrue(TemporarySharingFile.load(bundle).isEmpty)
    }
}
