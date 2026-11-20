import Foundation
import VMCore

/// Turns one of Microsoft's compressed install images (an "ESD") into an install disc Setup can boot.
///
/// An ESD is an archive of several images: the files of the install disc itself, two start-up
/// environments (Windows PE, then Windows Setup), and one image per edition. The disc is put
/// together the way Microsoft's own tool does it:
///
///   - the first image, unpacked, is the disc's file tree;
///   - the two start-up images become `sources/boot.wim`, the second marked as the one to start;
///   - the edition images become `sources/install.esd`, copied as they are (no recompression);
///   - the tree is written as a disc image whose boot record points at Microsoft's EFI boot image
///     that starts Setup without waiting for a key.
///
/// Reading and writing these archives needs wimlib (`brew install wimlib`), an open-source tool.
public enum WindowsImageBuilder {
    public static let wimlibInstallHint = "Install it in Terminal with: brew install wimlib"

    /// `wimlib-imagex`: the copy a packaged Tandem.app carries, else where Homebrew or a manual install puts it.
    public static var wimlib: URL? {
        if let bundled = BundledTools.tool("wimlib-imagex") { return bundled }
        var folders = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
        folders += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return folders.lazy.map { URL(fileURLWithPath: $0).appendingPathComponent("wimlib-imagex") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// One image inside an ESD or WIM archive.
    public struct ArchiveImage: Equatable, Sendable {
        public var index: Int
        public var name: String
        /// `WindowsPE` for the start-up environments, `Core`, `Professional`, … for editions; nil for the disc's files.
        public var editionID: String?
    }

    /// Reads the image list from the text `wimlib-imagex info` prints.
    public static func images(fromInfo text: String) -> [ArchiveImage] {
        var images: [ArchiveImage] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "Index": if let index = Int(value) { images.append(ArchiveImage(index: index, name: "", editionID: nil)) }
            case "Name": if !images.isEmpty, images[images.count - 1].name.isEmpty { images[images.count - 1].name = value }
            case "Edition ID": if !images.isEmpty { images[images.count - 1].editionID = value }
            default: break
            }
        }
        return images
    }

    /// Which image plays which part. Throws when the archive is not laid out as an install image.
    public static func plan(_ images: [ArchiveImage]) throws -> (media: Int, startup: [Int], editions: [ArchiveImage]) {
        let startup = images.filter { $0.editionID == "WindowsPE" }
        let editions = images.filter { $0.editionID != nil && $0.editionID != "WindowsPE" }
        guard let media = images.first(where: { $0.editionID == nil }), startup.count == 2, !editions.isEmpty else {
            throw VMError("The downloaded Windows image is not laid out as expected.",
                          detail: "Found: " + images.map { "\($0.index) \($0.name) [\($0.editionID ?? "files")]" }.joined(separator: ", "))
        }
        return (media.index, startup.map(\.index), editions)
    }

    /// Runs a tool, returning what it printed. Ends the tool if the task is cancelled, or when it runs
    /// past `timeout` (the default allows for an LZMS export of every edition on a slow disk).
    @discardableResult
    static func run(_ tool: URL, _ arguments: [String], timeout: TimeInterval = ToolRun.Limit.disk) async throws -> String {
        try Task.checkCancellation()
        let result = try await ToolRun.run(tool, arguments, timeout: timeout)
        guard result.succeeded else { throw ToolRun.failed(result, "\(tool.lastPathComponent) \(arguments.first ?? "") failed.") }
        return result.outputText
    }

