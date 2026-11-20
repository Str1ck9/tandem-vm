import DiskArbitration
import Foundation
import IdentityCore
import IOKit

// USB disks (thumb drives, card readers): hand the disk itself to the VM.
//
// macOS 26 does not let any process without Apple's restricted `com.apple.vm.device-access` entitlement
// take a USB device away from a macOS driver: even as root, libusb's capture tears the storage driver
// down, the device is then marked "NeedsDeviceAccessEntitlement" and every later user client fails with
// kIOReturnNoResources until the device is plugged in again (seen 2026-11-15 on macOS 26.6.2). A disk
// does not need the USB device: the helper unmounts it, serves its raw disk with `qemu-nbd` (run as root)
// on a unix socket only the user can reach, and keeps macOS from mounting it meanwhile; the VM's QEMU
// reads it over NBD and shows it to the guest as a USB storage device. macOS keeps its own driver, so
// nothing is captured.
//
// Ways that do not work on macOS 26: passing an open descriptor (QEMU switches every descriptor it
// receives over QMP to blocking mode, which a disk node refuses), and lending the device node to the user
// with chown (refused even to root with "Operation not permitted", seen in the user's test).

/// What the registry says about one BSD disk name.
struct DiskFacts: Equatable {
    var whole: Bool
    /// The disk sits under a USB device (its storage driver chain goes up to an IOUSBHostDevice).
    var onUSB: Bool
    /// A disk image attached with hdiutil (used by the tests).
    var diskImage: Bool
    var writable: Bool
    var size: UInt64
    /// The registry entry of the disk's media object. A disk that is unplugged and another plugged in
    /// may get the same BSD name, never the same registry entry.
    var registryID: UInt64 = 0
}

/// Whether a disk may be handed over, and if not why. Pure, so it can be tested.
func diskRefusal(bsd: String, facts: DiskFacts?, allowDiskImages: Bool) -> String? {
    guard bsd.range(of: "^disk[0-9]+$", options: .regularExpression) != nil else {
        return "\(bsd) is not a whole disk name (expected diskN)"
    }
    guard let facts else { return "there is no disk \(bsd)" }
    guard facts.whole else { return "\(bsd) is a partition, not a whole disk" }
    if facts.onUSB { return nil }
    if facts.diskImage && allowDiskImages { return nil }
    return "\(bsd) is not a USB disk; only USB disks are handed to virtual machines"
}

/// Reads the registry entry of `/dev/<bsd>`.
func diskFacts(bsd: String) -> DiskFacts? {
    guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsd) else { return nil }
    let media = IOServiceGetMatchingService(kIOMainPortDefault, matching)
    guard media != 0 else { return nil }
    defer { IOObjectRelease(media) }
    func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
    var facts = DiskFacts(whole: property(media, "Whole") as? Bool ?? false, onUSB: false, diskImage: false,
                          writable: property(media, "Writable") as? Bool ?? false,
                          size: (property(media, "Size") as? NSNumber)?.uint64Value ?? 0)
    var registryID: UInt64 = 0
    if IORegistryEntryGetRegistryEntryID(media, &registryID) == KERN_SUCCESS { facts.registryID = registryID }
    // Walk up the service plane: an IOUSBHostDevice means USB; the hdiutil driver means a disk image.
    var entry = media
    IOObjectRetain(entry)
    for _ in 0..<40 {
        var parent: io_registry_entry_t = 0
        let result = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
        IOObjectRelease(entry)
        guard result == KERN_SUCCESS, parent != 0 else { return facts }
        if IOObjectConformsTo(parent, "IOUSBHostDevice") != 0 { facts.onUSB = true }
        var name = [CChar](repeating: 0, count: 128)
        IOObjectGetClass(parent, &name)
        if String(cString: name).hasPrefix("IOHDIX") { facts.diskImage = true }
        entry = parent
    }
    IOObjectRelease(entry)
    return facts
}

// MARK: Keeping macOS from mounting a lent disk

/// Who holds one lent disk. Each lease has its own identity, so a connection can only ever release the
/// reservation it made: a second connection asking for the same disk is refused, and the delayed clean-up
/// of an old lease cannot take away the protection of a newer one.
struct DiskReservation: Equatable {
    let lease: UUID
    /// The disk's registry entry when it was reserved (0 when unknown).
    let device: UInt64
    /// False once the lease has ended without a release: mounts stay refused for a while (the VM's QEMU
    /// may still hold the disk), but a new lease may take the disk over.
    var active: Bool
}

