import CryptoKit
import XCTest
@testable import Provisioning
import VMCore

/// A stand-in web server: serves `StubServer.body`, honours `Range`, and can break off part-way.
final class StubServer: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()
    /// Stop after this many bytes of a response, with a network error (once; then it is cleared).
    nonisolated(unsafe) static var breakAfter: Int?
    /// Pause between pieces, so a test can cancel in the middle.
    nonisolated(unsafe) static var pieceDelay: TimeInterval = 0
    nonisolated(unsafe) static var honoursRanges = true
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var ranges: [String?] = []
    nonisolated(unsafe) static var userAgents: [String?] = []
    static let lock = NSLock()

    static func reset(_ body: Data) {
        lock.withLock { self.body = body; breakAfter = nil; pieceDelay = 0; honoursRanges = true; status = 200; ranges = []; userAgents = [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "stub.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private var stopped = false

    override func startLoading() {
        let range = request.value(forHTTPHeaderField: "Range")
        let (body, breakAfter, delay, honours, status) = Self.lock.withLock { () -> (Data, Int?, TimeInterval, Bool, Int) in
            Self.ranges.append(range)
            Self.userAgents.append(request.value(forHTTPHeaderField: "User-Agent"))
            let b = Self.breakAfter
            Self.breakAfter = nil
            return (Self.body, b, Self.pieceDelay, Self.honoursRanges, Self.status)
        }
        guard status == 200 else {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        var start = 0
        if honours, let range, range.hasPrefix("bytes="), let from = Int(range.dropFirst(6).dropLast()) { start = from }
        if start > body.count || (start == body.count && start > 0) {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 416, httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let slice = body.subdata(in: start..<body.count)
        let headers = ["Content-Length": String(slice.count), "Accept-Ranges": "bytes"]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: start > 0 ? 206 : 200, httpVersion: "HTTP/1.1", headerFields: headers)!,
                            cacheStoragePolicy: .notAllowed)
        if request.httpMethod == "HEAD" { client?.urlProtocolDidFinishLoading(self); return }
        DispatchQueue.global().async { [self] in
            var sent = 0
            let piece = 4096
            while sent < slice.count, !stopped {
                if let breakAfter, sent >= breakAfter {
                    // Let what was sent reach the client first, as bytes on a real connection would have.
                    Thread.sleep(forTimeInterval: 0.2)
                    client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                    return
                }
                let end = min(sent + piece, slice.count)
                client?.urlProtocol(self, didLoad: slice.subdata(in: sent..<end))
                sent = end
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            }
            if !stopped { client?.urlProtocolDidFinishLoading(self) }
        }
    }
    override func stopLoading() { stopped = true }
}

final class DownloaderTests: XCTestCase {
    private var cache: URL!
    private var downloader: Downloader!
    private let url = URL(string: "https://stub.test/files/system.img")!
    private let body = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    private var sha256: String { SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined() }

    override func setUp() {
        cache = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-dl-\(UUID().uuidString)")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        downloader = Downloader(cache: cache, configuration: configuration)
        // The stubbed transfers are tiny: they must not depend on how full this Mac's disk is.
        downloader.freeSpace = { _ in .max }
        StubServer.reset(body)
    }

    func testADownloadThatDoesNotFitIsRefusedBeforeItStarts() async throws {
        downloader.freeSpace = { _ in 1 << 30 }   // 1 GB free: less than the 2 GB kept spare
        let request = DownloadRequest(url: url, checksum: .sha256(sha256))
        do {
            _ = try await downloader.fetch(request) { _ in }
            XCTFail("there is not enough room")
        } catch {
            XCTAssertTrue("\(error)".contains("not enough free disk space"), "\(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloader.finalURL(request).path))
        downloader.freeSpace = { _ in nil }       // unknown: not checked
        _ = try await downloader.fetch(request) { _ in }
        XCTAssertTrue(downloader.isCached(request))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: cache) }

    func testDownloadsVerifiesAndReportsProgress() async throws {
        let seen = Box<[DownloadProgress]>([])
        let request = DownloadRequest(url: url, checksum: .sha256(sha256))
        let file = try await downloader.fetch(request) { p in seen.update { $0.append(p) } }
        XCTAssertEqual(try Data(contentsOf: file), body)
        XCTAssertEqual(file.lastPathComponent, "system.img")
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloader.partialURL(request).path))
        XCTAssertTrue(downloader.isCached(request))
        XCTAssertEqual(seen.value.last?.received, Int64(body.count))
        XCTAssertEqual(seen.value.last?.total, Int64(body.count))
        XCTAssertEqual(StubServer.userAgents.first ?? nil, Downloader.userAgent, "requests carry a generic client name and nothing else")
    }

    func testAVerifiedFileIsUsedAgainWithoutAskingTheServer() async throws {
        let request = DownloadRequest(url: url, checksum: .sha256(sha256))
        _ = try await downloader.fetch(request)
        let before = StubServer.ranges.count
        _ = try await downloader.fetch(request)
        XCTAssertEqual(StubServer.ranges.count, before)
    }

    func testAnInterruptedDownloadCarriesOnFromWhereItStopped() async throws {
        let request = DownloadRequest(url: url, checksum: .sha256(sha256))
        StubServer.breakAfter = 60_000
        do { _ = try await downloader.fetch(request); XCTFail("the first attempt should break off") }
        catch let error as VMError { XCTAssertTrue(error.message.contains("stopped"), error.message) }
        let partial = downloader.partialURL(request)
        let kept = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int)
        XCTAssertGreaterThan(kept, 0)
        XCTAssertLessThan(kept, body.count)

        let file = try await downloader.fetch(request)
        XCTAssertEqual(try Data(contentsOf: file), body)
        XCTAssertEqual(StubServer.ranges.last ?? nil, "bytes=\(kept)-", "the second request asks only for the rest")
    }

    func testAServerThatIgnoresRangesStartsOver() async throws {
        let request = DownloadRequest(url: url, checksum: .sha256(sha256))
        StubServer.breakAfter = 60_000
        _ = try? await downloader.fetch(request)
        StubServer.honoursRanges = false
        let file = try await downloader.fetch(request)
        XCTAssertEqual(try Data(contentsOf: file), body)
    }

    func testAStalePartialFileIsThrownAway() async throws {
        // A partial file longer than what the server has now: the server answers 416.
        let request = DownloadRequest(url: url, checksum: .sha256(sha256))
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(repeating: 1, count: body.count + 500).write(to: downloader.partialURL(request))
        let file = try await downloader.fetch(request)
        XCTAssertEqual(try Data(contentsOf: file), body)
    }

    func testAChecksumMismatchDeletesTheFile() async throws {
        let request = DownloadRequest(url: url, checksum: .sha256(String(repeating: "0", count: 64)))
        do { _ = try await downloader.fetch(request); XCTFail("a wrong checksum must fail") }
        catch let error as VMError { XCTAssertTrue(error.message.contains("damaged"), error.message) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloader.finalURL(request).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloader.partialURL(request).path))
        XCTAssertFalse(downloader.isCached(request))
    }

    func testCancellingKeepsThePartialFile() async throws {
        let request = DownloadRequest(url: url, checksum: .sha256(sha256))
        StubServer.pieceDelay = 0.01
        let downloader = self.downloader!
        let started = Box(false)
        let task = Task { try await downloader.fetch(request) { _ in started.update { $0 = true } } }
        for _ in 0..<200 where !started.value { try await Task.sleep(nanoseconds: 10_000_000) }
        task.cancel()
        do { _ = try await task.value; XCTFail("a cancelled download must not return a file") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloader.finalURL(request).path))
        let kept = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: downloader.partialURL(request).path)[.size] as? Int)
        XCTAssertGreaterThan(kept, 0)
        // And the next attempt finishes it.
        StubServer.pieceDelay = 0
        let finished = try await downloader.fetch(request)
        XCTAssertEqual(try Data(contentsOf: finished), body)
    }

    func testARefusedDownloadSaysSo() async throws {
        StubServer.status = 404
        do { _ = try await downloader.fetch(DownloadRequest(url: url)); XCTFail("404 must fail") }
        catch let error as VMError { XCTAssertTrue(error.detail?.contains("404") == true, "\(error)") }
        do { _ = try await downloader.text(url); XCTFail("404 must fail") } catch {}
    }

    func testEveryChecksumKind() throws {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let file = cache.appendingPathComponent("x")
        try Data("abc".utf8).write(to: file)
        XCTAssertTrue(try Checksum.sha1("A9993E364706816ABA3E25717850C26C9CD0D89D").matches(fileAt: file), "hex is compared without regard to case")
        XCTAssertTrue(try Checksum.sha256("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad").matches(fileAt: file))
        XCTAssertTrue(try Checksum.sha512("ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f").matches(fileAt: file))
        XCTAssertFalse(try Checksum.sha256(String(repeating: "0", count: 64)).matches(fileAt: file))
    }
}

