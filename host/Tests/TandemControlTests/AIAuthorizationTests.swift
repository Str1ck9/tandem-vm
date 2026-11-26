import XCTest
import VMCore
@testable import TandemControl

/// The per-VM AI level: which operation needs which level, enforced where the request arrives (not in the
/// MCP server), the baseline rule for reverting, the tool descriptions and the activity log.
final class AIAuthorizationTests: XCTestCase {
    private func request(_ op: ControlOp, client: ControlClient = .mcp, vm: String? = "VM", args: [String: JSON] = [:]) -> ControlRequest {
        ControlRequest(id: 1, client: client, op: op, vm: vm, args: args)
    }

    private func allowed(_ op: ControlOp, at tier: AITier, args: [String: JSON] = [:]) -> Bool {
        (try? AIAuthorization.authorize(request(op, args: args), vmName: "VM", tier: tier)) != nil
    }

    // MARK: The matrix

    /// Every operation, with the lowest level that allows it (nil: no level does).
    private static let lowest: [(ControlOp, [String: JSON], AITier?)] = [
        (.info, [:], .observe), (.ip, [:], .observe), (.snapshotList, [:], .observe), (.screenshot, [:], .observe),
        (.services, [:], .observe), (.programs, [:], .observe), (.sharing, [:], .observe),
        (.start, [:], .operate), (.resume, [:], .operate), (.suspend, [:], .operate), (.pause, [:], .operate),
        (.restart, [:], .operate), (.snapshotTake, [:], .operate), (.unshare, [:], .operate), (.keepAwake, [:], .operate),
        (.launch, [:], .operate), (.exec, [:], .operate),
        (.stop, [:], .operate), (.stop, ["force": true], .full), (.stop, ["force": false], .operate),
        (.share, [:], .operate), (.share, ["readOnly": true], .operate), (.share, ["readOnly": false], .full),
        (.reset, [:], .full), (.snapshotRevert, [:], .full), (.clone, [:], .full),
        (.snapshotDelete, [:], nil), (.snapshotBaseline, [:], nil),
        (.sharing, ["commands": "macUserAndAI"], nil), (.sharing, ["aiTier": "full"], nil),
    ]

    func testEveryOperationAtEveryLevel() {
        for (op, args, lowest) in Self.lowest {
            for tier in AITier.allCases {
                let expected = lowest.map { tier >= $0 } ?? false
                XCTAssertEqual(allowed(op, at: tier, args: args), expected, "\(op.rawValue) \(args) at \(tier)")
            }
        }
    }

    func testEveryOperationIsInTheMatrix() {
        let listed = Set(Self.lowest.map { $0.0 })
        for op in ControlOp.allCases where op.needsVM {
            XCTAssertTrue(listed.contains(op), "\(op.rawValue) needs a row in the matrix: decide what level it needs")
        }
    }

    func testOffMeansNothingAtAll() {
        for op in ControlOp.allCases where op.needsVM {
            XCTAssertFalse(allowed(op, at: .off), op.rawValue)
        }
        XCTAssertTrue(allowed(.list, at: .off), "listing needs no VM; the global switch is its only gate")
        XCTAssertTrue(allowed(.status, at: .off))
    }

    func testDeletingASnapshotIsNeverAllowedToAnAITool() {
        for tier in AITier.allCases { XCTAssertFalse(allowed(.snapshotDelete, at: tier)) }
        XCTAssertThrowsError(try AIAuthorization.authorize(request(.snapshotDelete), vmName: "VM", tier: .full)) { error in
            XCTAssertEqual((error as? ControlError)?.code, "refused")
            XCTAssertTrue((error as? ControlError)?.message.contains("delete snapshots") == true)
        }
    }

    func testTheMacUsersCommandLineIsNotLimitedByTheLevel() throws {
        for (op, args, _) in Self.lowest {
            try AIAuthorization.authorize(request(op, client: .cli, args: args), vmName: "VM", tier: .off)
        }
    }

    func testTheRefusalNamesTheLevelTheNeedAndTheWayToChangeIt() {
        XCTAssertThrowsError(try AIAuthorization.authorize(request(.snapshotRevert), vmName: "Debian", tier: .operate)) { error in
            let e = error as! ControlError
            XCTAssertEqual(e.code, "refused")
            XCTAssertTrue(e.message.contains("Debian") && e.message.contains("Operate") && e.message.contains("Full"), e.message)
            XCTAssertTrue((e.detail ?? "").contains("--ai-tier full"), e.detail ?? "")
            XCTAssertTrue((e.detail ?? "").contains("Sharing"), e.detail ?? "")
        }
        XCTAssertThrowsError(try AIAuthorization.authorize(request(.start), vmName: "Debian", tier: .off)) { error in
            XCTAssertTrue((error as! ControlError).message.contains("closed to AI tools"))
        }
    }

    // MARK: The baseline

