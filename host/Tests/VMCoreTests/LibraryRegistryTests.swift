import XCTest
@testable import VMCore

/// VMs in the library's own folders are listed without being registered; the registry only keeps
/// bundles stored elsewhere, and the app notices bundles that arrive in or leave its folders.
final class LibraryRegistryTests: XCTestCase {
    var root: URL!
    var library: VMLibrary!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-libreg-\(UUID().uuidString)")
        library = try VMLibrary(rootDirectory: root)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private var external: [String] {
        let data = (try? Data(contentsOf: root.appendingPathComponent("registry.json"))) ?? Data("{}".utf8)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return object["externalBundles"] as? [String] ?? []
    }

    private func writeRegistry(external paths: [String]) throws {
        let data = try JSONSerialization.data(withJSONObject: ["externalBundles": paths])
        try data.write(to: root.appendingPathComponent("registry.json"))
    }

    private func make(_ name: String, in folder: URL) throws -> VMBundle {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try VMBundle.create(config: VMConfig(name: name, guestOS: .linux, engine: .qemu), in: folder, createDisks: false)
    }

    func testBundleInTheVMsFolderIsNotRegistered() throws {
        let bundle = try make("inside", in: library.vmsDirectory)
        XCTAssertTrue(library.isInLibraryFolder(bundle.url))
        _ = try library.register(externalBundleAt: bundle.url)
        XCTAssertEqual(external, [], "a bundle the library lists anyway must not be written to the registry")
        XCTAssertEqual(library.list().bundles.map(\.config.name), ["inside"])
    }

    func testBundleReachedThroughALinkToTheVMsFolderIsInside() throws {
        let bundle = try make("linked", in: library.vmsDirectory)
        let link = root.appendingPathComponent("shortcut")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: library.vmsDirectory)
        XCTAssertTrue(library.isInLibraryFolder(link.appendingPathComponent(bundle.url.lastPathComponent)))
    }

    func testBundleElsewhereIsRegisteredOnce() throws {
        let bundle = try make("outside", in: root.appendingPathComponent("Elsewhere", isDirectory: true))
        XCTAssertFalse(library.isInLibraryFolder(bundle.url))
        _ = try library.register(externalBundleAt: bundle.url)
        _ = try library.register(externalBundleAt: bundle.url)
        XCTAssertEqual(external, [bundle.url.path])
        XCTAssertEqual(library.list().bundles.map(\.config.name), ["outside"])
    }

    func testPruneDropsEntriesInsideTheVMsFolderAndBundlesThatAreGone() throws {
        let inside = try make("inside", in: library.vmsDirectory)
        let elsewhere = root.appendingPathComponent("Elsewhere", isDirectory: true)
        let kept = try make("kept", in: elsewhere)
        let gone = elsewhere.appendingPathComponent("Gone-1234.tandemvm").path
        let unplugged = "/Volumes/TandemTestDiskThatIsNotThere-\(UUID().uuidString)/VMs/Away.tandemvm"
        // What an older build wrote: the VMs-folder bundle registered, plus stale and offline entries.
        try writeRegistry(external: [inside.url.path, kept.url.path, gone, unplugged])

        let dropped = library.pruneRegistry()
        XCTAssertEqual(Set(dropped), [inside.url.path, gone])
        XCTAssertEqual(external, [kept.url.path, unplugged], "a bundle on a disk that is not connected is remembered")
        XCTAssertEqual(library.list().bundles.map(\.config.name).sorted(), ["inside", "kept"], "each VM is listed once")
        XCTAssertEqual(library.pruneRegistry(), [], "nothing more to drop")
    }

    func testDeleteForgetsARegisteredBundle() throws {
        let bundle = try make("temp", in: root.appendingPathComponent("Elsewhere", isDirectory: true))
        _ = try library.register(externalBundleAt: bundle.url)
        try library.delete(bundle)
        XCTAssertEqual(external, [])
    }

    func testWatcherReportsABundleArrivingAndLeaving() throws {
        let queue = DispatchQueue(label: "watcher-arrive")
        let arrived = XCTestExpectation(description: "arrived")
        let watcher = LibraryWatcher(queue: queue, delay: 0.2) { arrived.fulfill() }
        watcher.watch(library.libraryFolders)
        defer { watcher.stop() }
        // What vmctl does: a new bundle folder appears in the VMs folder.
        let bundle = try make("made-elsewhere", in: library.vmsDirectory)
        wait(for: [arrived], timeout: 5)

        let left = XCTestExpectation(description: "left")
        let watcher2 = LibraryWatcher(queue: queue, delay: 0.2) { left.fulfill() }
        watcher2.watch(library.libraryFolders)
        defer { watcher2.stop() }
        try FileManager.default.removeItem(at: bundle.url)
        wait(for: [left], timeout: 5)
    }

    func testWatcherCoalescesABurstIntoOneReport() throws {
        let queue = DispatchQueue(label: "watcher-burst")
        let counter = Counter()
        let watcher = LibraryWatcher(queue: queue, delay: 0.5) { counter.add() }
        watcher.watch(library.libraryFolders)
        defer { watcher.stop() }
        for i in 0..<5 { _ = try make("burst\(i)", in: library.vmsDirectory) }
        Thread.sleep(forTimeInterval: 1.5)
        let seen = counter.value
        XCTAssertEqual(seen, 1, "several bundles written together are one reload")
    }

    func testWatcherIgnoresChangesInsideABundle() throws {
        var bundle = try make("quiet", in: library.vmsDirectory)
        let queue = DispatchQueue(label: "watcher-inside")
        let counter = Counter()
        let watcher = LibraryWatcher(queue: queue, delay: 0.2) { counter.add() }
        watcher.watch(library.libraryFolders)
        defer { watcher.stop() }
        try Data("x".utf8).write(to: bundle.url.appendingPathComponent("note.txt"))
        bundle.config.cpuCount = 3
        try bundle.save()
        Thread.sleep(forTimeInterval: 0.8)
        let seen = counter.value
        XCTAssertEqual(seen, 0, "a running VM writing its own files does not reload the library")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
