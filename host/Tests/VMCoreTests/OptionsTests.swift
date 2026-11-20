import XCTest
@testable import VMCore

final class VMOptionsTests: XCTestCase {
    private func roundTrip(_ config: VMConfig) throws -> VMConfig {
        try ConfigCoding.decoder().decode(VMConfig.self, from: try ConfigCoding.encoder().encode(config))
    }

    func testAConfigWrittenBeforeTheseSettingsLoadsWithDefaults() throws {
        // What an older Tandem wrote: no behavior, sound or boot keys.
        let old = #"{"id":"11111111-2222-3333-4444-555555555555","name":"old","guestOS":"linux","cpuCount":2,"memoryMiB":2048,"disks":[{"file":"disk0.img","sizeGiB":8,"bus":"virtio","format":"raw"}]}"#
        let config = try ConfigCoding.decoder().decode(VMConfig.self, from: Data(old.utf8))
        XCTAssertNil(config.behavior); XCTAssertNil(config.sound); XCTAssertNil(config.boot)
        XCTAssertEqual(config.behaviorOrDefault, VMBehavior())
        XCTAssertEqual(config.behaviorOrDefault.onQuit, .ask)
        XCTAssertEqual(config.behaviorOrDefault.onWindowClose, .keepRunning, "closing a window must not stop a VM unless asked to")
        XCTAssertEqual(config.soundOrDefault, SoundConfig(output: true, microphone: false))
        XCTAssertEqual(config.bootOrDefault.order, [.hardDisk, .cd])
        XCTAssertFalse(config.bootOrDefault.menu)
    }

    func testSettingsSurviveARoundTrip() throws {
        var config = VMConfig(name: "vm", guestOS: .windows11arm)
        var behavior = VMBehavior()
        behavior.autoStart = .withMac; behavior.startupView = .seamless; behavior.afterShutdown = .quitTandem
        behavior.onQuit = .suspend; behavior.onWindowClose = .shutDown; behavior.dockTiles = false
        behavior.commandKey = .macShortcuts; behavior.commandShortcutsToGuest = false; behavior.invertScrolling = true
        behavior.scaling = .actualSize; behavior.toolbarAlwaysVisibleInFullScreen = true
        config.behavior = behavior
        config.sound = SoundConfig(output: false, microphone: true)
        config.boot = BootConfig(order: [.network, .cd], menu: true)
        XCTAssertEqual(try roundTrip(config), config)
    }

    func testPartialBehaviorAndUnknownValuesAreTolerated() throws {
        // A later version may store fewer keys or new ones; missing ones take their defaults.
        let behavior = try JSONDecoder().decode(VMBehavior.self, from: Data(#"{"onQuit":"suspend","somethingNew":1}"#.utf8))
        XCTAssertEqual(behavior.onQuit, .suspend)
        XCTAssertEqual(behavior.commandKey, .windowsKey)
        XCTAssertTrue(behavior.commandShortcutsToGuest)
        let boot = try JSONDecoder().decode(BootConfig.self, from: Data(#"{"order":["cd","cd","hardDisk"]}"#.utf8))
        XCTAssertEqual(boot.order, [.cd, .hardDisk], "a device listed twice counts once")
    }

    func testOnlyBehaviorChangesMayBeSavedWhileRunning() {
        let original = VMConfig(name: "vm", guestOS: .linux, engine: .qemu)
        var draft = original
        XCTAssertFalse(draft.differsOnlyInBehavior(from: original), "no change at all")
        var behavior = VMBehavior(); behavior.invertScrolling = true
        draft.behavior = behavior
        XCTAssertTrue(draft.differsOnlyInBehavior(from: original))
        draft.sound = SoundConfig(output: false)
        XCTAssertFalse(draft.differsOnlyInBehavior(from: original), "the sound card is hardware")
        draft.sound = nil
        draft.memoryMiB += 1024
        XCTAssertFalse(draft.differsOnlyInBehavior(from: original))
    }
}
