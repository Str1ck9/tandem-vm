import Foundation
import Provisioning
import Virtualization
import VMCore

/// "Download macOS": a new macOS VM from Apple's own restore image.
///
/// Apple's Virtualization framework names the newest macOS restore image (`.ipsw`) this Mac can run
/// as a guest, Tandem downloads it from Apple, and the framework's installer puts macOS on the new
/// VM's disk. The provider lives in `EngineVZ` and not beside the other providers because every step
/// needs the framework, and because the VM it installs into must be configured exactly as the engine
/// will run it (`VZConfigurationBuilder`). The app and `vmctl` register it at start-up.
///
/// What Tandem cannot do for the user: after the install macOS starts with Apple's Setup Assistant
/// (language, account), which has no unattended mode.
public struct MacOSRestoreImages: SystemProvider {
    public init() {}

    public let slot = SystemCatalog.macOS
    public let title = "Download macOS"
    public let sourceNote = "The newest macOS this Mac can run as a virtual machine, downloaded from Apple and installed by Apple's own installer. Apple publishes no checksum for it, so Tandem checks its size and that the installer accepts it. When the installation has finished, macOS starts with Apple's Setup Assistant in the virtual machine's window, where you choose the language and make your account."
    public let guestOS = GuestOS.macos
    public let engine = EngineKind.vz
    public let wantsAccount = false

    /// Adds this provider to the catalogue. Call once at start-up.
    public static func register() { SystemCatalog.register(MacOSRestoreImages()) }

    public var availability: ProviderAvailability {
        #if arch(arm64)
        return VZVirtualMachine.isSupported ? .available : .unavailable("This Mac cannot run virtual machines.")
        #else
        return .unavailable("macOS virtual machines need a Mac with Apple silicon.")
        #endif
    }

    // MARK: What Apple offers

    /// The facts of a restore image that the rest of the provider needs, free of framework types.
    struct Release: Equatable, Sendable {
        var version: String
        var build: String
        var url: URL
        var hardwareModel: Data
        var minimumCPUCount: Int
        var minimumMemoryMiB: Int

        var optionID: String { "macos-" + build.lowercased() }
        var fileName: String { url.lastPathComponent.isEmpty ? "macOS-\(build).ipsw" : url.lastPathComponent }
    }

    static func release(of image: VZMacOSRestoreImage) throws -> Release {
        let v = image.operatingSystemVersion
        let version = v.patchVersion == 0 ? "\(v.majorVersion).\(v.minorVersion)" : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        guard let requirements = image.mostFeaturefulSupportedConfiguration, requirements.hardwareModel.isSupported else {
            throw VMError("This Mac cannot run macOS \(version) as a virtual machine.",
                          detail: "Apple's restore image \(image.buildVersion) has no configuration this Mac supports. Updating macOS on this Mac may help.")
        }
        return Release(version: version, build: image.buildVersion, url: image.url,
                       hardwareModel: requirements.hardwareModel.dataRepresentation,
                       minimumCPUCount: requirements.minimumSupportedCPUCount,
                       minimumMemoryMiB: Int(requirements.minimumSupportedMemorySize >> 20))
    }

    /// Asks Apple's catalogue, through the framework, for the newest restore image this Mac supports.
    static func latestRelease() async throws -> Release {
        do {
            return try release(of: try await VZMacOSRestoreImage.latestSupported)
        } catch let error as VMError {
            throw error
        } catch {
            throw VMError("Apple's list of macOS restore images could not be read.",
                          detail: "\(error.localizedDescription) Check the Internet connection. (The program asking must be signed with the virtualization entitlement, as Tandem and vmctl are.)")
        }
    }

    static func option(for release: Release, downloadBytes: Int64?) -> SystemOption {
        SystemOption(id: release.optionID, title: "macOS \(release.version)",
                     detail: "Build \(release.build), from Apple. Installing takes 10 to 20 minutes after the download; you then finish in Apple's Setup Assistant.",
                     downloadBytes: downloadBytes)
    }

    static func request(for release: Release, bytes: Int64?) -> DownloadRequest {
        DownloadRequest(url: release.url, fileName: release.fileName, expectedBytes: bytes)
    }

