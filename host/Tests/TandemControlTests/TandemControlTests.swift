import Foundation
import XCTest
@testable import TandemControl

final class ControlProtocolTests: XCTestCase {
    func testRequestRoundTripsAsOneLine() throws {
        let request = ControlRequest(id: 7, client: .cli, op: .start, vm: "Debian", args: ["wait": true, "timeout": 30])
        let data = try ControlCoding.encode(request)
        XCTAssertEqual(data.last, 0x0A)
        XCTAssertEqual(data.filter { $0 == 0x0A }.count, 1, "one request, one line")
        let back = try ControlCoding.decode(ControlRequest.self, line: data.dropLast())
        XCTAssertEqual(back, request)
        XCTAssertEqual(back.operation, .start)
        XCTAssertEqual(back.int("timeout"), 30)
        XCTAssertEqual(back.bool("wait"), true)
    }

    func testRequestWithoutArgsDecodes() throws {
        let line = Data(#"{"v":1,"id":1,"client":"mcp","op":"list"}"#.utf8)
        let request = try ControlCoding.decode(ControlRequest.self, line: line)
        XCTAssertEqual(request.args, [:])
        XCTAssertEqual(request.client, .mcp)
    }

    func testResponsesCarryResultOrError() throws {
        let ok = ControlResponse.success(3, .object(["state": "running"]))
        let back = try ControlCoding.decode(ControlResponse.self, line: try ControlCoding.encode(ok).dropLast())
        XCTAssertEqual(back.result?["state"]?.string, "running")
        let failure = ControlResponse.failure(4, .refused("No.", detail: "Because."))
        let backFailure = try ControlCoding.decode(ControlResponse.self, line: try ControlCoding.encode(failure).dropLast())
        XCTAssertFalse(backFailure.ok)
        XCTAssertEqual(backFailure.error?.code, "refused")
        XCTAssertEqual(backFailure.error?.detail, "Because.")
    }

    func testJSONKeepsWholeNumbersWhole() {
        XCTAssertEqual(String(decoding: JSON.object(["n": 3, "x": 1.5]).encodedLine(), as: UTF8.self), #"{"n":3,"x":1.5}"#)
    }

    func testGateRefusesAIToolsUntilAllowed() {
        let mcp = ControlRequest(id: 1, client: .mcp, op: .list)
        XCTAssertThrowsError(try ControlGate.check(mcp, settings: ControlSettings())) { error in
            XCTAssertEqual((error as? ControlError)?.code, "refused")
        }
        XCTAssertNoThrow(try ControlGate.check(mcp, settings: ControlSettings(allowAITools: true)))
        XCTAssertNoThrow(try ControlGate.check(ControlRequest(id: 1, client: .cli, op: .list), settings: ControlSettings()),
                         "the Mac's own user is not affected by the AI switch")
    }

    func testGateRefusesUnknownOpsOtherVersionsAndMissingVM() {
        var unknown = ControlRequest(id: 1, client: .cli, op: .list); unknown.op = "format-disk"
        XCTAssertEqual(code(try ControlGate.check(unknown, settings: ControlSettings())), "unknown-op")
        var future = ControlRequest(id: 1, client: .cli, op: .list); future.v = 2
        XCTAssertEqual(code(try ControlGate.check(future, settings: ControlSettings())), "bad-request")
        XCTAssertEqual(code(try ControlGate.check(ControlRequest(id: 1, client: .cli, op: .start), settings: ControlSettings())), "bad-request")
    }

    func testSettingsDefaultOffAndPersist() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-control-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(ControlSettings.load(libraryRoot: root).allowAITools)
        try ControlSettings(allowAITools: true).save(libraryRoot: root)
        XCTAssertTrue(ControlSettings.load(libraryRoot: root).allowAITools)
    }

    func testLibraryRootFollowsTandemHome() {
        XCTAssertEqual(ControlProtocol.libraryRoot(environment: ["TANDEM_HOME": "/tmp/x"]).path, "/tmp/x")
        XCTAssertTrue(ControlProtocol.libraryRoot(environment: [:]).path.hasSuffix("Application Support/Tandem"))
    }

    func testAppIsFoundAroundTheTool() {
        let tool = URL(fileURLWithPath: "/Applications/Tandem.app/Contents/Helpers/tandem")
        XCTAssertEqual(ControlLauncher.appURL(executable: tool, environment: [:])?.path, "/Applications/Tandem.app")
        XCTAssertNil(ControlLauncher.appURL(executable: URL(fileURLWithPath: "/usr/local/bin/tandem-copy"), environment: [:]))
        XCTAssertEqual(ControlLauncher.appURL(executable: tool, environment: ["TANDEM_APP": "/x/T.app"])?.path, "/x/T.app")
    }

    func testSocketServesALineAndChecksThePeer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = ControlProtocol.socketURL(libraryRoot: root).path
        let listener = try ControlSocket.listen(path: path)
        defer { close(listener); unlink(path) }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, "only this user may connect")
        XCTAssertThrowsError(try ControlSocket.listen(path: path), "a second server on the same library is refused")
        let served = expectation(description: "served")
        // The second `listen` above probed the socket with a connection of its own, which is accepted first
        // and closes without a request: keep accepting until a request has been answered.
        Thread.detachNewThread {
            for _ in 0..<4 {
                let fd = accept(listener, nil, nil)
                guard fd >= 0 else { break }
                XCTAssertTrue(ControlSocket.peerIsSameUser(fd))
                var buffer = Data()
                if let line = ControlSocket.readLine(fd, buffer: &buffer), let request = try? ControlCoding.decode(ControlRequest.self, line: line) {
                    _ = ControlSocket.writeAll(fd, try! ControlCoding.encode(ControlResponse.success(request.id, .object(["echo": .string(request.op)]))))
                    close(fd)
                    served.fulfill()
                    return
                }
                close(fd)
            }
        }
        let connection = try XCTUnwrap(ControlConnection.open(libraryRoot: root, client: .cli))
        XCTAssertEqual(try connection.send(.status)["echo"]?.string, "status")
        wait(for: [served], timeout: 5)
    }

    private func code(_ body: @autoclosure () throws -> Void) -> String? {
        do { try body(); return nil } catch { return (error as? ControlError)?.code }
    }
}

