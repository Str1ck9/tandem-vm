import Foundation

/// Opt-in crash reporting without a server. After Tandem has crashed, macOS leaves a report in
/// ~/Library/Logs/DiagnosticReports; at the next launch Tandem offers, once per crash, to collect the
/// diagnostics and open a pre-filled issue page or e-mail for the user to attach them to. Nothing leaves
/// the Mac unless the user sends it.
public enum CrashReports {
    /// Where issues are filed unless the user sets another repository (Settings > Advanced).
    public static let defaultRepository = TandemIdentity.projectURL

    /// UserDefaults keys.
    public static let offerKey = "offerCrashReports"
    public static let repositoryKey = "crashReportRepository"
    public static let lastSeenKey = "crashReportsLastSeen"

    /// Process names whose reports count as a crash of Tandem.
    public static let processNames = ["Tandem"]

    /// macOS's folder of crash reports; `TANDEM_CRASH_REPORTS` points elsewhere (tests, self-tests).
    public static var folder: URL {
        if let custom = ProcessInfo.processInfo.environment["TANDEM_CRASH_REPORTS"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    public struct Report: Equatable, Sendable {
        public var url: URL
        public var date: Date
    }

    /// Tandem's crash reports in `folder` written after `since`, newest first. macOS names them
    /// `Tandem-2026-11-16-101500.ips` (older systems: `.crash`, or `Tandem_…`).
    public static func reports(in folder: URL = folder, after since: Date?, names: [String] = processNames) -> [Report] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.compactMap { url -> Report? in
            let name = url.lastPathComponent
            guard ["ips", "crash"].contains(url.pathExtension),
                  names.contains(where: { name.hasPrefix($0 + "-") || name.hasPrefix($0 + "_") }),
                  let date = (try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { return nil }
            if let since, date <= since { return nil }
            return Report(url: url, date: date)
        }
        .sorted { $0.date > $1.date }
    }

    /// What to ask about at launch: reports since the last one offered. The first time (no record yet),
    /// only a crash of the last day counts, so an old report is not brought up out of the blue.
    public static func pending(in folder: URL = folder, lastSeen: Date?, now: Date = Date()) -> [Report] {
        reports(in: folder, after: lastSeen ?? now.addingTimeInterval(-86_400))
    }

    /// The facts of a crash, from the report's JSON. Nothing personal: no paths, no memory.
    public struct Summary: Equatable, Sendable {
        public var process: String
        public var appVersion: String
        public var osVersion: String
        public var exception: String
        public var reason: String
        public var frames: [String]
        public var date: Date

        /// The issue's title: what crashed, how.
        public var title: String { "Crash: \(process) \(appVersion) — \(exception)" }
    }

    /// Reads a `.ips` report (one line of JSON header, then the JSON body). Nil when it is not one.
    public static func summary(of report: Report, home: String = NSHomeDirectory()) -> Summary? {
        guard let data = try? Data(contentsOf: report.url), let newline = data.firstIndex(of: 0x0A),
              let header = try? JSONSerialization.jsonObject(with: data[..<newline]) as? [String: Any],
              let body = try? JSONSerialization.jsonObject(with: data[(newline + 1)...]) as? [String: Any] else { return nil }
        func scrub(_ s: String) -> String { home.count > 1 ? s.replacingOccurrences(of: home, with: "~") : s }
        let exception = body["exception"] as? [String: Any]
        let type = [exception?["type"] as? String, exception?["signal"] as? String].compactMap { $0 }.joined(separator: " / ")
        var reasons: [String] = []
        if let asi = body["asi"] as? [String: [String]] { reasons += asi.values.flatMap { $0 } }
        if let indicator = (body["termination"] as? [String: Any])?["indicator"] as? String { reasons.append(indicator) }
        let threads = body["threads"] as? [[String: Any]] ?? []
        let crashed = threads.first { $0["triggered"] as? Bool == true }
        let frames = (crashed?["frames"] as? [[String: Any]] ?? []).prefix(12).map { frame -> String in
            frame["symbol"] as? String ?? "0x" + String((frame["imageOffset"] as? Int) ?? 0, radix: 16)
        }
        return Summary(process: header["app_name"] as? String ?? header["name"] as? String ?? "Tandem",
                       appVersion: [header["app_version"] as? String, (header["build_version"] as? String).map { "(\($0))" }]
                           .compactMap { $0 }.filter { !$0.isEmpty && $0 != "()" }.joined(separator: " "),
                       osVersion: header["os_version"] as? String ?? "",
                       exception: type.isEmpty ? "unknown" : type,
                       reason: scrub(String(reasons.joined(separator: " ").prefix(500))),
                       frames: frames.map(scrub),
                       date: report.date)
    }

    /// The text of the issue or e-mail: the facts, then what to attach.
    public static func body(_ summary: Summary?, appVersion: String) -> String {
        var lines = ["Tandem quit unexpectedly.", "", "**Tandem:** \(appVersion)"]
        if let s = summary {
            lines += ["**macOS:** \(s.osVersion)", "**When:** \(ISO8601DateFormatter().string(from: s.date))",
                      "**Exception:** \(s.exception)"]
            if !s.reason.isEmpty { lines.append("**Reason:** \(s.reason)") }
            if !s.frames.isEmpty { lines += ["", "Crashed thread:", "```"] + s.frames + ["```"] }
        }
        lines += ["", "**What I was doing:** ", "",
                  "_Please attach the “Tandem Diagnostics” zip that Tandem just showed in Finder (drag it into this box)._"]
        return lines.joined(separator: "\n")
    }

    /// GitHub's new-issue page with the title and text filled in. Nil when `repository` is not a URL.
    public static func issueURL(repository: String, summary: Summary?, appVersion: String) -> URL? {
        let base = repository.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: base + "/issues/new"), components.scheme == "https", components.host != nil else { return nil }
        components.queryItems = [
            URLQueryItem(name: "title", value: summary?.title ?? "Crash: Tandem \(appVersion)"),
            URLQueryItem(name: "body", value: String(body(summary, appVersion: appVersion).prefix(6000))),
            URLQueryItem(name: "labels", value: "crash"),
        ]
        // URLComponents leaves "+" alone, and the page would read it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    /// A new e-mail with the subject and text filled in, to whoever the user chooses.
    public static func mailURL(summary: Summary?, appVersion: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = ""
        components.queryItems = [
            URLQueryItem(name: "subject", value: summary?.title ?? "Tandem crash report \(appVersion)"),
            URLQueryItem(name: "body", value: String(body(summary, appVersion: appVersion).replacingOccurrences(of: "**", with: "").prefix(4000))),
        ]
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }
}
