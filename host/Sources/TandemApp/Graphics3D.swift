import EngineQEMU
import Foundation
import VMCore

/// What the Graphics pane says about experimental 3D acceleration for Linux guests.
enum Graphics3D {
    static var isInstalled: Bool { (try? QEMUToolchain.locate3D()) != nil }

    static func note(installed: Bool) -> String {
        let what = "Linux programs get OpenGL 4.1 through the Mac’s graphics chip (virglrenderer, the approach UTM uses)."
        let limits = "While it is on, the VM cannot be suspended, because the graphics state cannot be saved."
        return installed
            ? "\(what) \(limits) Takes effect at the next start."
            : "\(what) It needs Tandem’s 3D build of QEMU, which is not installed (scripts/build-qemu-3d.sh). \(limits)"
    }

    static var isWindowsInstalled: Bool { (try? QEMUToolchain.locate3D(windows: true)) != nil }

    static func windowsNote(installed: Bool, driver: Windows3DDriverState?) -> String {
        let what = "Windows programs get Direct3D 11 (feature level 11_1) on the Mac’s graphics chip, through the open, Microsoft-signed ARM64 display driver from UTM’s guest tools and DXMT (Direct3D 11 on Metal)."
        let how = driver.map { "The driver (\($0.version)) is installed in Windows." }
            ?? "At the next start Tandem downloads the driver (about 140 MB, once), Windows installs it by itself, and restarts once."
        let limits = "Experimental: the VM cannot be suspended while 3D is on, and Direct3D 12 is not available. Turning 3D off returns to the normal display: at the next start Tandem takes the driver out of Windows, which restarts once (the normal display stays dark while the 3D driver is installed)."
        return installed
            ? "\(what) \(how) \(limits)"
            : "\(what) It needs Tandem’s 3D build of QEMU with DXMT and the render server, which is not installed (scripts/build-qemu-3d.sh)."
    }
}
