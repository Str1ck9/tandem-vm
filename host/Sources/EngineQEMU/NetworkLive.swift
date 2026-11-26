import Foundation
import NetHelperClient
import VMCore

/// What a change of network settings does to a VM that is running, decided apart from the VM so that it
/// can be tested. QEMU can change a few things live: the port forwards of the shared network, the virtual
/// cable, and (because the adapter and its backend meet in a hub, see `QEMUCommandBuilder`) the backend itself,
/// shared or bridged. The adapter's own address cannot change without a restart.
public struct NetworkLivePlan: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        /// `hostfwd_remove`: "tcp:127.0.0.1:2222".
        case hostForwardRemove(String)
        /// `hostfwd_add`: "tcp:127.0.0.1:2222-:22".
        case hostForwardAdd(String)
        /// The virtual cable: true plugs it in.
        case setCable(Bool)
        /// Swap the backend to what the new settings describe.
        case replaceBackend
    }

    public var steps: [Step] = []
    /// Plain words for what applies now.
    public var applied: [String] = []
    /// Plain words for what waits for the next start, and why.
    public var atNextStart: [String] = []

    public var isEmpty: Bool { steps.isEmpty && atNextStart.isEmpty }
}

public enum QEMUNetworkLive {
    /// `old` is what the running VM has, `new` what is wanted; both as the sharing policy lets them be.
    /// `canSwapBackend` is false while the VM's shared folders use the shared network's private path to the Mac:
    /// a bridged guest has none of it unless it was started with its second adapter.
    public static func plan(from old: NetworkConfig, to new: NetworkConfig, canSwapBackend: Bool) -> NetworkLivePlan {
        var plan = NetworkLivePlan()

        if old.mac.lowercased() != new.mac.lowercased() {
            plan.atNextStart.append("The network address (MAC) changes when the virtual machine starts again.")
        }

        let backendChanged = old.mode != new.mode || (new.mode == .bridged && old.bridgedInterface != new.bridgedInterface)
        if backendChanged {
            if canSwapBackend {
                plan.steps.append(.replaceBackend)
                plan.applied.append(new.mode == .bridged ? "The virtual machine moved to the bridged network." : "The virtual machine moved to the shared network.")
            } else {
                plan.atNextStart.append("The network source changes when the virtual machine starts again, because it shares Mac folders over the shared network.")
            }
        } else if new.mode == .nat {
            let oldKeys = Set(old.portForwards.map(key))
            let newKeys = Set(new.portForwards.map(key))
            for f in old.portForwards where !newKeys.contains(key(f)) { plan.steps.append(.hostForwardRemove("tcp:127.0.0.1:\(f.hostPort)")) }
            for f in new.portForwards where !oldKeys.contains(key(f)) { plan.steps.append(.hostForwardAdd("tcp:127.0.0.1:\(f.hostPort)-:\(f.guestPort)")) }
            if oldKeys != newKeys { plan.applied.append("Port forwards are updated.") }
        }

        if old.cableIsConnected != new.cableIsConnected {
            plan.steps.append(.setCable(new.cableIsConnected))
            plan.applied.append(new.cableIsConnected ? "The network cable is plugged in." : "The network cable is unplugged.")
        }
        return plan
    }

    private static func key(_ f: PortForward) -> String { "\(f.hostPort):\(f.guestPort)" }
}

public struct NetworkApplyResult: Equatable, Sendable {
    /// What took effect now, in plain words.
    public var applied: [String] = []
    /// What waits for the next start.
    public var atNextStart: [String] = []
    /// What was tried and did not work (for example a Mac port that is already in use).
    public var failures: [String] = []
    public var isClean: Bool { failures.isEmpty }
    public init(applied: [String] = [], atNextStart: [String] = [], failures: [String] = []) {
        self.applied = applied; self.atNextStart = atNextStart; self.failures = failures
    }
}

/// The QEMU monitor commands of a plan, behind a protocol so that a test can stand in for QEMU.
protocol NetworkMonitor: AnyObject {
    /// Runs a human-monitor command and returns what it printed.
    func humanCommand(_ line: String) async throws -> String
    func command(_ name: String, _ arguments: [String: Any]?) async throws
}