/// A value shared between a test and a callback on another thread.
final class Box<T>: @unchecked Sendable {
    private var stored: T
    private let lock = NSLock()
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func update(_ change: (inout T) -> Void) { lock.withLock { change(&stored) } }
}

final class LinuxCloudImagesTests: XCTestCase {
    func testUbuntuListingGivesTheArm64ServerImage() throws {
        let sums = """
        1111111111111111111111111111111111111111111111111111111111111111 *ubuntu-24.04-server-cloudimg-amd64.img
        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa *ubuntu-24.04-server-cloudimg-arm64.img
        2222222222222222222222222222222222222222222222222222222222222222 *ubuntu-24.04-server-cloudimg-arm64.tar.gz
        """
        let image = try XCTUnwrap(LinuxCloudImages.ubuntu("24.04", sums: sums))
        XCTAssertEqual(image.option.id, "ubuntu-24.04")
        XCTAssertEqual(image.checksum, .sha256(String(repeating: "a", count: 64)))
        XCTAssertEqual(image.url.absoluteString, "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-arm64.img")
        XCTAssertNil(LinuxCloudImages.ubuntu("26.04", sums: sums), "a listing without the file offers nothing")
    }

    func testDebianListingTakesTheImageWithTheFullKernel() throws {
        let hex = String(repeating: "b", count: 128)
        let sums = "\(String(repeating: "c", count: 128))  debian-13-genericcloud-arm64.qcow2\n\(hex)  debian-13-generic-arm64.qcow2\n"
        let image = try XCTUnwrap(LinuxCloudImages.debian((name: "trixie", version: "13"), sums: sums))
        XCTAssertEqual(image.checksum, .sha512(hex))
        XCTAssertTrue(image.url.absoluteString.hasSuffix("/trixie/latest/debian-13-generic-arm64.qcow2"))
    }

