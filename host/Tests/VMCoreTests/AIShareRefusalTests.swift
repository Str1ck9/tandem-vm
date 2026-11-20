import XCTest
@testable import VMCore

/// What an AI tool may share with a guest (security review 2026-11-16).
final class AIShareRefusalTests: XCTestCase {
    private var home: URL!
    private var library: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("ai-home-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        library = home.appendingPathComponent("Tandem Library")
        for folder in ["Documents/Project", "Library/Keychains", ".ssh", "Projects/app/.git", "Tandem Library/VMs"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("Innocent"), withDestinationURL: home.appendingPathComponent(".ssh"))
    }

    override func tearDown() { try? FileManager.default.removeItem(at: home) }

    private func refusal(_ relative: String) -> String? {
        SharingEdit.aiShareRefusal(path: home.appendingPathComponent(relative).path, home: home, libraryRoot: library)
    }

    func testOrdinaryFoldersInTheHomeFolderMayBeShared() {
        XCTAssertNil(refusal("Documents"))
        XCTAssertNil(refusal("Documents/Project"))
        XCTAssertNil(refusal("Projects/app"))
    }

    func testSecretsAndTheWholeHomeAreRefused() {
        XCTAssertNotNil(SharingEdit.aiShareRefusal(path: home.path, home: home, libraryRoot: library), "the whole home folder")
        XCTAssertNotNil(refusal("Library"))
        XCTAssertNotNil(refusal("Library/Keychains"))
        XCTAssertNotNil(refusal(".ssh"))
        XCTAssertNotNil(refusal("Projects/app/.git"))
        XCTAssertNotNil(refusal("Documents/../.ssh"), "dot-dot is resolved first")
        XCTAssertNotNil(refusal("Innocent"), "a link is followed to where it points")
    }

    func testTandemsLibraryIsRefusedSoAToolCannotRewriteItsOwnPermissions() {
        XCTAssertNotNil(refusal("Tandem Library"))
        XCTAssertNotNil(refusal("Tandem Library/VMs"))
    }

    func testSystemFoldersAreRefusedAndExternalDisksAllowed() {
        for path in ["/", "/etc", "/private/etc", "/Applications", "/Users", "/System/Library", "/Volumes"] {
            XCTAssertNotNil(SharingEdit.aiShareRefusal(path: path, home: home, libraryRoot: library), path)
        }
        XCTAssertNil(SharingEdit.aiShareRefusal(path: "/Volumes/USB Stick/Photos", home: home, libraryRoot: library))
        XCTAssertNotNil(SharingEdit.aiShareRefusal(path: "/Volumes/USB Stick/.Trashes", home: home, libraryRoot: library))
    }
}