/// The reservations, by whole-disk name. macOS is asked before every mount; while a disk (or one of its
/// partitions) is in here, the answer is no.
final class DiskReservations: @unchecked Sendable {
    private var table: [String: DiskReservation] = [:]
    private let lock = NSLock()

    /// Reserves `bsd` for a new lease, atomically. Refused while another lease holds it.
    func reserve(_ bsd: String, device: UInt64) throws -> UUID {
        try lock.withLock {
            if let held = table[bsd], held.active {
                throw BackendError("\(bsd) is already lent to a virtual machine")
            }
            let lease = UUID()
            table[bsd] = DiskReservation(lease: lease, device: device, active: true)
            return lease
        }
    }

    /// Ends the protection, but only for the lease that made it. Returns whether it was that lease's.
    @discardableResult
    func release(_ bsd: String, lease: UUID) -> Bool {
        lock.withLock {
            guard table[bsd]?.lease == lease else { return false }
            table[bsd] = nil
            return true
        }
    }

    /// The lease ended without a release: mounts stay refused, a new lease may take over.
    func deactivate(_ bsd: String, lease: UUID) {
        lock.withLock { if table[bsd]?.lease == lease { table[bsd]?.active = false } }
    }

    func isReserved(_ bsd: String) -> Bool { lock.withLock { table[wholeDiskName(bsd)] != nil } }
    func reservation(_ bsd: String) -> DiskReservation? { lock.withLock { table[bsd] } }
}

let diskReservations = DiskReservations()
/// How long a disk dropped without a release stays unmountable (`--disk-cooldown` shortens it for tests).
nonisolated(unsafe) var diskCooldown: TimeInterval = 30
private let arbitrationQueue = DispatchQueue(label: "tandem.disk-arbitration")
private var arbitration: DASession?

func wholeDiskName(_ bsd: String) -> String {
    guard let match = bsd.range(of: "^disk[0-9]+", options: .regularExpression) else { return bsd }
    return String(bsd[match])
}

/// Registers the mount-approval callback once.
func watchMounts() {
    arbitrationQueue.sync {
        guard arbitration == nil, let session = DASessionCreate(kCFAllocatorDefault) else { return }
        DASessionSetDispatchQueue(session, arbitrationQueue)
        DARegisterDiskMountApprovalCallback(session, nil, { disk, _ in
            guard let name = DADiskGetBSDName(disk).map({ String(cString: $0) }),
                  diskReservations.isReserved(name) else { return nil }
            let dissenter = DADissenterCreate(kCFAllocatorDefault, DAReturn(kDAReturnBusy), "In use by a Tandem virtual machine" as CFString)
            return Unmanaged.passRetained(dissenter)
        }, nil)
        arbitration = session
    }
}

/// Said wherever macOS refuses root access to a disk: the helper then lacks Full Disk Access.
var fullDiskAccessAdvice: String {
    bundleMode
        ? "Switch on Full Disk Access for “Tandem” in System Settings > Privacy & Security > Full Disk Access, then click Restart helper in Tandem > Settings > Network."
        : scriptFullDiskAccessAdvice
}
var scriptFullDiskAccessAdvice: String {
    "Allow Full Disk Access for '\(TandemIdentity.scriptHelper)' in System Settings > Privacy & Security > Full Disk Access (click +, press Command-Shift-G and enter /Library/PrivilegedHelperTools/\(TandemIdentity.scriptHelper))."
}

/// One disk served to the user. The helper (root) runs `qemu-nbd` on the raw disk; the VM's QEMU reads it
/// through `socketPath`, in a folder only the user can enter. Nothing about the device node changes:
/// macOS 26 refuses even root a `chown` of a disk node (seen 2026-11-15), which the earlier way needed.
final class DiskShare {
    let bsd: String
    let readOnly: Bool
    let size: UInt64
    var rawPath: String { "/dev/r\(bsd)" }
    let socketPath: String
    /// This lease's reservation of the disk.
    let lease: UUID
    private let device: UInt64
    private let folder: String
    private var server: ToolProcess?