final class CommandLineTests: XCTestCase {
    private func action(_ line: String) throws -> CLIAction { try CLIParser.parse(line.split(separator: " ").map(String.init)).action }

    func testSimpleCommands() throws {
        XCTAssertEqual(try action("list"), .request(op: .list, vm: nil, args: [:], screenshotFile: nil))
        XCTAssertEqual(try action("info Debian"), .request(op: .info, vm: "Debian", args: [:], screenshotFile: nil))
        XCTAssertEqual(try action("stop Debian --force"), .request(op: .stop, vm: "Debian", args: ["force": true, "wait": true], screenshotFile: nil))
        XCTAssertEqual(try action("start Debian --wait-tools"),
                       .request(op: .start, vm: "Debian", args: ["wait": true, "waitForTools": true], screenshotFile: nil))
        XCTAssertEqual(try action("keep-awake Debian on"), .request(op: .keepAwake, vm: "Debian", args: ["on": true], screenshotFile: nil))
        XCTAssertEqual(try action("sharing Debian --commands ai"),
                       .request(op: .sharing, vm: "Debian", args: ["commands": "macUserAndAI"], screenshotFile: nil))
        XCTAssertEqual(try action("resume Debian --wait-tools"),
                       .request(op: .resume, vm: "Debian", args: ["wait": true, "waitForTools": true], screenshotFile: nil))
        XCTAssertThrowsError(try action("sharing Debian --commands everyone"))
    }

    func testGlobalOptions() throws {
        let invocation = try CLIParser.parse(["--json", "--no-launch", "list"])
        XCTAssertTrue(invocation.json); XCTAssertFalse(invocation.launch)
        XCTAssertTrue(try CLIParser.parse(["list", "--json"]).json)
        XCTAssertEqual(try CLIParser.parse([]).action, .help(topic: nil))
    }

