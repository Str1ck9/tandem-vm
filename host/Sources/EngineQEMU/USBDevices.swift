import Foundation
import IOKit
import NetHelperClient
import VMCore

/// A USB device plugged into this Mac that could be handed to a VM.
public struct HostUSBDevice: Identifiable, Equatable, Sendable {
    public var vendorID: Int
    public var productID: Int
    public var name: String
    public var vendor: String?
    /// Where the device is plugged in. Tells two identical devices apart.
    public var location: UInt32
    /// The macOS driver on one of its interfaces (for example `IOUSBMassStorageInterfaceNub`), if any.
    /// Such a device cannot be taken away from macOS on macOS 26 without Apple's entitlement.
    public var macOSDriver: String? = nil
    /// The whole disk macOS made of it (`disk4`), for USB drives and card readers.
    public var diskBSDName: String? = nil
    /// Its serial port on the Mac (`/dev/cu.usbmodem…`), for serial devices such as a Flipper Zero.
    public var serialPath: String? = nil
    /// Its USB serial number string, so the guest sees the same identity as the Mac.
    public var serialNumber: String? = nil

    public init(vendorID: Int, productID: Int, name: String, vendor: String? = nil, location: UInt32) {
        self.vendorID = vendorID; self.productID = productID; self.name = name; self.vendor = vendor; self.location = location
    }

    public var id: String { String(format: "%04x-%04x-%08x", vendorID, productID, location) }
    /// The name QEMU knows the passed-through device by.
    public var qemuID: String { "usbhost-\(id)" }

    public static func list() -> [HostUSBDevice] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var devices: [HostUSBDevice] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property<T>(_ key: String, _ type: T.Type) -> T? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? T
            }
            guard let vendorID = property("idVendor", Int.self), let productID = property("idProduct", Int.self) else { continue }
            // Hubs cannot be passed through, and the Mac's built-in ones are not the user's devices.
            if property("bDeviceClass", Int.self) == 9 { continue }
            let name = (property("USB Product Name", String.self) ?? property("kUSBProductString", String.self))?.trimmingCharacters(in: .whitespaces)
            var device = HostUSBDevice(
                vendorID: vendorID, productID: productID,
                name: (name?.isEmpty == false ? name : nil) ?? String(format: "USB device %04x:%04x", vendorID, productID),
                vendor: property("USB Vendor Name", String.self)?.trimmingCharacters(in: .whitespaces),
                location: UInt32(truncatingIfNeeded: property("locationID", Int.self) ?? 0))
            device.serialNumber = (property("USB Serial Number", String.self) ?? property("kUSBSerialNumberString", String.self))?
                .trimmingCharacters(in: .whitespaces)
            Self.describeMacSide(service, into: &device)
            devices.append(device)
        }
        return devices.sorted { ($0.name, $0.location) < ($1.name, $1.location) }
    }

    /// Reads, without opening anything, what macOS made of the device: the driver on its interfaces, the
    /// whole disk of a storage device, the callout node of a serial device.
    static func describeMacSide(_ service: io_registry_entry_t, into device: inout HostUSBDevice) {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(service, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            func property<T>(_ key: String, _ type: T.Type) -> T? {
                IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? T
            }
            if device.macOSDriver == nil, IOObjectConformsTo(entry, "IOUSBHostInterface") != 0 {
                var child: io_registry_entry_t = 0
                if IORegistryEntryGetChildEntry(entry, kIOServicePlane, &child) == KERN_SUCCESS, child != 0 {
                    var name = [CChar](repeating: 0, count: 128)
                    IOObjectGetClass(child, &name)
                    device.macOSDriver = String(cString: name)
                    IOObjectRelease(child)
                }
            }
            if device.diskBSDName == nil, IOObjectConformsTo(entry, "IOMedia") != 0, property("Whole", Bool.self) == true {
                device.diskBSDName = property("BSD Name", String.self)
            }
            if device.serialPath == nil, IOObjectConformsTo(entry, "IOSerialBSDClient") != 0 {
                device.serialPath = property("IOCalloutDevice", String.self)
            }
        }
    }
}