    func testFedoraIndexGivesTheNewestFinishedRelease() throws {
        let sha = String(repeating: "d", count: 64)
        let index = """
        [{"version":"46 Beta","arch":"aarch64","link":"https://x/test/46_Beta/Fedora-Cloud-Base-Generic-46.aarch64.qcow2","variant":"Cloud","subvariant":"Cloud_Base","sha256":"\(sha)","size":"1"},
         {"version":"45","arch":"aarch64","link":"https://x/releases/45/Fedora-Cloud-Base-Generic-45-1.4.aarch64.qcow2","variant":"Cloud","subvariant":"Cloud_Base","sha256":"\(sha)","size":"596705280"},
         {"version":"45","arch":"aarch64","link":"https://x/releases/45/Fedora-Cloud-Base-UEFI-UKI-45-1.4.aarch64.qcow2","variant":"Cloud","subvariant":"Cloud_Base_UKI","sha256":"\(sha)","size":"2"},
         {"version":"45","arch":"x86_64","link":"https://x/releases/45/Fedora-Cloud-Base-Generic-45-1.4.x86_64.qcow2","variant":"Cloud","subvariant":"Cloud_Base","sha256":"\(sha)","size":"3"},
         {"version":"44","arch":"aarch64","link":"https://x/releases/44/Fedora-Cloud-Base-Generic-44-1.7.aarch64.qcow2","variant":"Cloud","subvariant":"Cloud_Base","sha256":"\(sha)","size":"4"},
         {"version":"45","arch":"aarch64","link":"https://x/releases/45/Fedora-Workstation-45.aarch64.iso","variant":"Workstation","subvariant":"Workstation"}]
        """
        let image = try XCTUnwrap(LinuxCloudImages.fedora(index: Data(index.utf8)))
        XCTAssertEqual(image.option.id, "fedora-45")
        XCTAssertEqual(image.option.downloadBytes, 596_705_280)
        XCTAssertTrue(image.url.absoluteString.contains("Generic-45-1.4.aarch64.qcow2"))
        XCTAssertNil(LinuxCloudImages.fedora(index: Data("not json".utf8)))
    }

