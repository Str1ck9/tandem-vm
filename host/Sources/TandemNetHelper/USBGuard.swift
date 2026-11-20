import Foundation
import IOKit

/// The name of the macOS driver that holds one of the device's interfaces, if any.
///
/// Taking such a device with libusb (even as root) makes macOS 26 tear the driver down and then refuse
/// every further user-space access to the device until it is plugged in again, because the capture
/// needs Apple's `com.apple.vm.device-access` entitlement. So the helper refuses instead of trying.
func macOSDriverHolding(vendor: Int, product: Int, location: UInt32) -> String? {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iterator) }
    while case let device = IOIteratorNext(iterator), device != 0 {
        defer { IOObjectRelease(device) }
        func number(_ entry: io_registry_entry_t, _ key: String) -> Int? {
            IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
        }
        guard number(device, "idVendor") == vendor, number(device, "idProduct") == product,
              UInt32(truncatingIfNeeded: number(device, "locationID") ?? -1) == location else { continue }
        return interfaceDriver(of: device)
    }
    return nil
}

/// The class of the first driver attached below one of the device's IOUSBHostInterface children.
func interfaceDriver(of device: io_registry_entry_t) -> String? {
    var children: io_iterator_t = 0
    guard IORegistryEntryGetChildIterator(device, kIOServicePlane, &children) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(children) }
    while case let child = IOIteratorNext(children), child != 0 {
        defer { IOObjectRelease(child) }
        guard IOObjectConformsTo(child, "IOUSBHostInterface") != 0 else { continue }
        var driver: io_registry_entry_t = 0
        guard IORegistryEntryGetChildEntry(child, kIOServicePlane, &driver) == KERN_SUCCESS, driver != 0 else { continue }
        defer { IOObjectRelease(driver) }
        var name = [CChar](repeating: 0, count: 128)
        IOObjectGetClass(driver, &name)
        return String(cString: name)
    }
    return nil
}
