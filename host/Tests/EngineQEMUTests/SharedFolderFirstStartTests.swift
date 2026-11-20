import XCTest
import VMCore
@testable import EngineQEMU

/// A folder shared for good while a Linux VM is stopped (what `tandem share` does then) is saved in the
/// sharing profile and is on the QEMU command line from the very next start, the first one included.
final class SharedFolderFirstStartTests: XCTestCase {
    var root: URL!
    let toolchain = QEMUToolchain(qemu: URL(fileURLWithPath: "/x/bin/qemu-system-aarch64"), qemuImg: URL(fileURLWithPath: "/x/bin/qemu-img"),
                                  swtpm: URL(fileURLWithPath: "/x/bin/swtpm"), firmwareCode: URL(fileURLWithPath: "/x/share/code.fd"),
                                  firmwareVarsTemplate: URL(fileURLWithPath: "/x/share/vars.fd"), qemuVersion: "QEMU emulator version 11.1.3")
    let paths = QEMURunPaths(directory: URL(fileURLWithPath: "/tmp/tandem-test"))

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-share-first-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testFolderSharedBeforeTheFirstStartIsAttachedAtThatStart() throws {
        let made = try VMBundle.create(config: VMConfig(name: "fresh", guestOS: .linux, engine: .qemu), in: root, createDisks: false)
        var stored = try VMBundle.load(from: made.url)
        var profile = stored.config.sharing
        profile.folders.append(SharedFolder(hostPath: "/Users/me", name: "Home"))
        stored.config.sharing = profile
        try stored.save()

        // The engine is built from the bundle as it is on disk when the VM starts.
        let atStart = try VMBundle.load(from: made.url)
        let a = try QEMUCommandBuilder.arguments(bundle: atStart, toolchain: toolchain, paths: paths, display: .none)
        let pairs = Array(zip(a, a.dropFirst()))
        XCTAssertTrue(pairs.contains { $0.0 == "-fsdev" && $0.1.hasPrefix("local,id=share0,path=/Users/me,") })
        XCTAssertTrue(pairs.contains { $0.0 == "-device" && $0.1.contains("mount_tag=tandem0") })
    }
}
