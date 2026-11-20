import Foundation
import VMCore

/// "Get Windows 11 from Microsoft": downloads the current Windows 11 for ARM from Microsoft's own
/// servers, builds an install disc from it, and sets the new VM up to install itself.
///
/// The image is the one Microsoft's Media Creation Tool would fetch (see `WindowsCatalogue`). It
/// installs without a product key of the user's; Windows then needs the user's own licence to activate.
public struct WindowsFromMicrosoft: SystemProvider {
    public init() {}

    public let slot = SystemCatalog.windows
    public let title = "Get Windows 11 from Microsoft"
    public let sourceNote = "Windows 11 for ARM, downloaded from Microsoft’s servers (about 4.5 GB) and checked against Microsoft’s published checksum. Tandem builds an install disc from it and installs Windows without questions. Windows needs your own licence to activate."
    public let guestOS = GuestOS.windows11arm
    public let engine = EngineKind.qemu
    public let wantsAccount = true
    public let allowsEmptyPassword = true

    public var availability: ProviderAvailability {
        WindowsImageBuilder.wimlib == nil
            ? .unavailable("Needs the wimlib tool. \(WindowsImageBuilder.wimlibInstallHint)")
            : .available
    }

    // MARK: Options

    /// The editions offered from a consumer image, by option suffix. Both install from the same download.
    static let editions: [(suffix: String, id: String, name: String)] = [
        ("", "Professional", "Windows 11 Pro"),
        ("-home", "Core", "Windows 11 Home"),
    ]

    /// `en-us` → Pro, `en-us-home` → Home.
    static func parse(optionID: String) -> (languageCode: String, edition: (suffix: String, id: String, name: String)) {
        if optionID.hasSuffix("-home") { return (String(optionID.dropLast(5)), editions[1]) }
        return (optionID, editions[0])
    }

    /// The language to list first: the Mac's own when Microsoft offers it, else US English.
    static func preferredLanguage(among codes: [String], preferred: [String] = Locale.preferredLanguages) -> String? {
        let available = Set(codes)
        for language in preferred {
            let code = language.lowercased()
            if available.contains(code) { return code }
            // "en" or "en-AU" → the first offered variant of the same language, US English first.
            let base = code.split(separator: "-").first.map(String.init) ?? code
            if base == "en", available.contains("en-us") { return "en-us" }
            if let match = codes.first(where: { $0.split(separator: "-").first.map(String.init) == base }) { return match }
        }
        return available.contains("en-us") ? "en-us" : codes.first
    }

    /// Pro and Home in the preferred language first, then Pro in every other language.
    /// (`<language>-home` works for any language from `vmctl` even though it is not listed.)
    static func options(from images: [WindowsCatalogue.Image], preferred: [String] = Locale.preferredLanguages) -> [SystemOption] {
        func option(_ image: WindowsCatalogue.Image, _ edition: (suffix: String, id: String, name: String)) -> SystemOption {
            SystemOption(id: image.languageCode + edition.suffix, title: "\(edition.name), \(image.language)",
                         detail: image.build.isEmpty ? "Current release from Microsoft" : "Build \(image.build) from Microsoft",
                         downloadBytes: image.bytes)
        }
        let first = preferredLanguage(among: images.map(\.languageCode), preferred: preferred)
        var result: [SystemOption] = []
        if let image = images.first(where: { $0.languageCode == first }) {
            for edition in editions where image.editions.isEmpty || image.editions.contains(edition.id) { result.append(option(image, edition)) }
        }
        for image in images.sorted(by: { $0.language < $1.language }) where image.languageCode != first {
            result.append(option(image, editions[0]))
        }
        return result
    }

    public func options(using downloads: Downloader) async throws -> [SystemOption] {
        Self.options(from: try await WindowsCatalogue.load(using: downloads))
    }

    public func defaults(for option: SystemOption) -> SystemDefaults {
        SystemDefaults(name: "Windows 11", cpuCount: min(4, ProcessInfo.processInfo.processorCount), memoryMiB: 8192, diskGiB: 64, minimumDiskGiB: 40)
    }

    // MARK: Download and build

    static func discName(for image: WindowsCatalogue.Image) -> String {
        (image.fileName as NSString).deletingPathExtension + ".iso"
    }

    private func image(for option: SystemOption, using downloads: Downloader) async throws -> WindowsCatalogue.Image {
        let wanted = Self.parse(optionID: option.id).languageCode
        guard let image = try await WindowsCatalogue.load(using: downloads).first(where: { $0.languageCode == wanted }) else {
            throw VMError("“\(option.title)” is no longer offered for download.", detail: "Microsoft's list has no Windows 11 for ARM in the language “\(wanted)”.")
        }
        return image
    }

