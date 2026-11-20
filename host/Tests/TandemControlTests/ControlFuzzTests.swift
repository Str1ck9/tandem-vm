import FuzzSupport
import Foundation
import XCTest
@testable import TandemControl

/// The control socket takes requests from any program the user runs, and `tandem mcp` from an AI
/// client: malformed or hostile JSON must be refused, never crash either side.
final class ControlFuzzTests: XCTestCase {
    private static let requestSamples: [String] = [
        #"{"v":1,"id":1,"client":"cli","op":"list","args":{}}"#,
        #"{"v":1,"id":2,"client":"mcp","op":"exec","vm":"Windows 11","args":{"command":"dir","timeout":30,"maxOutput":65536,"elevated":false}}"#,
        #"{"v":1,"id":3,"client":"cli","op":"start","vm":"Ubuntu","args":{"wait":true,"waitForTools":true,"timeout":180}}"#,
        #"{"v":1,"id":4,"client":"cli","op":"screenshot","vm":"x","args":{"maxWidth":1600}}"#,
        #"{"v":1,"id":5,"client":"cli","op":"share","vm":"x","args":{"path":"/Users/u/Documents","readOnly":true,"temporary":true}}"#,
    ]

    /// Every argument the app reads from a request, as it reads it.
    private func readEverything(_ r: ControlRequest) {
        for key in ["timeout", "maxOutput", "maxWidth", "command", "path", "wait", "waitForTools", "elevated", "readOnly", "name", "snapshot"] {
            _ = r.int(key); _ = r.string(key); _ = r.bool(key)
            _ = r.int(key).map { Double($0) }
        }
        _ = r.operation?.needsVM
        _ = r.operation?.changes
    }

    func testMutatedRequestsDecodeOrAreRefused() throws {
        try Fuzz.cases(3000) { rng, seed in
            let line = Fuzz.mutatedJSONData(Data(rng.pick(Self.requestSamples).utf8), using: &rng)
            guard let request = try? ControlCoding.decode(ControlRequest.self, line: line) else { return }
            readEverything(request)
            // What the app sends back must encode, whatever came in.
            let reply = ControlResponse.success(request.id, .object(request.args))
            XCTAssertNoThrow(try ControlCoding.encode(reply), "seed \(seed)")
            // And a request that decoded survives its own round trip.
            let again = try? ControlCoding.decode(ControlRequest.self, line: try ControlCoding.encode(request))
            XCTAssertEqual(again?.op, request.op, "seed \(seed)")
        }
    }

