import CryptoKit
import XCTest
@testable import Updater
import VMCore

final class AppVersionTests: XCTestCase {
    func v(_ s: String, _ b: Int = 0) -> AppVersion { AppVersion(s, build: b)! }

    func testParsing() {
        XCTAssertEqual(v("0.6.1").components, [0, 6, 1])
        XCTAssertEqual(v("v1.2").components, [1, 2])
        for bad in ["", "1..2", "1.2.x", "-1", "1.2.3.4.5", "1.2 beta", "１.２", "1234567890.1"] {
            XCTAssertNil(AppVersion(bad, build: 1), bad)
        }
        XCTAssertNil(AppVersion("1.0", build: -1))
    }

    func testOrdering() {
        XCTAssertLessThan(v("0.9.9"), v("0.10.0"))
        XCTAssertLessThan(v("0.6.1", 185), v("0.6.1", 190))
        XCTAssertLessThan(v("0.6.1", 999), v("0.6.2", 1))
        XCTAssertEqual(v("1.0", 5), v("1.0.0", 5))
        XCTAssertEqual(Set([v("1.0", 5), v("1.0.0", 5)]).count, 1)
        XCTAssertFalse(v("1.0", 5) < v("1.0.0", 5))
        XCTAssertEqual(v("0.6.1", 190).key, "0.6.1+190")
    }

    func testFromInfo() {
        XCTAssertEqual(AppVersion.of(info: ["CFBundleShortVersionString": "0.6.0", "CFBundleVersion": "182"]), v("0.6.0", 182))
        XCTAssertNil(AppVersion.of(info: [:]))
    }
}

/// A key, a release and a feed in a temporary folder, shared by the tests below.
class UpdateFixture: XCTestCase {
    var folder: URL!
    let key = Curve25519.Signing.PrivateKey()

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-updater-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    /// An archive with some bytes in it, and its signed release.
    func release(_ version: String, build: Int, bytes: Data = Data("archive".utf8), name: String? = nil,
                 notes: String? = "Notes", minimum: String? = "15.0", signedWith signer: Curve25519.Signing.PrivateKey? = nil) throws -> UpdateRelease {
        let file = folder.appendingPathComponent(name ?? "Tandem-\(version)-\(build).zip")
        try bytes.write(to: file)
        let digest = try UpdateSignature.digest(of: file)
        var r = UpdateRelease(version: version, build: build, minimumSystemVersion: minimum, notes: notes,
                              url: file.lastPathComponent, length: digest.length, sha256: digest.sha256, signature: "")
        r.signature = try UpdateSignature.sign(r, with: signer ?? key)
        return r
    }

    func writeFeed(_ releases: [UpdateRelease]) throws -> URL {
        let url = folder.appendingPathComponent("tandem-update.json")
        try UpdateFeed(releases: releases).encoded().write(to: url)
        return url
    }

    func client(_ feed: URL, current: String = "0.6.0", build: Int = 182) -> UpdateClient {
        UpdateClient(feedURL: feed, publicKey: key.publicKey, current: AppVersion(current, build: build)!)
    }
}

final class UpdateFeedTests: UpdateFixture {
    func testRoundTripAndOrder() throws {
        var feed = UpdateFeed(releases: [])
        feed.add(try release("0.6.1", build: 190))
        feed.add(try release("0.7.0", build: 200))
        feed.add(try release("0.6.2", build: 195))
        XCTAssertEqual(feed.releases.map(\.version), ["0.7.0", "0.6.2", "0.6.1"])
        feed.add(try release("0.7.0", build: 200, notes: "Replaced"))
        XCTAssertEqual(feed.releases.count, 3)
        XCTAssertEqual(feed.releases.first?.notes, "Replaced")
        XCTAssertEqual(try UpdateFeed.parse(feed.encoded()), feed)
    }