    func testWithABaselineAnAIToolMayOnlyGoBackToIt() throws {
        let baseline = UUID(), other = UUID()
        try AIAuthorization.authorizeRevert(request(.snapshotRevert), vmName: "VM", target: baseline, targetName: "Clean",
                                            baseline: baseline, baselineName: "Clean")
        XCTAssertThrowsError(try AIAuthorization.authorizeRevert(request(.snapshotRevert), vmName: "VM", target: other, targetName: "Dirty",
                                                                 baseline: baseline, baselineName: "Clean")) { error in
            let e = error as! ControlError
            XCTAssertEqual(e.code, "refused")
            XCTAssertTrue(e.message.contains("baseline"), e.message)
            XCTAssertTrue((e.detail ?? "").contains("Dirty") && (e.detail ?? "").contains("Clean"), e.detail ?? "")
        }
    }

    func testWithoutABaselineAnySnapshotWillDoAtTheFullLevel() throws {
        try AIAuthorization.authorizeRevert(request(.snapshotRevert), vmName: "VM", target: UUID(), targetName: "Any", baseline: nil, baselineName: nil)
    }

    func testTheBaselineRuleDoesNotBindThePerson() throws {
        try AIAuthorization.authorizeRevert(request(.snapshotRevert, client: .cli), vmName: "VM", target: UUID(), targetName: "Any",
                                            baseline: UUID(), baselineName: "Clean")
    }

    // MARK: Enforced where requests arrive

    private struct Facts { var name: String; var tier: AITier }

    /// The app's order of checks, over a real socket: the global gate, then the VM's level.
    private func serve(vms: [String: Facts], log: URL, settings: ControlSettings = ControlSettings(allowAITools: true)) throws -> (ControlSocketServer, String) {
        let path = ControlProtocol.socketURL(libraryRoot: log).path
        let server = ControlSocketServer(path: path) { request in
            let response: ControlResponse
            do {
                try ControlGate.check(request, settings: settings)
                if request.client == .mcp, request.op != "list", let key = request.vm, let facts = vms[key] {
                    try AIAuthorization.authorize(request, vmName: facts.name, tier: facts.tier)
                }
                response = .success(request.id, .object(["done": .string(request.op)]))
            } catch let error as ControlError {
                response = .failure(request.id, error)
            } catch {
                response = .failure(request.id, .failed("\(error)"))
            }
            if request.client == .mcp { AIActivityLog.append(AIActivityLog.entry(for: request, response: response), libraryRoot: log) }
            return response
        }
        try server.start()
        return (server, path)
    }

    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aiauth-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func connect(_ path: String, as client: ControlClient) throws -> ControlConnection {
        let fd = try XCTUnwrap(ControlSocket.connect(path: path))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return ControlConnection(fd: fd, client: client)
    }

    func testAProgramThatCallsItselfMCPIsHeldToTheLevelAtTheSocket() throws {
        let root = try tempRoot()
        let (server, path) = try serve(vms: ["lab": Facts(name: "Lab", tier: .observe), "work": Facts(name: "Work", tier: .full)], log: root)
        defer { server.stop() }
        let ai = try connect(path, as: .mcp)
        XCTAssertNoThrow(try ai.send(.info, vm: "lab"))
        XCTAssertThrowsError(try ai.send(.start, vm: "lab")) { XCTAssertEqual(($0 as? ControlError)?.code, "refused") }
        XCTAssertThrowsError(try ai.send(.snapshotRevert, vm: "lab", args: ["snapshot": "x"]))
        XCTAssertNoThrow(try ai.send(.snapshotRevert, vm: "work", args: ["snapshot": "x"]))
        XCTAssertThrowsError(try ai.send(.snapshotDelete, vm: "work", args: ["snapshot": "x"]), "not even at Full")
        XCTAssertThrowsError(try ai.send(.sharing, vm: "work", args: ["aiTier": "full"]), "an AI tool may not raise its own level")
        // The person's own command line is not held to it.
        let person = try connect(path, as: .cli)
        XCTAssertNoThrow(try person.send(.snapshotRevert, vm: "lab", args: ["snapshot": "x"]))
        XCTAssertNoThrow(try person.send(.sharing, vm: "lab", args: ["aiTier": "full"]))
    }

    func testTheGlobalSwitchStillComesFirst() throws {
        let root = try tempRoot()
        let (server, path) = try serve(vms: ["work": Facts(name: "Work", tier: .full)], log: root, settings: ControlSettings(allowAITools: false))
        defer { server.stop() }
        XCTAssertThrowsError(try connect(path, as: .mcp).send(.info, vm: "work")) { error in
            XCTAssertEqual((error as? ControlError)?.message, ControlGate.aiOffMessage)
        }
        XCTAssertNoThrow(try connect(path, as: .cli).send(.info, vm: "work"))
    }

    // MARK: The activity log