extension HostUSBDevice {
    /// How the device would reach a VM, in a few words for the Devices > USB menu. Decided from what macOS
    /// made of it, without opening anything.
    public var routeLabel: String {
        if diskBSDName != nil { return "as a USB drive" }
        if serialPath != nil { return "as a COM port" }
        if macOSDriver != nil { return "not available: macOS is using it" }
        return "as a USB device"
    }

    /// Whether ticking it in Devices > USB can work at all.
    public var canBeHandedToVM: Bool { diskBSDName != nil || serialPath != nil || macOSDriver == nil }
}

/// How a device reaches the VM. On macOS 26 a device that a macOS driver holds cannot be captured without
/// Apple's restricted `com.apple.vm.device-access` entitlement, not even by root: the attempt tears the
/// driver down and leaves the device unusable until it is plugged in again. So such devices go another
/// way, or not at all, and only devices without a macOS driver are passed through as USB devices.
public enum USBRoute: Equatable, Sendable {
    /// A USB drive: the helper hands over its raw disk; the guest sees a USB storage device.
    case disk(bsd: String)
    /// A serial device: QEMU opens its Mac serial port; the guest sees a USB serial adapter.
    case serial(path: String)
    /// No macOS driver: QEMU takes the device itself (`usb-host`).
    case host
    /// Cannot be handed over; the reason is for the user.
    case refuse(String, detail: String)

    public static func choose(for device: HostUSBDevice, helper: NetHelper.Info?) -> USBRoute {
        if let bsd = device.diskBSDName {
            guard helper?.supportsDisks == true else {
                return .refuse("“\(device.name)” needs the Tandem helper.",
                               detail: "USB drives are handed to the VM as a disk, which only an administrator may open. \(helper == nil ? "" : "The installed helper is too old. ")\(NetHelper.installAdvice)")
            }
            return .disk(bsd: bsd)
        }
        if let path = device.serialPath { return .serial(path: path) }
        if let driver = device.macOSDriver {
            return .refuse("macOS is using “\(device.name)” with its own driver (\(driver)).",
                           detail: "Taking a device away from a macOS driver needs an entitlement that Apple grants only to approved virtualization apps, and trying anyway leaves the device unusable until it is unplugged and plugged in again. USB drives and serial devices are handed over another way; this kind of device cannot be, yet.")
        }
        return .host
    }
}

/// The QMP commands that hand a device to the VM and take it back. Two ways:
/// - `redirect`: the root helper takes the device from macOS and serves it as a usbredir stream on a unix
///   socket; QEMU's `usb-redir` device reads it through a socket chardev. Works for any device, including
///   those macOS has its own driver for (storage, serial adapters such as a Flipper Zero, keyboards).
/// - `host`: QEMU opens the device itself (`usb-host`). Works only for devices macOS has no driver for,
///   because only root may detach one. Used when the helper is missing or too old.
public enum USBPassthroughPlan {
    public static func chardevID(_ qemuID: String) -> String { "chr-\(qemuID)" }

    public static func redirectCommands(qemuID: String, socketPath: String) -> [(String, [String: Any])] {
        [("chardev-add", ["id": chardevID(qemuID),
                          "backend": ["type": "socket", "data": [
                              "addr": ["type": "unix", "data": ["path": socketPath]],
                              "server": false]]]),
         ("device_add", ["driver": "usb-redir", "bus": "usb.0", "id": qemuID, "chardev": chardevID(qemuID)])]
    }

    public static func hostCommands(_ device: HostUSBDevice) -> [(String, [String: Any])] {
        [("device_add", ["driver": "usb-host", "bus": "usb.0", "id": device.qemuID,
                         "vendorid": device.vendorID, "productid": device.productID])]
    }

    public static func nodeName(_ qemuID: String) -> String { "blk-\(qemuID)" }

    /// A USB drive as a disk: QEMU reads it over NBD from the socket the helper serves it on (the helper,
    /// as root, opens the raw disk; macOS 26 lets no user process open it and refuses even root a chown of
    /// the node); it becomes a block node and a removable USB storage device.
    public static func diskCommands(qemuID: String, socketPath: String, readOnly: Bool) -> [(String, [String: Any])] {
        [("blockdev-add", ["node-name": nodeName(qemuID), "driver": "raw", "read-only": readOnly,
                           "file": ["driver": "nbd", "server": ["type": "unix", "path": socketPath],
                                    "read-only": readOnly] as [String: Any]]),
         ("device_add", ["driver": "usb-storage", "bus": "usb.0", "id": qemuID, "drive": nodeName(qemuID), "removable": true])]
    }

