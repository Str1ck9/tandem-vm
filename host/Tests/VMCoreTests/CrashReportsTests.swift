import XCTest
@testable import VMCore

final class CrashReportsTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("crash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    /// A report as macOS 26 writes it: one line of header JSON, then the body JSON.
    private func writeReport(_ name: String, at date: Date, home: String = "/Users/someone") throws -> URL {
        let header = #"{"app_name":"Tandem","timestamp":"2026-11-16 10:15:00.00 -0500","app_version":"0.9.0","build_version":"170","bug_type":"309","os_version":"macOS 26.6.2 (25G83)","name":"Tandem"}"#
        let body = """
        {"procPath":"\(home)/Applications/Tandem.app/Contents/MacOS/Tandem","exception":{"type":"EXC_BREAKPOINT","signal":"SIGTRAP"},
         "termination":{"indicator":"Trace/BPT trap: 5"},
         "asi":{"libswiftCore.dylib":["Fatal error: Range requires lowerBound <= upperBound in \(home)/src/x.swift"]},
         "threads":[{"frames":[{"symbol":"idle"}]},{"triggered":true,"frames":[{"symbol":"WebDAVServer.get(_:_:)"},{"imageOffset":4096},{"symbol":"WebDAVServer.serveOne(_:)"}]}]}
        """
        let url = folder.appendingPathComponent(name)
        try Data((header + "\n" + body).utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        return url
    }

    func testFindsOnlyTandemReportsNewerThanTheLastOneSeen() throws {
        let now = Date()
        _ = try writeReport("Tandem-2026-11-15-090000.ips", at: now.addingTimeInterval(-7200))
        let newest = try writeReport("Tandem-2026-11-16-101500.ips", at: now.addingTimeInterval(-60))
        _ = try writeReport("qemu-system-aarch64-2026-11-16-101500.ips", at: now)
        _ = try writeReport("TandemNetHelper-2026-11-16-101500.ips", at: now)
        _ = try writeReport("Tandem-notes.txt", at: now)
        let all = CrashReports.reports(in: folder, after: nil)
        XCTAssertEqual(all.map(\.url.lastPathComponent), ["Tandem-2026-11-16-101500.ips", "Tandem-2026-11-15-090000.ips"])
        XCTAssertEqual(CrashReports.reports(in: folder, after: now.addingTimeInterval(-3600)).map(\.url.lastPathComponent), [newest.lastPathComponent])
        XCTAssertEqual(CrashReports.pending(in: folder, lastSeen: all[0].date), [], "asked once per crash")
    }

    func testFirstLaunchOnlyOffersACrashOfTheLastDay() throws {
        let now = Date()
        _ = try writeReport("Tandem-2026-11-01-090000.ips", at: now.addingTimeInterval(-10 * 86_400))
        XCTAssertEqual(CrashReports.pending(in: folder, lastSeen: nil, now: now), [])
        _ = try writeReport("Tandem-2026-11-16-090000.ips", at: now.addingTimeInterval(-3600))
        XCTAssertEqual(CrashReports.pending(in: folder, lastSeen: nil, now: now).count, 1)
    }

    func testSummaryHasTheFactsAndNoHomePath() throws {
        let url = try writeReport("Tandem-2026-11-16-101500.ips", at: Date(), home: "/Users/someone")
        let summary = try XCTUnwrap(CrashReports.summary(of: .init(url: url, date: Date()), home: "/Users/someone"))
        XCTAssertEqual(summary.process, "Tandem")
        XCTAssertEqual(summary.appVersion, "0.9.0 (170)")
        XCTAssertEqual(summary.osVersion, "macOS 26.6.2 (25G83)")
        XCTAssertEqual(summary.exception, "EXC_BREAKPOINT / SIGTRAP")
        XCTAssertEqual(summary.frames, ["WebDAVServer.get(_:_:)", "0x1000", "WebDAVServer.serveOne(_:)"])
        XCTAssertTrue(summary.reason.contains("Range requires lowerBound"))
        XCTAssertFalse(summary.reason.contains("/Users/someone"), summary.reason)
        XCTAssertNil(CrashReports.summary(of: .init(url: folder.appendingPathComponent("missing.ips"), date: Date())))
    }

    func testIssuePageIsPrefilledAndEncoded() throws {
        let url = try writeReport("Tandem-2026-11-16-101500.ips", at: Date())
        let summary = CrashReports.summary(of: .init(url: url, date: Date()))
        let issue = try XCTUnwrap(CrashReports.issueURL(repository: "https://github.com/someone/tandem/", summary: summary, appVersion: "0.9.0+dev (build 170)"))
        XCTAssertTrue(issue.absoluteString.hasPrefix("https://github.com/someone/tandem/issues/new?"))
        let items = URLComponents(url: issue, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "labels" }?.value, "crash")
        XCTAssertEqual(items.first { $0.name == "title" }?.value, "Crash: Tandem 0.9.0 (170) — EXC_BREAKPOINT / SIGTRAP")
        let body = try XCTUnwrap(items.first { $0.name == "body" }?.value)
        XCTAssertTrue(body.contains("0.9.0+dev (build 170)"))
        XCTAssertTrue(body.contains("WebDAVServer.get(_:_:)"))
        XCTAssertFalse(issue.absoluteString.contains("+dev"), "a plus must be encoded, or the page reads a space")
        XCTAssertNil(CrashReports.issueURL(repository: "not a url", summary: nil, appVersion: "1"))
        XCTAssertNil(CrashReports.issueURL(repository: "http://example.com/x", summary: nil, appVersion: "1"), "https only")
    }

    func testMailHasNoAddressOnlySubjectAndText() throws {
        let mail = try XCTUnwrap(CrashReports.mailURL(summary: nil, appVersion: "1.0 (build 1)"))
        XCTAssertTrue(mail.absoluteString.hasPrefix("mailto:?subject="), mail.absoluteString)
        XCTAssertTrue(mail.absoluteString.contains("body="))
    }
}
