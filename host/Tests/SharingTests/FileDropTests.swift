import XCTest
@testable import Sharing
import VMCore

final class FileDropTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func write(_ relative: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent("mac/" + relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    func testStagingListsFoldersBeforeTheirFilesAndKeepsNamesApart() throws {
        let a = try write("one/report.txt", "12345")
        let b = try write("two/report.txt", "abc")
        _ = try write("Folder/inner/deep.bin", "xyz")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("mac/Folder/link"), withDestinationURL: a)
        let folder = root.appendingPathComponent("mac/Folder")
        let staging = root.appendingPathComponent("drops")
        let manifest = try FileDrop.stage([a, b, folder], in: staging, id: "d1")
        XCTAssertEqual(manifest.items.map(\.path), ["d1/report.txt", "d1/report 2.txt", "d1/Folder", "d1/Folder/inner", "d1/Folder/inner/deep.bin"],
                       "a second file of the same name is numbered; a link inside a dropped folder is left out")
        XCTAssertEqual(manifest.items.map(\.directory), [false, false, true, true, false])
        XCTAssertEqual(manifest.totalBytes, 11)
        XCTAssertEqual(manifest.topLevel, ["report.txt", "report 2.txt", "Folder"])
        XCTAssertEqual(try String(contentsOf: staging.appendingPathComponent("d1/report 2.txt"), encoding: .utf8), "abc")
        FileDrop.discard("d1", in: staging)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.appendingPathComponent("d1").path))
    }

    func testGuestTextEncodesPathsForTheURL() {
        let manifest = FileDrop.Manifest(id: "ab", port: 47123, items: [
            .init(path: "ab/My Folder", size: 0, directory: true),
            .init(path: "ab/My Folder/é&%.txt", size: 9, directory: false),
        ])
        XCTAssertEqual(manifest.guestText, "tandem-drop 1\nab\t47123\tTandemDrop\nd\tab/My%20Folder\nf\t9\tab/My%20Folder/%C3%A9%26%25.txt\n")
    }

    func testFilesFollowTheClipboardDirectionAndTheRestrictedPresetRefuses() {
        var both = SharingProfile.default
        both.clipboard = .both
        XCTAssertTrue(SharingPolicy(profile: both).allowsFilesToGuest)
        XCTAssertTrue(SharingPolicy(profile: both).allowsFilesToMac)
        var toGuest = both; toGuest.clipboard = .macToGuest
        XCTAssertTrue(SharingPolicy(profile: toGuest).allowsFilesToGuest)
        XCTAssertFalse(SharingPolicy(profile: toGuest).allowsFilesToMac)
        let restricted = SharingPolicy(profile: .restricted)
        XCTAssertThrowsError(try restricted.requireFilesToGuest()) { error in
            XCTAssertTrue((error as? VMError)?.message.contains("turned off") == true)
        }
        XCTAssertThrowsError(try restricted.requireFilesToMac())
        // A temporary clipboard grant opens the matching direction until shutdown.
        let granted = SharingPolicy(profile: .restricted, temporary: TemporaryGrants(clipboard: .macToGuest))
        XCTAssertNoThrow(try granted.requireFilesToGuest())
        XCTAssertThrowsError(try granted.requireFilesToMac())
    }

    func testArrivalsAreDeliveredWithoutOverwriting() throws {
        let inbox = root.appendingPathComponent("inbox")
        let downloads = root.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: inbox.appendingPathComponent("x1/Sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: inbox.appendingPathComponent("x1/a.txt"))
        try Data("inside".utf8).write(to: inbox.appendingPathComponent("x1/Sub/b.txt"))
        try Data("old".utf8).write(to: downloads.appendingPathComponent("a.txt"))
        // Not finished yet: no manifest, nothing is taken.
        XCTAssertEqual(FileDrop.finishedArrivals(in: inbox), [])
        try Data("a.txt\nSub\n../escape\n".utf8).write(to: inbox.appendingPathComponent("x1.done"))
        let arrivals = FileDrop.finishedArrivals(in: inbox)
        XCTAssertEqual(arrivals, [FileDrop.Arrival(id: "x1", names: ["a.txt", "Sub"])], "names that climb out are dropped")
        let result = FileDrop.deliver(arrivals[0], from: inbox, to: downloads)
        XCTAssertEqual(result.delivered.map(\.lastPathComponent), ["a 2.txt", "Sub"])
        XCTAssertTrue(result.complete)
        XCTAssertEqual(try String(contentsOf: downloads.appendingPathComponent("a.txt"), encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOf: downloads.appendingPathComponent("Sub/b.txt"), encoding: .utf8), "inside")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: inbox.path), [])
    }

    // R05: a failed delivery must not delete what the guest sent.

    private func makeArrival(_ inbox: URL, id: String, files: [String: String]) throws -> FileDrop.Arrival {
        try FileManager.default.createDirectory(at: inbox.appendingPathComponent(id), withIntermediateDirectories: true)
        for (name, text) in files { try Data(text.utf8).write(to: inbox.appendingPathComponent("\(id)/\(name)")) }
        try Data((files.keys.sorted().joined(separator: "\n") + "\n").utf8).write(to: inbox.appendingPathComponent("\(id).done"))
        return try XCTUnwrap(FileDrop.finishedArrivals(in: inbox).first { $0.id == id })
    }

    func testADestinationThatIsAFileKeepsTheArrival() throws {
        let inbox = root.appendingPathComponent("inbox-r05a"), keep = root.appendingPathComponent("keep-r05a")
        let notAFolder = root.appendingPathComponent("Downloads-file")
        try Data("i am a file".utf8).write(to: notAFolder)
        let arrival = try makeArrival(inbox, id: "y1", files: ["a.txt": "A", "b.txt": "B"])
        let result = FileDrop.deliver(arrival, from: inbox, to: notAFolder, keepIn: keep)
        XCTAssertEqual(result.delivered, [])
        XCTAssertEqual(result.failures.count, 2)
        XCTAssertFalse(result.complete)
        XCTAssertEqual(Set(result.kept.map(\.lastPathComponent)), ["a.txt", "b.txt"])
        for url in result.kept { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(url.path) kept") }
        XCTAssertEqual(try String(contentsOf: keep.appendingPathComponent("y1/a.txt"), encoding: .utf8), "A")
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.appendingPathComponent("y1/Why these files are here.txt").path))
        XCTAssertFalse(result.leftInInbox)
        XCTAssertEqual(FileDrop.finishedArrivals(in: inbox), [], "not retried in a loop")
    }

    func testOneFailureAmongSeveralDeliversTheRestAndKeepsTheFailure() throws {
        let inbox = root.appendingPathComponent("inbox-r05b"), keep = root.appendingPathComponent("keep-r05b")
        let downloads = root.appendingPathComponent("Downloads-r05b")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        var arrival = try makeArrival(inbox, id: "y2", files: ["good.txt": "G"])
        // A folder without write permission cannot be moved to another parent (its ".." would change),
        // so this one fails while good.txt goes through.
        let bad = inbox.appendingPathComponent("y2/Bad")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("B".utf8).write(to: bad.appendingPathComponent("inside.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: bad.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bad.path) }
        arrival.names.append("Bad")
        let result = FileDrop.deliver(arrival, from: inbox, to: downloads, keepIn: keep)
        XCTAssertEqual(result.delivered.map(\.lastPathComponent), ["good.txt"])
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.leftInInbox, "the folder cannot be kept elsewhere either, so it stays where it is")
        XCTAssertEqual(try String(contentsOf: bad.appendingPathComponent("inside.txt"), encoding: .utf8), "B")
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("y2/good.txt").path))
        XCTAssertEqual(try String(contentsOf: inbox.appendingPathComponent("y2.failed"), encoding: .utf8), "Bad\n")
    }

    func testWhenNothingCanBeKeptTheFilesStayInTheInboxAndSurviveClear() throws {
        let library = root.appendingPathComponent("library-r05c")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let bundle = try VMBundle.create(config: VMConfig(name: "r05c", guestOS: .linux, cpuCount: 1, memoryMiB: 1024), in: library)
        let inbox = FileDrop.inboxRoot(bundle)
        let notAFolder = root.appendingPathComponent("Downloads-file-r05c")
        try Data("file".utf8).write(to: notAFolder)
        let keepBlocked = root.appendingPathComponent("keep-is-a-file")
        try Data("file".utf8).write(to: keepBlocked)
        let arrival = try makeArrival(inbox, id: "y3", files: ["c.txt": "C"])
        let result = FileDrop.deliver(arrival, from: inbox, to: notAFolder, keepIn: keepBlocked)
        XCTAssertTrue(result.leftInInbox)
        XCTAssertEqual(result.kept, [])
        XCTAssertEqual(FileDrop.finishedArrivals(in: inbox), [], "not retried in a loop")
        // An unrelated half-received upload is removed at the VM's stop; the failed one stays.
        try FileManager.default.createDirectory(at: inbox.appendingPathComponent("z9"), withIntermediateDirectories: true)
        FileDrop.clear(bundle)
        XCTAssertEqual(try String(contentsOf: inbox.appendingPathComponent("y3/c.txt"), encoding: .utf8), "C")
        XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("y3.failed").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("z9").path))
    }

    func testListedButMissingFilesAreNotFailures() throws {
        let inbox = root.appendingPathComponent("inbox-r05d"), downloads = root.appendingPathComponent("Downloads-r05d")
        let arrival = try makeArrival(inbox, id: "y4", files: ["here.txt": "H"])
        let result = FileDrop.deliver(FileDrop.Arrival(id: arrival.id, names: ["here.txt", "never-sent.txt"]), from: inbox, to: downloads)
        XCTAssertTrue(result.complete)
        XCTAssertEqual(result.delivered.map(\.lastPathComponent), ["here.txt"])
    }

    func testDragOutUploadsAreNotDeliveredToDownloads() throws {
        let inbox = root.appendingPathComponent("inbox-dragout")
        try FileManager.default.createDirectory(at: inbox.appendingPathComponent("dragout-1"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: inbox.appendingPathComponent("dragout-1/a.txt"))
        try Data("a.txt\n".utf8).write(to: inbox.appendingPathComponent("dragout-1.done"))
        XCTAssertEqual(FileDrop.finishedArrivals(in: inbox), [], "a drag out belongs to the drop that asked for it")
    }

    func testHiddenTransferSharesAreServedButNotListed() throws {
        let drops = root.appendingPathComponent("drops/d1")
        try FileManager.default.createDirectory(at: drops, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: drops.appendingPathComponent("f.txt"))
        let service = SharedFolderService()
        let config = VMConfig(name: "w", guestOS: .windows11arm)
        try service.start(config: config, policy: SharingPolicy(profile: .default))
        defer { service.stop() }
        XCTAssertTrue(service.setTransferShares([WebDAVServer.Share(name: FileDrop.dropShare, root: root.appendingPathComponent("drops"), readOnly: true)]))
        XCTAssertEqual(service.announcedNames, [], "the guest is not told about the hidden share")
        // The server insists on the guest's address as Host; speak HTTP by hand.
        func request(_ text: String) throws -> String {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(fd) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(UInt16(service.port).bigEndian)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            XCTAssertEqual(connected, 0)
            _ = text.withCString { send(fd, $0, strlen($0), 0) }
            var buffer = [UInt8](repeating: 0, count: 65536)
            var data = Data()
            while true {
                let n = recv(fd, &buffer, buffer.count, 0)
                if n <= 0 { break }
                data.append(contentsOf: buffer[0..<n])
                if let s = String(data: data, encoding: .utf8), s.contains("\r\n\r\n"), s.hasSuffix("payload") || s.contains("</D:multistatus>") || s.contains("Content-Length: 0") { break }
            }
            return String(decoding: data, as: UTF8.self)
        }
        let got = try request("GET /TandemDrop/d1/f.txt HTTP/1.1\r\nHost: 10.0.2.2:\(service.port)\r\nConnection: close\r\n\r\n")
        XCTAssertTrue(got.hasPrefix("HTTP/1.1 200"), got)
        XCTAssertTrue(got.hasSuffix("payload"))
        let listing = try request("PROPFIND / HTTP/1.1\r\nHost: 10.0.2.2:\(service.port)\r\nDepth: 1\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        XCTAssertFalse(listing.contains("TandemDrop"), "a mapped drive must not show the hidden share")
        let put = try request("PUT /TandemDrop/d1/x.txt HTTP/1.1\r\nHost: 10.0.2.2:\(service.port)\r\nContent-Length: 1\r\nConnection: close\r\n\r\nx")
        XCTAssertTrue(put.hasPrefix("HTTP/1.1 403"), "the drop share is read-only for the guest: \(put)")
        // Revoked: the share is gone at once.
        service.setTransferShares([])
        let gone = try request("GET /TandemDrop/d1/f.txt HTTP/1.1\r\nHost: 10.0.2.2:\(service.port)\r\nConnection: close\r\n\r\n")
        XCTAssertFalse(gone.hasPrefix("HTTP/1.1 200"), gone)
    }
}
