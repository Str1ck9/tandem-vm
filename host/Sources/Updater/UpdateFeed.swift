import Foundation
import VMCore

/// Tandem's own update feed: a small JSON file listing releases, newest first. Each release names its
/// archive (the DMG from scripts/make-dmg.sh, or a zip of Tandem.app), the archive's length and SHA-256,
/// and an Ed25519 signature over those facts (`UpdateSignature`), made with the release key that only the
/// developer holds. The feed itself needs no protection: anything in it that matters is signed.
///
///     {
///       "format": "tandem-update-feed", "formatVersion": 1,
///       "releases": [
///         { "version": "0.7.0", "build": 190, "published": "2026-11-16T12:00:00Z",
///           "minimumSystemVersion": "15.0", "notes": "What changed…",
///           "url": "Tandem-0.7.0.dmg", "length": 56123456,
///           "sha256": "…64 hex…", "signature": "…base64…" }
///       ]
///     }
///
/// `url` may be relative to the feed's own address (a feed and its archives side by side, on a web server
/// or in a folder for file:// testing).
public struct UpdateFeed: Codable, Equatable, Sendable {
    public static let formatName = "tandem-update-feed"
    public var format: String
    public var formatVersion: Int
    public var releases: [UpdateRelease]

    public init(releases: [UpdateRelease]) {
        format = Self.formatName; formatVersion = 1; self.releases = releases
    }

    /// Parses a feed; refuses anything that is not one (a GitHub sign-in page, say) with a plain message.
    public static func parse(_ data: Data) throws -> UpdateFeed {
        guard data.count <= 4 << 20 else { throw VMError("The update feed is too large to be one.") }
        let feed: UpdateFeed
        do { feed = try JSONDecoder().decode(UpdateFeed.self, from: data) }
        catch { throw VMError("The update feed could not be read.", detail: "It is not a Tandem update feed (\(Self.describe(error))).") }
        guard feed.format == formatName else { throw VMError("The update feed could not be read.", detail: "It is not a Tandem update feed.") }
        guard feed.formatVersion == 1 else {
            throw VMError("The update feed is in a newer format than this Tandem understands.", detail: "Download the newest Tandem by hand.")
        }
        return feed
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Adds a release, replacing one with the same version and build, and keeps the list newest first.
    public mutating func add(_ release: UpdateRelease) {
        releases.removeAll { $0.appVersion == release.appVersion }
        releases.append(release)
        releases.sort { $0.appVersion > $1.appVersion }
    }

    /// The newest release that is newer than `current`, runs on `system`, and was not skipped.
    /// Entries that cannot be understood (a version that is not numbers) are passed over.
    public func newest(after current: AppVersion, system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
                       skipping skipped: Set<String> = []) -> UpdateRelease? {
        releases
            .filter { $0.isWellFormed && $0.appVersion > current && $0.runs(on: system) && !skipped.contains($0.appVersion.key) }
            .max { $0.appVersion < $1.appVersion }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.keyNotFound(let key, _): return "“\(key.stringValue)” is missing"
        case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
            return "unexpected value at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case DecodingError.dataCorrupted: return "not JSON"
        default: return error.localizedDescription
        }
    }
}

public struct UpdateRelease: Codable, Equatable, Sendable {
    public var version: String
    public var build: Int
    public var published: String?
    public var minimumSystemVersion: String?
    public var notes: String?
    public var url: String
    public var length: Int64
    public var sha256: String
    public var signature: String

    public init(version: String, build: Int, published: String? = nil, minimumSystemVersion: String? = nil, notes: String? = nil,
                url: String, length: Int64, sha256: String, signature: String) {
        self.version = version; self.build = build; self.published = published
        self.minimumSystemVersion = minimumSystemVersion; self.notes = notes
        self.url = url; self.length = length; self.sha256 = sha256; self.signature = signature
    }

    public var appVersion: AppVersion { AppVersion(version, build: build) ?? AppVersion(components: [], build: build) }

    var isWellFormed: Bool {
        AppVersion(version, build: build) != nil && length > 0 && length <= UpdateRelease.maximumLength
            && sha256.count == 64 && sha256.allSatisfy(\.isHexDigit)
    }

    /// An app, its QEMU builds and tools: a few hundred MB. Anything far larger is not a Tandem update.
    public static let maximumLength: Int64 = 4 << 30

    public func runs(on system: OperatingSystemVersion) -> Bool {
        guard let minimum = minimumSystemVersion, let needed = AppVersion(minimum, build: 0) else { return true }
        let have = AppVersion(components: [system.majorVersion, system.minorVersion, system.patchVersion], build: 0)
        return have >= needed
    }

    /// The archive's address: absolute, or relative to the feed.
    public func archiveURL(relativeTo feed: URL) -> URL? {
        URL(string: url, relativeTo: feed)?.absoluteURL
    }

    /// The archive's file name for the download folder: the last part of its address, made safe.
    public var archiveFileName: String {
        let last = (URL(string: url)?.lastPathComponent ?? url).replacingOccurrences(of: "/", with: "_")
        let safe = last.filter { $0.isLetter || $0.isNumber || "._-".contains($0) }
        let ext = (safe as NSString).pathExtension.lowercased()
        let name = safe.isEmpty || safe.hasPrefix(".") ? "Tandem-\(version)" : safe
        return ["dmg", "zip"].contains(ext) ? name : name + ".dmg"
    }
}

/// "0.6.1" with its build number. Ordered by the dotted numbers, then the build, so 0.6.1 (190) is newer
/// than 0.6.1 (185) and 0.10.0 newer than 0.9.9.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var components: [Int]
    public var build: Int

    public init(components: [Int], build: Int) { self.components = components; self.build = build }

    /// nil unless `text` is one to four dot-separated numbers ("0.6", "0.6.1"); a leading "v" is allowed.
    public init?(_ text: String, build: Int) {
        var text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count), build >= 0 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 9, part.allSatisfy(\.isASCIIDigit), let n = Int(part) else { return nil }
            numbers.append(n)
        }
        components = numbers; self.build = build
    }

    /// The running app's version, from its Info.plist.
    public static func of(bundle: Bundle) -> AppVersion? {
        let info = bundle.infoDictionary ?? [:]
        return of(info: info)
    }

    public static func of(info: [String: Any]) -> AppVersion? {
        guard let short = info["CFBundleShortVersionString"] as? String else { return nil }
        let build = (info["CFBundleVersion"] as? String).flatMap { Int($0) } ?? 0
        return AppVersion(short, build: build)
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        let n = max(a.components.count, b.components.count)
        for i in 0..<n {
            let x = i < a.components.count ? a.components[i] : 0
            let y = i < b.components.count ? b.components[i] : 0
            if x != y { return x < y }
        }
        return a.build < b.build
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
    public func hash(into hasher: inout Hasher) {
        var trimmed = components
        while trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed); hasher.combine(build)
    }

    public var short: String { components.map(String.init).joined(separator: ".") }
    public var description: String { "\(short) (build \(build))" }
    /// What "Skip This Version" remembers.
    public var key: String { "\(short)+\(build)" }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
