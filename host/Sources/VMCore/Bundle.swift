import Foundation

/// One VM on disk: a directory holding `config.json` and the VM's files.
public struct VMBundle: Sendable, Identifiable, Equatable {
    public static let pathExtension = "tandemvm"
    public static let configFileName = "config.json"

    public let url: URL
    public var config: VMConfig
    public var id: UUID { config.id }

    public var configURL: URL { url.appendingPathComponent(Self.configFileName) }
    public var efiVarsURL: URL { url.appendingPathComponent("efi-vars.fd") }
    public var tpmDirectory: URL { url.appendingPathComponent("tpm", isDirectory: true) }
    public var logsDirectory: URL { url.appendingPathComponent("logs", isDirectory: true) }
    public var snapshotsDirectory: URL { url.appendingPathComponent("snapshots", isDirectory: true) }
    public var runDirectory: URL { url.appendingPathComponent("run", isDirectory: true) }
    public var machineIdentifierURL: URL { url.appendingPathComponent("machine-id.bin") }
    public var hardwareModelURL: URL { url.appendingPathComponent("hardware-model.bin") }
    public var auxiliaryStorageURL: URL { url.appendingPathComponent("aux.img") }

    public func diskURL(_ disk: DiskConfig) -> URL { resolve(disk.file) }
    /// Present while a new disk has not been made yet (`<disk>.uninitialized`). Consumed when it is made.
    public func uninitializedMarker(_ disk: DiskConfig) -> URL { diskURL(disk).appendingPathExtension("uninitialized") }

    /// Whether the engine may make this disk now because it is missing: only a disk that was never made.
    /// VMs made before the marker existed count as never made only while they have never been started
    /// (QEMU writes the firmware variables at the first start). Anything else is a disk that went missing.
    public func mayCreateMissingDisk(_ disk: DiskConfig, fileManager fm: FileManager = .default) -> Bool {
        fm.fileExists(atPath: uninitializedMarker(disk).path) || !fm.fileExists(atPath: efiVarsURL.path)
    }
    public func mediaURL(_ media: RemovableMedia) -> URL { resolve(media.file) }

    private func resolve(_ path: String) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : url.appendingPathComponent(path)
    }

    init(url: URL, config: VMConfig) { self.url = url; self.config = config }

    /// Creates the bundle directory, its subdirectories, the config file and empty sparse raw disks.
    /// qcow2 disks are created by the QEMU engine, which owns `qemu-img`.
    /// `createDisks: false` leaves the disk files to the caller (an import brings its own).
    public static func create(config: VMConfig, in directory: URL, createDisks: Bool = true, fileManager fm: FileManager = .default) throws -> VMBundle {
        let problems = config.validate()
        guard problems.isEmpty else { throw VMError("Invalid configuration.", detail: problems.joined(separator: "\n")) }
        let url = directory.appendingPathComponent(safeFileName(config.name) + "-" + config.id.uuidString.prefix(8).lowercased())
            .appendingPathExtension(pathExtension)
        guard !fm.fileExists(atPath: url.path) else { throw VMError("A VM bundle already exists at \(url.path).") }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        let bundle = VMBundle(url: url, config: config)
        do {
            for dir in [bundle.logsDirectory, bundle.runDirectory] {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            for disk in config.disks where createDisks {
                let target = try DiskPathRules.containedURL(disk.file, in: url)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                switch disk.format {
                case .raw: try DiskImage.createSparseRaw(at: target, sizeGiB: disk.sizeGiB)
                // qcow2 disks are made by the QEMU engine (it owns qemu-img) at the first start. The marker says
                // that this disk was never made, so that a disk missing later is not silently replaced by an empty one.
                case .qcow2: try Data().write(to: bundle.uninitializedMarker(disk), options: .withoutOverwriting)
                }
            }
            try bundle.save()
        } catch {
            try? fm.removeItem(at: url)
            throw error
        }
        return bundle
    }

    public static func load(from url: URL) throws -> VMBundle {
        // A return to a snapshot that was cut off (crash, power cut) is put right before anything is read:
        // half-way through, the VM's own files, config.json included, may be in a hidden folder.
        if FileManager.default.fileExists(atPath: url.appendingPathComponent(SnapshotStore.journalName).path) {
            _ = try? SnapshotStore(bundleURL: url).recoverInterruptedRevert()
        }
        let data: Data
        do { data = try Data(contentsOf: url.appendingPathComponent(configFileName)) }
        catch { throw VMError("Cannot read \(configFileName) in \(url.lastPathComponent).", detail: error.localizedDescription) }
        do {
            let config = try ConfigCoding.decoder().decode(VMConfig.self, from: data)
            guard config.schemaVersion <= VMConfig.currentSchemaVersion else {
                throw VMError("\(url.lastPathComponent) was written by a newer version (schema \(config.schemaVersion)).")
            }
            return VMBundle(url: url, config: config)
        } catch let e as VMError { throw e }
        catch { throw VMError("\(configFileName) in \(url.lastPathComponent) is not valid.", detail: "\(error)") }
    }

    /// The saved state of a suspended VM: memory and devices, written when it was suspended (or when a
    /// snapshot was taken while it ran). While this file exists the next start resumes from it.
    /// The name tells how it was written: plain, or compressed with zstd.
    public static let suspendFileNames = ["suspend.state", "suspend.state.zst"]
    public var suspendStateURL: URL? {
        Self.suspendFileNames.map { url.appendingPathComponent($0) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
    public var isSuspended: Bool { suspendStateURL != nil }
    /// Throws the saved state away. The VM then starts from its disk, as after a power cut.
    public func discardSuspendState() {
        for name in Self.suspendFileNames { try? FileManager.default.removeItem(at: url.appendingPathComponent(name)) }
    }

    /// Writes the config atomically.
    public func save() throws {
        let data = try ConfigCoding.encoder().encode(config)
        try data.write(to: configURL, options: .atomic)
    }

    /// `toTrash`: move the bundle to the Trash (the app's Remove) instead of deleting it for good (vmctl).
    public func delete(fileManager fm: FileManager = .default, toTrash: Bool = false) throws {
        guard url.pathExtension == Self.pathExtension else {
            throw VMError("Refusing to delete \(url.path): not a .\(Self.pathExtension) bundle.")
        }
        if toTrash { try fm.trashItem(at: url, resultingItemURL: nil) } else { try fm.removeItem(at: url) }
    }

    public static func safeFileName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "vm" : cleaned
    }
}

public enum DiskImage {
    /// Creates a new sparse file of the given size. Uses no disk space until written. Never replaces an
    /// existing file (or follows a link in its place): that could be another disk, or something outside the VM.
    public static func createSparseRaw(at url: URL, sizeGiB: Int) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            let reason = errno == EEXIST ? "a file with that name already exists" : String(cString: strerror(errno))
            throw VMError("Cannot create disk image at \(url.path).", detail: reason)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        do { try handle.truncate(atOffset: UInt64(sizeGiB) << 30) }
        catch { try? FileManager.default.removeItem(at: url); throw error }
    }

    /// Grows a raw image. Shrinking is refused because it destroys data.
    public static func growRaw(at url: URL, toGiB sizeGiB: Int) throws {
        let current = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        let target = UInt64(sizeGiB) << 30
        guard target >= current else { throw VMError("Refusing to shrink \(url.lastPathComponent).") }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: target)
    }
}
