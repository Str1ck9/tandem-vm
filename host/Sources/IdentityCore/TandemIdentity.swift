import Foundation

/// Tandem's identifiers: the app's bundle identifier and everything named after it (the helper's launchd
/// labels, the signing identifiers of the bundled tools, the guest agent's LaunchDaemon, the document type
/// and the launchers' bundle identifiers).
///
/// Every one of them derives from two values, chosen when the app is built (see `scripts/identity.sh` and the
/// README, "Maintainers"):
///
/// - the **prefix** (`TANDEM_BUNDLE_PREFIX`, default `local.tandem`), which the helper, the tools and the
///   document type are named after, and
/// - the **app identifier** (`TANDEM_APP_ID`, default `<prefix>.app`).
///
/// The build writes both into the app's Info.plist (`TandemBundlePrefix`, `TandemAppID`). At run time they
/// are read from, in order: the environment (`TANDEM_BUNDLE_PREFIX`, `TANDEM_APP_ID`), the running app's
/// Info.plist, the Info.plist of the app the running program sits in (the helper and the command-line tool
/// live inside Tandem.app), and finally the defaults. This target has no dependencies so that every program
/// of Tandem, including the root helper, can use it.
public enum TandemIdentity {
    /// THE ONE PLACE that names the project's GitHub repository, as `owner/repo`. Issue reports and the
    /// default update feed are derived from it.
    public static let projectRepository = "Str1ck9/tandem-vm"
    /// The repository's web address.
    public static let projectURL = "https://github.com/" + projectRepository
    /// The name shown as the developer in the About window and in Info.plist.
    public static let developerName = "The Tandem contributors"

    public static let defaultPrefix = "local.tandem"
    public static let prefixKey = "TandemBundlePrefix"
    public static let appKey = "TandemAppID"
    public static let prefixEnvironmentVariable = "TANDEM_BUNDLE_PREFIX"
    public static let appEnvironmentVariable = "TANDEM_APP_ID"

    /// The two values everything else derives from.
    public struct Base: Equatable, Sendable {
        public var prefix: String
        public var app: String
        public init(prefix: String, app: String? = nil) {
            self.prefix = prefix
            self.app = app ?? prefix + ".app"
        }
        public static let standard = Base(prefix: defaultPrefix)
    }

    // MARK: Identifiers

    /// The prefix of every identifier except the app's own.
    public static var prefix: String { base.prefix }
    /// The app's bundle identifier.
    public static var app: String { base.app }
    /// The helper daemon a packaged Tandem.app registers with SMAppService; also its signing identifier.
    public static var helper: String { prefix + ".helper" }
    /// Its launch file inside the app: Contents/Library/LaunchDaemons/<this>.
    public static var helperPlistName: String { helper + ".plist" }
    /// The helper daemon scripts/install-net-helper.sh installs for development builds.
    public static var scriptHelper: String { prefix + ".nethelper" }
    /// The guest agent's LaunchDaemon label inside macOS guests.
    public static var guestAgent: String { prefix + ".agent" }
    /// The `.tandemvm` document type.
    public static var documentType: String { prefix + ".vm" }
    /// Prefix of the launchers' and stand-ins' bundle identifiers and of their notifications.
    public static var guestApp: String { prefix + ".guestapp" }
    /// The signing identifier of a bundled tool (`qemu-nbd`, `usbredirect`, …).
    public static func tool(_ name: String) -> String { prefix + "." + name }

    // MARK: Resolving

    private static let lock = NSLock()
    nonisolated(unsafe) private static var chosen: Base?

    /// The identifiers of this build (resolved once).
    public static var base: Base {
        lock.lock(); defer { lock.unlock() }
        if let chosen { return chosen }
        let resolved = resolve(environment: ProcessInfo.processInfo.environment,
                               infoDictionaries: infoDictionaries(executablePath: Bundle.main.executablePath ?? CommandLine.arguments.first ?? ""))
        chosen = resolved
        return resolved
    }

    /// Tests: use these values instead (nil: resolve again).
    public static func overrideForTesting(_ value: Base?) {
        lock.lock(); defer { lock.unlock() }
        chosen = value
    }

    /// Letters, digits, dots, dashes and underscores: it ends up in file names, launchd labels and code
    /// signing requirements, so nothing else is accepted.
    public static func isValidIdentifier(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 120 && text.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil
    }

    /// The first source that names a valid prefix wins; its app identifier is used when valid, else `<prefix>.app`.
    public static func resolve(environment: [String: String], infoDictionaries: [[String: Any]]) -> Base {
        var sources: [(prefix: String?, app: String?)] = [(environment[prefixEnvironmentVariable], environment[appEnvironmentVariable])]
        for info in infoDictionaries { sources.append((info[prefixKey] as? String, info[appKey] as? String)) }
        for source in sources {
            guard let prefix = source.prefix, isValidIdentifier(prefix) else { continue }
            return Base(prefix: prefix, app: source.app.flatMap { isValidIdentifier($0) ? $0 : nil })
        }
        return .standard
    }

    /// The running app's Info.plist, then that of the app the program sits in (nearest `.app` above it).
    static func infoDictionaries(executablePath: String) -> [[String: Any]] {
        var found: [[String: Any]] = []
        if let main = Bundle.main.infoDictionary { found.append(main) }
        if let info = enclosingAppInfo(of: executablePath) { found.append(info) }
        return found
    }

    /// The Info.plist of the nearest `.app` folder above `path`, or nil.
    public static func enclosingAppInfo(of path: String) -> [String: Any]? {
        var url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        while url.path != "/" {
            url.deleteLastPathComponent()
            if url.pathExtension == "app" {
                let plist = url.appendingPathComponent("Contents/Info.plist")
                guard let data = try? Data(contentsOf: plist),
                      let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
                return info
            }
        }
        return nil
    }
}
