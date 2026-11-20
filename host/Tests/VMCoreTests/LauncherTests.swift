import XCTest
@testable import VMCore

final class LauncherTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-launcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testALauncherKnowsItsWayBackAndItsDocumentTypes() throws {
        let stub = root.appendingPathComponent("stub")
        try Data("#!/bin/sh\n".utf8).write(to: stub)
        let vm = UUID()
        let launcher = GuestAppBundle.Launcher(host: URL(fileURLWithPath: "/Applications/Tandem.app"), library: root,
                                               documentExtensions: [".TXT", "log", ".txt", ".we ird", ""])
        let bundle = try GuestAppBundle.write(in: root.appendingPathComponent("Apps"), name: "Notepad", vm: vm,
                                              program: "program:Microsoft.WindowsNotepad_8wekyb3d8bbwe!App", icon: nil, stub: stub, launcher: launcher)
        let info = try XCTUnwrap(NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) as? [String: Any])
        XCTAssertEqual(info[GuestAppBundle.launcherKey] as? Bool, true)
        XCTAssertEqual(info[GuestAppBundle.hostKey] as? String, "/Applications/Tandem.app")
        XCTAssertEqual(info[GuestAppBundle.libraryKey] as? String, root.path)
        let types = try XCTUnwrap(info["CFBundleDocumentTypes"] as? [[String: Any]])
        XCTAssertEqual(types.count, 1)
        XCTAssertEqual(types[0]["CFBundleTypeExtensions"] as? [String], ["txt", "log"], "no dots, no duplicates, nothing odd")
        XCTAssertEqual(types[0]["LSHandlerRank"] as? String, "Alternate", "a launcher never becomes a file type's default program")
        // A tile, by contrast, offers itself for nothing and names no host.
        let tile = try GuestAppBundle.write(in: root.appendingPathComponent("Tiles"), name: "Notepad", vm: vm, program: "app:notepad.exe", icon: nil, stub: stub)
        let tileInfo = try XCTUnwrap(NSDictionary(contentsOf: tile.appendingPathComponent("Contents/Info.plist")) as? [String: Any])
        XCTAssertNil(tileInfo["CFBundleDocumentTypes"])
        XCTAssertNil(tileInfo[GuestAppBundle.launcherKey])
    }

    func testALauncherWithoutKnownTypesTakesDroppedFilesButStaysOutOfOpenWith() throws {
        let stub = root.appendingPathComponent("stub")
        try Data("#!/bin/sh\n".utf8).write(to: stub)
        let bundle = try GuestAppBundle.write(in: root, name: "Tool", vm: UUID(), program: "program:tool", icon: nil, stub: stub,
                                              launcher: GuestAppBundle.Launcher(host: URL(fileURLWithPath: "/Applications/Tandem.app")))
        let info = try XCTUnwrap(NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) as? [String: Any])
        let types = try XCTUnwrap(info["CFBundleDocumentTypes"] as? [[String: Any]])
        XCTAssertEqual(types[0]["LSHandlerRank"] as? String, "None")
        XCTAssertEqual(types[0]["LSItemContentTypes"] as? [String], ["public.data"])
        XCTAssertNil(types[0]["CFBundleTypeExtensions"])
        XCTAssertNil(info[GuestAppBundle.libraryKey], "the default library is not named")
    }

    func testRequestsAreCollectedOnceOldestFirstAndStaleOnesDropped() throws {
        let vm = UUID()
        let old = GuestAppBundle.LaunchRequest(vm: vm, program: "program:a", name: "A", documents: [], created: Date().addingTimeInterval(-30))
        let new = GuestAppBundle.LaunchRequest(vm: vm, program: "program:b", name: "B", documents: ["/Users/x/a b.txt"], created: Date())
        let stale = GuestAppBundle.LaunchRequest(vm: vm, program: "program:c", name: "C", documents: [], created: Date().addingTimeInterval(-600))
        try GuestAppBundle.leave(new, root: root)
        try GuestAppBundle.leave(stale, root: root)
        try GuestAppBundle.leave(old, root: root)
        try Data("not json".utf8).write(to: GuestAppBundle.requestsDirectory(root: root).appendingPathComponent("junk.json"))
        let collected = GuestAppBundle.collect(root: root)
        XCTAssertEqual(collected.map(\.program), ["program:a", "program:b"])
        XCTAssertEqual(collected[1].documents, ["/Users/x/a b.txt"])
        XCTAssertEqual(GuestAppBundle.collect(root: root), [], "a request is carried out once")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: GuestAppBundle.requestsDirectory(root: root).path), [])
    }
}
