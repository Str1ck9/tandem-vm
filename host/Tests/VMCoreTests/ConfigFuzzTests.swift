import FuzzSupport
import XCTest
@testable import VMCore

/// A `.tandemvm` can come from anywhere (double-clicked in Finder, copied from a colleague), so its
/// `config.json` is input like any other: a damaged one must be refused or read, never crash the app.
final class ConfigFuzzTests: XCTestCase {
    private func samples() throws -> [Data] {
        var configs: [VMConfig] = []
        for os in [GuestOS.windows11arm, .linux, .macos] {
            var config = VMConfig(name: "Sample \(os.rawValue)", guestOS: os)
            config.sharedFolders = [SharedFolder(hostPath: "/Users/u/Documents", name: "Documents", readOnly: true)]
            config.sharingRules = SharingRules(clipboard: .macToGuest, network: .open, usb: false)
            config.power = PowerSettings(idleSuspendMinutes: 30, keepAwake: false)
            config.publishedServices = [PublishedService(name: "web", guestPort: 80, hostPort: 8080)]
            config.notes = "notes"
            configs.append(config)
        }
        return try configs.map { try ConfigCoding.encoder().encode($0) }
    }

    /// What the app does with a config it has just read: list it, check it, decide its sharing,
    /// work out its idle timer and names, and write it back.
    private func use(_ config: VMConfig, seed: UInt64) {
        _ = config.validate()
        let policy = SharingPolicy(config)
        _ = policy.folders
        _ = policy.allowsInboundServices
        _ = policy.enforced(config.network)
        _ = PublishedServices.hostName(forVMNamed: config.name)
        _ = PublishedServices.publishingAllowed(for: config)
        for service in config.publishedServices ?? [] {
            _ = PublishedServices.validate(name: service.name, guestPort: service.guestPort, hostPort: service.hostPort)
        }
        let now = Date()
        _ = IdlePolicy.evaluate(config.power ?? PowerSettings(),
                                IdlePolicy.Signals(now: now, runningSince: now.addingTimeInterval(-3600), guestReportAt: now,
                                                   guestIdleSeconds: config.cpuCount, guestCPUPercent: Double(config.memoryMiB)))
        XCTAssertNoThrow(try ConfigCoding.encoder().encode(config), "seed \(seed)")
    }

    func testMutatedConfigsAreReadOrRefused() throws {
        let documents = try samples()
        var read = 0
        Fuzz.cases(2500) { rng, seed in
            let data = Fuzz.mutatedJSONData(rng.pick(documents), using: &rng)
            guard let config = try? ConfigCoding.decoder().decode(VMConfig.self, from: data) else { return }
            read += 1
            use(config, seed: seed)
            // Written back and read again, it is the same configuration.
            if let again = try? ConfigCoding.decoder().decode(VMConfig.self, from: ConfigCoding.encoder().encode(config)) {
                XCTAssertEqual(again, config, "seed \(seed)")
            } else {
                XCTFail("seed \(seed): a config that was read could not be read back")
            }
        }
        XCTAssertGreaterThan(read, 300, "too few mutated configs decoded to exercise the code behind")
    }

    /// Regression (fuzzer): a guest reporting 1e300 % processor use trapped `Int(_:)` in the idle check.
    func testHugeProcessorShareDoesNotTrap() {
        let now = Date()
        let verdict = IdlePolicy.evaluate(PowerSettings(idleSuspendMinutes: Int.max),
                                          IdlePolicy.Signals(now: now, runningSince: now, guestReportAt: now, guestIdleSeconds: Int.max, guestCPUPercent: 1e300))
        XCTAssertFalse(verdict.heldAwakeBy.isEmpty)
        XCTAssertEqual(IdlePolicy.percent(1e300), 10_000)
        XCTAssertEqual(IdlePolicy.percent(-5), 0)
    }
}