    func testExecTakesEverythingAfterTheSeparator() throws {
        let parsed = try CLIParser.parse(["exec", "Debian", "--user", "tester", "--timeout", "30", "--", "ls", "-la", "--color", "/tmp"]).action
        XCTAssertEqual(parsed, .request(op: .exec, vm: "Debian",
                                        args: ["command": "ls -la --color /tmp", "elevated": false, "user": "tester", "timeout": 30], screenshotFile: nil))
        XCTAssertEqual(try action("exec Win --elevated -- whoami"),
                       .request(op: .exec, vm: "Win", args: ["command": "whoami", "elevated": true], screenshotFile: nil))
        XCTAssertThrowsError(try action("exec Win --"))
        XCTAssertThrowsError(try action("exec Win --timeout x -- ls"))
    }

    func testSnapshotsAndSharing() throws {
        XCTAssertEqual(try action("snapshot take Debian Before upgrade --note careful"),
                       .request(op: .snapshotTake, vm: "Debian", args: ["name": "Before upgrade", "note": "careful"], screenshotFile: nil))
        XCTAssertEqual(try action("snapshot revert Debian 1a2b"),
                       .request(op: .snapshotRevert, vm: "Debian", args: ["snapshot": "1a2b"], screenshotFile: nil))
        XCTAssertEqual(try action("share Debian /tmp --read-only --temporary"),
                       .request(op: .share, vm: "Debian", args: ["path": "/tmp", "readOnly": true, "temporary": true], screenshotFile: nil))
        XCTAssertEqual(try action("screenshot Debian shot.png"), .request(op: .screenshot, vm: "Debian", args: [:], screenshotFile: "shot.png"))
    }

    func testMistakesAreReported() {
        XCTAssertThrowsError(try action("start"))
        XCTAssertThrowsError(try action("frobnicate Debian"))
        XCTAssertThrowsError(try action("info Debian extra"))
        XCTAssertThrowsError(try action("keep-awake Debian maybe"))
        XCTAssertThrowsError(try CLIParser.parse(["--bogus", "list"]))
    }
}

final class MCPServerTests: XCTestCase {
    private var calls: [(ControlOp, String?, [String: JSON])] = []
    private var allowed = true
    private var answer: (ControlOp) throws -> JSON = { _ in .object([:]) }

    private func server() -> MCPServer {
        MCPServer(version: "test", aiAllowed: { [unowned self] in allowed }) { [unowned self] op, vm, args in
            calls.append((op, vm, args))
            return try answer(op)
        }
    }

    private func send(_ server: MCPServer, _ json: String) throws -> JSON? {
        guard let line = server.handle(line: Data(json.utf8)) else { return nil }
        XCTAssertEqual(line.last, 0x0A)
        return try JSON.decode(line.dropLast())
    }

