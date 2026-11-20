import Foundation

/// The VM library: every bundle in the default directory plus bundles registered from elsewhere.
public final class VMLibrary: @unchecked Sendable {
    public static let appDirectoryName = "Tandem"

    public let rootDirectory: URL
    /// Where VMs are kept unless the user chose another folder.
    public var defaultVMsDirectory: URL { rootDirectory.appendingPathComponent("VMs", isDirectory: true) }
    /// Where new and imported VMs go: the folder the user chose, or the default one.
    public var vmsDirectory: URL {
        readRegistry().vmsDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultVMsDirectory
    }
    private var registryURL: URL { rootDirectory.appendingPathComponent("registry.json") }
    private let fm = FileManager.default

    private struct RegistryFile: Codable {
        var externalBundles: [String] = []
        var vmsDirectory: String?
    }

    public static func defaultRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appDirectoryName, isDirectory: true)
    }

    public init(rootDirectory: URL = VMLibrary.defaultRoot()) throws {
        self.rootDirectory = rootDirectory
        try fm.createDirectory(at: rootDirectory.appendingPathComponent("VMs"), withIntermediateDirectories: true)
    }

    private func readRegistry() -> RegistryFile {
        guard let data = try? Data(contentsOf: registryURL),
              let file = try? JSONDecoder().decode(RegistryFile.self, from: data) else { return RegistryFile() }
        return file
    }

    private func writeRegistry(_ file: RegistryFile) throws {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(file).write(to: registryURL, options: .atomic)
    }

    public struct Listing: Sendable {
        public var bundles: [VMBundle]
        /// Bundles that exist but could not be loaded, with the reason.
        public var failures: [(url: URL, reason: String)]
    }

    public func list() -> Listing {
        // VMs made before the folder was changed stay listed, so both folders are read.
        // A chosen folder that is missing (a disk that is not plugged in) simply lists nothing.
        let folders = libraryFolders
        var urls = folders.flatMap { folder in
            (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == VMBundle.pathExtension } ?? []
        }
        urls += readRegistry().externalBundles.map { URL(fileURLWithPath: $0) }
        var listing = Listing(bundles: [], failures: [])
        var seen = Set<UUID>()
        for url in urls.sorted(by: { $0.path < $1.path }) {
            do {
                let bundle = try VMBundle.load(from: url)
                if seen.insert(bundle.id).inserted { listing.bundles.append(bundle) }
            } catch {
                listing.failures.append((url, error.localizedDescription))
            }
        }
        listing.bundles.sort { $0.config.name.localizedCaseInsensitiveCompare($1.config.name) == .orderedAscending }
        return listing
    }

    /// Chooses the folder for new and imported VMs; nil goes back to the default. Existing VMs do not move.
    public func setVMsDirectory(_ url: URL?) throws {
        var file = readRegistry()
        if let url, url.standardizedFileURL != defaultVMsDirectory.standardizedFileURL {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            guard fm.isWritableFile(atPath: url.path) else {
                throw VMError("Tandem cannot write to “\(url.lastPathComponent)”.", detail: url.path)
            }
            file.vmsDirectory = url.standardizedFileURL.path
        } else {
            file.vmsDirectory = nil
        }
        try writeRegistry(file)
    }

    public func create(_ config: VMConfig, createDisks: Bool = true) throws -> VMBundle {
        let folder = vmsDirectory
        guard fm.fileExists(atPath: folder.path) else {
            throw VMError("The virtual machines folder is not available.", detail: "\(folder.path)\nConnect its disk, or choose another folder in Preferences.")
        }
        if list().bundles.contains(where: { $0.config.name == config.name }) {
            throw VMError("A VM named “\(config.name)” already exists.")
        }
        return try VMBundle.create(config: config, in: folder, createDisks: createDisks)
    }

    /// Finds a VM by exact name, full UUID, or unique UUID prefix.
    public func find(_ key: String) throws -> VMBundle {
        let all = list().bundles
        let matches = all.filter {
            $0.config.name == key || $0.id.uuidString.lowercased().hasPrefix(key.lowercased())
        }
        switch matches.count {
        case 1: return matches[0]
        case 0: throw VMError("No VM matches “\(key)”.")
        default: throw VMError("“\(key)” matches \(matches.count) VMs. Use the full ID.")
        }
    }

    /// The folders whose bundles are listed without being registered: the default one and the chosen one.
    public var libraryFolders: [URL] {
        var folders = [defaultVMsDirectory]
        let chosen = vmsDirectory
        if chosen.standardizedFileURL != defaultVMsDirectory.standardizedFileURL { folders.append(chosen) }
        return folders
    }

    /// Whether a bundle sits directly in one of the library's folders (and so is listed anyway).
    public func isInLibraryFolder(_ url: URL) -> Bool {
        let parent = url.resolvingSymlinksInPath().standardizedFileURL.deletingLastPathComponent().path
        return libraryFolders.contains { $0.resolvingSymlinksInPath().standardizedFileURL.path == parent }
    }

    /// Registers a bundle kept outside the library's folders. One inside them is listed already and is
    /// not written to the registry.
    public func register(externalBundleAt url: URL) throws -> VMBundle {
        let bundle = try VMBundle.load(from: url)
        guard !isInLibraryFolder(url) else { return bundle }
        var file = readRegistry()
        if !file.externalBundles.contains(url.path) { file.externalBundles.append(url.path) }
        try writeRegistry(file)
        return bundle
    }

    /// Drops registry entries that point into the library's own folders (they are listed anyway) or at a
    /// bundle that is gone. A bundle on a disk that is not connected is kept, so it comes back when the
    /// disk does. Returns the paths dropped.
    @discardableResult
    public func pruneRegistry() -> [String] {
        var file = readRegistry()
        let before = file.externalBundles
        file.externalBundles = before.filter { path in
            let url = URL(fileURLWithPath: path)
            if isInLibraryFolder(url) { return false }
            if fm.fileExists(atPath: path) { return true }
            return !Self.volumeIsMounted(for: url)
        }
        guard file.externalBundles != before else { return [] }
        try? writeRegistry(file)
        return before.filter { !file.externalBundles.contains($0) }
    }

    /// False for a path on an external volume (/Volumes/<name>/…) whose volume is not mounted.
    static func volumeIsMounted(for url: URL) -> Bool {
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count > 2, parts[1] == "Volumes" else { return true }
        return FileManager.default.fileExists(atPath: "/Volumes/" + parts[2])
    }

    /// Deletes the bundle from disk and forgets it.
    public func delete(_ bundle: VMBundle, toTrash: Bool = false) throws {
        try bundle.delete(toTrash: toTrash)
        var file = readRegistry()
        file.externalBundles.removeAll { $0 == bundle.url.path }
        try writeRegistry(file)
    }
}