    /// After the guest has let go of a disk (`device_del` done): its block node, which closes the disk.
    public static func diskCleanupCommands(qemuID: String) -> [(String, [String: Any])] {
        [("blockdev-del", ["node-name": nodeName(qemuID)])]
    }

    /// A serial device: QEMU opens its Mac serial port and the guest sees a USB serial device.
    /// With `identity` (QEMU built with Tandem's `usb-cdc-acm`) it is a USB modem-class (CDC ACM) port
    /// carrying the Mac device's own vendor and product ids, names and serial number: the guest's inbox
    /// driver takes it (no driver install on Windows), and programs that look for the device by its ids,
    /// such as a Flipper Zero's own tools, find it. Without, QEMU's FTDI-compatible `usb-serial`, which
    /// Windows on ARM needs FTDI's driver for.
    public static func serialCommands(qemuID: String, path: String, identity: HostUSBDevice? = nil) -> [(String, [String: Any])] {
        let chardev: (String, [String: Any]) = ("chardev-add", ["id": chardevID(qemuID), "backend": ["type": "serial", "data": ["device": path]]])
        guard let identity else {
            return [chardev, ("device_add", ["driver": "usb-serial", "bus": "usb.0", "id": qemuID, "chardev": chardevID(qemuID)])]
        }
        var device: [String: Any] = ["driver": cdcACMDevice, "bus": "usb.0", "id": qemuID, "chardev": chardevID(qemuID),
                                     "vendorid": identity.vendorID, "productid": identity.productID,
                                     "product": descriptorString(identity.name)]
        if let vendor = identity.vendor, !vendor.isEmpty { device["manufacturer"] = descriptorString(vendor) }
        if let serial = identity.serialNumber, !serial.isEmpty { device["serial"] = descriptorString(serial) }
        return [chardev, ("device_add", device)]
    }

    /// Tandem's CDC ACM device in its QEMU build (`patches/qemu-11.1.3-usb-cdc-acm.patch`).
    public static let cdcACMDevice = "usb-cdc-acm"

    /// USB string descriptors as QEMU writes them: one byte per character, so keep to printable ASCII.
    static func descriptorString(_ text: String) -> String {
        let ascii = String(text.unicodeScalars.map { $0.isASCII && $0.value >= 0x20 && $0.value < 0x7f ? Character($0) : "?" })
        return String(ascii.prefix(126))
    }

    /// Taking a device back: the device first, then (for a redirected one) its chardev. QEMU 11.1 frees a
    /// `usb-redir` device's chardev together with the device, so the second command normally finds nothing
    /// (seen in a trial); it stays as a best-effort cleanup for versions that keep it.
    public static func detachCommands(qemuID: String, redirected: Bool) -> [(String, [String: Any])] {
        var commands: [(String, [String: Any])] = [("device_del", ["id": qemuID])]
        if redirected { commands.append(("chardev-remove", ["id": chardevID(qemuID)])) }
        return commands
    }
}

