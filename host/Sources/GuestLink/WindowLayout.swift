import CoreGraphics
import Foundation

/// Where the guest's windows go on the Mac when each is shown as a window of its own.
/// The guest's desktop is laid over `area` (Mac screen coordinates, origin bottom-left, y up);
/// guest coordinates have their origin top-left, y down.
public struct GuestWindowLayout: Equatable, Sendable {
    public var desktop: CGSize
    public var area: CGRect

    public init(desktop: CGSize, area: CGRect) { self.desktop = desktop; self.area = area }

    private var scaleX: CGFloat { desktop.width > 0 ? area.width / desktop.width : 1 }
    private var scaleY: CGFloat { desktop.height > 0 ? area.height / desktop.height : 1 }

    /// The part of a guest window that is on the guest's screen, in guest pixels. Nil when none of it is.
    public func visibleRect(of window: GuestWindow) -> CGRect? {
        let rect = CGRect(x: window.x, y: window.y, width: window.width, height: window.height)
            .intersection(CGRect(origin: .zero, size: desktop))
        return rect.isNull || rect.width < 1 || rect.height < 1 ? nil : rect
    }

    /// The Mac screen frame for a rectangle of the guest's screen.
    public func macFrame(forGuestRect rect: CGRect) -> CGRect {
        CGRect(x: area.minX + rect.minX * scaleX, y: area.maxY - rect.maxY * scaleY,
               width: rect.width * scaleX, height: rect.height * scaleY)
    }

    /// The guest pixel under a point of the Mac screen, clamped to the guest's screen.
    public func guestPoint(forMacPoint point: CGPoint) -> (x: Int, y: Int) {
        // Clamped before the conversion to Int, which traps on values out of range: the desktop size
        // comes from the guest, and an empty area divides by zero.
        func pixel(_ value: CGFloat, within size: CGFloat) -> Int {
            let last = max(min(size, 1_073_741_824) - 1, 0).rounded(.down)
            guard !value.isNaN else { return 0 }
            return Int(min(max(value, 0), last).rounded(.down))
        }
        return (pixel((point.x - area.minX) / scaleX, within: desktop.width), pixel((area.maxY - point.y) / scaleY, within: desktop.height))
    }

    /// The rectangle as a fraction of the guest's screen, origin top-left: what a layer's `contentsRect` takes.
    public func unitRect(forGuestRect rect: CGRect) -> CGRect {
        guard desktop.width > 0, desktop.height > 0 else { return .zero }
        return CGRect(x: rect.minX / desktop.width, y: rect.minY / desktop.height,
                      width: rect.width / desktop.width, height: rect.height / desktop.height)
    }

    /// The part of the Mac screen area the guest's desktop is laid over, so that guest pixels land on
    /// whole screen pixels. The display driver does not always take the exact size it was asked for
    /// (1744 or 1748 lines for 1740), and stretching by that little blurs every line of text. When the
    /// desktop is close to a whole multiple of the area (1x or 2x), it is laid over the top-left of the
    /// area at exactly that multiple instead; a few points at the bottom are then left over or hidden.
    public static func pixelExactArea(desktop: CGSize, screen area: CGRect) -> CGRect {
        guard desktop.width > 0, desktop.height > 0, area.width > 0, area.height > 0 else { return area }
        let scale = (desktop.width / area.width).rounded()
        guard scale >= 1, abs(desktop.width / area.width - scale) < 0.02, abs(desktop.height / area.height - scale) < 0.02 else { return area }
        let size = CGSize(width: desktop.width / scale, height: desktop.height / scale)
        return CGRect(x: area.minX, y: area.maxY - size.height, width: size.width, height: size.height)
    }

