import Foundation
import VMCore

/// Housekeeping for a VM's disk files (Configure > Options > Maintenance).
public enum DiskMaintenance {
    public struct Usage: Equatable, Sendable {
        public var file: String
        /// What the guest sees as the disk's size.
        public var virtualBytes: Int64
        /// What the file occupies on the Mac.
        public var allocatedBytes: Int64
        /// Only qcow2 files can be compacted.
        public var canCompact: Bool
    }

    public static func allocatedBytes(of url: URL) -> Int64 {
        // A fresh URL: resource values are cached on the URL object until the run loop turns, and a file
        // replaced since the last look would otherwise still report its old size.
        Int64((try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
    }

    public static func usage(of bundle: VMBundle) -> [Usage] {
        bundle.config.disks.map { disk in
            Usage(file: disk.file, virtualBytes: Int64(disk.sizeGiB) << 30,
                  allocatedBytes: allocatedBytes(of: bundle.diskURL(disk)), canCompact: disk.format == .qcow2)
        }
    }

    /// Rewrites each qcow2 disk without the clusters the guest has freed or zeroed, and returns the
    /// bytes this gave back. The VM must be stopped. The new file is compared with the old one before
    /// it takes its place, so a failed or interrupted run leaves the disk as it was.
    @discardableResult
    public static func compact(bundle: VMBundle, toolchain: QEMUToolchain) throws -> Int64 {
        var freed: Int64 = 0
        for disk in bundle.config.disks where disk.format == .qcow2 {
            let url = bundle.diskURL(disk)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let before = allocatedBytes(of: url)
            let fresh = url.deletingLastPathComponent().appendingPathComponent(".compact-" + url.lastPathComponent)
            try? FileManager.default.removeItem(at: fresh)
            do {
                var arguments = ["convert", "-f", "qcow2", "-O", "qcow2"]
                // A disk that sits on top of another file (an imported VM) keeps doing so.
                if let backing = disk.backing { arguments += ["-B", backing.path, "-F", backing.format] }
                try QEMUToolchain.run(toolchain.qemuImg, arguments + [url.path, fresh.path], timeout: ToolRun.Limit.disk)
                try QEMUToolchain.run(toolchain.qemuImg, ["compare", "-f", "qcow2", "-F", "qcow2", url.path, fresh.path], timeout: ToolRun.Limit.disk)
            } catch {
                try? FileManager.default.removeItem(at: fresh)
                throw VMError("“\(disk.file)” could not be compacted. It is unchanged.", detail: (error as? VMError)?.detail ?? error.localizedDescription)
            }
            let after = allocatedBytes(of: fresh)
            guard after < before else {
                // Nothing to gain: keep the original file.
                try? FileManager.default.removeItem(at: fresh)
                continue
            }
            _ = try FileManager.default.replaceItemAt(url, withItemAt: fresh)
            freed += before - after
        }
        return freed
    }
}