    func testRefusesWhatIsNotAFeed() {
        for text in ["<html>Sign in to GitHub</html>", "{}", #"{"format":"other","formatVersion":1,"releases":[]}"#, "[]"] {
            XCTAssertThrowsError(try UpdateFeed.parse(Data(text.utf8)), text)
        }
        let newer = #"{"format":"tandem-update-feed","formatVersion":2,"releases":[]}"#
        XCTAssertThrowsError(try UpdateFeed.parse(Data(newer.utf8))) { error in
            XCTAssertTrue((error as? VMError)?.message.contains("newer format") == true)
        }
        XCTAssertThrowsError(try UpdateFeed.parse(Data(count: 5 << 20)))
    }

    func testNewestSelection() throws {
        let current = AppVersion("0.6.0", build: 182)!
        let system = OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 0)
        var a = try release("0.6.1", build: 190)
        var b = try release("0.7.0", build: 200, minimum: "26.0")
        let c = try release("0.5.0", build: 100)
        XCTAssertEqual(UpdateFeed(releases: [a, b, c]).newest(after: current, system: system)?.version, "0.6.1", "0.7.0 needs macOS 26")
        XCTAssertEqual(UpdateFeed(releases: [a, b, c]).newest(after: current, system: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))?.version, "0.7.0")
        XCTAssertNil(UpdateFeed(releases: [a, b, c]).newest(after: current, system: system, skipping: [a.appVersion.key]))
        XCTAssertNil(UpdateFeed(releases: [c]).newest(after: current, system: system), "older is never offered")
        XCTAssertNil(UpdateFeed(releases: [try release("0.6.0", build: 182)]).newest(after: current, system: system), "the same build is not an update")
        // Malformed entries are passed over.
        a.version = "0.6.x"; b.sha256 = "zz"; b.minimumSystemVersion = nil
        XCTAssertNil(UpdateFeed(releases: [a, b]).newest(after: current, system: system))
        var huge = try release("0.8.0", build: 300); huge.length = UpdateRelease.maximumLength + 1
        XCTAssertNil(UpdateFeed(releases: [huge]).newest(after: current, system: system))
    }

    func testArchiveAddresses() throws {
        let feed = URL(string: "https://example.org/releases/latest/download/tandem-update.json")!
        var r = try release("0.6.1", build: 190, name: "Tandem-0.6.1.dmg")
        XCTAssertEqual(r.archiveURL(relativeTo: feed)?.absoluteString, "https://example.org/releases/latest/download/Tandem-0.6.1.dmg")
        XCTAssertEqual(r.archiveFileName, "Tandem-0.6.1.dmg")
        r.url = "https://cdn.example.org/x/Tandem.zip"
        XCTAssertEqual(r.archiveURL(relativeTo: feed)?.host, "cdn.example.org")
        XCTAssertEqual(r.archiveFileName, "Tandem.zip")
        r.url = "../../../etc/passwd"
        XCTAssertFalse(r.archiveFileName.contains("/"))
        XCTAssertEqual(r.archiveFileName, "passwd.dmg")
        r.url = ".."
        XCTAssertEqual(r.archiveFileName, "Tandem-0.6.1.dmg")
    }
}

final class UpdateSignatureTests: UpdateFixture {
    func testValidSignature() throws {
        let r = try release("0.6.1", build: 190)
        XCTAssertNoThrow(try UpdateSignature.verify(r, publicKey: key.publicKey))
    }