extension QMPClient: NetworkMonitor {
    func humanCommand(_ line: String) async throws -> String {
        let reply = try await execute("human-monitor-command", arguments: ["command-line": line])
        return (reply["value"] as? String) ?? ""
    }
    func command(_ name: String, _ arguments: [String: Any]?) async throws { try await execute(name, arguments: arguments) }
}

/// The helper's end of a bridge, as far as the applier needs it.
protocol NetworkBridge: AnyObject {
    var helperSocketPath: String { get }
    func close()
}
extension BridgeLease: NetworkBridge {}

/// Applies network settings to one running QEMU VM and remembers what the VM really has.
@MainActor
final class NetworkLiveApplier {
    /// What the running VM has now (the address it started with; the rest follows what was applied).
    private(set) var current: NetworkConfig
    private(set) var bridge: NetworkBridge?
    private let monitor: NetworkMonitor
    private let localSocket: String
    private let hostServicePort: () -> Int?
    private let serviceBackends: () -> [Int: Int]
    private let openBridge: (NetworkConfig) throws -> NetworkBridge

    init(monitor: NetworkMonitor, current: NetworkConfig, bridge: NetworkBridge?, localSocket: String,
         hostServicePort: @escaping () -> Int?, serviceBackends: @escaping () -> [Int: Int],
         openBridge: @escaping (NetworkConfig) throws -> NetworkBridge) {
        self.monitor = monitor; self.current = current; self.bridge = bridge; self.localSocket = localSocket
        self.hostServicePort = hostServicePort; self.serviceBackends = serviceBackends; self.openBridge = openBridge
    }

    /// Ends the bridge with the VM.
    func shutdown() { bridge?.close(); bridge = nil }

