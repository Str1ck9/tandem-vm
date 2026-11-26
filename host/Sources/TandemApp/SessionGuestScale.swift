import AppKit
import Foundation
import GuestLink
import VMCore

/// Windows' display scale follows the size of the guest's screen against the Mac window: a Retina-sized
/// screen (more pixels than the window has points) makes Windows' interface tiny at 100%, so the guest is
/// asked for the scale that gives it the size it would have in a window of that many points.
extension VMSession {
    /// Pixels per point of the screen the VM's window is on.
    static var windowBackingScale: CGFloat {
        (NSApp.windows.first { $0.isKeyWindow }?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
    }

    /// Guest tools capability bit 15: the agent can set the guest's display scale.
    private var canSetGuestScale: Bool { (agent?.capabilities ?? 0) & (1 << 15) != 0 }

    /// Asks Windows for the scale that matches its screen to the window, once the guest has reported its size.
    /// Called when the guest reports its display and when the window's size settles. Seamless Mode sets its own
    /// scale while it lasts.
    func adjustGuestScale(after seconds: Double = 0.8) {
        guard config.guestOS == .windows11arm, state == .running, seamless == nil, canSetGuestScale else { return }
        retinaScaleTask?.cancel()
        retinaScaleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.seamless == nil, let report = self.displayReport else { return }
            let target = GuestDisplayScale.target(guestWidth: Int(report.width), viewWidthPoints: self.viewPointSize.map { Double($0.width) },
                                                enabled: self.config.display.matchWindowsScale)
            self.applyRetinaScale(target)
        }
    }

    private func applyRetinaScale(_ target: Int?) {
        switch (target, retinaScaleRequested) {
        case (nil, nil):
            return
        case (nil, .some), (100, .some):
            // Back to the scale the guest had before Tandem changed it.
            link.setDisplayScale(0)
            retinaScaleRequested = nil
        case (100, nil):
            return
        case let (percent?, previous):
            guard previous != percent else { return }
            link.setDisplayScale(percent)
            retinaScaleRequested = percent
        }
    }
}