    func testInitializeNegotiatesTheVersionAndDeclaresTools() throws {
        let s = server()
        let reply = try XCTUnwrap(send(s, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#))
        XCTAssertEqual(reply["id"]?.int, 1)
        XCTAssertEqual(reply["result"]?["protocolVersion"]?.string, "2025-03-26")
        XCTAssertNotNil(reply["result"]?["capabilities"]?["tools"])
        XCTAssertEqual(reply["result"]?["serverInfo"]?["name"]?.string, "tandem")
        let unknownVersion = try XCTUnwrap(send(s, #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#))
        XCTAssertEqual(unknownVersion["result"]?["protocolVersion"]?.string, MCPServer.supportedVersions[0])
        XCTAssertNil(try send(s, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#), "notifications get no answer")
    }

    func testToolsListHasSchemasAndMarksDestructiveTools() throws {
        let reply = try XCTUnwrap(send(server(), #"{"jsonrpc":"2.0","id":"a","method":"tools/list"}"#))
        XCTAssertEqual(reply["id"]?.string, "a")
        let tools = try XCTUnwrap(reply["result"]?["tools"]?.array)
        let names = tools.compactMap { $0["name"]?.string }
        for wanted in ["list_vms", "vm_info", "start_vm", "stop_vm", "suspend_vm", "resume_vm", "take_snapshot", "list_snapshots",
                       "revert_snapshot", "screenshot", "guest_exec", "share_folder", "unshare_folder"] {
            XCTAssertTrue(names.contains(wanted), wanted)
        }
        let revert = try XCTUnwrap(tools.first { $0["name"]?.string == "revert_snapshot" })
        XCTAssertEqual(revert["annotations"]?["destructiveHint"]?.bool, true)
        XCTAssertTrue(revert["description"]?.string?.hasPrefix("DESTRUCTIVE") ?? false)
        XCTAssertEqual(revert["inputSchema"]?["required"]?.array?.compactMap(\.string), ["vm", "snapshot"])
        XCTAssertEqual(tools.first { $0["name"]?.string == "list_vms" }?["annotations"]?["readOnlyHint"]?.bool, true)
    }

    func testToolCallsBecomeControlRequests() throws {
        let s = server()
        answer = { _ in .array([.object(["name": "Debian"])]) }
        let list = try XCTUnwrap(send(s, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_vms","arguments":{}}}"#))
        XCTAssertEqual(list["result"]?["isError"]?.bool, false)
        XCTAssertTrue(list["result"]?["content"]?.array?.first?["text"]?.string?.contains("Debian") ?? false)
        answer = { _ in .object(["status": "completed", "exitCode": 0, "stdout": "Linux\n", "stderr": ""]) }
        let exec = try XCTUnwrap(send(s, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"guest_exec","arguments":{"vm":"Debian","command":"uname","timeout_seconds":20}}}"#))
        XCTAssertTrue(exec["result"]?["content"]?.array?.first?["text"]?.string?.contains("Linux") ?? false)
        let last = try XCTUnwrap(calls.last)
        XCTAssertEqual(last.0, .exec); XCTAssertEqual(last.1, "Debian")
        XCTAssertEqual(last.2["command"]?.string, "uname"); XCTAssertEqual(last.2["timeout"]?.int, 20)
    }

    func testFoldersAnAIToolSharesAreReadOnlyUnlessItAsks() throws {
        let s = server()
        _ = try send(s, #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"share_folder","arguments":{"vm":"W","path":"/Users/x/Documents"}}}"#)
        XCTAssertEqual(calls.last?.2["readOnly"]?.bool, true, "read-only unless asked otherwise")
        _ = try send(s, #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"share_folder","arguments":{"vm":"W","path":"/Users/x/Out","read_only":false}}}"#)
        XCTAssertEqual(calls.last?.2["readOnly"]?.bool, false)
    }

    func testScreenshotIsAnImageBlock() throws {
        let s = server()
        answer = { _ in .object(["png": "iVBORw0KGgo=", "width": 10, "height": 10]) }
        let reply = try XCTUnwrap(send(s, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"screenshot","arguments":{"vm":"W"}}}"#))
        let block = try XCTUnwrap(reply["result"]?["content"]?.array?.first)
        XCTAssertEqual(block["type"]?.string, "image")
        XCTAssertEqual(block["mimeType"]?.string, "image/png")
        XCTAssertEqual(block["data"]?.string, "iVBORw0KGgo=")
    }

    func testRefusalsAreToolErrorsNotProtocolErrors() throws {
        let s = server()
        allowed = false
        let off = try XCTUnwrap(send(s, #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"list_vms","arguments":{}}}"#))
        XCTAssertEqual(off["result"]?["isError"]?.bool, true)
        XCTAssertTrue(off["result"]?["content"]?.array?.first?["text"]?.string?.contains("not allowed") ?? false)
        XCTAssertTrue(calls.isEmpty, "nothing reaches the app while AI tools are off")
        allowed = true
        answer = { _ in throw ControlError.refused("This virtual machine does not accept commands from AI tools.") }
        let refused = try XCTUnwrap(send(s, #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"guest_exec","arguments":{"vm":"W","command":"dir"}}}"#))
        XCTAssertEqual(refused["result"]?["isError"]?.bool, true)
        let missing = try XCTUnwrap(send(s, #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"guest_exec","arguments":{"vm":"W"}}}"#))
        XCTAssertEqual(missing["result"]?["isError"]?.bool, true)
    }

    func testProtocolErrors() throws {
        let s = server()
        XCTAssertEqual(try send(s, "not json")?["error"]?["code"]?.int, -32700)
        XCTAssertEqual(try send(s, #"{"jsonrpc":"2.0","id":9,"method":"resources/list"}"#)?["error"]?["code"]?.int, -32601)
        XCTAssertEqual(try send(s, #"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"format_disk"}}"#)?["error"]?["code"]?.int, -32602)
        XCTAssertEqual(try send(s, #"{"jsonrpc":"2.0","id":11,"method":"ping"}"#)?["result"], .object([:]))
    }
}
