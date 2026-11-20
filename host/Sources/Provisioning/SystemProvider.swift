import Foundation
import VMCore

// "Free Systems": Tandem fetches a system for the user and makes a VM from it.
//
// A `SystemProvider` knows one source (a Linux vendor's ready-made images, Microsoft's Windows
// catalogue, Apple's macOS restore images). The app's assistant and `vmctl` both drive providers
// the same way:
//
//   1. `options()`      what can be downloaded right now
//   2. the caller makes an empty VM from `defaults(for:)` and the user's choices
//   3. `prepare(...)`   downloads, then leaves that VM ready for its first start
//
// Providers register in `SystemCatalog`; the assistant shows a tile for each slot that has one.

/// One thing a provider can download, as shown in a list.
public struct SystemOption: Identifiable, Hashable, Sendable {
    /// Stable within the provider; also what `vmctl --download <provider>:<id>` takes.
    public var id: String
    public var title: String
    /// One line under the title: version, what kind of system it is.
    public var detail: String
    public var downloadBytes: Int64?
    /// Options that are one system in different flavours (Ubuntu Desktop with MATE, Xfce or GNOME) share
    /// a group: the list shows the group once, with a picker of the `variant` names.
    public var variantGroup: String?
    public var variant: String?

    public init(id: String, title: String, detail: String, downloadBytes: Int64? = nil, variantGroup: String? = nil, variant: String? = nil) {
        self.id = id; self.title = title; self.detail = detail; self.downloadBytes = downloadBytes
        self.variantGroup = variantGroup; self.variant = variant
    }

    /// The options as a list shows them: a system offered in several flavours appears once, as the
    /// selected flavour, else the one last picked (`preferred`), else the first one offered.
    public static func listing(_ all: [SystemOption], preferring preferred: String?, selected: SystemOption?) -> [SystemOption] {
        var seen = Set<String>()
        return all.compactMap { item in
            guard let group = item.variantGroup else { return item }
            guard seen.insert(group).inserted else { return nil }
            if let selected, selected.variantGroup == group { return selected }
            return all.first { $0.variantGroup == group && $0.variant == preferred } ?? item
        }
    }
}

/// What a new VM of a downloaded system starts with. The user can change it before creating.
public struct SystemDefaults: Equatable, Sendable {
    public var name: String
    public var cpuCount: Int
    public var memoryMiB: Int
    public var diskGiB: Int
    /// The least disk the system can be put on (a ready-made disk cannot shrink).
    public var minimumDiskGiB: Int

    public init(name: String, cpuCount: Int = 4, memoryMiB: Int = 4096, diskGiB: Int = 64, minimumDiskGiB: Int = 8) {
        self.name = name; self.cpuCount = cpuCount; self.memoryMiB = memoryMiB; self.diskGiB = diskGiB; self.minimumDiskGiB = minimumDiskGiB
    }
}

/// The account made inside the new system.
public struct SystemAccount: Equatable, Sendable {
    public var userName: String
    /// Optional: empty means an account without a password (sign-in without one, `sudo` without one).
    public var password: String
    /// Go straight to the desktop (or the console) at every start.
    public var autoLogin: Bool
    public init(userName: String, password: String, autoLogin: Bool = true) {
        self.userName = userName; self.password = password; self.autoLogin = autoLogin
    }
    public var hasPassword: Bool { !password.isEmpty }

    /// Characters no setup file can carry safely: control characters (XML cannot hold them at all, a
    /// login prompt cannot take them, NUL ends a C string) and the invisible U+FEFF, which parsers drop
    /// at the start of a value (found by the fuzz tests: a password of U+FEFF came back empty).
    public static func hasUnsupportedCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { s in
            s.value < 0x20 || (0x7F...0x9F).contains(s.value) || s.value == 0xFEFF || s.value == 0xFFFE || s.value == 0xFFFF
        }
    }

    /// What is wrong with the password whatever the system, in sentences to show the user.
    public var passwordProblems: [String] {
        Self.hasUnsupportedCharacters(password) ? ["The password must not contain control characters or invisible characters."] : []
    }
}

