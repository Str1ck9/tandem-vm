import Foundation
import VMCore

/// Picks the Windows 11 ARM64 drivers out of a mounted virtio-win ISO (spike 0.2: version 0.1.302 has them all).
public enum VirtioDrivers {
    /// Drivers a Windows guest on the QEMU engine needs, by folder name on the ISO.
    /// NetKVM = network, vioserial = guest agent channel, viogpudo = display, viostor/vioscsi = storage,
    /// viorng = entropy, Balloon = memory balloon, vioinput = input.
    public static let wanted = ["NetKVM", "vioserial", "viogpudo", "viostor", "vioscsi", "viorng", "Balloon", "vioinput"]

    /// Copies `<driver>/w11/ARM64` for each wanted driver into `destination/<driver>`.
    /// Returns the names copied. Throws if the network or serial driver is missing, because the
    /// unattended install cannot finish without them.
    @discardableResult
    public static func collect(fromMountedISO root: URL, to destination: URL) throws -> [String] {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var copied: [String] = []
        for name in wanted {
            let source = root.appendingPathComponent(name).appendingPathComponent("w11/ARM64")
            guard fm.fileExists(atPath: source.path) else { continue }
            try fm.copyItem(at: source, to: destination.appendingPathComponent(name))
            copied.append(name)
        }
        let missing = ["NetKVM", "vioserial"].filter { !copied.contains($0) }
        guard missing.isEmpty else {
            throw VMError("The driver ISO has no Windows 11 ARM64 build of: \(missing.joined(separator: ", ")).",
                          detail: "Expected folders like NetKVM/w11/ARM64 in \(root.path).")
        }
        return copied
    }

    /// Mounts a virtio-win ISO read-only, collects the drivers, and unmounts it.
    @discardableResult
    public static func collect(fromISO iso: URL, to destination: URL) throws -> [String] {
        let fm = FileManager.default
        let mount = fm.temporaryDirectory.appendingPathComponent("tandem-virtio-\(UUID().uuidString)")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: mount) }
        func hdiutil(_ args: [String]) throws -> (Int32, String) {
            let result = try ToolRun.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), args, timeout: ToolRun.Limit.image, output: .discard)
            return (result.status, result.errorText)
        }
        let (status, message) = try hdiutil(["attach", "-readonly", "-nobrowse", "-mountpoint", mount.path, iso.path])
        guard status == 0 else { throw VMError("Could not open \(iso.lastPathComponent).", detail: message) }
        defer { _ = try? hdiutil(["detach", mount.path, "-force"]) }
        return try collect(fromMountedISO: mount, to: destination)
    }
}
