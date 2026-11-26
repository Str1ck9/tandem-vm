import XCTest
@testable import EngineQEMU
import VMCore

/// Network changes on a running VM: the plan, the applier against a recording stand-in for QEMU, and
/// the real QEMU (a paused throwaway machine) when it is installed.
final class NetworkLiveTests: XCTestCase {
    private func net(_ mode: NetworkMode = .nat, forwards: [(Int, Int)] = [], cable: Bool? = nil, interface: String? = nil, mac: String = "02:00:00:00:00:01") -> NetworkConfig {
        var n = NetworkConfig(mode: mode, mac: mac, portForwards: forwards.map { PortForward(hostPort: $0.0, guestPort: $0.1) })
        n.cableConnected = cable; n.bridgedInterface = interface
        return n
    }

    // MARK: Plan

    func testNothingChangedPlansNothing() {
        XCTAssertTrue(QEMUNetworkLive.plan(from: net(forwards: [(2222, 22)]), to: net(forwards: [(2222, 22)]), canSwapBackend: true).isEmpty)
    }

    func testForwardsAreAddedAndRemovedOneByOne() {
        let plan = QEMUNetworkLive.plan(from: net(forwards: [(2222, 22), (8080, 80)]), to: net(forwards: [(2222, 22), (3389, 3389)]), canSwapBackend: true)
        XCTAssertEqual(plan.steps, [.hostForwardRemove("tcp:127.0.0.1:8080"), .hostForwardAdd("tcp:127.0.0.1:3389-:3389")])
        XCTAssertEqual(plan.applied, ["Port forwards are updated."])
        // The same Mac port to another guest port is a removal and an addition.
        let moved = QEMUNetworkLive.plan(from: net(forwards: [(2222, 22)]), to: net(forwards: [(2222, 2200)]), canSwapBackend: true)
        XCTAssertEqual(moved.steps, [.hostForwardRemove("tcp:127.0.0.1:2222"), .hostForwardAdd("tcp:127.0.0.1:2222-:2200")])
    }

    func testTheCableIsALiveChange() {
        let plan = QEMUNetworkLive.plan(from: net(), to: net(cable: false), canSwapBackend: true)
        XCTAssertEqual(plan.steps, [.setCable(false)])
        XCTAssertEqual(QEMUNetworkLive.plan(from: net(cable: false), to: net(cable: nil), canSwapBackend: true).steps, [.setCable(true)])
    }

    func testChangingTheSourceSwapsTheBackendWhenNothingNeedsThePrivatePath() {
        let toBridge = QEMUNetworkLive.plan(from: net(), to: net(.bridged, interface: "en0"), canSwapBackend: true)
        XCTAssertEqual(toBridge.steps, [.replaceBackend])
        XCTAssertTrue(toBridge.atNextStart.isEmpty)
        // Another interface is a swap too; the same one is nothing.
        XCTAssertEqual(QEMUNetworkLive.plan(from: net(.bridged, interface: "en0"), to: net(.bridged, interface: "en1"), canSwapBackend: true).steps, [.replaceBackend])
        XCTAssertTrue(QEMUNetworkLive.plan(from: net(.bridged, interface: "en0"), to: net(.bridged, interface: "en0"), canSwapBackend: true).isEmpty)
        // Forwards go with the new shared backend; they are not also sent as separate steps.
        let back = QEMUNetworkLive.plan(from: net(.bridged, interface: "en0"), to: net(forwards: [(2222, 22)]), canSwapBackend: true)
        XCTAssertEqual(back.steps, [.replaceBackend])
    }

    func testShareFoldersKeepTheSourceUntilTheNextStart() {
        let plan = QEMUNetworkLive.plan(from: net(), to: net(.bridged), canSwapBackend: false)
        XCTAssertTrue(plan.steps.isEmpty)
        XCTAssertEqual(plan.atNextStart.count, 1)
        XCTAssertTrue(plan.atNextStart[0].contains("Mac folders"))
    }

    func testTheAddressAlwaysWaitsForTheNextStart() {
        let plan = QEMUNetworkLive.plan(from: net(), to: net(mac: "02:00:00:00:00:99"), canSwapBackend: true)
        XCTAssertTrue(plan.steps.isEmpty)
        XCTAssertTrue(plan.atNextStart[0].contains("MAC"))
    }