/// Where a provider is in its work. `fraction` nil means it cannot tell (show an indeterminate bar).
public struct ProvisioningProgress: Equatable, Sendable {
    /// Short and in the present tense: "Downloading Ubuntu Server", "Preparing the disk".
    public var phase: String
    public var fraction: Double?
    /// Optional second line: "412 MB of 1.2 GB, 18 MB/s".
    public var detail: String?

    public init(_ phase: String, fraction: Double? = nil, detail: String? = nil) {
        self.phase = phase; self.fraction = fraction; self.detail = detail
    }
}

/// Starts a VM without a display and returns once its guest has powered itself off; throws on an error,
/// on cancellation (the VM is stopped) and after `timeout` seconds. Supplied by the caller, which owns
/// the engines.
public typealias BootUntilPowerOff = @Sendable (VMBundle, TimeInterval) async throws -> Void

/// Everything a provider is handed besides the VM itself. Providers live below the engines, so the
/// caller supplies the engine-side tools they may need.
public struct ProvisioningContext: Sendable {
    /// Shared download cache: `<library root>/Downloads`.
    public var downloads: Downloader
    public var account: SystemAccount?
    /// `qemu-img`, for providers that convert or grow disk images.
    public var qemuImg: URL?
    /// The Windows guest agent and driver disc, for providers that build an unattended Windows install.
    public var windowsAgent: URL?
    public var virtioISO: URL?
    public var progress: @Sendable (ProvisioningProgress) -> Void
    /// Lets a provider run a hidden VM (to make a template). Without it, no templates are made or used.
    public var bootUntilPowerOff: BootUntilPowerOff?
    /// Make and use templates when the provider supports them (`vmctl --no-template` turns this off).
    public var useTemplates: Bool

    public init(downloads: Downloader, account: SystemAccount? = nil, qemuImg: URL? = nil, windowsAgent: URL? = nil,
                virtioISO: URL? = nil, bootUntilPowerOff: BootUntilPowerOff? = nil, useTemplates: Bool = true,
                progress: @escaping @Sendable (ProvisioningProgress) -> Void = { _ in }) {
        self.downloads = downloads; self.account = account; self.qemuImg = qemuImg
        self.windowsAgent = windowsAgent; self.virtioISO = virtioISO; self.progress = progress
        self.bootUntilPowerOff = bootUntilPowerOff; self.useTemplates = useTemplates
    }

    /// Downloads with the progress shown as one phase.
    public func download(_ request: DownloadRequest, phase: String) async throws -> URL {
        let report = progress
        report(ProvisioningProgress(phase, fraction: downloads.isCached(request) ? 1 : nil))
        return try await downloads.fetch(request) { p in
            report(ProvisioningProgress(phase, fraction: p.fraction, detail: p.summary))
        }
    }
}

/// What the caller should do once `prepare` returns.
public enum ProvisioningOutcome: Equatable, Sendable {
    /// Start the VM now: its first start finishes the setup (first boot of a ready-made disk, an
    /// unattended install) and should happen without the user having to ask.
    case startNow
    /// The VM is complete; leave it stopped.
    case ready
}

public enum ProviderAvailability: Equatable, Sendable {
    case available
    /// Shown on the tile in place of making it clickable.
    case unavailable(String)
}

public protocol SystemProvider: Sendable {
    /// Which tile this provider fills: `SystemCatalog.linux`, `.windows` or `.macOS`.
    var slot: String { get }
    /// The tile's text: "Download a Linux system".
    var title: String { get }
    /// What the options page says above the list: where the systems come from.
    var sourceNote: String { get }
    var guestOS: GuestOS { get }
    /// The engine the VM must be created on (macOS guests need `.vz`).
    var engine: EngineKind { get }
    /// True when `prepare` makes a user account and so needs a name and a password.
    var wantsAccount: Bool { get }
    /// True when an empty password is acceptable for that account.
    var allowsEmptyPassword: Bool { get }
    /// Checked on this Mac, without the network.
    var availability: ProviderAvailability { get }