    public func options(using downloads: Downloader) async throws -> [SystemOption] {
        let release = try await Self.latestRelease()
        return [Self.option(for: release, downloadBytes: await downloads.size(of: release.url))]
    }

    public func defaults(for option: SystemOption) -> SystemDefaults {
        SystemDefaults(name: "macOS", cpuCount: min(4, ProcessInfo.processInfo.processorCount), memoryMiB: 8192,
                       diskGiB: 64, minimumDiskGiB: MacOSInstall.minimumDiskGiB)
    }

    public func adjust(_ config: inout VMConfig, for option: SystemOption) {
        // A size the guest's own display settings offer, and sharp enough for the Setup Assistant.
        config.display = DisplayConfig(width: 1920, height: 1200, dynamicResize: config.display.dynamicResize)
    }

    public func fetch(_ option: SystemOption, context: ProvisioningContext) async throws -> [URL] {
        let release = try await Self.latestRelease()
        return [try await download(release, context: context, installedDiskGiB: 0)]
    }

    /// Downloads the restore image (or finds it in the cache) and makes sure Apple's framework reads it.
    private func download(_ release: Release, context: ProvisioningContext, installedDiskGiB: Int) async throws -> URL {
        let bytes = await context.downloads.size(of: release.url)
        let request = Self.request(for: release, bytes: bytes)
        let cached = context.downloads.isCached(request)
        let partial = (try? context.downloads.partialURL(request).resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        try MacOSInstall.checkDiskSpace(freeBytes: MacOSInstall.freeBytes(at: context.downloads.cache),
                                        downloadBytes: cached ? 0 : max((bytes ?? MacOSInstall.typicalImageBytes) - partial, 0),
                                        installBytes: Int64(installedDiskGiB > 0 ? MacOSInstall.typicalInstalledGiB : 0) << 30)
        let file = try await context.download(request, phase: "Downloading macOS \(release.version)")
        context.progress(ProvisioningProgress("Checking the macOS restore image"))
        do {
            if let bytes, let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(size) != bytes {
                throw VMError("The file is \(size) bytes; Apple's server says \(bytes).")
            }
            let image = try await VZMacOSRestoreImage.image(from: file)
            guard image.buildVersion == release.build else { throw VMError("It is build \(image.buildVersion), not \(release.build).") }
        } catch {
            context.downloads.remove(request)
            throw VMError("The downloaded macOS restore image is damaged and was deleted.",
                          detail: "\(error.localizedDescription) Try again; the download starts over.")
        }
        return file
    }

    public func prepare(_ option: SystemOption, bundle: inout VMBundle, context: ProvisioningContext) async throws -> ProvisioningOutcome {
        let release = try await Self.latestRelease()
        guard option.id == release.optionID else {
            throw VMError("\(option.title) is no longer the macOS Apple offers for this Mac.", detail: "Apple now offers build \(release.build). Choose it from the list again.")
        }
        guard bundle.config.guestOS == .macos, bundle.config.engine == .vz, let disk = bundle.config.disks.first else {
            throw VMError("“\(bundle.config.name)” is not a macOS virtual machine on Apple's Virtualization engine.")
        }
        let restoreImage = try await download(release, context: context, installedDiskGiB: disk.sizeGiB)
        try Task.checkCancellation()

        context.progress(ProvisioningProgress("Preparing the virtual machine"))
        try MacOSInstall.layOut(&bundle, release: release)
        try Task.checkCancellation()

        try await MacOSInstall.install(restoreImage, into: bundle, version: release.version, progress: context.progress)
        bundle.config.install = InstallInfo(state: .complete)
        // The tools disc is there from the first start (not during Apple's install), ready once Setup
        // Assistant is done.
        if GuestTools.macOSAgent != nil {
            bundle.config.guestTools.toolsDiscRequested = Date()
            bundle.config.guestTools.toolsDiscAttached = true
        }
        try bundle.save()
        // The first start is Apple's Setup Assistant, which needs the user at the VM's window.
        return .startNow
    }
}

/// Making and installing a macOS VM. Separate from the provider so that the file layout and the
/// checks can be tested without Apple's servers.
enum MacOSInstall {
    /// Apple's installer needs room for the system, its snapshot and a first update.
    static let minimumDiskGiB = 40
    /// Used for the disk-space check when the server does not state the size.
    static let typicalImageBytes: Int64 = 20 << 30
    /// What a fresh install really occupies on the Mac's disk (the VM's disk is sparse).
    static let typicalInstalledGiB = 25