    func testAnyChangeBreaksTheSignature() throws {
        let r = try release("0.6.1", build: 190)
        var changes: [(String, UpdateRelease)] = []
        var x = r; x.version = "0.9.0"; changes.append(("version", x))
        x = r; x.build = 999; changes.append(("build", x))
        x = r; x.length += 1; changes.append(("length", x))
        x = r; x.sha256 = String(repeating: "0", count: 64); changes.append(("sha256", x))
        x = r; x.notes = "Something else"; changes.append(("notes", x))
        x = r; x.minimumSystemVersion = "1.0"; changes.append(("minimum", x))
        x = r; x.signature = "not base64"; changes.append(("garbage", x))
        x = r; x.signature = Data(count: 64).base64EncodedString(); changes.append(("zeros", x))
        for (what, changed) in changes {
            XCTAssertThrowsError(try UpdateSignature.verify(changed, publicKey: key.publicKey), what)
        }
        // The URL and date are not signed: what is fetched is checked against the signed digest instead.
        x = r; x.url = "elsewhere.dmg"; x.published = "2030-01-01"
        XCTAssertNoThrow(try UpdateSignature.verify(x, publicKey: key.publicKey))
    }

    func testOtherKeyIsRefused() throws {
        let r = try release("0.6.1", build: 190, signedWith: Curve25519.Signing.PrivateKey())
        XCTAssertThrowsError(try UpdateSignature.verify(r, publicKey: key.publicKey))
    }

    func testPublicKeyParsing() throws {
        let text = key.publicKey.rawRepresentation.base64EncodedString()
        XCTAssertEqual(try UpdateSignature.publicKey(base64: " \(text)\n").rawRepresentation, key.publicKey.rawRepresentation)
        XCTAssertThrowsError(try UpdateSignature.publicKey(base64: "AAAA"))
        XCTAssertThrowsError(try UpdateSignature.publicKey(base64: "%%%"))
    }

    func testKeyFiles() throws {
        let url = folder.appendingPathComponent("keys/update-signing.key")
        let made = try UpdateSignature.generateKey(at: url)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(try UpdateSignature.privateKey(at: url).rawRepresentation, made.rawRepresentation)
        XCTAssertThrowsError(try UpdateSignature.generateKey(at: url), "an existing key is never replaced")
        XCTAssertEqual(try UpdateSignature.privateKey(at: url).rawRepresentation, made.rawRepresentation)
        try Data("junk".utf8).write(to: url)
        XCTAssertThrowsError(try UpdateSignature.privateKey(at: url))
    }

    func testArchiveCheck() throws {
        let r = try release("0.6.1", build: 190, bytes: Data(repeating: 7, count: 10_000_000))
        let file = folder.appendingPathComponent(r.url)
        XCTAssertNoThrow(try UpdateSignature.check(archive: file, against: r))
        let handle = try FileHandle(forWritingTo: file)
        try handle.seek(toOffset: 5_000_000); handle.write(Data([8])); try handle.close()
        XCTAssertThrowsError(try UpdateSignature.check(archive: file, against: r))
        try Data(repeating: 7, count: 9_999_999).write(to: file)
        XCTAssertThrowsError(try UpdateSignature.check(archive: file, against: r))
    }
}

final class UpdateClientTests: UpdateFixture {
    func testFindsAndDownloadsTheNewest() async throws {
        let feed = try writeFeed([try release("0.6.1", build: 190), try release("0.7.0", build: 200), try release("0.5.0", build: 1)])
        let found = try await client(feed).check()
        XCTAssertEqual(found?.version, "0.7.0")
        let downloads = folder.appendingPathComponent("downloads")
        let archive = try await client(feed).download(found!, into: downloads)
        XCTAssertEqual(archive.lastPathComponent, "Tandem-0.7.0-200.zip")
        XCTAssertEqual(try Data(contentsOf: archive), Data("archive".utf8))
        // A second download uses the first.
        let again = try await client(feed).download(found!, into: downloads)
        XCTAssertEqual(again, archive)
    }

    func testUpToDate() async throws {
        let feed = try writeFeed([try release("0.6.0", build: 182), try release("0.5.0", build: 1)])
        let found = try await client(feed).check()
        XCTAssertNil(found)
    }

    func testBadNewestFallsBackToGoodOlder() async throws {
        let bad = try release("0.8.0", build: 300, signedWith: Curve25519.Signing.PrivateKey())
        let good = try release("0.6.1", build: 190)
        let found = try await client(try writeFeed([bad, good])).check()
        XCTAssertEqual(found?.version, "0.6.1")
    }

