import XCTest
@testable import VMCore

/// What a running VM may change about its network, as the configuration sheet decides it.
final class NetworkLiveConfigTests: XCTestCase {
    private func config() -> VMConfig {
        VMConfig(name: "t", guestOS: .linux, engine: .qemu)
    }

    func testNetworkChangesAloneAreAllowedWhileRunning() {
        let original = config()
        var edited = original
        edited.network.portForwards = [PortForward(hostPort: 2222, guestPort: 22)]
        edited.network.cableConnected = false
        XCTAssertTrue(edited.differsOnlyInBehaviorAndNetwork(from: original))
        XCTAssertFalse(edited.differsOnlyInBehavior(from: original))
    }

    func testHardwareChangesAreNotAllowedWhileRunning() {
        let original = config()
        var edited = original
        edited.memoryMiB += 1024
        edited.network.cableConnected = false
        XCTAssertFalse(edited.differsOnlyInBehaviorAndNetwork(from: original))
    }

    func testNothingChangedIsNotAChange() {
        let original = config()
        XCTAssertFalse(original.differsOnlyInBehaviorAndNetwork(from: original))
    }

    func testTheCableDefaultsToPluggedInAndOlderConfigsStillLoad() throws {
        XCTAssertTrue(NetworkConfig().cableIsConnected)
        var n = NetworkConfig()
        n.cableConnected = false
        XCTAssertFalse(n.cableIsConnected)
        // A configuration written before the cable existed has no such key.
        let data = try JSONEncoder().encode(NetworkConfig())
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "cableConnected")
        let back = try JSONDecoder().decode(NetworkConfig.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(back.cableIsConnected)
    }
}
