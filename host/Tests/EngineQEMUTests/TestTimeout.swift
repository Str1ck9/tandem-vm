import XCTest

extension XCTestCase {
    /// Runs `body` but gives up after `seconds`, failing the test by name instead of hanging the whole
    /// suite. A body stuck in a blocking call keeps its thread; the suite still goes on.
    func withTestTimeout(_ seconds: TimeInterval, file: StaticString = #filePath, line: UInt = #line,
                         _ body: @escaping @Sendable () async throws -> Void) async throws {
        let outcome = OneShot()
        let result: Result<Void, Error>? = await withCheckedContinuation { continuation in
            outcome.continuation = continuation
            Task.detached {
                do { try await body(); outcome.finish(.success(())) } catch { outcome.finish(.failure(error)) }
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                outcome.finish(nil)
            }
        }
        guard let result else {
            XCTFail("\(name) did not finish within \(Int(seconds)) s", file: file, line: line)
            return
        }
        try result.get()
    }
}

/// Resumes its continuation once, with whichever outcome arrives first.
private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    var continuation: CheckedContinuation<Result<Void, Error>?, Never>?
    func finish(_ value: Result<Void, Error>?) {
        let c = lock.withLock { () -> CheckedContinuation<Result<Void, Error>?, Never>? in
            let c = continuation; continuation = nil; return c
        }
        c?.resume(returning: value)
    }
}