    func testOnlyBadSignatureIsAnError() async throws {
        let bad = try release("0.8.0", build: 300, signedWith: Curve25519.Signing.PrivateKey())
        do { _ = try await client(try writeFeed([bad])).check(); XCTFail("accepted a release signed with another key") }
        catch { XCTAssertTrue(error.userFacingText.contains("signature"), error.userFacingText) }
    }

    func testTamperedArchiveIsRefusedAndRemoved() async throws {
        let r = try release("0.7.0", build: 200)
        let feed = try writeFeed([r])
        try Data("archivf".utf8).write(to: folder.appendingPathComponent(r.url))
        let downloads = folder.appendingPathComponent("downloads")
        do { _ = try await client(feed).download(r, into: downloads); XCTFail("accepted a changed archive") }
        catch { XCTAssertTrue(error.userFacingText.contains("damaged"), error.userFacingText) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: downloads.path), [])
    }

    func testDowngradeIsRefused() async throws {
        let old = try release("0.5.0", build: 100)
        let feed = try writeFeed([old])
        do { _ = try await client(feed).download(old, into: folder.appendingPathComponent("d")); XCTFail("downloaded an older version") }
        catch { XCTAssertTrue(error.userFacingText.contains("not newer"), error.userFacingText) }
    }

    func testInsecureAddressIsRefused() async throws {
        var r = try release("0.7.0", build: 200)
        r.url = "http://example.org/Tandem.dmg"
        r.signature = try UpdateSignature.sign(r, with: key)
        let feed = URL(string: "https://example.org/tandem-update.json")!
        do { _ = try await client(feed).download(r, into: folder.appendingPathComponent("d")); XCTFail("used plain http") }
        catch { XCTAssertTrue(error.userFacingText.contains("secure"), error.userFacingText) }
    }

    func testMissingFeedSaysSo() async throws {
        do { _ = try await client(folder.appendingPathComponent("none.json")).check(); XCTFail() }
        catch { XCTAssertTrue(error.userFacingText.contains("could not be read"), error.userFacingText) }
        let notFound = UpdateClient.httpError(404, UpdateClient.defaultFeedURL)
        XCTAssertTrue(notFound.detail?.contains("private") == true)
    }
}

