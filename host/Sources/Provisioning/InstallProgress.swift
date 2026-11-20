import Foundation
import VMCore

/// The life of an unattended install, as recorded in the VM's configuration:
/// `notStarted` (boot the install disc), `installing` (Windows Setup restarts the VM several times),
/// `complete` (the guest tools answered: the desktop is up, the install media can go).
public enum InstallProgress {
    /// True when the next start must boot the install disc: a new VM with an installer attached.
    public static func needsInstallerBoot(_ config: VMConfig) -> Bool {
        config.install.unattended && config.install.state == .notStarted
            && config.removableMedia.contains { $0.kind == .installerISO }
    }

    /// Call when the VM has been started for an install. Returns true if the configuration changed.
    @discardableResult
    public static func markStarted(_ bundle: inout VMBundle) -> Bool {
        guard needsInstallerBoot(bundle.config) else { return false }
        bundle.config.install.state = .installing
        try? bundle.save()
        return true
    }

    /// Call when the guest tools first answer. Detaches the install disc and removes the answer disc,
    /// which holds the account password in plain text. Returns true if the configuration changed.
    @discardableResult
    public static func markComplete(_ bundle: inout VMBundle) -> Bool {
        guard bundle.config.install.unattended, bundle.config.install.state != .complete else { return false }
        bundle.config.install.state = .complete
        if bundle.config.install.hasDisplayDriver == true { bundle.config.display.virtioGPU = true }
        bundle.config.removableMedia.removeAll { $0.kind == .installerISO || $0.kind == .unattendDisk }
        // The setup disc of a downloaded Linux system also holds the account's password.
        bundle.config.removableMedia.removeAll { $0.kind == .seedISO && $0.file == LinuxSeed.fileName }
        try? FileManager.default.removeItem(at: bundle.url.appendingPathComponent(LinuxSeed.fileName))
        try? bundle.save()
        // QEMU may still have the file open; unlinking it is safe and it disappears when the VM stops.
        try? FileManager.default.removeItem(at: bundle.url.appendingPathComponent(UnattendMediaBuilder.fileName))
        return true
    }
}

/// Sets a new Windows VM up to install itself: builds the answer disc (answers, drivers, guest tools)
/// in the bundle, attaches it, and records that the next start is an unattended install.
public enum WindowsInstall {
    /// Returns the names of the drivers put on the disc (empty without a driver disc).
    @discardableResult
    public static func prepare(_ bundle: inout VMBundle, options: WindowsUnattendOptions, virtioISO: URL?, agent: URL?) throws -> [String] {
        guard bundle.config.guestOS == .windows11arm else { throw VMError("“\(bundle.config.name)” is not a Windows VM.") }
        var contents = UnattendMediaBuilder.Contents(options: options)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-prepare-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        var drivers: [String] = []
        if let virtioISO {
            let folder = scratch.appendingPathComponent("drivers")
            drivers = try VirtioDrivers.collect(fromISO: virtioISO, to: folder)
            contents.driversDirectory = folder
        }
        contents.agentExecutable = agent
        try UnattendMediaBuilder.build(contents, for: bundle)
        bundle.config.removableMedia.removeAll { $0.kind == .unattendDisk }
        bundle.config.removableMedia.append(RemovableMedia(file: UnattendMediaBuilder.fileName, kind: .unattendDisk))
        bundle.config.install = InstallInfo(state: .notStarted, unattended: true, user: options.userName,
                                            hasDisplayDriver: drivers.contains("viogpudo"),
                                            passwordless: options.password.isEmpty ? true : nil)
        try bundle.save()
        return drivers
    }
}
