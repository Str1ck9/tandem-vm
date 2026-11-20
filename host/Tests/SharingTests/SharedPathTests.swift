import XCTest
import VMCore
@testable import Sharing

final class SharedPathTests: XCTestCase {
    private func config(_ folders: [SharedFolder]) -> VMConfig {
        var config = VMConfig(name: "w", guestOS: .windows11arm, cpuCount: 2, memoryMiB: 4096)
        config.sharedFolders = folders
        return config
    }

    func testAFileInsideAShareIsNamedBelowIt() {
        let c = config([SharedFolder(hostPath: "/Users/x/Documents", name: "Documents")])
        XCTAssertEqual(SharedFolderService.sharedPath(for: "/Users/x/Documents/notes/a b.txt", in: c), "Documents/notes/a b.txt")
        XCTAssertEqual(SharedFolderService.sharedPath(for: "/Users/x/Documents/./notes/../c.txt", in: c), "Documents/c.txt")
    }

    func testFilesOutsideEveryShareAreNotShared() {
        let c = config([SharedFolder(hostPath: "/Users/x/Documents", name: "Documents")])
        XCTAssertNil(SharedFolderService.sharedPath(for: "/Users/x/Desktop/a.txt", in: c))
        XCTAssertNil(SharedFolderService.sharedPath(for: "/Users/x/Documents-private/a.txt", in: c), "a folder whose name merely starts the same")
        XCTAssertNil(SharedFolderService.sharedPath(for: "/Users/x/Documents/../Desktop/a.txt", in: c), "leaving the share by ..")
        XCTAssertNil(SharedFolderService.sharedPath(for: "/Users/x/Documents", in: c), "the share itself is not a document")
        XCTAssertNil(SharedFolderService.sharedPath(for: "/Users/x/Documents/a.txt", in: config([])))
    }

    func testTheDeepestShareWins() {
        let c = config([SharedFolder(hostPath: "/Users/x", name: "Home"), SharedFolder(hostPath: "/Users/x/Projects", name: "Projects")])
        XCTAssertEqual(SharedFolderService.sharedPath(for: "/Users/x/Projects/p/main.c", in: c), "Projects/p/main.c")
        XCTAssertEqual(SharedFolderService.sharedPath(for: "/Users/x/other.txt", in: c), "Home/other.txt")
    }

    func testASymbolicLinkOutOfTheShareIsNotShared() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-sharedpath-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared"), secret = root.appendingPathComponent("secret")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secret, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: secret.appendingPathComponent("a.txt"))
        try FileManager.default.createSymbolicLink(at: shared.appendingPathComponent("link"), withDestinationURL: secret)
        let c = config([SharedFolder(hostPath: shared.path, name: "shared")])
        XCTAssertNil(SharedFolderService.sharedPath(for: shared.appendingPathComponent("link/a.txt").path, in: c))
    }
}