final class UpdateInstallerTests: UpdateFixture {
    /// A minimal app bundle: Info.plist and a copy of /usr/bin/true, signed ad hoc.
    func makeApp(at url: URL, version: String, build: Int, identifier: String = UpdateInstaller.bundleIdentifier) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version, "CFBundleVersion": "\(build)",
                                  "CFBundleExecutable": "Tandem", "CFBundlePackageType": "APPL"]
        info.write(to: url.appendingPathComponent("Contents/Info.plist"), atomically: true)
        try fm.copyItem(atPath: "/usr/bin/true", toPath: url.appendingPathComponent("Contents/MacOS/Tandem").path)
        _ = try ToolRun.checked(URL(fileURLWithPath: "/usr/bin/codesign"), ["--force", "--sign", "-", url.path], timeout: 60, failure: "codesign")
    }

    func testAdHocCopyCannotBeUpdated() throws {
        let apps = folder.appendingPathComponent("Applications")
        let installed = apps.appendingPathComponent("Tandem.app")
        try makeApp(at: installed, version: "0.6.0", build: 182)
        XCTAssertNil(try UpdateInstaller.teamIdentifier(of: installed))
        let r = try release("0.7.0", build: 200)
        XCTAssertThrowsError(try UpdateInstaller.stage(archive: folder.appendingPathComponent(r.url), release: r, replacing: installed)) { error in
            XCTAssertTrue(error.userFacingText.contains("not signed by a developer"), error.userFacingText)
        }
        // Nothing left behind next to the app.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: apps.path), ["Tandem.app"])
    }

    func testOlderReleaseIsNotStaged() throws {
        let installed = folder.appendingPathComponent("Applications/Tandem.app")
        try makeApp(at: installed, version: "0.6.0", build: 182)
        let r = try release("0.6.0", build: 100)
        XCTAssertThrowsError(try UpdateInstaller.stage(archive: folder.appendingPathComponent(r.url), release: r, replacing: installed)) { error in
            XCTAssertTrue(error.userFacingText.contains("not newer"), error.userFacingText)
        }
    }

    func testAdHocUpdateFailsTheTeamRequirement() throws {
        let app = folder.appendingPathComponent("New/Tandem.app")
        try makeApp(at: app, version: "0.7.0", build: 200)
        XCTAssertThrowsError(try UpdateInstaller.checkSignature(of: app, team: "ABCDE12345")) { error in
            XCTAssertTrue(error.userFacingText.contains("not signed by the developer"), error.userFacingText)
        }
        XCTAssertThrowsError(try UpdateInstaller.checkSignature(of: app, team: "x\" or true"))
        XCTAssertEqual(UpdateInstaller.requirement(team: "ABC"),
                       "anchor apple generic and identifier \"\(TandemIdentity.app)\" and certificate leaf[subject.OU] = \"ABC\"")
    }

    func testZipExtraction() throws {
        let app = folder.appendingPathComponent("src/Tandem.app")
        try makeApp(at: app, version: "0.7.0", build: 200)
        try makeApp(at: folder.appendingPathComponent("src/Other.app"), version: "1.0", build: 1, identifier: "org.example.other")
        let zip = folder.appendingPathComponent("Tandem.zip")
        _ = try ToolRun.checked(URL(fileURLWithPath: "/usr/bin/ditto"), ["-c", "-k", folder.appendingPathComponent("src").path, zip.path], timeout: 60, failure: "zip")
        let out = folder.appendingPathComponent("out/Tandem.app")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try UpdateInstaller.extract(zip, to: out)
        XCTAssertEqual(Bundle(url: out)?.bundleIdentifier, UpdateInstaller.bundleIdentifier)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.deletingLastPathComponent().appendingPathComponent(".unzipped").path))
    }

    func testSwapIsOneStepAndOldCopyGoes() throws {
        let fm = FileManager.default
        let apps = folder.appendingPathComponent("Applications")
        let installed = apps.appendingPathComponent("Tandem.app")
        try makeApp(at: installed, version: "0.6.0", build: 182)
        let stage = apps.appendingPathComponent(".Tandem-update-test")
        let new = stage.appendingPathComponent("Tandem.app")
        try makeApp(at: new, version: "0.7.0", build: 200)
        let staged = UpdateInstaller.Staged(app: new, target: installed, version: AppVersion("0.7.0", build: 200)!, team: "TEST", folder: stage)
        XCTAssertNil(try UpdateInstaller.install(staged, oldCopy: .delete))
        let info = NSDictionary(contentsOf: installed.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
        XCTAssertEqual(AppVersion.of(info: info), AppVersion("0.7.0", build: 200))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: apps.path), ["Tandem.app"])
    }

    func testInterruptedStagingIsCleanedUp() throws {
        let fm = FileManager.default
        let apps = folder.appendingPathComponent("Applications")
        try fm.createDirectory(at: apps.appendingPathComponent(".Tandem-update-1234/Tandem.app"), withIntermediateDirectories: true)
        try fm.createDirectory(at: apps.appendingPathComponent("Tandem.app"), withIntermediateDirectories: true)
        try fm.createDirectory(at: apps.appendingPathComponent(".Other"), withIntermediateDirectories: true)
        UpdateInstaller.removeLeftovers(nextTo: apps.appendingPathComponent("Tandem.app"))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: apps.path).sorted(), [".Other", "Tandem.app"])
    }
}
