import CryptoKit
import Foundation
import Updater
import VMCore

/// The developer's side of Tandem's updates (scripts/release.sh drives it):
///
///   tandem-release keygen [--key FILE]            make the release key (default ~/.config/tandem/update-signing.key)
///   tandem-release public-key [--key FILE]        print the public key that goes into Tandem's Info.plist
///   tandem-release sign ARCHIVE --version V --build N --feed FEED.json
///                       [--notes FILE] [--min-system 15.0] [--url NAME] [--key FILE]
///                                                 sign the archive and add it to the feed (made if missing)
///   tandem-release verify --feed URL --public-key B64 [--current V --build N]
///                                                 check the feed the way Tandem does and say what it offers
///   tandem-release try-update --feed URL --app PATH [--public-key B64] [--downloads DIR] [--keep-old]
///                                                 update the Tandem.app at PATH from the feed, as the app's own
///                                                 updater does (for testing releases; never point it at a
///                                                 Tandem that is running)
@main
struct ReleaseTool {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else { usage() }
        args.removeFirst()
        do {
            switch command {
            case "keygen": try keygen(Options(args))
            case "public-key": try publicKey(Options(args))
            case "sign": try sign(Options(args))
            case "verify": try await verify(Options(args))
            case "try-update": try await tryUpdate(Options(args))
            default: usage()
            }
        } catch {
            FileHandle.standardError.write(Data(("error: " + error.userFacingText + "\n").utf8))
            exit(1)
        }
    }

    static func usage() -> Never {
        FileHandle.standardError.write(Data("usage: tandem-release keygen|public-key|sign|verify|try-update … (see the source for options)\n".utf8))
        exit(2)
    }

    static func keyURL(_ o: Options) -> URL {
        o["--key"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? UpdateSignature.defaultPrivateKeyURL
    }

    static func keygen(_ o: Options) throws {
        let url = keyURL(o)
        let key = try UpdateSignature.generateKey(at: url)
        print("Release key written to \(url.path) (only you can read it; keep a backup somewhere safe).")
        print("Public key: \(key.publicKey.rawRepresentation.base64EncodedString())")
    }

    static func publicKey(_ o: Options) throws {
        print(try UpdateSignature.privateKey(at: keyURL(o)).publicKey.rawRepresentation.base64EncodedString())
    }

    static func sign(_ o: Options) throws {
        guard let archivePath = o.positional.first, let version = o["--version"], let buildText = o["--build"],
              let build = Int(buildText), let feedPath = o["--feed"] else { usage() }
        guard AppVersion(version, build: build) != nil else { throw VMError("Not a version: \(version)") }
        let archive = URL(fileURLWithPath: archivePath)
        let key = try UpdateSignature.privateKey(at: keyURL(o))
        let digest = try UpdateSignature.digest(of: archive)
        let notes = try o["--notes"].map { try String(contentsOfFile: $0, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) }
        let formatter = ISO8601DateFormatter()
        var release = UpdateRelease(version: version, build: build, published: formatter.string(from: Date()),
                                    minimumSystemVersion: o["--min-system"] ?? "15.0", notes: notes,
                                    url: o["--url"] ?? archive.lastPathComponent, length: digest.length, sha256: digest.sha256, signature: "")
        release.signature = try UpdateSignature.sign(release, with: key)
        let feedURL = URL(fileURLWithPath: feedPath)
        var feed = FileManager.default.fileExists(atPath: feedPath) ? try UpdateFeed.parse(Data(contentsOf: feedURL)) : UpdateFeed(releases: [])
        feed.add(release)
        try feed.encoded().write(to: feedURL, options: .atomic)
        print("Signed \(archive.lastPathComponent): Tandem \(release.appVersion), \(digest.length) bytes, SHA-256 \(digest.sha256)")
        print("Feed: \(feedURL.path) (\(feed.releases.count) release\(feed.releases.count == 1 ? "" : "s"))")
    }

    static func feedURL(_ text: String) -> URL {
        if text.contains("://") { return URL(string: text)! }
        return URL(fileURLWithPath: (text as NSString).expandingTildeInPath)
    }

    static func verify(_ o: Options) async throws {
        guard let feed = o["--feed"], let key = o["--public-key"] else { usage() }
        let current = AppVersion(o["--current"] ?? "0.0.0", build: Int(o["--build"] ?? "0") ?? 0) ?? AppVersion(components: [0], build: 0)
        let client = UpdateClient(feedURL: feedURL(feed), publicKey: try UpdateSignature.publicKey(base64: key), current: current)
        if let release = try await client.check() {
            print("Offers Tandem \(release.appVersion): \(release.archiveURL(relativeTo: client.feedURL)?.absoluteString ?? release.url), signature valid")
        } else {
            print("Nothing newer than \(current)")
        }
    }

    static func tryUpdate(_ o: Options) async throws {
        guard let feed = o["--feed"], let appPath = o["--app"] else { usage() }
        let app = URL(fileURLWithPath: (appPath as NSString).expandingTildeInPath)
        guard let bundle = Bundle(url: app), let current = AppVersion.of(bundle: bundle) else { throw VMError("No Tandem at \(app.path)") }
        let key = try o["--public-key"].map { try UpdateSignature.publicKey(base64: $0) } ?? UpdateSignature.publicKey(of: bundle)
        guard let key else { throw VMError("\(app.lastPathComponent) carries no update key (TandemUpdatePublicKey).") }
        let client = UpdateClient(feedURL: feedURL(feed), publicKey: key, current: current)
        print("Installed: Tandem \(current)")
        guard let release = try await client.check() else { print("Up to date."); return }
        print("Found: Tandem \(release.appVersion)")
        let downloads = o["--downloads"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory.appendingPathComponent("tandem-release-downloads")
        let archive = try await client.download(release, into: downloads)
        print("Downloaded and checked: \(archive.path)")
        let staged = try UpdateInstaller.stage(archive: archive, release: release, replacing: app)
        print("Staged: \(staged.app.path) (team \(staged.team))")
        let old = try UpdateInstaller.install(staged, oldCopy: o.has("--keep-old") ? .trash : .delete)
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
        let now = AppVersion.of(info: info)
        print("Installed: Tandem \(now?.description ?? "?") at \(app.path)\(old.map { "; old copy in \($0.path)" } ?? "")")
    }
}

struct Options {
    var values: [String: String] = [:]
    var flags: Set<String> = []
    var positional: [String] = []
    static let flagNames: Set<String> = ["--keep-old"]

    init(_ args: [String]) {
        var i = 0
        while i < args.count {
            let a = args[i]
            if Self.flagNames.contains(a) { flags.insert(a); i += 1 }
            else if a.hasPrefix("--"), i + 1 < args.count { values[a] = args[i + 1]; i += 2 }
            else { positional.append(a); i += 1 }
        }
    }

    subscript(_ name: String) -> String? { values[name] }
    func has(_ flag: String) -> Bool { flags.contains(flag) }
}
