import Foundation
import NetHelperClient
import VMCore

/// Gathers the facts about this Mac that `Compatibility` (VMCore) reasons about.
public enum HostProbe {
    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    /// A virtio-win driver disc in the places Tandem looks: its own folder, ~/ISOs, ~/Downloads.
    public static func driverDisc() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Tandem")
        for folder in [support, home.appendingPathComponent("ISOs"), home.appendingPathComponent("Downloads")] {
            let names = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
            if let name = names.first(where: { $0.lowercased().hasSuffix(".iso") && $0.lowercased().contains("virtio-win") }) {
                return folder.appendingPathComponent(name)
            }
        }
        return nil
    }

    /// `vmFolder`: where the VM will be kept, for the free-space figure. `driverDisc`: a disc the caller
    /// already knows about (the app remembers the one chosen at an import).
    public static func current(vmFolder: URL? = nil, driverDisc known: URL? = nil) -> HostFacts {
        let fm = FileManager.default
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let toolchain = try? QEMUToolchain.locate()
        let key = URLResourceKey.volumeAvailableCapacityForImportantUsageKey
        let folder = vmFolder ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let free = (try? folder.resourceValues(forKeys: [key]))?.volumeAvailableCapacityForImportantUsage
            ?? (try? fm.homeDirectoryForCurrentUser.resourceValues(forKeys: [key]))?.volumeAvailableCapacityForImportantUsage
        let zstd = BundledTools.locate("zstd", fallbacks: BundledTools.systemPaths("zstd")) != nil
        let disc = known.flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil } ?? driverDisc()
        return HostFacts(
            chip: sysctlString("machdep.cpu.brand_string") ?? "Unknown processor",
            isAppleSilicon: sysctlInt("hw.optional.arm64") == 1,
            macOSMajor: version.majorVersion, macOSMinor: version.minorVersion,
            memoryGiB: Int(ProcessInfo.processInfo.physicalMemory >> 30),
            cores: ProcessInfo.processInfo.processorCount,
            freeDiskGiB: Int((free ?? 0) >> 30),
            qemuVersion: toolchain?.qemuVersion,
            qemuIsTandemBuild: toolchain?.isPatchedBuild ?? false,
            swtpm: toolchain?.swtpm != nil || BundledTools.tool("swtpm") != nil || QEMUToolchain.find("swtpm") != nil,
            zstd: zstd,
            networkHelper: NetHelper.isInstalled,
            // The translator for Intel Linux programs ships inside the Rosetta install.
            rosetta: fm.fileExists(atPath: "/Library/Apple/usr/share/rosetta/rosetta") || fm.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime"),
            driverDisc: disc != nil,
            windowsGuestTools: GuestTools.windowsAgent != nil,
            linuxGuestTools: GuestTools.linuxAgent != nil,
            macOSGuestTools: GuestTools.macOSAgent != nil)
    }
}
