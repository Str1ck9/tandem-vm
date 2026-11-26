import XCTest
@testable import Sharing
@testable import VMCore

/// Linux guests on QEMU: folders are devices, but drops and sends go through a server on the Mac.
final class TransferServerTests: XCTestCase {
    private func linux(_ engine: EngineKind) -> VMConfig {
        var config = VMConfig(name: "l", guestOS: .linux, engine: engine, cpuCount: 1, memoryMiB: 1024)
        config.sharedFolders = [SharedFolder(hostPath: NSTemporaryDirectory(), name: "Tmp")]
        return config
    }

    func testLinuxOnQEMUGetsAServerForTransfersOnly() throws {
        let folders = SharedFolderService()
        let config = linux(.qemu)
        try folders.start(config: config)
        defer { folders.stop() }
        XCTAssertEqual(folders.kind, "9p", "the folders themselves stay devices")
        XCTAssertNotEqual(folders.port, 0, "drops and sends need the server")
        XCTAssertEqual(folders.names, ["Tmp"])
        XCTAssertTrue(folders.setTransferShares([WebDAVServer.Share(name: FileDrop.dropShare, root: URL(fileURLWithPath: NSTemporaryDirectory()), readOnly: true)]))
        // A new folder is not served over the server: it waits for the restart, as devices do.
        var wider = config
        wider.sharedFolders.append(SharedFolder(hostPath: "/usr", name: "Usr"))
        let change = folders.apply(SharingPolicy(wider))
        XCTAssertNotNil(change.deferred)
        XCTAssertEqual(folders.names, ["Tmp"])
    }

    func testLinuxOnAppleSEngineHasNoServer() throws {
        let folders = SharedFolderService()
        try folders.start(config: linux(.vz))
        defer { folders.stop() }
        XCTAssertEqual(folders.port, 0)
        XCTAssertEqual(folders.kind, "virtiofs")
    }
}