    init(bsd: String, allowDiskImages: Bool, qemuNBD: String) throws {
        let facts = diskFacts(bsd: bsd)
        if let refusal = diskRefusal(bsd: bsd, facts: facts, allowDiskImages: allowDiskImages) { throw BackendError(refusal) }
        self.bsd = bsd
        self.readOnly = facts?.writable == false
        self.size = facts?.size ?? 0
        self.device = facts?.registryID ?? 0
        let number: Int = bridgeCounter.withLock { nextBridgeNumber += 1; return nextBridgeNumber }
        folder = "\(dgramBase)-disk-\(number)"
        socketPath = folder + "/nbd.sock"
        watchMounts()
        // Reserved before anything changes: from here on macOS may not mount it, and no other connection
        // may lend it. Then its volumes are unmounted.
        lease = try diskReservations.reserve(bsd, device: device)
        let unmount = runTool("/usr/sbin/diskutil", ["unmountDisk", "/dev/\(bsd)"])
        if unmount.status != 0 {
            // Some of its volumes may have gone already: give them back.
            let back = giveBack()
            throw BackendError("the Mac is still using \(bsd) (\(unmount.output.trimmingCharacters(in: .whitespacesAndNewlines))); close the files on it and try again" + (back.map { ". \($0)" } ?? ""))
        }
        do {
            // The disk must still be the one that was checked: an unplug and replug in between could
            // put another disk under the same name.
            guard device == 0 || diskFacts(bsd: bsd)?.registryID == device else {
                throw BackendError("\(bsd) changed while it was being prepared (unplugged?); try again")
            }
            try startServer(qemuNBD)
        } catch {
            stopServer()
            let back = giveBack()
            if let back { throw BackendError("\((error as? BackendError)?.message ?? "\(error)"). \(back)") }
            throw error
        }
    }

    /// Ends this lease's protection, then asks macOS to mount the disk again (in that order: the mount
    /// would be refused while the disk is still reserved). Returns a sentence when the mount failed.
    private func giveBack() -> String? {
        diskReservations.release(bsd, lease: lease)
        let mount = runTool("/usr/sbin/diskutil", ["mountDisk", "/dev/\(bsd)"])
        guard mount.status != 0 else { return nil }
        let reason = mount.output.trimmingCharacters(in: .whitespacesAndNewlines)
        logLine("disk \(bsd) could not be mounted again: \(reason)")
        return "macOS could not mount \(bsd) again (\(reason.isEmpty ? "diskutil failed" : reason)); unplug it and plug it in again"
    }

    /// qemu-nbd serving the raw disk on a socket in a folder of the helper's own, and that socket given to
    /// the user. The folder stays the helper's (root's): its entries can only be changed by root, so the
    /// socket cannot be swapped for a link to some other file between its creation and the `chown` that
    /// gives it to the user (with a folder of the user's own, that `chown` could be turned onto any file
    /// on the Mac). While qemu-nbd starts nobody else may enter it; afterwards anyone may pass through
    /// (0711) but not list it, and only the user may open the socket (0600).
    private func startServer(_ qemuNBD: String) throws {
        removeFolder()
        guard mkdir(folder, 0o700) == 0 else { throw BackendError("cannot make \(folder): \(errnoText())") }

        // driver=host_device: QEMU's raw-device access, which finds the disk's size and sector alignment.
        // One client (the VM); qemu-nbd ends by itself when it disconnects.
        var arguments = ["--image-opts", "driver=raw,file.driver=host_device,file.filename=\(rawPath)",
                         "--socket=\(socketPath)", "--shared=1"]
        if readOnly { arguments.append("--read-only") }
        // Started suspended and checked as loaded when it must be signed by the helper's team.
        let server: ToolProcess
        do { server = try ToolProcess(path: qemuNBD, arguments: arguments, team: verifiedToolTeam) }
        catch { throw BackendError("\(error)") }
        self.server = server

        // The socket appears once qemu-nbd has opened the disk; an early exit carries its reason.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: socketPath) { break }
            if !server.isRunning { break }
            usleep(50_000)
        }
        guard server.isRunning, FileManager.default.fileExists(atPath: socketPath) else {
            server.end()
            let text = server.errorText()
            if text.contains("Operation not permitted") {
                throw BackendError("macOS did not let the helper open \(rawPath) (Operation not permitted). \(fullDiskAccessAdvice)")
            }
            throw BackendError(text.isEmpty ? "qemu-nbd could not open \(rawPath)" : "qemu-nbd: \(text)")
        }
        var info = stat()
        guard lstat(socketPath, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == getuid() else {
            throw BackendError("the disk socket is not the one qemu-nbd made")
        }
        if lchown(socketPath, allowedUID, gid_t.max) != 0, getuid() == 0 { throw BackendError("cannot give the disk socket to the user: \(errnoText())") }
        guard chmod(socketPath, 0o600) == 0, chmod(folder, 0o711) == 0 else { throw BackendError("cannot set the disk socket's permissions: \(errnoText())") }
    }