    static func freeBytes(at url: URL) -> Int64 {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" { probe.deleteLastPathComponent() }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? .max
    }

    /// Refuses before a 20 GB download rather than failing after it.
    static func checkDiskSpace(freeBytes: Int64, downloadBytes: Int64, installBytes: Int64) throws {
        let needed = downloadBytes + installBytes + (2 << 30)
        guard freeBytes >= needed else {
            let f = ByteCountFormatter(); f.countStyle = .file
            throw VMError("There is not enough free disk space for macOS.",
                          detail: "About \(f.string(fromByteCount: needed)) is needed (\(f.string(fromByteCount: downloadBytes)) to download, \(f.string(fromByteCount: installBytes)) for the installed system) and \(f.string(fromByteCount: freeBytes)) is free.")
        }
    }

    /// Writes the three files a macOS guest is tied to (hardware model, a new machine identifier, its
    /// auxiliary storage), raises processors and memory to what this macOS needs, and saves the
    /// configuration. The disk was made by `VMBundle.create`.
    static func layOut(_ bundle: inout VMBundle, release: MacOSRestoreImages.Release) throws {
        guard let model = VZMacHardwareModel(dataRepresentation: release.hardwareModel), model.isSupported else {
            throw VMError("This Mac cannot run macOS \(release.version) as a virtual machine.")
        }
        guard let disk = bundle.config.disks.first, disk.sizeGiB >= minimumDiskGiB else {
            throw VMError("macOS needs a disk of at least \(minimumDiskGiB) GB.")
        }
        guard FileManager.default.fileExists(atPath: bundle.diskURL(disk).path) else {
            throw VMError("The virtual machine's disk is missing: \(bundle.diskURL(disk).lastPathComponent)")
        }
        do {
            try model.dataRepresentation.write(to: bundle.hardwareModelURL, options: .atomic)
            try VZMacMachineIdentifier().dataRepresentation.write(to: bundle.machineIdentifierURL, options: .atomic)
            _ = try VZMacAuxiliaryStorage(creatingStorageAt: bundle.auxiliaryStorageURL, hardwareModel: model, options: [.allowOverwrite])
        } catch {
            throw VMError("The macOS virtual machine's files could not be made.", detail: error.localizedDescription)
        }
        bundle.config.cpuCount = max(bundle.config.cpuCount, release.minimumCPUCount)
        bundle.config.memoryMiB = max(bundle.config.memoryMiB, release.minimumMemoryMiB)
        bundle.config.install = InstallInfo(state: .installing)
        try bundle.save()
    }

    /// Runs Apple's installer on the VM as the engine will later run it. The VM is created and
    /// installed on the main queue, which is where the engine keeps its VMs too.
    @MainActor
    static func install(_ restoreImage: URL, into bundle: VMBundle, version: String,
                        progress: @escaping @Sendable (ProvisioningProgress) -> Void) async throws {
        let phase = "Installing macOS \(version)"
        let configuration = try VZConfigurationBuilder.build(for: bundle)
        let machine = VZVirtualMachine(configuration: configuration)
        let installer = VZMacOSInstaller(virtualMachine: machine, restoringFromImageAt: restoreImage)
        progress(ProvisioningProgress(phase, fraction: 0))
        let observation = installer.progress.observe(\.fractionCompleted, options: [.new]) { installProgress, _ in
            progress(ProvisioningProgress(phase, fraction: min(max(installProgress.fractionCompleted, 0), 1)))
        }
        defer { observation.invalidate() }
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    installer.install { result in continuation.resume(with: result) }
                }
            } onCancel: {
                DispatchQueue.main.async { installer.progress.cancel() }
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw VMError("macOS could not be installed.", detail: error.localizedDescription)
        }
        try Task.checkCancellation()
    }
}
