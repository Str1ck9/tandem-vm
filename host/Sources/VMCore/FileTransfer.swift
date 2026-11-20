import Foundation

// MARK: Files carried between the Mac and a guest (drag and drop, "Send to Mac")

/// Files moved by hand between the Mac and a guest go the same way as copy and paste: they are
/// allowed in the directions the VM's clipboard setting allows, and not at all when it is off
/// (the restricted preset). No folder needs to be shared for this.
extension SharingPolicy {
    /// Files may be dropped from the Mac into the guest.
    public var allowsFilesToGuest: Bool { clipboard.toGuest }
    /// The guest may send files to the Mac.
    public var allowsFilesToMac: Bool { clipboard.toMac }

    /// Throws unless files may be dropped into the guest.
    public func requireFilesToGuest() throws {
        guard allowsFilesToGuest else {
            throw VMError("Dragging files into this virtual machine is turned off.",
                          detail: "Under Configure > Options > Sharing, set Clipboard to “Both ways” or “Mac to virtual machine only”.")
        }
    }

    /// Throws unless the guest may send files to the Mac.
    public func requireFilesToMac() throws {
        guard allowsFilesToMac else {
            throw VMError("Sending files from this virtual machine to the Mac is turned off.",
                          detail: "Under Configure > Options > Sharing, set Clipboard to “Both ways” or “Virtual machine to Mac only”.")
        }
    }
}