    func testEveryAICallIsLoggedWithItsOutcome() throws {
        let root = try tempRoot()
        let (server, path) = try serve(vms: ["lab": Facts(name: "Lab", tier: .operate)], log: root)
        defer { server.stop() }
        let ai = try connect(path, as: .mcp)
        _ = try? ai.send(.list)
        _ = try? ai.send(.start, vm: "lab")
        _ = try? ai.send(.snapshotRevert, vm: "lab", args: ["snapshot": "Clean"])
        _ = try? ai.send(.exec, vm: "lab", args: ["command": "ls -l\nwhoami"])
        _ = try? connect(path, as: .cli).send(.start, vm: "lab")   // the person's own call is not an AI call
        let entries = AIActivityLog.recent(libraryRoot: root)
        XCTAssertEqual(entries.map(\.tool), ["exec", "snapshot.revert", "start", "list"], "newest first, the command line left out")
        XCTAssertEqual(entries.map(\.outcome), ["allowed", "denied", "allowed", "allowed"])
        XCTAssertEqual(entries[1].summary, "Clean")
        XCTAssertNotNil(entries[1].message, "a refusal says why")
        XCTAssertEqual(entries[0].summary, "ls -l whoami", "one line, whatever the command held")
        XCTAssertEqual(entries[2].vm, "lab")
    }

    func testAFailedCallIsLoggedAsFailedNotDenied() {
        let r = request(.start)
        let failed = AIActivityLog.entry(for: r, response: .failure(1, .failed("did not start")))
        XCTAssertEqual(failed.outcome, "failed")
        let denied = AIActivityLog.entry(for: r, response: .failure(1, .refused("no")))
        XCTAssertEqual(denied.outcome, "denied")
    }

    func testTheLogIsPrivateKeepsToItsSizeAndSkipsDamagedLines() throws {
        let root = try tempRoot()
        for i in 0..<30 {
            AIActivityLog.append(AIActivityEntry(time: Date(), tool: "start", vm: "vm\(i)", outcome: "allowed"), libraryRoot: root, maxBytes: 1_000)
        }
        let file = AIActivityLog.url(libraryRoot: root)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600, "readable by the owner only")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("ai-activity.log.1").path), "moved aside when it grew")
        XCTAssertLessThanOrEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int ?? 0, 2_000)
        try Data("not json\n".utf8).write(to: file, options: .atomic)
        AIActivityLog.append(AIActivityEntry(time: Date(), tool: "list", vm: nil, outcome: "allowed"), libraryRoot: root)
        XCTAssertEqual(AIActivityLog.recent(libraryRoot: root).map(\.tool), ["list"], "the damaged line is skipped")
        XCTAssertEqual(AIActivityLog.recent(libraryRoot: root, limit: 0).count, 0)
    }

    // MARK: The MCP tool list

    func testEveryToolDescriptionSaysWhatItNeeds() throws {
        let server = MCPServer(aiAllowed: { true }, transport: { _, _, _ in .null })
        let answer = try XCTUnwrap(server.handle(line: Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)))
        let tools = try XCTUnwrap(try JSON.decode(answer)["result"]?["tools"]?.array)
        var byName: [String: String] = [:]
        for tool in tools { byName[tool["name"]?.string ?? ""] = tool["description"]?.string ?? "" }
        XCTAssertEqual(byName.count, MCPServer.tools.count)
        for (name, text) in byName where name != "list_vms" {
            XCTAssertTrue(text.contains("AI level"), "\(name) says what it needs: \(text)")
        }
        XCTAssertTrue(byName["revert_snapshot"]?.contains("Full") == true)
        XCTAssertTrue(byName["revert_snapshot"]?.contains("baseline") == true)
        XCTAssertTrue(byName["clone_vm"]?.contains("Full") == true)
        XCTAssertTrue(byName["start_vm"]?.contains("Operate") == true)
        XCTAssertTrue(byName["vm_info"]?.contains("Observe") == true)
        XCTAssertTrue(byName["stop_vm"]?.contains("force") == true && byName["stop_vm"]?.contains("Full") == true)
        XCTAssertTrue(byName["share_folder"]?.contains("Full") == true)
        XCTAssertNil(byName["delete_snapshot"], "no tool deletes snapshots")
    }

    func testTheToolListNeverOffersDeletingSnapshots() {
        for tool in MCPServer.tools {
            XCTAssertFalse(tool.name.contains("delete"), tool.name)
        }
    }

    // MARK: The command line

    func testTheCommandLineSetsTheLevelAndTheBaseline() throws {
        let tier = try CLIParser.parse(["sharing", "Debian", "--ai-tier", "observe"]).action
        guard case .request(let op, let vm, let args, _) = tier else { return XCTFail("\(tier)") }
        XCTAssertEqual(op, .sharing); XCTAssertEqual(vm, "Debian"); XCTAssertEqual(args["aiTier"]?.string, "observe")
        XCTAssertThrowsError(try CLIParser.parse(["sharing", "Debian", "--ai-tier", "root"]))
        let base = try CLIParser.parse(["snapshot", "baseline", "Debian", "Clean", "install"]).action
        guard case .request(let op2, _, let args2, _) = base else { return XCTFail("\(base)") }
        XCTAssertEqual(op2, .snapshotBaseline); XCTAssertEqual(args2["snapshot"]?.string, "Clean install")
    }
}