    /// Regression (fuzzer): `"timeout": 1e300` made `Int(_:)` trap in the app's control service.
    func testHugeNumbersAreNotIntegers() throws {
        let request = try ControlCoding.decode(ControlRequest.self, line: Data(#"{"v":1,"id":1,"client":"cli","op":"exec","vm":"x","args":{"timeout":1e300,"maxOutput":-1e300,"maxWidth":9.3e18,"n":42}}"#.utf8))
        XCTAssertNil(request.int("timeout"))
        XCTAssertNil(request.int("maxOutput"))
        XCTAssertNil(request.int("maxWidth"))
        XCTAssertEqual(request.int("n"), 42)
        XCTAssertEqual(JSON.number(-9.1e18).int, -9_100_000_000_000_000_000)
    }

    // MARK: MCP

    private static let mcpSamples: [String] = [
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
        #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        #"{"jsonrpc":"2.0","id":3,"method":"ping"}"#,
        #"{"jsonrpc":"2.0","id":4,"result":{}}"#,
    ]

    private static let toolArguments: [String: String] = [
        "list_vms": #"{}"#, "vm_info": #"{"vm":"a"}"#, "start_vm": #"{"vm":"a","wait_for_tools":true}"#,
        "stop_vm": #"{"vm":"a","force":false}"#, "suspend_vm": #"{"vm":"a"}"#, "resume_vm": #"{"vm":"a"}"#,
        "list_snapshots": #"{"vm":"a"}"#, "clone_vm": #"{"vm":"a","name":"b","keep_identity":true,"include_snapshots":false}"#,
        "take_snapshot": #"{"vm":"a","name":"s","note":"n"}"#, "revert_snapshot": #"{"vm":"a","snapshot":"s"}"#,
        "screenshot": #"{"vm":"a"}"#, "guest_exec": #"{"vm":"a","command":"ls","user":"u","timeout_seconds":30,"elevated":false}"#,
        "share_folder": #"{"vm":"a","path":"/tmp","read_only":true,"temporary":false}"#, "unshare_folder": #"{"vm":"a","folder":"tmp"}"#,
    ]

    /// What the app might answer: mutated, so the server's reading of results is fuzzed as well.
    private static let resultSamples: [String] = [
        #"{"status":"completed","exitCode":0,"stdout":"hi","stderr":"","stdoutTruncated":false,"stderrTruncated":false,"message":""}"#,
        #"{"png":"iVBORw0KGgo=","width":10,"height":10}"#,
        #"{"vms":[{"name":"a","state":"running"}]}"#,
    ]

    func testMutatedMessagesGetOneWellFormedAnswer() throws {
        var rng = SeededRandom(seed: Fuzz.seed)
        let server = MCPServer(version: "fuzz", aiAllowed: { true }) { _, _, _ in
            if rng.chance(0.2) { throw ControlError(rng.pick(["refused", "failed", "timeout"]), rng.awkwardString(), detail: rng.chance(0.5) ? rng.awkwardString() : nil) }
            let sample = Data(rng.pick(Self.resultSamples).utf8)
            return (try? JSON.decode(Fuzz.mutatedJSONData(sample, using: &rng))) ?? .null
        }
        let tools = MCPServer.tools.map(\.name)
        try Fuzz.cases(1500) { caseRNG, seed in
            var message: Data
            if caseRNG.chance(0.6) {
                let name = caseRNG.chance(0.95) ? caseRNG.pick(tools) : caseRNG.awkwardString(maxLength: 10)
                let arguments = Self.toolArguments[name] ?? "{}"
                message = Data(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#.utf8)
            } else {
                message = Data(caseRNG.pick(Self.mcpSamples).utf8)
            }
            message = Fuzz.mutatedJSONData(message, using: &caseRNG)
            guard let answer = server.handle(line: message) else { return }
            XCTAssertEqual(answer.last, 0x0A, "seed \(seed)")
            XCTAssertEqual(answer.filter { $0 == 0x0A }.count, 1, "seed \(seed): one line per answer")
            let parsed = try XCTUnwrap(try? JSON.decode(answer.dropLast()), "seed \(seed): the answer is not JSON")
            XCTAssertEqual(parsed["jsonrpc"]?.string, "2.0", "seed \(seed)")
            XCTAssertTrue(parsed["result"] != nil || parsed["error"] != nil, "seed \(seed)")
        }
    }

    /// Regression (fuzzer): an exit code or timeout of 1e300 trapped in `Int(_:)`.
    func testGuestExecWithHugeNumbers() throws {
        let server = MCPServer(version: "t", aiAllowed: { true }) { _, _, args in
            XCTAssertNil(args["timeout"], "a timeout with no integer value is left out")
            return .object(["status": "completed", "exitCode": .number(1e300)])
        }
        let line = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"guest_exec","arguments":{"vm":"a","command":"x","timeout_seconds":1e300}}}"#.utf8)
        let answer = try XCTUnwrap(server.handle(line: line))
        XCTAssertTrue(String(decoding: answer, as: UTF8.self).contains("exit code: -1"))
    }

    /// Very deep nesting is refused by the decoder rather than overflowing the stack.
    func testDeepNestingIsRefused() {
        let deep = Data((String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000)).utf8)
        XCTAssertThrowsError(try JSON.decode(deep))
        let server = MCPServer(aiAllowed: { true }) { _, _, _ in .null }
        XCTAssertNotNil(server.handle(line: deep))
    }
}
