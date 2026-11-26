import XCTest
@testable import VMCore

/// The per-VM AI level (`AITier`): how it is stored, how old configurations read, how it combines with
/// "Commands from the Mac", and the baseline snapshot kept beside the snapshots.
final class AITierTests: XCTestCase {
    private func config() -> VMConfig { VMConfig(name: "vm", guestOS: .linux, engine: .qemu, cpuCount: 1, memoryMiB: 1024) }

    // MARK: The level itself

    func testTheLevelsAreOrdered() {
        XCTAssertLessThan(AITier.off, .observe)
        XCTAssertLessThan(AITier.observe, .operate)
        XCTAssertLessThan(AITier.operate, .full)
        XCTAssertEqual(AITier.allCases, [.off, .observe, .operate, .full])
        XCTAssertEqual(AITier.standard, .operate)
        for tier in AITier.allCases {
            XCTAssertFalse(tier.label.isEmpty)
            XCTAssertFalse(tier.summary.isEmpty)
        }
    }

    // MARK: Migration

    func testAnOldConfigurationGetsOperateAndNothingMore() throws {
        var old = config()
        old.sharingRules = SharingRules(commands: .macUserAndAI)
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: ConfigCoding.encoder().encode(old)) as? [String: Any])
        var rules = try XCTUnwrap(object["sharingRules"] as? [String: Any])
        rules["aiTier"] = nil
        object["sharingRules"] = rules
        let loaded = try ConfigCoding.decoder().decode(VMConfig.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(loaded.sharingRules?.aiTier, "nothing was written, so nothing is invented")
        XCTAssertEqual(loaded.sharing.aiTier, .operate, "AI tools keep what they had: not the destructive operations")
        XCTAssertEqual(loaded.sharing.commands, .macUserAndAI)
        XCTAssertNotEqual(loaded.sharing.aiTier, .full)
    }

    func testAConfigurationWithoutAnyRulesGetsTheStandardLevel() {
        XCTAssertEqual(config().sharing.aiTier, .standard)
        XCTAssertNil(config().sharingRules)
    }

    func testTheStandardLevelWritesNothingAndLeavesAnOldConfigurationAlone() {
        var c = config()
        let before = c
        c.sharing = c.sharing
        XCTAssertEqual(c, before)
        var profile = c.sharing
        profile.aiTier = .operate
        c.sharing = profile
        XCTAssertEqual(c, before, "operate is what an unset VM gets, so it is not stored")
    }

    func testAChosenLevelRoundTripsThroughTheConfigurationFile() throws {
        for tier in AITier.allCases {
            var c = config()
            var profile = c.sharing
            profile.aiTier = tier
            c.sharing = profile
            let loaded = try ConfigCoding.decoder().decode(VMConfig.self, from: ConfigCoding.encoder().encode(c))
            XCTAssertEqual(loaded.sharing.aiTier, tier)
        }
    }

    func testTheProfileFileDecodesWithoutALevel() throws {
        let json = #"{"folders":[],"clipboard":"both","network":{"outbound":true,"inbound":true,"bridged":true},"usb":true,"commands":"macUserAndAI"}"#
        let profile = try JSONDecoder().decode(SharingProfile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.aiTier, .operate)
        XCTAssertEqual(profile.commands, .macUserAndAI)
    }

    func testPresetsKeepTheirMeaning() {
        XCTAssertEqual(SharingProfile.default.preset, .default)
        XCTAssertEqual(SharingProfile.restricted.preset, .restricted)
        var other = SharingProfile.default
        other.aiTier = .observe
        XCTAssertNil(other.preset, "a changed level is a custom profile")
    }

    // MARK: With "Commands from the Mac"

    private func policy(commands: CommandAccess, tier: AITier) -> SharingPolicy {
        var profile = SharingProfile.default
        profile.commands = commands
        profile.aiTier = tier
        return SharingPolicy(profile: profile)
    }

    func testAnAIToolRunsCommandsOnlyWhenBothSettingsAllowIt() {
        for commands in CommandAccess.allCases {
            for tier in AITier.allCases {
                let allowed = commands == .macUserAndAI && tier >= .operate
                let result = Result { try policy(commands: commands, tier: tier).requireCommands(fromAI: true) }
                if allowed { XCTAssertNoThrow(try result.get(), "\(commands) at \(tier)") }
                else { XCTAssertThrowsError(try result.get(), "\(commands) at \(tier)") }
            }
        }
    }

    func testTheLevelNeverLimitsTheMacUsersOwnCommandLine() {
        for tier in AITier.allCases {
            XCTAssertNoThrow(try policy(commands: .macUser, tier: tier).requireCommands(fromAI: false))
            XCTAssertNoThrow(try policy(commands: .macUserAndAI, tier: tier).requireCommands(fromAI: false))
            XCTAssertThrowsError(try policy(commands: .off, tier: tier).requireCommands(fromAI: false))
        }
    }

    func testTheRefusalNamesTheLevel() {
        XCTAssertThrowsError(try policy(commands: .macUserAndAI, tier: .observe).requireCommands(fromAI: true)) { error in
            let message = (error as? VMError)?.message ?? ""
            XCTAssertTrue(message.contains("Observe"), message)
        }
    }

    // MARK: The baseline snapshot

    private func makeBundle() throws -> VMBundle {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aitier-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return try VMBundle.create(config: VMConfig(name: "Base", guestOS: .linux, cpuCount: 1, memoryMiB: 1024), in: dir)
    }

    func testABaselineIsMarkedAndTakenAway() throws {
        let bundle = try makeBundle()
        let store = SnapshotStore(bundle: bundle)
        XCTAssertNil(store.baseline(), "no baseline until someone marks one")
        let one = try store.create(name: "one", config: bundle.config)
        let two = try store.create(name: "two", config: bundle.config)
        try store.setBaseline(one.id)
        XCTAssertEqual(store.baseline(), one.id)
        try store.setBaseline(two.id)
        XCTAssertEqual(store.baseline(), two.id, "there is only one baseline")
        try store.setBaseline(nil)
        XCTAssertNil(store.baseline())
    }

    func testOnlyAnExistingSnapshotCanBeTheBaseline() throws {
        let bundle = try makeBundle()
        XCTAssertThrowsError(try SnapshotStore(bundle: bundle).setBaseline(UUID()))
        XCTAssertNil(SnapshotStore(bundle: bundle).baseline())
    }

    func testDeletingTheBaselineClearsIt() throws {
        let bundle = try makeBundle()
        let store = SnapshotStore(bundle: bundle)
        let one = try store.create(name: "one", config: bundle.config)
        let two = try store.create(name: "two", config: bundle.config)
        try store.setBaseline(one.id)
        try store.delete(two.id)
        XCTAssertEqual(store.baseline(), one.id, "deleting another snapshot leaves it")
        try store.delete(one.id)
        XCTAssertNil(store.baseline(), "a baseline that is gone is no baseline: nothing points at a missing snapshot")
    }

    func testAMarkPointingAtAMissingSnapshotReadsAsNone() throws {
        let bundle = try makeBundle()
        let store = SnapshotStore(bundle: bundle)
        let one = try store.create(name: "one", config: bundle.config)
        try store.setBaseline(one.id)
        try FileManager.default.removeItem(at: bundle.url.appendingPathComponent("snapshots/\(one.id.uuidString.lowercased())"))
        XCTAssertNil(store.baseline())
    }

    func testGoingBackToASnapshotKeepsTheBaseline() throws {
        let bundle = try makeBundle()
        let store = SnapshotStore(bundle: bundle)
        let one = try store.create(name: "one", config: bundle.config)
        try store.setBaseline(one.id)
        try store.revert(to: one.id)
        XCTAssertEqual(store.baseline(), one.id, "the mark belongs to the VM, not to a state of it")
    }

    func testGoingBackKeepsWhoMayUseTheVMAsItIsNow() throws {
        var bundle = try makeBundle()
        var profile = bundle.config.sharing
        profile.aiTier = .full
        profile.commands = .macUserAndAI
        bundle.config.sharing = profile
        try bundle.save()
        let snapshot = try SnapshotStore(bundle: bundle).create(name: "when it was open", config: bundle.config)
        // The person lowers the level afterwards, and later goes back to that snapshot.
        profile.aiTier = .observe
        profile.commands = .macUser
        bundle.config.sharing = profile
        try bundle.save()
        try SnapshotStore(bundle: bundle).revertKeepingAccess(to: snapshot.id)
        let after = try VMBundle.load(from: bundle.url).config.sharing
        XCTAssertEqual(after.aiTier, .observe, "going back to a snapshot must not raise what AI tools may do")
        XCTAssertEqual(after.commands, .macUser)
        // The plain revert restores everything the snapshot held, including the access settings.
        try SnapshotStore(bundle: bundle).revert(to: snapshot.id)
        XCTAssertEqual(try VMBundle.load(from: bundle.url).config.sharing.aiTier, .full)
    }

    func testGoingBackAlsoKeepsALowerLevelThanTheSnapshotHad() throws {
        var bundle = try makeBundle()
        let snapshot = try SnapshotStore(bundle: bundle).create(name: "standard", config: bundle.config)   // operate
        var profile = bundle.config.sharing
        profile.aiTier = .off
        bundle.config.sharing = profile
        try bundle.save()
        try SnapshotStore(bundle: bundle).revertKeepingAccess(to: snapshot.id)
        XCTAssertEqual(try VMBundle.load(from: bundle.url).config.sharing.aiTier, .off)
    }

    func testTheBaselineIsNotPartOfASnapshot() throws {
        let bundle = try makeBundle()
        let store = SnapshotStore(bundle: bundle)
        let one = try store.create(name: "one", config: bundle.config)
        try store.setBaseline(one.id)
        let two = try store.create(name: "two", config: bundle.config)
        let folder = bundle.url.appendingPathComponent("snapshots/\(two.id.uuidString.lowercased())")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("baseline.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("snapshots").path))
    }
}