    /// What can be downloaded now. Needs the network; throws a `VMError` worth showing when offline.
    func options(using downloads: Downloader) async throws -> [SystemOption]

    func defaults(for option: SystemOption) -> SystemDefaults

    /// What is wrong with an account for this system, in sentences to show the user. Empty when it is fine.
    func accountProblems(_ account: SystemAccount) -> [String]

    /// Last word on the configuration before the VM is made: disk bus and format, firmware, anything
    /// the system needs that the caller's generic `VMConfig` does not have.
    func adjust(_ config: inout VMConfig, for option: SystemOption)

    /// Downloads the option's files into the cache without making a VM (`vmctl download get`).
    func fetch(_ option: SystemOption, context: ProvisioningContext) async throws -> [URL]

    /// Turns the empty VM in `bundle` into one that is ready for its first start. The caller has made
    /// the bundle (and, on the QEMU engine, an empty disk of the chosen size) and deletes it if this
    /// throws. Saves the bundle's configuration when it changes it. Honours task cancellation.
    func prepare(_ option: SystemOption, bundle: inout VMBundle, context: ProvisioningContext) async throws -> ProvisioningOutcome
}

public extension SystemProvider {
    var allowsEmptyPassword: Bool { false }
    var availability: ProviderAvailability { .available }
    func adjust(_ config: inout VMConfig, for option: SystemOption) {}
    func accountProblems(_ account: SystemAccount) -> [String] {
        (account.password.isEmpty && !allowsEmptyPassword ? ["Choose a password for the account."] : []) + account.passwordProblems
    }
}

/// The providers this build has, by tile.
public enum SystemCatalog {
    public static let windows = "windows", macOS = "macos", linux = "linux"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var registered: [String: any SystemProvider] = [linux: LinuxCloudImages(), windows: WindowsFromMicrosoft()]

    /// Adds or replaces the provider for its slot. Call before the assistant is shown.
    public static func register(_ provider: any SystemProvider) {
        lock.withLock { registered[provider.slot] = provider }
    }

    public static func provider(for slot: String) -> (any SystemProvider)? { lock.withLock { registered[slot] } }

    public static var all: [any SystemProvider] {
        lock.withLock { [windows, macOS, linux].compactMap { registered[$0] } }
    }

    /// The download cache of a library.
    public static func downloads(in libraryRoot: URL) -> Downloader {
        Downloader(cache: libraryRoot.appendingPathComponent("Downloads", isDirectory: true))
    }

    /// A marker in a bundle whose setup is still under way (or was interrupted): which provider and option.
    public static let markerFileName = "provisioning.json"
    public struct Marker: Codable, Equatable, Sendable {
        public var slot: String
        public var option: String
        public var title: String
        public init(slot: String, option: String, title: String) { self.slot = slot; self.option = option; self.title = title }
    }
    public static func writeMarker(_ marker: Marker, in bundle: VMBundle) throws {
        try JSONEncoder().encode(marker).write(to: bundle.url.appendingPathComponent(markerFileName), options: .atomic)
    }
    public static func marker(in bundle: VMBundle) -> Marker? {
        (try? Data(contentsOf: bundle.url.appendingPathComponent(markerFileName))).flatMap { try? JSONDecoder().decode(Marker.self, from: $0) }
    }
    public static func clearMarker(in bundle: VMBundle) {
        try? FileManager.default.removeItem(at: bundle.url.appendingPathComponent(markerFileName))
    }

    /// The whole of step 3, for callers that already have an empty VM: marker, prepare, marker gone.
    /// On failure or cancellation the marker stays, so the half-made VM is recognisable.
    public static func provision(_ provider: any SystemProvider, option: SystemOption, bundle: inout VMBundle,
                                 context: ProvisioningContext) async throws -> ProvisioningOutcome {
        try writeMarker(Marker(slot: provider.slot, option: option.id, title: option.title), in: bundle)
        let outcome = try await provider.prepare(option, bundle: &bundle, context: context)
        try Task.checkCancellation()
        clearMarker(in: bundle)
        return outcome
    }
}