    /// Builds `iso` from `esd`. Work files go in a folder beside `iso` and are removed afterwards.
    /// `progress` gets a short description of each step.
    public static func build(from esd: URL, to iso: URL, volumeName: String = "WINDOWS11",
                             progress: @Sendable (String) -> Void = { _ in }) async throws {
        guard let wimlib else {
            throw VMError("Building the Windows install disc needs the wimlib tool.", detail: wimlibInstallHint)
        }
        let fm = FileManager.default
        let stage = iso.deletingPathExtension().appendingPathExtension("stage")
        let building = iso.appendingPathExtension("building")
        try? fm.removeItem(at: stage)
        try? fm.removeItem(at: building)
        defer { try? fm.removeItem(at: stage); try? fm.removeItem(at: building) }

        // The tree and the disc image are each about as large as the download.
        let size = (try? esd.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let free = (try? iso.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? .max
        let needed = size * 5 / 2 + (1 << 30)
        guard free >= needed else {
            throw VMError("There is not enough free disk space to build the Windows install disc.",
                          detail: "It needs about \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) while it works; \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) is free.")
        }

        progress("Reading the Windows image")
        let layout = try plan(images(fromInfo: try await run(wimlib, ["info", esd.path])))

        progress("Unpacking the install disc's files")
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        try await run(wimlib, ["apply", esd.path, String(layout.media), stage.path])
        let sources = stage.appendingPathComponent("sources")
        let bootImage = stage.appendingPathComponent("efi/microsoft/boot/efisys_noprompt.bin")
        guard fm.fileExists(atPath: sources.path), fm.fileExists(atPath: bootImage.path) else {
            throw VMError("The downloaded Windows image has no install disc files for this kind of Mac.",
                          detail: "Expected sources/ and efi/microsoft/boot/efisys_noprompt.bin in its first image.")
        }

        progress("Building the start-up image")
        let bootWim = sources.appendingPathComponent("boot.wim").path
        try await run(wimlib, ["export", esd.path, String(layout.startup[0]), bootWim, "--compress=LZX"])
        try await run(wimlib, ["export", esd.path, String(layout.startup[1]), bootWim, "--compress=LZX", "--boot"])

        progress("Copying the Windows editions")
        // Same compression as the source, so the data is copied as it is: seconds, not minutes.
        let install = sources.appendingPathComponent("install.esd").path
        for edition in layout.editions {
            try await run(wimlib, ["export", esd.path, String(edition.index), install, "--compress=LZMS", "--solid"])
        }

        progress("Writing the install disc")
        // The edition file is over 4 GB, more than the older of the disc's two file systems can hold;
        // Setup reads the newer one (UDF), so the file is left out of the old one.
        try await run(URL(fileURLWithPath: "/usr/bin/hdiutil"),
                      ["makehybrid", "-quiet", "-iso", "-udf", "-default-volume-name", volumeName, "-hide-iso", "install.esd",
                       "-eltorito-boot", bootImage.path, "-no-emul-boot", "-o", building.path, stage.path])
        // hdiutil appends ".iso" when the name does not end in it.
        let written = fm.fileExists(atPath: building.path) ? building : building.appendingPathExtension("iso")
        let bootBytes = (try? bootImage.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        try markBootRecordEFI(of: written, bootImageBytes: bootBytes)
        try Task.checkCancellation()
        try? fm.removeItem(at: iso)
        try fm.moveItem(at: written, to: iso)
    }

    /// The disc tool writes a boot record for a PC BIOS that loads four sectors. This one is for EFI
    /// and names a whole small disk image, so both fields are corrected: platform 0xEF and the
    /// image's real length. Without it some firmware does not offer the disc for starting.
    static func markBootRecordEFI(of iso: URL, bootImageBytes: Int) throws {
        let sector = 2048
        let handle = try FileHandle(forUpdating: iso)
        defer { try? handle.close() }
        func read(_ offset: Int, _ count: Int) throws -> [UInt8] {
            try handle.seek(toOffset: UInt64(offset))
            return [UInt8](try handle.read(upToCount: count) ?? Data())
        }
        // The boot record is one of the volume descriptors that start at sector 16.
        var catalogue: Int?
        for index in 16..<32 {
            let descriptor = try read(index * sector, sector)
            guard descriptor.count == sector, Array(descriptor[1..<6]) == Array("CD001".utf8) else { break }
            if descriptor[0] == 0, String(decoding: descriptor[7..<30], as: UTF8.self) == "EL TORITO SPECIFICATION" {
                catalogue = Int(descriptor[0x47]) | Int(descriptor[0x48]) << 8 | Int(descriptor[0x49]) << 16 | Int(descriptor[0x4A]) << 24
                break
            }
            if descriptor[0] == 255 { break }
        }
        guard let catalogue else { throw VMError("The install disc was written without a boot record.") }
        var entries = try read(catalogue * sector, 64)
        guard entries.count == 64, entries[0] == 1, entries[30] == 0x55, entries[31] == 0xAA, entries[32] == 0x88 else {
            throw VMError("The install disc's boot record is not in the expected form.")
        }
        // Validation entry: platform, then a checksum that makes its sixteen words add up to zero.
        entries[1] = 0xEF
        entries[28] = 0; entries[29] = 0
        var sum = 0
        for word in 0..<16 { sum = (sum + Int(entries[word * 2]) + Int(entries[word * 2 + 1]) << 8) & 0xFFFF }
        let checksum = (0x10000 - sum) & 0xFFFF
        entries[28] = UInt8(checksum & 0xFF); entries[29] = UInt8(checksum >> 8)
        // Default entry: the image's length in 512-byte sectors.
        let sectors = min((bootImageBytes + 511) / 512, 0xFFFF)
        entries[38] = UInt8(sectors & 0xFF); entries[39] = UInt8(sectors >> 8)
        try handle.seek(toOffset: UInt64(catalogue * sector))
        try handle.write(contentsOf: Data(entries))
    }
}
