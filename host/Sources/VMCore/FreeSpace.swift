import Foundation

/// Free space checks made before long copies, on the volume the data actually goes to.
public enum FreeSpace {
    /// Space the system would give an important write on the volume holding `url`, or nil when it cannot
    /// say. A path that does not exist yet is measured at its nearest existing parent folder.
    public static func available(at url: URL) -> Int64? {
        var probe = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" { probe.deleteLastPathComponent() }
        guard let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return bytes
    }

    /// Throws when the volume of `destination` has less than `bytes` free. Unknown capacity is not treated as
    /// zero: the copy is allowed, and fails later with the system's own error if space really runs out.
    public static func require(_ bytes: Int64, at destination: URL, for what: String,
                               capacity: (URL) -> Int64? = FreeSpace.available) throws {
        guard let free = capacity(destination), free < bytes else { return }
        throw VMError(String(format: "%@ needs about %.0f GiB free on the disk holding “%@”; %.0f GiB is available.",
                             what, Double(bytes) / 1_073_741_824, destination.lastPathComponent, Double(free) / 1_073_741_824),
                      detail: destination.path)
    }
}