    /// Where a window that the user is dragging is now: its frame when the drag began, moved by as far
    /// as the pointer has moved since the button went down. Windows keeps the point that was grabbed
    /// under the pointer, so this is where the guest will draw the window, without waiting for the next
    /// report. `pressedAt` is where the button went down; without it, the pointer when Windows began
    /// the move (a few pixels later, past the drag threshold) is the next best.
    public static func draggedRect(_ move: GuestWindowMove, pointer: (x: Int, y: Int), pressedAt: (x: Int, y: Int)? = nil) -> CGRect {
        // Everything clamped first, so no guest-chosen number can overflow the sums below.
        let move = move.sanitized()
        func c(_ v: Int) -> Int { min(max(v, -GuestWindowList.coordinateLimit), GuestWindowList.coordinateLimit) }
        let grab = pressedAt.map { (c($0.x), c($0.y)) } ?? (move.pointerX, move.pointerY)
        let dx = c(pointer.x) - grab.0, dy = c(pointer.y) - grab.1
        guard let edge = move.edge else {
            return CGRect(x: move.x + dx, y: move.y + dy, width: move.width, height: move.height)
        }
        // A resize: the grabbed edges follow the pointer, the others stay; Windows stops at its own minimum
        // size, which is not known here, so a small one is used and the next report corrects it.
        var left = move.x, top = move.y, right = move.x + move.width, bottom = move.y + move.height
        let minW = Int(minimumPredictedSize.width), minH = Int(minimumPredictedSize.height)
        if edge.movesLeft { left = min(left + dx, right - minW) }
        if edge.movesRight { right = max(right + dx, left + minW) }
        if edge.movesTop { top = min(top + dy, bottom - minH) }
        if edge.movesBottom { bottom = max(bottom + dy, top + minH) }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// The smallest size a resize is predicted down to, in guest pixels.
    public static let minimumPredictedSize = CGSize(width: 120, height: 40)

    // MARK: Several Mac displays

    /// One Mac display as Seamless Mode sees it: its usable area (menu bar and Dock left out) in global
    /// Mac coordinates (points, origin bottom-left of the main display, y up; displays left of or below
    /// the main one have negative coordinates), and its pixels per point.
    public struct Display: Equatable, Sendable {
        public var visibleFrame: CGRect
        public var scale: CGFloat
        public var isMain: Bool
        public init(visibleFrame: CGRect, scale: CGFloat, isMain: Bool = false) {
            self.visibleFrame = visibleFrame; self.scale = scale; self.isMain = isMain
        }
    }

    /// How the guest's single desktop is laid over every Mac display.
    public struct DesktopPlan: Equatable, Sendable {
        /// The rectangle of the Mac's display arrangement the guest's desktop covers, in points.
        public var area: CGRect
        /// Guest pixels per point.
        public var scale: CGFloat
        /// The guest's desktop size in pixels (even numbers, as the display device wants).
        public var pixels: CGSize
        /// The main display's usable area in guest pixels: where Windows should put maximised windows,
        /// so they fill one display rather than the whole arrangement.
        public var mainWorkArea: CGRect
        public init(area: CGRect, scale: CGFloat, pixels: CGSize, mainWorkArea: CGRect) {
            self.area = area; self.scale = scale; self.pixels = pixels; self.mainWorkArea = mainWorkArea
        }
    }

    /// The largest desktop the guest's display device takes.
    public static let maximumPixels = CGSize(width: 5120, height: 2880)

    /// Lays the guest's desktop over the bounding rectangle of all displays. The guest has one monitor,
    /// so gaps between displays of different sizes belong to the desktop but are on no Mac screen.
    /// `retina`: as many guest pixels per point as the sharpest display has (2 on Retina screens), so
    /// text is sharp there; a 1x display beside it then shows the guest at half its pixels, which is
    /// what it would show anyway. When that would exceed what the display device takes, 1 pixel per
    /// point (sharp on 1x displays, soft on Retina ones); when even that is too big, whatever fits.
    public static func plan(displays: [Display], retina: Bool, maximum: CGSize = maximumPixels) -> DesktopPlan? {
        guard let first = displays.first else { return nil }
        let area = displays.dropFirst().reduce(first.visibleFrame) { $0.union($1.visibleFrame) }.integral
        guard area.width > 0, area.height > 0 else { return nil }
        let sharpest = retina ? max(displays.map(\.scale).max() ?? 1, 1) : 1
        func fits(_ s: CGFloat) -> Bool { area.width * s <= maximum.width && area.height * s <= maximum.height }
        var scale: CGFloat = 1
        if fits(sharpest) { scale = sharpest }
        else if !fits(1) { scale = min(maximum.width / area.width, maximum.height / area.height) }
        let pixels = CGSize(width: CGFloat(Int(area.width * scale) & ~1), height: CGFloat(Int(area.height * scale) & ~1))
        let main = displays.first(where: \.isMain) ?? first
        let m = main.visibleFrame
        // Guest coordinates: origin at the area's top-left, y down.
        let work = CGRect(x: (m.minX - area.minX) * scale, y: (area.maxY - m.maxY) * scale,
                          width: m.width * scale, height: m.height * scale).integral
            .intersection(CGRect(origin: .zero, size: pixels))
        return DesktopPlan(area: area, scale: scale, pixels: pixels, mainWorkArea: work)
    }

    /// The windows to show, front-most first: program windows and their popups that are on screen.
    /// The task bar is left out (the user found it in the way), and so are minimised windows.
    public func shown(_ windows: [GuestWindow]) -> [GuestWindow] {
        windows.filter { $0.kind != .taskbar && $0.state != .minimized && visibleRect(of: $0) != nil }
    }
}