    // MARK: Applier against a recording monitor

    @MainActor
    private func applier(_ start: NetworkConfig, monitor: RecordingMonitor, bridges: [FakeBridge] = [], servicePort: Int? = nil,
                         bridge: FakeBridge? = nil) -> (NetworkLiveApplier, BridgeFactory) {
        let factory = BridgeFactory(bridges)
        let a = NetworkLiveApplier(monitor: monitor, current: start, bridge: bridge, localSocket: "/tmp/tandem-test-net.sock",
                                   hostServicePort: { servicePort }, serviceBackends: { [:] }, openBridge: { _ in try factory.next() })
        return (a, factory)
    }

    @MainActor
    func testForwardsAreSentToTheMonitorAndRemembered() async {
        let monitor = RecordingMonitor()
        let (a, _) = applier(net(forwards: [(2222, 22), (8080, 80)]), monitor: monitor)
        monitor.humanReplies = ["hostfwd_remove": "host forwarding rule for tcp:127.0.0.1:8080 removed\r\n", "hostfwd_add": ""]
        let result = await a.apply(net(forwards: [(2222, 22), (3389, 3389)]), policy: SharingPolicy(profile: .default))
        XCTAssertEqual(monitor.log, ["hmp hostfwd_remove net0 tcp:127.0.0.1:8080", "hmp hostfwd_add net0 tcp:127.0.0.1:3389-:3389"])
        XCTAssertTrue(result.isClean)
        XCTAssertEqual(result.applied, ["Port forwards are updated."])
        XCTAssertEqual(a.current.portForwards.map { "\($0.hostPort):\($0.guestPort)" }.sorted(), ["2222:22", "3389:3389"])
    }