    func testSeedCarriesTheAccountAndSurvivesAwkwardCharacters() throws {
        let text = LinuxSeed.userData(hostName: "my-vm", account: SystemAccount(userName: "tester", password: "p\"a: s#s\\w'rd"))
        XCTAssertTrue(text.hasPrefix("#cloud-config\n"))
        XCTAssertTrue(text.contains("hostname: \"my-vm\""))
        XCTAssertTrue(text.contains("name: \"tester\""))
        XCTAssertTrue(text.contains(#"plain_text_passwd: "p\"a: s#s\\w'rd""#), "the password is a quoted string, so YAML cannot misread it")
        XCTAssertTrue(text.contains("lock_passwd: false"))
        XCTAssertTrue(text.contains("TANDEM_TOOLS"), "first boot installs the guest tools from the tools disc")
        XCTAssertTrue(text.contains("cloud-init.disabled"), "cloud-init is switched off once first boot is done")
        XCTAssertFalse(text.contains("\t"))
        XCTAssertEqual(LinuxSeed.metaData(hostName: "my-vm", instance: "tandem-1"), "instance-id: tandem-1\nlocal-hostname: my-vm\n")
    }

    func testHostAndAccountNames() {
        XCTAssertEqual(LinuxSeed.hostName(from: "Ubuntu Server 24.04 LTS"), "ubuntu-server-24-04-lts")
        XCTAssertEqual(LinuxSeed.hostName(from: "Größe (test)"), "gr-e-test")
        XCTAssertEqual(LinuxSeed.hostName(from: "!!!"), "tandem-vm")
        XCTAssertTrue(LinuxSeed.problems(userName: "tester").isEmpty)
        XCTAssertFalse(LinuxSeed.problems(userName: "Jane Doe").isEmpty)
        XCTAssertFalse(LinuxSeed.problems(userName: "root").isEmpty)
        XCTAssertFalse(LinuxSeed.problems(userName: "").isEmpty)
    }

    func testCompletionRemovesTheSetupDisc() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-seed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try VMLibrary(rootDirectory: root)
        var bundle = try library.create(VMConfig(name: "seeded", guestOS: .linux, engine: .qemu, cpuCount: 1, memoryMiB: 1024))
        try Data("x".utf8).write(to: bundle.url.appendingPathComponent(LinuxSeed.fileName))
        bundle.config.removableMedia = [RemovableMedia(file: LinuxSeed.fileName, kind: .seedISO), RemovableMedia(file: "/other/seed.iso", kind: .seedISO)]
        bundle.config.install = InstallInfo(state: .installing, unattended: true, user: "tester")
        XCTAssertTrue(InstallProgress.markComplete(&bundle))
        XCTAssertEqual(bundle.config.removableMedia, [RemovableMedia(file: "/other/seed.iso", kind: .seedISO)], "only Tandem's own setup disc goes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.url.appendingPathComponent(LinuxSeed.fileName).path))
        XCTAssertFalse(InstallProgress.markComplete(&bundle), "only once")
    }

    func testMarkerRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-marker-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try VMLibrary(rootDirectory: root).create(VMConfig(name: "m", guestOS: .linux, engine: .qemu, cpuCount: 1, memoryMiB: 1024))
        XCTAssertNil(SystemCatalog.marker(in: bundle))
        let marker = SystemCatalog.Marker(slot: "linux", option: "debian-13", title: "Debian 13")
        try SystemCatalog.writeMarker(marker, in: bundle)
        XCTAssertEqual(SystemCatalog.marker(in: bundle), marker)
        SystemCatalog.clearMarker(in: bundle)
        XCTAssertNil(SystemCatalog.marker(in: bundle))
        XCTAssertNotNil(SystemCatalog.provider(for: SystemCatalog.linux))
    }
}