    func apply(_ requested: NetworkConfig, policy: SharingPolicy) async -> NetworkApplyResult {
        let new = policy.enforced(requested)
        let plan = QEMUNetworkLive.plan(from: current, to: new, canSwapBackend: (hostServicePort() ?? 0) <= 0)
        var result = NetworkApplyResult(applied: [], atNextStart: plan.atNextStart)
        var appliedNotes = Set<String>()
        for step in plan.steps {
            do {
                switch step {
                case .hostForwardRemove(let rule):
                    let text = try await monitor.humanCommand("hostfwd_remove net0 \(rule)")
                    guard text.contains("removed") else { result.failures.append("The port forward \(rule) was not open."); continue }
                    let port = Int(rule.split(separator: ":").last ?? "") ?? -1
                    current.portForwards.removeAll { $0.hostPort == port }
                    appliedNotes.insert("Port forwards are updated.")
                case .hostForwardAdd(let rule):
                    let text = try await monitor.humanCommand("hostfwd_add net0 \(rule)")
                    guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        result.failures.append("The Mac port in “\(rule)” could not be opened; another program is probably using it.")
                        continue
                    }
                    if let forward = Self.forward(from: rule) { current.portForwards.append(forward) }
                    appliedNotes.insert("Port forwards are updated.")
                case .setCable(let connected):
                    let text = try await monitor.humanCommand("set_link \(QEMUCommandBuilder.hubAdapterPort) \(connected ? "on" : "off")")
                    guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        result.failures.append("The network cable could not be changed: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
                        continue
                    }
                    current.cableConnected = connected ? nil : false
                    appliedNotes.insert(connected ? "The network cable is plugged in." : "The network cable is unplugged.")
                case .replaceBackend:
                    try await replaceBackend(with: new, policy: policy)
                    current.mode = new.mode
                    current.bridgedInterface = new.bridgedInterface
                    current.portForwards = new.mode == .nat ? new.portForwards : current.portForwards
                    appliedNotes.insert(new.mode == .bridged ? "The virtual machine moved to the bridged network." : "The virtual machine moved to the shared network.")
                }
            } catch {
                result.failures.append((error as? VMError)?.message ?? error.localizedDescription)
                // The settings that follow a failed swap are tried on top of the old backend.
            }
        }
        // In the order the plan gave them.
        result.applied = plan.applied.filter { appliedNotes.contains($0) }
        return result
    }

    /// "tcp:127.0.0.1:2222-:22" → host 2222, guest 22.
    private static func forward(from rule: String) -> PortForward? {
        let parts = rule.split(separator: "-")
        guard parts.count == 2, let host = Int(parts[0].split(separator: ":").last ?? ""), let guest = Int(parts[1].split(separator: ":").last ?? "") else { return nil }
        return PortForward(hostPort: host, guestPort: guest)
    }

    /// Takes the adapter's backend out of the hub and puts the one `new` describes in its place.
    private func replaceBackend(with new: NetworkConfig, policy: SharingPolicy) async throws {
        let old = current
        // Bridged: the helper's end first, so that nothing is touched if it cannot be had. A move between two
        // interfaces gives the old one back first, because both use this VM's socket.
        var newBridge: NetworkBridge?
        if new.mode == .bridged && old.mode != .bridged { newBridge = try openBridge(new) }

        do {
            try await monitor.command("netdev_del", ["id": QEMUCommandBuilder.hubBackendPort])
            try await monitor.command("netdev_del", ["id": "net0"])
        } catch {
            newBridge?.close()
            throw error
        }
        if old.mode == .bridged { bridge?.close(); bridge = nil }
        unlink(localSocket)

        do {
            if new.mode == .bridged && newBridge == nil { newBridge = try openBridge(new) }
            try await addBackend(new, bridge: newBridge, policy: policy)
        } catch {
            // The VM must not be left without a network: go back to the shared one.
            newBridge?.close()
            _ = try? await monitor.command("netdev_del", ["id": "net0"])
            let fallback = NetworkConfig(mode: .nat, mac: new.mac, portForwards: old.mode == .nat ? old.portForwards : [])
            if (try? await addBackend(fallback, bridge: nil, policy: policy)) != nil {
                current.mode = .nat; current.bridgedInterface = nil; current.portForwards = fallback.portForwards
            }
            throw error
        }
        bridge = newBridge
    }

    private func addBackend(_ network: NetworkConfig, bridge: NetworkBridge?, policy: SharingPolicy) async throws {
        switch network.mode {
        case .nat:
            let user = QEMUCommandBuilder.userNetdev(network: network, policy: policy, hostServicePort: hostServicePort(), serviceBackends: serviceBackends())
            var arguments: [String: Any] = ["type": "user", "id": "net0"]
            if user.restrict { arguments["restrict"] = true }
            if !user.hostForwards.isEmpty { arguments["hostfwd"] = user.hostForwards.map { ["str": $0] } }
            if !user.guestForwards.isEmpty { arguments["guestfwd"] = user.guestForwards.map { ["str": $0] } }
            try await monitor.command("netdev_add", arguments)
        case .bridged:
            guard let bridge else { throw VMError("Bridged networking needs the Tandem network helper.") }
            try await monitor.command("netdev_add", ["type": "dgram", "id": "net0",
                                                      "local": ["type": "unix", "path": localSocket],
                                                      "remote": ["type": "unix", "path": bridge.helperSocketPath]])
        }
        try await monitor.command("netdev_add", ["type": "hubport", "id": QEMUCommandBuilder.hubBackendPort, "hubid": 0, "netdev": "net0"])
    }
}

extension QEMUEngine {
    /// Applies new network settings to the running VM as far as QEMU allows, and says what has to wait.
    /// The settings are not saved here; the caller saves them (the bundle on disk is what a later start uses).
    public func applyNetwork(_ requested: NetworkConfig) async throws -> NetworkApplyResult {
        guard let applier = networkLive, lifecycle.state == .running || lifecycle.state == .paused else {
            throw VMError("The virtual machine is not running.")
        }
        return await applier.apply(requested, policy: SharingPolicy(bundle.config))
    }

    /// What the running VM has now, if it runs.
    public var liveNetwork: NetworkConfig? { networkLive?.current }
}
