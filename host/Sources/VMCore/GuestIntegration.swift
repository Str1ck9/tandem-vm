import Foundation

/// What the Mac can do with a guest's programs, files and windows, by guest system.
public enum GuestIntegration {
    /// Window classes (X11's `WM_CLASS`) of the file managers a drag out of a Linux guest can start from.
    public static func isLinuxFileManager(_ windowClass: String) -> Bool {
        let lower = windowClass.lowercased()
        let names = ["caja", "nautilus", "thunar", "nemo", "pcmanfm", "dolphin", "pantheon-files", "files", "spacefm", "doublecmd", "krusader"]
        return names.contains { lower == $0 || lower.hasSuffix("." + $0) }
    }
}

extension VMConfig {
    /// Windows, and Linux on the QEMU engine, list their programs: the Mac can start them and keep launchers.
    public var supportsGuestPrograms: Bool { guestOS == .windows11arm || (guestOS == .linux && engine == .qemu) }
    /// Windows and Linux (QEMU) guests take files dropped from the Mac and give files back.
    public var supportsGuestFileDrop: Bool { supportsGuestPrograms }
    /// Seamless Mode: Windows with the guest tools, and Linux when the user has turned that on.
    public func supportsSeamless(linuxEnabled: Bool) -> Bool {
        engine == .qemu && (guestOS == .windows11arm || (guestOS == .linux && linuxEnabled))
    }
    /// How the guest's operating system is named in messages about its programs.
    public var guestSystemWord: String { guestOS == .linux ? "Linux" : "Windows" }
}
