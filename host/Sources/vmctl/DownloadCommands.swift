import EngineQEMU
import Foundation
import Provisioning
import VMCore

// `vmctl download` and `vmctl create --download`: the assistant's "Free Systems" from the command line,
// through the same providers (`SystemCatalog`) and the same download cache.

private func byteText(_ bytes: Int64?) -> String {
    guard let bytes else { return "size unknown" }
    let f = ByteCountFormatter(); f.countStyle = .file
    return f.string(fromByteCount: bytes)
}

private func provider(_ slot: String) -> any SystemProvider {
    guard let provider = SystemCatalog.provider(for: slot) else {
        fail("no downloadable system called “\(slot)”. Known: \(SystemCatalog.all.map(\.slot).joined(separator: ", "))")
    }
    if case .unavailable(let why) = provider.availability { fail("\(provider.title) is not available on this Mac: \(why)") }
    return provider
}

/// Prints each phase once, and its progress every ten percent.
private func progressPrinter() -> @Sendable (ProvisioningProgress) -> Void {
    nonisolated(unsafe) var last = ""
    nonisolated(unsafe) var lastTime = Date.distantPast
    let lock = NSLock()
    return { p in
        let step = p.fraction.map { "\(Int($0 * 10) * 10)%" } ?? ""
        let line = p.phase + (step.isEmpty ? "" : " " + step)
        // A long phase without a fraction (a template being set up) is reported every half minute.
        let changed = lock.withLock { () -> Bool in
            let quiet = p.fraction == nil && p.detail != nil && Date().timeIntervalSince(lastTime) >= 30
            if line == last && !quiet { return false }
            last = line; lastTime = Date(); return true
        }
        if changed { print("download: \(line)\(p.detail.map { " (\($0))" } ?? "")") }
    }
}

private func choose(_ provider: any SystemProvider, _ id: String?, downloads: Downloader) async throws -> SystemOption {
    let options = try await provider.options(using: downloads)
    guard let id else { return options[0] }
    guard let option = options.first(where: { $0.id == id }) else {
        fail("“\(id)” is not offered. Choices: \(options.map(\.id).joined(separator: ", "))")
    }
    return option
}

