import XCTest
@testable import VMCore

final class SharingProfileTests: XCTestCase {
    private func config() -> VMConfig { VMConfig(name: "vm", guestOS: .linux, engine: .qemu, cpuCount: 1, memoryMiB: 1024) }

    // MARK: Old and new configurations

    func testAnOldConfigurationReadsAsEverythingAllowed() throws {
        // Written before sharing profiles: folders, no rules, no clipboard field.
        var old = config()
        old.sharedFolders = [SharedFolder(hostPath: "/Users/me/Work", name: "Work", readOnly: true)]
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: ConfigCoding.encoder().encode(old)) as? [String: Any])
        object["sharedClipboard"] = nil; object["sharingRules"] = nil
        let loaded = try ConfigCoding.decoder().decode(VMConfig.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(loaded.sharingRules)
        XCTAssertEqual(loaded.sharing, SharingProfile(folders: old.sharedFolders, clipboard: .both, network: .open, usb: true))
    }

    func testTheOldClipboardSwitchStillMeansOff() {
        var c = config()
        c.sharedClipboard = false
        XCTAssertEqual(c.sharing.clipboard, .off)
        // Even against newer rules: an older build that turned the clipboard off must be obeyed.
        c.sharingRules = SharingRules(clipboard: .both)
        XCTAssertEqual(c.sharing.clipboard, .off)
    }

    func testSettingAnUnchangedProfileLeavesAnOldConfigurationAlone() {
        var c = config()
        let before = c
        c.sharing = c.sharing
        XCTAssertEqual(c, before, "no new fields appear in a configuration nothing was asked of")
    }

    func testProfileRoundTripsThroughTheConfigurationFile() throws {
        var c = config()
        let profile = SharingProfile(folders: [SharedFolder(hostPath: "/tmp/a", name: "A"), SharedFolder(hostPath: "/tmp/b", name: "B", readOnly: true)],
                                     clipboard: .macToGuest, network: NetworkExposure(outbound: false, inbound: false, bridged: true), usb: false)
        c.sharing = profile
        XCTAssertEqual(c.sharedClipboard, true, "older builds read the clipboard as shared, which errs towards the user's choice of one direction")
        let loaded = try ConfigCoding.decoder().decode(VMConfig.self, from: ConfigCoding.encoder().encode(c))
        XCTAssertEqual(loaded.sharing, profile)
        c.sharing.clipboard = .off
        XCTAssertEqual(c.sharedClipboard, false)
    }

    func testRestrictedPreset() {
        let p = SharingProfile.restricted
        XCTAssertTrue(p.folders.isEmpty)
        XCTAssertEqual(p.clipboard, .off)
        XCTAssertFalse(p.usb)
        XCTAssertFalse(p.network.inbound)
        XCTAssertFalse(p.network.bridged)
        XCTAssertTrue(p.network.outbound, "a disposable VM keeps the Internet; turning it off is a separate switch")
        XCTAssertEqual(p.preset, .restricted)
        XCTAssertEqual(SharingProfile.default.preset, .default)
        var custom = SharingProfile.default; custom.usb = false
        XCTAssertNil(custom.preset)
    }

    // MARK: Policy

    func testTemporaryFoldersAddButNeverReplaceOrWiden() {
        var c = config()
        c.sharing.folders = [SharedFolder(hostPath: "/tmp/docs", name: "Docs", readOnly: true)]
        let grants = TemporaryGrants(folders: [
            SharedFolder(hostPath: "/tmp/extra", name: "Extra"),
            SharedFolder(hostPath: "/tmp/other", name: "docs"),            // same name as a profile folder
            SharedFolder(hostPath: "/tmp/docs/", name: "Writable copy"),   // same folder, asking for write access
        ])
        let policy = SharingPolicy(c, temporary: grants)
        XCTAssertEqual(policy.folders.map(\.name), ["Docs", "Extra"])
        XCTAssertEqual(policy.folders.map(\.temporary), [false, true])
        XCTAssertTrue(policy.folders[0].folder.readOnly)
    }

    func testAccessToAMacPathFollowsTheSharedFolders() {
        var c = config()
        c.sharing.folders = [SharedFolder(hostPath: "/Users/me", name: "Home", readOnly: true),
                             SharedFolder(hostPath: "/Users/me/Projects", name: "Projects")]
        let policy = SharingPolicy(c)
        let match = policy.share(containing: "/Users/me/Projects/app/main.swift")
        XCTAssertEqual(match?.folder.name, "Projects", "the deepest shared folder wins")
        XCTAssertEqual(match?.relativePath, "app/main.swift")
        XCTAssertEqual(policy.share(containing: "/Users/me/notes.txt")?.folder.name, "Home")
        XCTAssertNil(policy.share(containing: "/Users/meme/notes.txt"), "a name that merely starts the same is not inside the folder")
        XCTAssertNil(policy.share(containing: "/etc/passwd"))
        XCTAssertNoThrow(try policy.requireAccess(.read, toHostPath: "/Users/me/notes.txt"))
        XCTAssertThrowsError(try policy.requireAccess(.write, toHostPath: "/Users/me/notes.txt"))
        XCTAssertNoThrow(try policy.requireAccess(.write, toHostPath: "/Users/me/Projects/x"))
        XCTAssertThrowsError(try policy.requireAccess(.read, toHostPath: "/etc/passwd"))
    }

    func testTemporaryClipboardAndUSBReplaceTheProfileWhileTheyLast() {
        var c = config()
        c.sharing = .restricted
        XCTAssertEqual(SharingPolicy(c).clipboard, .off)
        XCTAssertThrowsError(try SharingPolicy(c).requireUSB())
        let granted = SharingPolicy(c, temporary: TemporaryGrants(clipboard: .macToGuest, usb: true))
        XCTAssertEqual(granted.clipboard, .macToGuest)
        XCTAssertNoThrow(try granted.requireUSB())
        // Revoked: the grant is gone, the profile is back.
        XCTAssertEqual(SharingPolicy(c, temporary: TemporaryGrants()).clipboard, .off)
    }

    func testNetworkIsCutDownNeverRefused() {
        var c = config()
        c.network.mode = .bridged
        c.network.bridgedInterface = "en0"
        c.network.portForwards = [PortForward(hostPort: 2222, guestPort: 22)]
        XCTAssertEqual(SharingPolicy(c).enforced(c.network), c.network, "the default profile changes nothing")
        c.sharing = .restricted
        let policy = SharingPolicy(c)
        let enforced = policy.enforced(c.network)
        XCTAssertEqual(enforced.mode, .nat)
        XCTAssertNil(enforced.bridgedInterface)
        XCTAssertTrue(enforced.portForwards.isEmpty)
        XCTAssertEqual(enforced.mac, c.network.mac)
        XCTAssertEqual(policy.networkNotes(for: c.network).count, 2)
        XCTAssertFalse(policy.allowsInboundServices)
        XCTAssertThrowsError(try policy.requireInboundServices())
    }

    func testPublishedServicesAskTheSharingPolicy() {
        var c = config()
        XCTAssertTrue(PublishedServices.publishingAllowed(for: c))
        c.sharing.network.inbound = false
        XCTAssertFalse(PublishedServices.publishingAllowed(for: c))
        XCTAssertThrowsError(try PublishedServices.publish(name: "web", guestPort: 80, hostPort: nil, scope: .mac, in: &c,
                                                           takenElsewhere: [], isFree: { _ in true }))
        XCTAssertTrue((c.publishedServices ?? []).isEmpty)
    }

    // MARK: The run file

    func testTemporaryGrantsLiveInTheRunFileAndNeverInTheConfiguration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sharing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundle = try VMBundle.create(config: config(), in: root)
        XCTAssertTrue(TemporarySharingFile.load(bundle).isEmpty)
        XCTAssertFalse(TemporarySharingFile.hasLiveOwner(bundle))
        TemporarySharingFile.claim(bundle)
        XCTAssertTrue(TemporarySharingFile.hasLiveOwner(bundle), "this test process is the owner")
        let grants = TemporaryGrants(folders: [SharedFolder(hostPath: "/tmp", name: "Tmp")], usb: true)
        try TemporarySharingFile.save(grants, bundle)
        XCTAssertEqual(TemporarySharingFile.load(bundle), grants)
        let configText = try String(contentsOf: bundle.url.appendingPathComponent("config.json"), encoding: .utf8)
        XCTAssertFalse(configText.contains("Tmp"))
        TemporarySharingFile.release(bundle)
        XCTAssertTrue(TemporarySharingFile.load(bundle).isEmpty)
        XCTAssertFalse(TemporarySharingFile.hasLiveOwner(bundle))
    }

    func testFolderNamesAreMadeSafeAndUnique() throws {
        XCTAssertEqual(SharingEdit.uniqueName("My: Files?", taken: []), "My- Files-")
        XCTAssertEqual(SharingEdit.uniqueName("Work", taken: ["work"]), "Work 2")
        XCTAssertThrowsError(try SharingEdit.folder(path: "/no/such/folder", name: nil, readOnly: false, taken: []))
        var folders = [SharedFolder(hostPath: "/tmp/a", name: "A"), SharedFolder(hostPath: "/tmp/b", name: "B")]
        XCTAssertEqual(SharingEdit.remove("a", from: &folders), 1)
        XCTAssertEqual(SharingEdit.remove("/tmp/b/", from: &folders), 1)
        XCTAssertTrue(folders.isEmpty)
    }
}
