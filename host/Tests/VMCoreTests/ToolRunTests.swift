import XCTest
@testable import VMCore

final class ToolRunTests: XCTestCase {
    private let sh = URL(fileURLWithPath: "/bin/sh")

    func testCapturesBothStreamsAndStatus() throws {
        let result = try ToolRun.run(sh, ["-c", "echo out; echo err >&2; exit 3"], timeout: 10)
        XCTAssertEqual(result.status, 3)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.outputText, "out\n")
        XCTAssertEqual(result.errorText, "err\n")
        XCTAssertEqual(ToolRun.failed(result, "It failed.").detail, "err")
    }

    /// Reading one stream to its end before the other used to stall a tool that fills the second pipe.
    func testLargeOutputOnBothStreamsDoesNotStall() throws {
        let started = Date()
        let result = try ToolRun.run(sh, ["-c", "head -c 3000000 /dev/zero; head -c 3000000 /dev/zero >&2"], timeout: 30)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output.count, 3_000_000)
        XCTAssertEqual(result.errors.count, 3_000_000)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testDiscardedStreams() throws {
        let result = try ToolRun.run(sh, ["-c", "echo out; echo err >&2"], timeout: 10, output: .discard, errors: .discard)
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.isEmpty && result.errors.isEmpty)
    }

    func testTimeoutStopsTheToolAndNamesIt() throws {
        let started = Date()
        XCTAssertThrowsError(try ToolRun.run(URL(fileURLWithPath: "/bin/sleep"), ["30"], timeout: 0.5)) { error in
            let message = (error as? VMError)?.message ?? ""
            XCTAssertTrue(message.hasPrefix("sleep did not finish within 1 second"), message)
            XCTAssertEqual((error as? VMError)?.detail, "Command: sleep 30")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)
    }

    /// A tool that ignores SIGTERM is killed.
    func testTimeoutKillsAToolThatIgnoresTerminate() throws {
        let started = Date()
        XCTAssertThrowsError(try ToolRun.run(sh, ["-c", "trap '' TERM; sleep 30"], timeout: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(started), 9)
    }

    /// A background child that keeps the output pipe open must not keep the caller waiting.
    func testChildHoldingThePipeDoesNotBlock() throws {
        let started = Date()
        let result = try ToolRun.run(sh, ["-c", "sleep 20 & echo hi"], timeout: 10)
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.outputText.hasPrefix("hi"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)
        _ = try? ToolRun.run(URL(fileURLWithPath: "/usr/bin/pkill"), ["-f", "^sleep 20$"], timeout: 5)
    }

    func testMissingToolThrows() {
        XCTAssertThrowsError(try ToolRun.run(URL(fileURLWithPath: "/nonexistent/tool"), [], timeout: 5)) { error in
            XCTAssertEqual((error as? VMError)?.message, "tool could not be started.")
        }
    }

    func testCheckedReturnsOutputOrThrowsTheFailure() throws {
        XCTAssertEqual(try ToolRun.checked(sh, ["-c", "printf ok"], timeout: 10, failure: "x"), "ok")
        XCTAssertThrowsError(try ToolRun.checked(sh, ["-c", "echo bad >&2; exit 1"], timeout: 10, failure: "Broke.")) { error in
            XCTAssertEqual(error as? VMError, VMError("Broke.", detail: "bad"))
        }
    }

    func testAsyncRunAndTimeout() async throws {
        let result = try await ToolRun.run(sh, ["-c", "echo async"], timeout: 10)
        XCTAssertEqual(result.outputText, "async\n")
        do {
            _ = try await ToolRun.run(URL(fileURLWithPath: "/bin/sleep"), ["30"], timeout: 0.3)
            XCTFail("expected a timeout")
        } catch let error as VMError {
            XCTAssertTrue(error.message.contains("sleep did not finish"))
        }
    }

    func testAsyncCancellationStopsTheTool() async throws {
        let started = Date()
        let task = Task { try await ToolRun.run(URL(fileURLWithPath: "/bin/sleep"), ["30"], timeout: 60) }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") } catch is CancellationError {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)
    }

    func testDescribe() {
        XCTAssertEqual(ToolRun.describe(1), "1 second")
        XCTAssertEqual(ToolRun.describe(60), "60 seconds")
        XCTAssertEqual(ToolRun.describe(15 * 60), "15 minutes")
        XCTAssertEqual(ToolRun.describe(4 * 3600), "4 hours")
    }
}