    @MainActor
    func testAPortThatIsInUseIsReportedAndNotRemembered() async {
        let monitor = RecordingMonitor()
        let (a, _) = applier(net(), monitor: monitor)
        monitor.humanReplies = ["hostfwd_add": "Could not set up host forwarding rule 'tcp:127.0.0.1:22-:22'\r\n"]
        let result = await a.apply(net(forwards: [(22, 22)]), policy: SharingPolicy(profile: .default))
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.failures[0].contains("another program"))
        XCTAssertTrue(a.current.portForwards.isEmpty)
        XCTAssertFalse(result.applied.contains("Port forwards are updated."))
    }

    @MainActor
    func testTheCableGoesThroughTheAdapterPort() async {
        let monitor = RecordingMonitor()
        let (a, _) = applier(net(), monitor: monitor)
        _ = await a.apply(net(cable: false), policy: SharingPolicy(profile: .default))
        XCTAssertEqual(monitor.log, ["hmp set_link nic0 off"])
        XCTAssertFalse(a.current.cableIsConnected)
        _ = await a.apply(net(), policy: SharingPolicy(profile: .default))
        XCTAssertEqual(monitor.log.last, "hmp set_link nic0 on")
        XCTAssertTrue(a.current.cableIsConnected)
    }

    @MainActor
    func testMovingToTheBridgeSwapsTheBackendInTheHub() async {
        let monitor = RecordingMonitor()
        let bridge = FakeBridge(path: "/var/run/tandem-net-9.dgram")
        let (a, factory) = applier(net(forwards: [(2222, 22)]), monitor: monitor, bridges: [bridge])
        var profile = SharingProfile.default
        profile.network.bridged = true
        let result = await a.apply(net(.bridged, interface: "en0"), policy: SharingPolicy(profile: profile))
        XCTAssertTrue(result.isClean, "\(result.failures)")
        XCTAssertEqual(factory.opened, 1)
        XCTAssertEqual(monitor.log.prefix(2), ["qmp netdev_del hub0be", "qmp netdev_del net0"])
        XCTAssertTrue(monitor.log[2].hasPrefix("qmp netdev_add dgram net0"))
        XCTAssertTrue(monitor.log[2].contains("/var/run/tandem-net-9.dgram"))
        XCTAssertEqual(monitor.log[3], "qmp netdev_add hubport hub0be")
        XCTAssertEqual(a.current.mode, .bridged)
        XCTAssertTrue(a.bridge === bridge)
        // And back: the bridge is given back to the helper, and the shared backend returns with the forwards.
        let back = await a.apply(net(forwards: [(2222, 22)]), policy: SharingPolicy(profile: profile))
        XCTAssertTrue(back.isClean, "\(back.failures)")
        XCTAssertTrue(bridge.closed)
        XCTAssertNil(a.bridge)
        XCTAssertEqual(a.current.mode, .nat)
        XCTAssertTrue(monitor.log.contains { $0.hasPrefix("qmp netdev_add user net0") && $0.contains("hostfwd") })
    }

    @MainActor
    func testAFailedSwapFallsBackToTheSharedNetwork() async {
        let monitor = RecordingMonitor()
        monitor.failAdd = "dgram"
        let (a, _) = applier(net(), monitor: monitor, bridges: [FakeBridge(path: "/x")])
        var profile = SharingProfile.default
        profile.network.bridged = true
        let result = await a.apply(net(.bridged, interface: "en0"), policy: SharingPolicy(profile: profile))
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(a.current.mode, .nat, "the VM is not left without a network")
        XCTAssertTrue(monitor.log.contains { $0.hasPrefix("qmp netdev_add user net0") })
    }

    @MainActor
    func testNoBridgeIsOpenedIfTheHelperRefuses() async {
        let monitor = RecordingMonitor()
        let (a, _) = applier(net(), monitor: monitor, bridges: [])   // the factory has nothing: opening throws
        var profile = SharingProfile.default
        profile.network.bridged = true
        let result = await a.apply(net(.bridged), policy: SharingPolicy(profile: profile))
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(monitor.log.isEmpty, "nothing was taken out of the hub")
        XCTAssertEqual(a.current.mode, .nat)
    }

    @MainActor
    func testFoldersOnTheSharedNetworkKeepTheSwapForTheNextStart() async {
        let monitor = RecordingMonitor()
        let (a, factory) = applier(net(), monitor: monitor, bridges: [FakeBridge(path: "/x")], servicePort: 47001)
        var profile = SharingProfile.default
        profile.network.bridged = true
        let result = await a.apply(net(.bridged), policy: SharingPolicy(profile: profile))
        XCTAssertTrue(monitor.log.isEmpty)
        XCTAssertEqual(factory.opened, 0)
        XCTAssertEqual(result.atNextStart.count, 1)
        XCTAssertEqual(a.current.mode, .nat)
    }

    func testTheCommandLineHasTheHubAndTheAdapterOnItsPort() throws {
        let user = QEMUCommandBuilder.userNetdev(network: net(forwards: [(2222, 22)]), policy: SharingPolicy(profile: .default),
                                                 hostServicePort: nil, serviceBackends: [:])
        XCTAssertEqual(user.option, "user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22")
        XCTAssertEqual(QEMUCommandBuilder.hubAdapterPort, "nic0")
        XCTAssertEqual(QEMUCommandBuilder.hubBackendPort, "hub0be")
        XCTAssertEqual(QEMUCommandBuilder.bridgeNetdevOption(socket: "/a,b/net.sock", helperSocket: "/var/run/x"),
                       "dgram,id=net0,local.type=unix,local.path=/a,,b/net.sock,remote.type=unix,remote.path=/var/run/x")
    }

    // MARK: The real QEMU

    /// A paused machine with the same hub as a real VM's command line: forwards, the cable and the
    /// backend swap are answered by QEMU itself.
    @MainActor
    func testRealQEMUAcceptsTheWholeSequence() async throws {
        guard let toolchain = try? QEMUToolchain.locate() else { throw XCTSkip("QEMU is not installed") }
        let dir = "/tmp/tnl-\(getpid())-\(UInt16.random(in: 0...UInt16.max))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let qmpPath = dir + "/q.sock"
        let process = Process()
        process.executableURL = toolchain.qemu
        let user = QEMUCommandBuilder.userNetdev(network: net(forwards: [(40981, 22)]), policy: SharingPolicy(profile: .default), hostServicePort: nil, serviceBackends: [:])
        process.arguments = ["-machine", "virt,accel=hvf", "-cpu", "host", "-m", "128", "-nodefaults", "-display", "none", "-S",
                             "-qmp", "unix:\(qmpPath),server=on,wait=off", "-netdev", user.option,
                             "-netdev", "hubport,id=\(QEMUCommandBuilder.hubBackendPort),hubid=0,netdev=net0",
                             "-netdev", "hubport,id=\(QEMUCommandBuilder.hubAdapterPort),hubid=0",
                             "-device", "virtio-net-pci,netdev=\(QEMUCommandBuilder.hubAdapterPort),mac=02:00:00:00:00:01,romfile="]
        if let data = toolchain.dataDirectory { process.arguments! += ["-L", data.path] }
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw XCTSkip("QEMU did not start: \(error)") }
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        guard let qmp = try? await QMPClient.connect(path: qmpPath, timeout: 10) else { throw XCTSkip("no QEMU monitor (hardware virtualization may be unavailable here)") }
        defer { qmp.close() }

        let bridge = FakeBridge(path: dir + "/helper.sock")
        let start = net(forwards: [(40981, 22)])
        let a = NetworkLiveApplier(monitor: qmp, current: start, bridge: nil, localSocket: dir + "/net.sock",
                                   hostServicePort: { nil }, serviceBackends: { [:] }, openBridge: { _ in bridge })
        var profile = SharingProfile.default
        profile.network.bridged = true
        let policy = SharingPolicy(profile: profile)

        let forwards = await a.apply(net(forwards: [(40982, 80)]), policy: policy)
        XCTAssertTrue(forwards.isClean, "\(forwards.failures)")
        let cable = await a.apply(net(forwards: [(40982, 80)], cable: false), policy: policy)
        XCTAssertTrue(cable.isClean, "\(cable.failures)")
        let toBridge = await a.apply(net(.bridged, cable: false, interface: "en0"), policy: policy)
        XCTAssertTrue(toBridge.isClean, "\(toBridge.failures)")
        let info = try await qmp.humanCommand("info network")
        XCTAssertTrue(info.contains("type=dgram"), info)
        let back = await a.apply(net(forwards: [(40983, 443)], cable: false), policy: policy)
        XCTAssertTrue(back.isClean, "\(back.failures)")
        let usernet = try await qmp.humanCommand("info usernet")
        XCTAssertTrue(usernet.contains("40983"), usernet)
        XCTAssertFalse(usernet.contains("40982"), usernet)
        XCTAssertTrue(bridge.closed)
        try await qmp.execute("quit")
    }
}