extension QEMUEngine {
    /// Hands a Mac USB device to the running VM the way `USBRoute.choose` decides: a USB drive as its
    /// disk (through the root helper), a serial device through its Mac serial port, a device without a
    /// macOS driver directly. Devices a macOS driver holds are refused before anything touches them.
    /// `policy` is the VM's sharing policy at this moment: there is no way to attach a device without one.
    public func attachUSB(_ device: HostUSBDevice, policy: SharingPolicy) async throws {
        try policy.requireUSB()
        guard let qmp = controlChannel, lifecycle.state == .running else { throw VMError("The VM is not running.") }
        guard usbLeases[device.qemuID] == nil, usbDisks[device.qemuID] == nil else { return }
        if await usbRequested().contains(device.qemuID) { return }

        let helper = NetHelper.isInstalled ? try? await Task.detached { try NetHelper.info() }.value : nil
        let failed = "“\(device.name)” could not be connected to the VM."
        switch USBRoute.choose(for: device, helper: helper) {
        case .refuse(let message, let detail):
            throw VMError(message, detail: detail)

        case .disk(let bsd):
            let lease: DiskLease
            do { lease = try await Task.detached { try NetHelper.disk(bsd: bsd) }.value }
            catch let error as VMError where error.message.hasPrefix("The network helper") {
                // The helper's own reason (for example macOS refusing it the disk) is the useful part.
                throw VMError(failed, detail: error.detail ?? error.message)
            }
            do {
                for (command, arguments) in USBPassthroughPlan.diskCommands(qemuID: device.qemuID, socketPath: lease.socketPath, readOnly: lease.readOnly) {
                    try await qmp.execute(command, arguments: arguments)
                }
            } catch {
                for (command, arguments) in USBPassthroughPlan.diskCleanupCommands(qemuID: device.qemuID) {
                    _ = try? await qmp.execute(command, arguments: arguments)
                }
                Task.detached { lease.release() }
                throw VMError(failed, detail: (error as? VMError)?.detail ?? "\(error)")
            }
            usbDisks[device.qemuID] = lease

        case .serial(let path):
            // The device's own identity where this QEMU can present it, else the FTDI-compatible adapter.
            let identity = await qemuHasDevice(USBPassthroughPlan.cdcACMDevice) ? device : nil
            do {
                for (command, arguments) in USBPassthroughPlan.serialCommands(qemuID: device.qemuID, path: path, identity: identity) {
                    try await qmp.execute(command, arguments: arguments)
                }
            } catch {
                _ = try? await qmp.execute("chardev-remove", arguments: ["id": USBPassthroughPlan.chardevID(device.qemuID)])
                throw VMError(failed, detail: (error as? VMError)?.detail ?? "\(error)")
            }

        case .host:
            for (command, arguments) in USBPassthroughPlan.hostCommands(device) {
                try await qmp.execute(command, arguments: arguments)
            }
            // QEMU accepts the request first and opens the device afterwards.
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if await usbIsAttached(device) { return }
            }
            _ = try? await qmp.execute("device_del", arguments: ["id": device.qemuID])
            throw VMError(failed, detail: "QEMU could not open it. Another program on the Mac may be using it.")
        }
    }

    public func detachUSB(_ device: HostUSBDevice) async throws {
        guard controlChannel != nil else { throw VMError("The VM is not running.") }
        await removeUSB(device.qemuID)
    }

    /// Takes one device back: from the VM, then (for a redirected one) its socket and the helper's lease,
    /// which gives the device back to macOS.
    func removeUSB(_ qemuID: String) async {
        let lease = usbLeases.removeValue(forKey: qemuID)
        let disk = usbDisks.removeValue(forKey: qemuID)
        guard let qmp = controlChannel else {
            lease?.close()
            if let disk { Task.detached { disk.abandon() } }
            return
        }
        _ = try? await qmp.execute("device_del", arguments: ["id": qemuID])
        // A chardev or a disk can only go once the guest has let go of the device using it.
        var gone = false
        for _ in 0..<50 {
            if await !usbRequested().contains(qemuID) { gone = true; break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        // Serial and redirected devices have a chardev; for the others this finds nothing.
        await qmp.removeChardevWhenFree(USBPassthroughPlan.chardevID(qemuID))
        if let disk {
            await qmp.removeBlockNodeWhenFree(USBPassthroughPlan.nodeName(qemuID))
            // Mount it on the Mac again only when the guest has certainly let go.
            let lease = disk
            Task.detached { if gone { lease.release() } else { lease.abandon() } }
        }
        lease?.close()
    }

    /// Whether this QEMU has the `usb-redir` device (built with usbredir).
    public func qemuHasUSBRedirect() async -> Bool { await qemuHasDevice("usb-redir") }

    /// Whether this QEMU build has a device type, for example Tandem's own `usb-cdc-acm`.
    public func qemuHasDevice(_ type: String) async -> Bool {
        guard let qmp = controlChannel else { return false }
        return (try? await qmp.execute("device-list-properties", arguments: ["typename": type])) != nil
    }

    /// Takes every Mac USB device back from the VM when the policy no longer allows them.
    /// Returns the ids that were detached.
    @discardableResult
    public func enforceUSB(_ policy: SharingPolicy) async -> Set<String> {
        guard !policy.usbAllowed, controlChannel != nil else { return [] }
        let held = await usbRequested().union(usbLeases.keys).union(usbDisks.keys)
        for id in held { await removeUSB(id) }
        return held
    }

    /// Whether the VM currently holds the device.
    public func usbIsAttached(_ device: HostUSBDevice) async -> Bool {
        guard let qmp = controlChannel else { return false }
        let reply = try? await qmp.execute("qom-get", arguments: ["path": "/machine/peripheral/\(device.qemuID)", "property": "attached"])
        return reply?["value"] as? Bool ?? false
    }

    /// The devices the VM was asked to take (attached or still waiting), by `HostUSBDevice.qemuID`.
    public func usbRequested() async -> Set<String> {
        guard let qmp = controlChannel,
              let reply = try? await qmp.execute("qom-list", arguments: ["path": "/machine/peripheral"]),
              let items = reply["value"] as? [[String: Any]] else { return [] }
        return Set(items.compactMap { $0["name"] as? String }.filter { $0.hasPrefix("usbhost-") })
    }

    /// Closes every way into a running guest on the shared network: its port forwards and the private
    /// ports behind its published services. Used when the sharing policy stops allowing connections in.
    /// They open again at the next start, if allowed then. Returns how many were closed.
    @discardableResult
    public func closeInboundForwards() async -> Int {
        guard let qmp = controlChannel else { return 0 }
        // What this run was started with, not what the configuration says now.
        let ports = (liveNetwork ?? bundle.config.network).portForwards.map(\.hostPort) + serviceBackends.values
        var closed = 0
        for port in ports {
            let reply = try? await qmp.execute("human-monitor-command", arguments: ["command-line": "hostfwd_remove net0 tcp:127.0.0.1:\(port)"])
            if let text = reply?["value"] as? String, text.contains("removed") { closed += 1 }
        }
        return closed
    }

    /// Pulls shared-folder devices out of a running Linux guest, by their position in the list the VM was
    /// started with. The guest should have unmounted them first. Returns the positions that are gone;
    /// a guest that does not answer the unplug request keeps the device until it is restarted.
    @discardableResult
    public func detachSharedFolders(_ positions: [Int]) async -> [Int] {
        guard let qmp = controlChannel, !positions.isEmpty else { return [] }
        foldersDetached = true
        for i in positions { _ = try? await qmp.execute("device_del", arguments: ["id": "sharedev\(i)"]) }
        var gone: [Int] = []
        // The guest has to answer the request; a Linux guest takes a few seconds.
        for _ in 0..<60 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let reply = try? await qmp.execute("qom-list", arguments: ["path": "/machine/peripheral"]),
                  let items = reply["value"] as? [[String: Any]] else { continue }
            let names = Set(items.compactMap { $0["name"] as? String })
            gone = positions.filter { !names.contains("sharedev\($0)") }
            if gone.count == positions.count { break }
        }
        return gone
    }
}

extension QMPClient {
    /// Removes a block node once the device that used it has let go. `usb-storage` keeps an inner SCSI
    /// disk on the node, and QEMU releases that a moment after the device has left the bus, so a first
    /// `blockdev-del` can fail with "Node … is in use" (seen intermittently in the test suite). Retries for up
    /// to five seconds; a node that is already gone ends the wait. Returns whether the node is gone.
    @discardableResult
    public func removeBlockNodeWhenFree(_ nodeName: String) async -> Bool {
        for _ in 0..<50 {
            do {
                try await execute("blockdev-del", arguments: ["node-name": nodeName])
                return true
            } catch {
                let text = "\(error)"
                if text.contains("not found") || text.contains("Cannot find") { return true }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        return false
    }

    /// Removes a chardev once the device that used it has let go. QEMU reports the device deleted a
    /// moment before it frees the chardev, so a first attempt can find it still in use; a chardev that is
    /// already gone (QEMU frees a `usb-redir` device's itself) ends the wait at once.
    func removeChardevWhenFree(_ id: String) async {
        for _ in 0..<20 {
            do {
                try await execute("chardev-remove", arguments: ["id": id])
                return
            } catch {
                if "\(error)".contains("not found") { return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
}
