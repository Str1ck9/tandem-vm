import XCTest
@testable import Sharing

final class WebDAVServerTests: XCTestCase {
    private var root: URL!
    private var server: WebDAVServer!
    private var base: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dav-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("rw/sub dir"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("ro"), withIntermediateDirectories: true)
        try Data("hello world".utf8).write(to: root.appendingPathComponent("rw/a&b.txt"))
        try Data("locked".utf8).write(to: root.appendingPathComponent("ro/keep.txt"))
        try Data("secret".utf8).write(to: root.appendingPathComponent("outside.txt"))
        server = WebDAVServer(shares: [.init(name: "Files", root: root.appendingPathComponent("rw")),
                                       .init(name: "Fixed", root: root.appendingPathComponent("ro"), readOnly: true)], requiredHost: nil)
        base = "http://127.0.0.1:\(try server.start())"
    }

    override func tearDown() {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private func call(_ method: String, _ path: String, headers: [String: String] = [:], body: Data? = nil) throws -> (Int, Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: base + path)!)
        request.httpMethod = method
        request.httpBody = body
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let done = expectation(description: method + path)
        var result: (Int, Data, HTTPURLResponse)?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse { result = (http.statusCode, data ?? Data(), http) }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return try XCTUnwrap(result)
    }

    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    func testOptionsAdvertisesClassTwo() throws {
        let (status, _, response) = try call("OPTIONS", "/")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(response.value(forHTTPHeaderField: "DAV"), "1, 2")
    }

    func testListing() throws {
        let (status, data, _) = try call("PROPFIND", "/", headers: ["Depth": "1"])
        XCTAssertEqual(status, 207)
        XCTAssertTrue(text(data).contains("<D:href>/Files/</D:href>"))
        XCTAssertTrue(text(data).contains("<D:href>/Fixed/</D:href>"))

        let (_, listing, _) = try call("PROPFIND", "/Files", headers: ["Depth": "1"])
        XCTAssertTrue(text(listing).contains("<D:href>/Files/a%26b.txt</D:href>"), text(listing))
        XCTAssertTrue(text(listing).contains("<D:displayname>a&amp;b.txt</D:displayname>"))
        XCTAssertTrue(text(listing).contains("<D:getcontentlength>11</D:getcontentlength>"))
        XCTAssertTrue(text(listing).contains("<D:href>/Files/sub%20dir/</D:href>"))
        XCTAssertNoThrow(try XMLDocument(data: listing), "the listing must be well-formed XML")

        let (_, single, _) = try call("PROPFIND", "/Files/", headers: ["Depth": "0"])
        XCTAssertFalse(text(single).contains("a%26b.txt"))
        XCTAssertEqual(try call("PROPFIND", "/Files/missing").0, 404)
        XCTAssertEqual(try call("PROPFIND", "/Nope/").0, 404)
    }

    func testReadWithRange() throws {
        XCTAssertEqual(text(try call("GET", "/Files/a%26b.txt").1), "hello world")
        let (status, data, response) = try call("GET", "/Files/a%26b.txt", headers: ["Range": "bytes=6-"])
        XCTAssertEqual(status, 206)
        XCTAssertEqual(text(data), "world")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Range"), "bytes 6-10/11")
        XCTAssertEqual(text(try call("GET", "/Files/a%26b.txt", headers: ["Range": "bytes=-5"]).1), "world")
        XCTAssertEqual(try call("GET", "/Files/a%26b.txt", headers: ["Range": "bytes=50-"]).0, 416)
    }

    func testWriteMoveCopyDelete() throws {
        let big = Data((0..<700_000).map { UInt8(truncatingIfNeeded: $0) })
        XCTAssertEqual(try call("PUT", "/Files/new.bin", body: big).0, 201)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("rw/new.bin")), big)
        XCTAssertEqual(try call("PUT", "/Files/new.bin", body: Data("v2".utf8)).0, 204)
        XCTAssertEqual(try call("PUT", "/Files/nodir/x", body: Data()).0, 409)
        XCTAssertEqual(try call("MKCOL", "/Files/made").0, 201)
        XCTAssertEqual(try call("MKCOL", "/Files/made").0, 405)
        XCTAssertEqual(try call("MOVE", "/Files/new.bin", headers: ["Destination": base + "/Files/made/moved%20file.bin"]).0, 201)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("rw/made/moved file.bin"), encoding: .utf8), "v2")
        XCTAssertEqual(try call("COPY", "/Files/made/moved%20file.bin", headers: ["Destination": "/Files/copy.bin"]).0, 201)
        XCTAssertEqual(try call("COPY", "/Files/made/moved%20file.bin", headers: ["Destination": "/Files/copy.bin", "Overwrite": "F"]).0, 412)
        XCTAssertEqual(try call("DELETE", "/Files/made").0, 204)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("rw/made").path))
        XCTAssertEqual(try call("DELETE", "/Files/made").0, 404)
        XCTAssertEqual(try call("DELETE", "/Files/").0, 403, "a share itself cannot be deleted")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("rw").path).filter { $0.hasPrefix(".tandem-upload") }
        XCTAssertEqual(leftovers, [])
    }

    func testLockCreatesEmptyFileAndProppatchSetsTime() throws {
        let (status, data, response) = try call("LOCK", "/Files/fresh.txt", body: Data("<lockinfo/>".utf8))
        XCTAssertEqual(status, 201)
        XCTAssertNotNil(response.value(forHTTPHeaderField: "Lock-Token"))
        XCTAssertTrue(text(data).contains("opaquelocktoken:"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("rw/fresh.txt").path))
        XCTAssertEqual(try call("LOCK", "/Files/fresh.txt").0, 200)
        XCTAssertEqual(try call("UNLOCK", "/Files/fresh.txt").0, 204)

        let patch = "<D:propertyupdate xmlns:D=\"DAV:\" xmlns:Z=\"urn:schemas-microsoft-com:\"><D:set><D:prop><Z:Win32LastModifiedTime>Mon, 02 Jan 2023 03:04:05 GMT</Z:Win32LastModifiedTime></D:prop></D:set></D:propertyupdate>"
        XCTAssertEqual(try call("PROPPATCH", "/Files/fresh.txt", body: Data(patch.utf8)).0, 207)
        let modified = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("rw/fresh.txt").path)[.modificationDate] as? Date
        XCTAssertEqual(modified?.timeIntervalSince1970, 1_672_628_645)

        // A guest whose clock zone is an hour east of what its wall clock really shows: its UTC runs an hour ahead.
        server.clockSkew = 3600
        XCTAssertEqual(try call("PROPPATCH", "/Files/fresh.txt", body: Data(patch.utf8)).0, 207)
        let shifted = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("rw/fresh.txt").path)[.modificationDate] as? Date
        XCTAssertEqual(shifted?.timeIntervalSince1970, 1_672_628_645 - 3600, "times from the guest are moved back to real UTC")
        let listing = text(try call("PROPFIND", "/Files/fresh.txt", headers: ["Depth": "0"]).1)
        XCTAssertTrue(listing.contains("<D:getlastmodified>Mon, 02 Jan 2023 03:04:05 GMT</D:getlastmodified>"), "and shown to the guest as it sent them")
        server.clockSkew = 0
    }

    func testReadOnlyShareRefusesChanges() throws {
        XCTAssertEqual(text(try call("GET", "/Fixed/keep.txt").1), "locked")
        XCTAssertEqual(try call("PUT", "/Fixed/new.txt", body: Data("x".utf8)).0, 403)
        XCTAssertEqual(try call("DELETE", "/Fixed/keep.txt").0, 403)
        XCTAssertEqual(try call("MKCOL", "/Fixed/d").0, 403)
        XCTAssertEqual(try call("LOCK", "/Fixed/new.txt").0, 403)
        XCTAssertEqual(try call("MOVE", "/Files/a%26b.txt", headers: ["Destination": "/Fixed/a.txt"]).0, 403)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("ro").path), ["keep.txt"])
    }

    func testCannotLeaveAShare() throws {
        XCTAssertNil(server.resolve("/Files/../outside.txt"))
        XCTAssertNil(server.resolve("/Files/%2e%2e/outside.txt"))
        XCTAssertNil(server.resolve("/Files/sub/..%2F..%2Foutside.txt"))
        XCTAssertNil(server.resolve("/outside.txt"))
        XCTAssertEqual(try call("GET", "/Files/%2e%2e/outside.txt").0, 404)
        XCTAssertEqual(try call("MOVE", "/Files/a%26b.txt", headers: ["Destination": "/Files/%2e%2e/stolen.txt"]).0, 400)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("rw/a&b.txt").path))
    }

    // MARK: R01: links out of a share

    private func makeLinks() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("elsewhere"), withIntermediateDirectories: true)
        try Data("far".utf8).write(to: root.appendingPathComponent("elsewhere/far.txt"))
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("rw/link-file").path, withDestinationPath: "../outside.txt")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("rw/link-dir").path, withDestinationPath: root.appendingPathComponent("elsewhere").path)
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("rw/dangling").path, withDestinationPath: root.appendingPathComponent("not-yet.txt").path)
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("rw/inner").path, withDestinationPath: "sub dir")
        try Data("in".utf8).write(to: root.appendingPathComponent("rw/sub dir/in.txt"))
    }

    func testLinksOutOfTheShareAreNotResolved() throws {
        try makeLinks()
        XCTAssertNil(server.resolve("/Files/link-file"))
        XCTAssertNil(server.resolve("/Files/link-dir"))
        XCTAssertNil(server.resolve("/Files/link-dir/far.txt"))
        XCTAssertNil(server.resolve("/Files/link-dir/new.txt"), "a new name below a link out")
        XCTAssertNil(server.resolve("/Files/%6Cink-dir/far.txt"), "percent-encoded")
        XCTAssertNil(server.resolve("/Files/LINK-DIR/far.txt"), "another letter case")
        XCTAssertNil(server.resolve("/Files/dangling"), "a link to nothing would create the file wherever it points")
        XCTAssertNotNil(server.resolve("/Files/inner/in.txt"), "a link that stays inside keeps working")
        XCTAssertNotNil(server.resolve("/Files/brand-new.txt"))
    }

    func testLinksOutOfTheShareCannotBeReadOrChanged() throws {
        try makeLinks()
        XCTAssertEqual(try call("GET", "/Files/link-file").0, 404)
        XCTAssertEqual(try call("GET", "/Files/link-dir/far.txt").0, 404)
        XCTAssertEqual(try call("PROPFIND", "/Files/link-dir", headers: ["Depth": "1"]).0, 404)
        XCTAssertEqual(try call("PUT", "/Files/link-dir/planted.txt", body: Data("x".utf8)).0, 404, "PUT under a linked parent")
        XCTAssertEqual(try call("PUT", "/Files/dangling", body: Data("x".utf8)).0, 404)
        XCTAssertEqual(try call("LOCK", "/Files/dangling").0, 404)
        XCTAssertEqual(try call("MKCOL", "/Files/link-dir/newdir").0, 404)
        XCTAssertEqual(try call("DELETE", "/Files/link-dir/far.txt").0, 404)
        XCTAssertEqual(try call("COPY", "/Files/link-file", headers: ["Destination": "/Files/stolen.txt"]).0, 404, "COPY source")
        XCTAssertEqual(try call("MOVE", "/Files/link-dir/far.txt", headers: ["Destination": "/Files/stolen.txt"]).0, 404, "MOVE source")
        XCTAssertEqual(try call("COPY", "/Files/a%26b.txt", headers: ["Destination": "/Files/link-dir/planted.txt"]).0, 400, "COPY destination")
        XCTAssertEqual(try call("MOVE", "/Files/a%26b.txt", headers: ["Destination": "/Files/link-file"]).0, 400, "MOVE destination")
        // Nothing outside changed, and nothing was created there.
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("outside.txt"), encoding: .utf8), "secret")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("elsewhere").path), ["far.txt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("not-yet.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("rw/a&b.txt").path))
        // The listing leaves out links that lead outside, and keeps the one that stays in.
        let listing = text(try call("PROPFIND", "/Files", headers: ["Depth": "1"]).1)
        XCTAssertFalse(listing.contains("link-file"), listing)
        XCTAssertFalse(listing.contains("link-dir"))
        XCTAssertFalse(listing.contains("dangling"))
        XCTAssertTrue(listing.contains("/Files/inner/"))
        XCTAssertEqual(text(try call("GET", "/Files/inner/in.txt").1), "in")
    }

    func testALinkSwappedInAfterACheckIsRefusedOnTheNextRequest() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("rw/swap"), withIntermediateDirectories: true)
        try Data("ok".utf8).write(to: root.appendingPathComponent("rw/swap/f.txt"))
        XCTAssertEqual(text(try call("GET", "/Files/swap/f.txt").1), "ok")
        try FileManager.default.removeItem(at: root.appendingPathComponent("rw/swap"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("rw/swap").path, withDestinationPath: root.appendingPathComponent("elsewhere").path)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("elsewhere"), withIntermediateDirectories: true)
        try Data("far".utf8).write(to: root.appendingPathComponent("elsewhere/f.txt"))
        XCTAssertEqual(try call("GET", "/Files/swap/f.txt").0, 404)
    }

    // MARK: R06: overwriting keeps the old destination until the new one is in place

    func testOverwritingCopyAndMoveReplaceFilesAndFolders() throws {
        try Data("old".utf8).write(to: root.appendingPathComponent("rw/target.txt"))
        XCTAssertEqual(try call("COPY", "/Files/a%26b.txt", headers: ["Destination": "/Files/target.txt"]).0, 204)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("rw/target.txt"), encoding: .utf8), "hello world")
        try Data("moving".utf8).write(to: root.appendingPathComponent("rw/m.txt"))
        XCTAssertEqual(try call("MOVE", "/Files/m.txt", headers: ["Destination": "/Files/target.txt"]).0, 204)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("rw/target.txt"), encoding: .utf8), "moving")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("rw/m.txt").path))
        // A folder over a folder: the result is the source folder, not a merge.
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("rw/d1"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("rw/d2"), withIntermediateDirectories: true)
        try Data("1".utf8).write(to: root.appendingPathComponent("rw/d1/one.txt"))
        try Data("2".utf8).write(to: root.appendingPathComponent("rw/d2/two.txt"))
        XCTAssertEqual(try call("COPY", "/Files/d1", headers: ["Destination": "/Files/d2"]).0, 204)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("rw/d2").path), ["one.txt"])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("rw/d1").path), ["one.txt"])
        let leftovers = try fm.contentsOfDirectory(atPath: root.appendingPathComponent("rw").path).filter { $0.hasPrefix(".tandem-upload") }
        XCTAssertEqual(leftovers, [])
    }

    /// Copy and move fail on demand, as when the disk fills up half way.
    private final class FailingFileManager: FileManager, @unchecked Sendable {
        var failCopy = false, failMove = false
        override func copyItem(at srcURL: URL, to dstURL: URL) throws {
            if failCopy {
                // Leave half a copy behind, as a real failure would.
                try Data("partial".utf8).write(to: dstURL)
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
            }
            try super.copyItem(at: srcURL, to: dstURL)
        }
        override func moveItem(at srcURL: URL, to dstURL: URL) throws {
            if failMove { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) }
            try super.moveItem(at: srcURL, to: dstURL)
        }
    }

    func testAFailedCopyLeavesTheOldDestination() throws {
        let fm = FailingFileManager()
        fm.failCopy = true
        let destination = root.appendingPathComponent("rw/dest.txt"), source = root.appendingPathComponent("rw/a&b.txt")
        try Data("precious".utf8).write(to: destination)
        XCTAssertThrowsError(try WebDAVServer.replace(destination, with: source, move: false, fileManager: fm)) { error in
            XCTAssertTrue(WebDAVServer.isOutOfSpace(error))
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "precious")
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "hello world")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("rw").path).filter { $0.hasPrefix(".tandem-upload") }
        XCTAssertEqual(leftovers, [], "the partial copy is removed")
    }

    func testCommitPutsTheOldDestinationBackWhenTheNewOneCannotGoIn() throws {
        let destination = root.appendingPathComponent("rw/dest.txt")
        try Data("precious".utf8).write(to: destination)
        // A staged item that is not there: the swap fails, the fallback moves the old one aside and back.
        let staged = root.appendingPathComponent("rw/.tandem-upload-missing")
        XCTAssertThrowsError(try WebDAVServer.commit(staged, over: destination))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "precious")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("rw").path).filter { $0.hasPrefix(".tandem-upload") }
        XCTAssertEqual(leftovers, [])
    }

    func testHostHeaderCheck() throws {
        let strict = WebDAVServer(shares: server.shares)
        let port = try strict.start()
        defer { strict.stop() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/Files/a%26b.txt")!)
        let done = expectation(description: "blocked")
        var status = 0
        URLSession.shared.dataTask(with: request) { _, response, _ in status = (response as? HTTPURLResponse)?.statusCode ?? 0; done.fulfill() }.resume()
        wait(for: [done], timeout: 10)
        XCTAssertEqual(status, 403, "a request addressed to a loopback name is refused")
        request.setValue("10.0.2.2:\(port)", forHTTPHeaderField: "Host")
        let allowed = expectation(description: "allowed")
        URLSession.shared.dataTask(with: request) { _, response, _ in status = (response as? HTTPURLResponse)?.statusCode ?? 0; allowed.fulfill() }.resume()
        wait(for: [allowed], timeout: 10)
        XCTAssertEqual(status, 200)
    }
}
