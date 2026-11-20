import XCTest
@testable import VMCore

final class UninstallPlanTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("uninstall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    private func make(_ path: String, bytes: Int = 0) throws {
        let url = base.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    /// A library with caches, two VMs inside it, a chosen second VMs folder, and one VM elsewhere.
    private func inputs(test: Bool) throws -> UninstallPlan.Inputs {
        try make("lib/Downloads/win.iso", bytes: 100_000)
        try make("lib/Templates/t.tandemvm/config.json")
        try make("lib/qemu.old/bin/qemu")
        try make("lib/registry.json")
        try make("lib/VMs/A.tandemvm/config.json", bytes: 5000)
        try make("other/B.tandemvm/config.json")
        try make("away/C.tandemvm/config.json")
        try make("home/Library/Preferences/\(TandemIdentity.app).plist")
        try make("sys/Library/PrivilegedHelperTools/\(TandemIdentity.tool("qemu-nbd"))/qemu-nbd")
        try make("sys/Library/PrivilegedHelperTools/\(TandemIdentity.scriptHelper)")
        try make("sys/var/log/tandem-nethelper.log")
        try make("sys/var/run/tandem-net-disk-1")
        try make("app/Tandem.app/Contents/Info.plist")
        try FileManager.default.createSymbolicLink(at: base.appendingPathComponent("home/Tandem"), withDestinationURL: base.appendingPathComponent("lib/VMs"))
        return .init(libraryRoot: base.appendingPathComponent("lib"), vmsDirectory: base.appendingPathComponent("other"),
                     bundles: ["lib/VMs/A.tandemvm", "other/B.tandemvm", "away/C.tandemvm"].map { base.appendingPathComponent($0) },
                     isTestLibrary: test, home: base.appendingPathComponent("home"), bundleIdentifier: TandemIdentity.app,
                     app: base.appendingPathComponent("app/Tandem.app"), commandLineLink: nil, macAppsFolder: nil,
                     systemRoot: base.appendingPathComponent("sys"))
    }

    func testGroupsAndKeepsOutsideVMs() throws {
        let plan = UninstallPlan.make(try inputs(test: false))
        let caches = plan.items(in: .caches).map { URL(fileURLWithPath: $0.path).lastPathComponent }
        XCTAssertEqual(Set(caches), ["Downloads", "Templates", "qemu.old"])
        XCTAssertGreaterThanOrEqual(plan.size(of: .caches), 100_000)

        let library = plan.items(in: .library)
        let vms = library.filter(\.toTrash).map { URL(fileURLWithPath: $0.path).lastPathComponent }
        XCTAssertEqual(Set(vms), ["A.tandemvm", "B.tandemvm"], "VMs in the library folders go to the Trash")
        XCTAssertEqual(plan.keptVMs.map { URL(fileURLWithPath: $0).lastPathComponent }, ["C.tandemvm"], "a VM elsewhere is never removed")
        XCTAssertTrue(library.contains { $0.title == "Link to the VMs folder" })
        XCTAssertTrue(library.contains { $0.path.hasSuffix("registry.json") })

        let system = plan.items(in: .system)
        XCTAssertTrue(system.contains { $0.path == "launchd:system/\(TandemIdentity.helper)" })
        XCTAssertTrue(system.contains { $0.path.hasSuffix("var/log/tandem-nethelper.log") && $0.needsAdministrator })
        XCTAssertTrue(system.contains { $0.path.hasSuffix("var/run/tandem-net-disk-1") && $0.needsAdministrator })
        XCTAssertTrue(system.contains { $0.title == "Settings" && !$0.needsAdministrator })
        XCTAssertTrue(system.contains { $0.path.hasSuffix("PrivilegedHelperTools/\(TandemIdentity.tool("qemu-nbd"))") && $0.needsAdministrator })
        XCTAssertTrue(system.contains { $0.path.hasSuffix("PrivilegedHelperTools/\(TandemIdentity.scriptHelper)") && $0.needsAdministrator })
        XCTAssertTrue(system.contains { $0.path.hasSuffix("Tandem.app") && $0.toTrash })
    }

    func testTestLibraryLeavesTheMacAlone() throws {
        let plan = UninstallPlan.make(try inputs(test: true))
        XCTAssertTrue(plan.isTestLibrary)
        XCTAssertTrue(plan.items(in: .system).isEmpty)
        XCTAssertFalse(plan.items(in: .library).contains { $0.title == "Link to the VMs folder" })
        XCTAssertEqual(plan.items(in: .caches).count, 3)
    }

    func testEmptyLibrary() throws {
        try FileManager.default.createDirectory(at: base.appendingPathComponent("lib/VMs"), withIntermediateDirectories: true)
        let plan = UninstallPlan.make(.init(libraryRoot: base.appendingPathComponent("lib"), vmsDirectory: base.appendingPathComponent("lib/VMs"),
                                            bundles: [], isTestLibrary: true, home: base, bundleIdentifier: "x", app: nil,
                                            commandLineLink: nil, macAppsFolder: nil))
        XCTAssertTrue(plan.items.isEmpty)
        XCTAssertEqual(plan.vmsDirectories.count, 1)
    }
}
