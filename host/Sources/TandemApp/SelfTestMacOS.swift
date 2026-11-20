import AppKit
import CoreImage
import IOSurface
import VMCore

/// Self-test for macOS guests: `TANDEM_SNAPSHOT_VZSCREEN=<vm name>` starts the VM in its window, waits,
/// and writes what the guest's screen shows to `vz-screen-<n>.png` in the snapshot folder.
///
/// Apple's VM view draws through IOSurfaces that `cacheDisplay` does not see, so the picture is taken
/// from the view's own layers. That needs no screen-recording permission.
extension SelfTest {
    private static func surfaces(in layer: CALayer, into found: inout [IOSurface]) {
        if let contents = layer.contents, CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() {
            found.append(unsafeBitCast(contents as AnyObject, to: IOSurface.self))
        }
        for sublayer in layer.sublayers ?? [] { surfaces(in: sublayer, into: &found) }
    }

    static func vzScreen(_ model: AppModel, name: String) async {
        guard let directory, let session = model.sessions.first(where: { $0.config.name == name }) else {
            print("selftest: no VM named \(name)"); return
        }
        let wait = Double(ProcessInfo.processInfo.environment["TANDEM_SNAPSHOT_WAIT"] ?? "") ?? 90
        model.selection = session.id
        session.start()
        NotificationCenter.default.post(name: .selfTestShow, object: session.id)
        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        print("selftest: vz state=\(session.state.rawValue) error=\(session.errorMessage ?? "none")")
        var found: [IOSurface] = []
        for window in NSApp.windows where window.isVisible && window.title == name {
            if let layer = window.contentView?.superview?.layer ?? window.contentView?.layer { surfaces(in: layer, into: &found) }
        }
        print("selftest: vz surfaces=\(found.map { "\($0.width)x\($0.height)" })")
        let context = CIContext()
        for (index, surface) in found.enumerated() {
            let image = CIImage(ioSurface: unsafeBitCast(surface, to: IOSurfaceRef.self))
            let url = directory.appendingPathComponent("vz-screen-\(index).png")
            if let space = CGColorSpace(name: CGColorSpace.sRGB) {
                try? context.writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: space)
            }
        }
        await session.forceStopAndWait()
        print("selftest: vz final state=\(session.state.rawValue)")
    }
}