// MARK: Stand-ins

final class FakeBridge: NetworkBridge, @unchecked Sendable {
    let helperSocketPath: String
    private(set) var closed = false
    init(path: String) { helperSocketPath = path }
    func close() { closed = true }
}

final class BridgeFactory: @unchecked Sendable {
    private var bridges: [FakeBridge]
    private(set) var opened = 0
    init(_ bridges: [FakeBridge]) { self.bridges = bridges }
    func next() throws -> NetworkBridge {
        guard !bridges.isEmpty else { throw VMError("The network helper is not installed.") }
        opened += 1
        return bridges.removeFirst()
    }
}

final class RecordingMonitor: NetworkMonitor, @unchecked Sendable {
    var log: [String] = []
    var humanReplies: [String: String] = [:]
    /// A netdev_add of this type is refused.
    var failAdd: String?

    func humanCommand(_ line: String) async throws -> String {
        log.append("hmp \(line)")
        let verb = line.split(separator: " ").first.map(String.init) ?? ""
        return humanReplies[verb] ?? ""
    }

    func command(_ name: String, _ arguments: [String: Any]?) async throws {
        var text = "qmp \(name)"
        if let arguments {
            if let id = arguments["id"] as? String, name == "netdev_del" { text += " \(id)" }
            if name == "netdev_add", let type = arguments["type"] as? String, let id = arguments["id"] as? String {
                text += " \(type) \(id)"
                if let remote = (arguments["remote"] as? [String: Any])?["path"] as? String { text += " remote=\(remote)" }
                if arguments["hostfwd"] != nil { text += " hostfwd" }
            }
        }
        log.append(text)
        if name == "netdev_add", let failAdd, arguments?["type"] as? String == failAdd { throw VMError("QEMU rejected the command.") }
    }
}