/// `vmctl download list [system] [--json]` and `vmctl download get <system> [--option id]`.
func cmdDownload(_ args: Args) async throws {
    let downloads = SystemCatalog.downloads(in: openLibrary().rootDirectory)
    switch args.positional.first ?? "list" {
    case "list":
        let wanted = args.positional.dropFirst().first
        var rows: [[String: Any]] = []
        for provider in SystemCatalog.all where wanted == nil || provider.slot == wanted {
            if case .unavailable(let why) = provider.availability {
                if !args.flags.contains("json") { print("\(provider.slot): not available (\(why))") }
                continue
            }
            let options = try await provider.options(using: downloads)
            if !args.flags.contains("json") { print("\(provider.slot): \(provider.title)") }
            // Wide enough for the longest id, which must never be cut short: it is what `--download` takes.
            let idWidth = max(16, options.map(\.id.count).max() ?? 0)
            for option in options {
                rows.append(["system": provider.slot, "option": option.id, "title": option.title, "detail": option.detail,
                             "bytes": option.downloadBytes ?? NSNull()])
                if !args.flags.contains("json") {
                    print("  \(provider.slot):\(option.id.padding(toLength: idWidth, withPad: " ", startingAt: 0)) \(option.title), \(byteText(option.downloadBytes)). \(option.detail)")
                }
            }
        }
        if args.flags.contains("json") {
            print(String(decoding: try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        }
    case "get":
        guard args.positional.count >= 2 else { fail("download get needs a system, for example: vmctl download get linux --option ubuntu-24.04") }
        let provider = provider(args.positional[1])
        let option = try await choose(provider, args.options["option"], downloads: downloads)
        let context = ProvisioningContext(downloads: downloads, qemuImg: (try? QEMUToolchain.locate())?.qemuImg, progress: progressPrinter())
        for url in try await provider.fetch(option, context: context) { print(url.path) }
    default:
        fail("download takes list or get")
    }
}

/// `vmctl create <name> --download <system>[:option] [--user NAME --password TEXT]`.
func cmdCreateDownloaded(_ args: Args, spec: String) async throws {
    guard args.positional.count == 1 else { fail("create needs a name") }
    let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
    let provider = provider(parts[0])
    let library = openLibrary()
    let downloads = SystemCatalog.downloads(in: library.rootDirectory)
    var optionID = parts.count > 1 ? parts[1] : nil
    // --desktop mate|xfce|gnome picks the desktop of an Ubuntu Desktop choice (same as naming its option ID).
    if let name = args.options["desktop"] {
        guard let desktop = LinuxDesktop(rawValue: name.lowercased()) else {
            fail("--desktop takes one of: \(LinuxDesktop.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        guard let id = optionID, LinuxDesktop.from(optionID: id) != nil,
              let release = LinuxCloudImages.ubuntuReleases.first(where: { id.hasSuffix("-\($0)") }) else {
            fail("--desktop goes with an Ubuntu Desktop choice, for example --download linux:ubuntu-desktop-24.04 --desktop xfce")
        }
        optionID = desktop.optionID(release: release)
    }
    let option = try await choose(provider, optionID, downloads: downloads)

    var account: SystemAccount?
    if provider.wantsAccount {
        guard let user = args.options["user"] else { fail("\(option.title) needs an account: --user NAME [--password TEXT] [--no-auto-login]") }
        let password = args.options["password"] ?? ""
        if password.isEmpty && !provider.allowsEmptyPassword { fail("\(option.title) needs a password for its account: --password TEXT") }
        // Signs in by itself at every start unless --no-auto-login.
        account = SystemAccount(userName: user, password: password, autoLogin: !args.flags.contains("no-auto-login"))
    }

    let defaults = provider.defaults(for: option)
    var config = VMConfig(name: args.positional[0], guestOS: provider.guestOS, engine: provider.engine,
                          cpuCount: args.int("cpus") ?? defaults.cpuCount, memoryMiB: args.int("memory") ?? defaults.memoryMiB)
    let disk = args.int("disk") ?? defaults.diskGiB
    guard disk >= defaults.minimumDiskGiB else { fail("\(option.title) needs a disk of at least \(defaults.minimumDiskGiB) GiB") }
    config.disks[0].sizeGiB = disk
    provider.adjust(&config, for: option)

    var bundle = try library.create(config)
    do {
        var qemuImg: URL?
        if config.engine == .qemu {
            let toolchain = try QEMUToolchain.locate()
            try QEMUEngine.prepare(bundle: bundle, toolchain: toolchain, paths: QEMURunPaths.forVM(bundle.id))
            qemuImg = toolchain.qemuImg
        } else {
            qemuImg = (try? QEMUToolchain.locate())?.qemuImg
        }
        let context = ProvisioningContext(downloads: downloads, account: account, qemuImg: qemuImg, windowsAgent: GuestTools.windowsAgent,
                                          virtioISO: args.options["virtio-iso"].map { URL(fileURLWithPath: $0) },
                                          bootUntilPowerOff: { bundle, timeout in try await HeadlessRun.untilPowerOff(bundle, timeout: timeout) },
                                          useTemplates: !args.flags.contains("no-template"), progress: progressPrinter())
        let started = Date()
        let outcome = try await SystemCatalog.provision(provider, option: option, bundle: &bundle, context: context)
        print("Created \(bundle.config.name) (\(bundle.id.uuidString.lowercased())) from \(option.title) in \(Int(Date().timeIntervalSince(started))) s")
        print(bundle.url.path)
        if outcome == .startNow { print("Start it to finish its setup: vmctl start \"\(bundle.config.name)\"") }
    } catch {
        // Leave no half-made VM behind; what was downloaded stays in the cache.
        try? library.delete(bundle)
        throw error
    }
}

/// `vmctl templates list|delete`.
func cmdTemplates(_ args: Args) throws {
    let store = LinuxTemplateStore(libraryRoot: openLibrary().rootDirectory)
    switch args.positional.first ?? "list" {
    case "list":
        let entries = store.list()
        if args.flags.contains("json") {
            let rows: [[String: Any]] = entries.map { e in
                ["option": e.manifest.option, "title": e.manifest.title, "created": ISO8601DateFormatter().string(from: e.manifest.created),
                 "diskGiB": e.manifest.diskGiB, "allocatedBytes": e.allocatedBytes, "buildSeconds": Int(e.manifest.buildSeconds),
                 "path": e.disk.deletingLastPathComponent().path]
            }
            print(String(decoding: try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
            return
        }
        if entries.isEmpty { print("No templates. One is made the first time a Linux system is downloaded."); return }
        for e in entries {
            print("\(e.manifest.option)  \(e.manifest.title), \(byteText(e.allocatedBytes)) on disk (shared with VMs made from it), "
                  + "set up in \(Int(e.manifest.buildSeconds / 60)) min on \(e.manifest.created.formatted(date: .abbreviated, time: .shortened))")
        }
    case "delete":
        if args.flags.contains("all") {
            for e in store.list() { try store.delete(option: e.manifest.option); print("Deleted the template of \(e.manifest.title)") }
        } else {
            guard args.positional.count >= 2 else { fail("templates delete needs an option ID (see: vmctl templates list) or --all") }
            try store.delete(option: args.positional[1])
            print("Deleted the template \(args.positional[1])")
        }
    default:
        fail("templates takes list or delete")
    }
}