    private func stopServer() {
        server?.end()
        removeFolder()
    }

    /// Removes the socket folder without following anything in it.
    private func removeFolder() {
        if let names = try? FileManager.default.contentsOfDirectory(atPath: folder) {
            for name in names { unlink(folder + "/" + name) }
        }
        rmdir(folder)
    }

    /// The VM has let go (`remount`), or the lease simply ended. qemu-nbd stops either way (QEMU then sees
    /// the disk vanish); macOS mounts the disk again only after a proper release. Returns a sentence when
    /// the disk could not be mounted again.
    @discardableResult
    func release(remount: Bool) -> String? {
        stopServer()
        if remount { return giveBack() }
        // Keep refusing mounts for a while: QEMU exits with the app that dropped the lease. Only this lease's
        // reservation is touched, so a newer lease of the same disk keeps its protection.
        diskReservations.deactivate(bsd, lease: lease)
        let name = bsd, lease = self.lease
        DispatchQueue.global().asyncAfter(deadline: .now() + diskCooldown) { diskReservations.release(name, lease: lease) }
        return nil
    }
}

/// Runs a tool (diskutil, mostly) and returns its exit status and output, giving up after `timeout`
/// seconds: a root helper thread stuck on a wedged diskutil would keep its client waiting for good.
func runTool(_ path: String, _ arguments: [String], timeout: TimeInterval = 120) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    let collected = Mutex(Data())
    let ended = DispatchSemaphore(value: 0)
    pipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        if chunk.isEmpty { handle.readabilityHandler = nil; ended.signal() } else { collected.withLock { $0.append(chunk) } }
    }
    do { try process.run() } catch {
        pipe.fileHandleForReading.readabilityHandler = nil
        return (-1, "\(error)")
    }
    let deadline = Date().addingTimeInterval(timeout)
    func gone() -> Bool { !process.isRunning || (kill(process.processIdentifier, 0) != 0 && errno == ESRCH) }
    while !gone(), Date() < deadline { usleep(20_000) }
    guard gone() else {
        endProcess(process, grace: 3)
        pipe.fileHandleForReading.readabilityHandler = nil
        let name = (path as NSString).lastPathComponent
        return (-1, "\(name) did not finish within \(Int(timeout)) seconds and was stopped.")
    }
    _ = ended.wait(timeout: .now() + 5)
    pipe.fileHandleForReading.readabilityHandler = nil
    let reaped = Date().addingTimeInterval(2)
    while process.isRunning, Date() < reaped { usleep(5_000) }
    let status: Int32 = process.isRunning ? -1 : process.terminationStatus
    return (status, String(decoding: collected.withLock { $0 }, as: UTF8.self))
}

/// A small lock around a value.
final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R { lock.withLock { body(&value) } }
}

/// Ends a child and waits for it, but never forever: SIGTERM, up to 5 s, then SIGKILL. `waitUntilExit`
/// is not used because it can miss an exit that races `terminate()` and then wait for good; a helper
/// thread stuck that way also keeps its disk lent (a qemu-nbd left behind on 2026-11-15).
func endProcess(_ process: Process, grace: TimeInterval = 5) {
    guard process.processIdentifier != 0 else { return }
    func ended() -> Bool {
        guard process.isRunning else { return true }
        return kill(process.processIdentifier, 0) != 0 && errno == ESRCH
    }
    if ended() { return }
    process.terminate()
    var deadline = Date().addingTimeInterval(grace)
    while !ended(), Date() < deadline { usleep(20_000) }
    if ended() { return }
    kill(process.processIdentifier, SIGKILL)
    deadline = Date().addingTimeInterval(2)
    while !ended(), Date() < deadline { usleep(20_000) }
}