    /// The install disc for an image, from the cache or downloaded and built now.
    private func installDisc(for image: WindowsCatalogue.Image, title: String, context: ProvisioningContext) async throws -> URL {
        let iso = context.downloads.cache.appendingPathComponent(Self.discName(for: image))
        // A finished disc is moved into place in one step, so one that exists is whole.
        if FileManager.default.fileExists(atPath: iso.path) {
            context.progress(ProvisioningProgress("Using the Windows install disc downloaded earlier", fraction: 1))
            return iso
        }
        guard WindowsImageBuilder.wimlib != nil else {
            throw VMError("Getting Windows from Microsoft needs the wimlib tool.", detail: WindowsImageBuilder.wimlibInstallHint)
        }
        let request = DownloadRequest(url: image.url, fileName: image.fileName, checksum: .sha1(image.sha1), expectedBytes: image.bytes)
        let esd = try await context.download(request, phase: "Downloading \(title)")
        try Task.checkCancellation()
        let report = context.progress
        try await WindowsImageBuilder.build(from: esd, to: iso) { step in report(ProvisioningProgress("Building the install disc", detail: step)) }
        // The disc holds everything the download did; keeping both would cost another 4.5 GB.
        context.downloads.remove(request)
        return iso
    }

    public func fetch(_ option: SystemOption, context: ProvisioningContext) async throws -> [URL] {
        context.progress(ProvisioningProgress("Asking Microsoft for \(option.title)"))
        let image = try await image(for: option, using: context.downloads)
        return [try await installDisc(for: image, title: option.title, context: context)]
    }

    // MARK: Driver disc

    /// The VirtIO driver disc Tandem's Windows VMs are tested with, from the project that publishes it.
    static let driverDisc = DownloadRequest(
        url: URL(string: "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.302-1/virtio-win-0.1.302.iso")!,
        fileName: "virtio-win-0.1.302.iso",
        checksum: .sha256("303f7ae40dad495d6ae474fdc571df58958a4dbc5c37a522d80f9a203867949d"),
        expectedBytes: 877_373_440)

    /// A driver disc already on this Mac: the one the caller named, or one in Tandem's own folders.
    static func localDriverDisc(named: URL?, cache: URL, extraFolders: [URL] = [VMLibrary.defaultRoot()]) -> URL? {
        let fm = FileManager.default
        if let named, fm.fileExists(atPath: named.path) { return named }
        for folder in [cache] + extraFolders {
            let names = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).sorted().reversed()
            if let name = names.first(where: { $0.lowercased().hasPrefix("virtio-win") && $0.lowercased().hasSuffix(".iso") }) {
                return folder.appendingPathComponent(name)
            }
        }
        return nil
    }

    // MARK: Prepare

    /// A Windows computer name from the VM's name: letters, digits and hyphens, 15 at most.
    static func computerName(from name: String) -> String {
        let mapped = name.uppercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }
        let joined = String(mapped).split(separator: "-").joined(separator: "-")
        let trimmed = String(joined.prefix(15)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "TANDEM-VM" : trimmed
    }

    public func prepare(_ option: SystemOption, bundle: inout VMBundle, context: ProvisioningContext) async throws -> ProvisioningOutcome {
        guard bundle.config.guestOS == .windows11arm, bundle.config.engine == .qemu else {
            throw VMError("“\(bundle.config.name)” is not a Windows VM on the QEMU engine.")
        }
        guard let account = context.account, !account.userName.isEmpty else {
            throw VMError("Windows needs an account name to set up.")
        }
        let choice = Self.parse(optionID: option.id)
        context.progress(ProvisioningProgress("Asking Microsoft for \(option.title)"))
        let image = try await image(for: option, using: context.downloads)
        let answers = WindowsUnattendOptions(computerName: Self.computerName(from: bundle.config.name), userName: account.userName,
                                             password: account.password, locale: image.locale, edition: choice.edition.name,
                                             autoLogin: account.autoLogin)
        // Before anything large is downloaded.
        let problems = answers.validate()
        guard problems.isEmpty else { throw VMError("The Windows account cannot be set up as given.", detail: problems.joined(separator: "\n")) }

        let iso = try await installDisc(for: image, title: option.title, context: context)
        try Task.checkCancellation()

        // Drivers for the network, the display and the guest tools' channel. Without them Windows
        // installs but has no network, so a missing disc is fetched rather than left out.
        let drivers: URL
        if let local = Self.localDriverDisc(named: context.virtioISO, cache: context.downloads.cache) {
            drivers = local
        } else {
            drivers = try await context.download(Self.driverDisc, phase: "Downloading Windows drivers")
        }
        try Task.checkCancellation()

        context.progress(ProvisioningProgress("Writing the setup disc"))
        bundle.config.removableMedia.removeAll { $0.kind == .installerISO }
        bundle.config.removableMedia.insert(RemovableMedia(file: iso.path, kind: .installerISO), at: 0)
        try WindowsInstall.prepare(&bundle, options: answers, virtioISO: drivers, agent: context.windowsAgent ?? GuestTools.windowsAgent)
        return .startNow
    }
}
