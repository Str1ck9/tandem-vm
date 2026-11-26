import AppKit
import EngineQEMU
import GuestLink
import VMCore

/// Seamless mode: every program window of the guest is shown as a Mac window of its own.
///
/// The guest's desktop is laid over the Mac screen's usable area at the same size. The guest tools
/// report which windows exist, where, and in which order; each Mac window shows that rectangle of the
/// guest's screen picture and sends pointer and keys back at the matching guest position. A guest
/// window covered by another has no pixels of its own, so the Mac windows keep the guest's order.
@MainActor
final class SeamlessController: NSObject, NSWindowDelegate {
    private let client: RFBClient
    private let link: GuestLinkHost
    private let input: GuestInput
    private let name: String
    private(set) var layout: GuestWindowLayout
    private var windows: [UInt64: SeamlessWindow] = [:]
    /// Guest window ids as last stacked, front-most first.
    private var order: [UInt64] = []
    private var activeGuestWindow: UInt64?
    private var image: CGImage?
    private var refreshTimer: Timer?
    private let dirtyLock = NSLock()
    private nonisolated(unsafe) var dirty = true
    private var cursor: RFBClient.Cursor?
    private var needsFirstKey = true
    /// The guest's last report in full, minimised windows included.
    private var reported: [GuestWindow] = []
    /// Told about every report, with the windows on screen.
    var onWindows: (([GuestWindow]) -> Void)?
    /// The icon of a guest window's program, when the guest has handed one out.
    var iconProvider: ((GuestWindow) -> NSImage?)?
    /// The window the user is dragging, from the guest's report; nil when none is.
    private var move: GuestWindowMove?
    /// Where each window was last reported, in guest pixels: what its picture is cut from.
    private var reportedRects: [UInt64: CGRect] = [:]
    /// Moving a dragged window with the pointer between reports. Off only for measurements.
    var predictDrags = ProcessInfo.processInfo.environment["TANDEM_SEAMLESS_NO_PREDICT"] == nil
    /// Counters for the self-test: how often frames changed and what the picture cost.
    private(set) var stats = Stats()
    struct Stats {
        var reports = 0
        var frameMoves = 0
        var pictures = 0
        /// Copying the guest's screen, off the main thread.
        var pictureSeconds = 0.0
        /// Handing each copy to the windows, on the main thread.
        var mainSeconds = 0.0
    }
    func resetStats() { stats = Stats() }

    /// The Mac displays, as Seamless Mode lays the guest's desktop over them. The first screen is the one
    /// with the menu bar. `TANDEM_SEAMLESS_DISPLAYS` ("x,y,w,h,scale;…", the first is the main one)
    /// stands in for real displays in self-tests on a Mac with only one.
    static func displays() -> [GuestWindowLayout.Display] {
        if let spec = ProcessInfo.processInfo.environment["TANDEM_SEAMLESS_DISPLAYS"] {
            let simulated = spec.split(separator: ";").enumerated().compactMap { index, part -> GuestWindowLayout.Display? in
                let n = part.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                guard n.count == 5 else { return nil }
                return GuestWindowLayout.Display(visibleFrame: CGRect(x: n[0], y: n[1], width: n[2], height: n[3]), scale: n[4], isMain: index == 0)
            }
            if !simulated.isEmpty { return simulated }
        }
        return NSScreen.screens.enumerated().map { index, screen in
            GuestWindowLayout.Display(visibleFrame: screen.visibleFrame, scale: screen.backingScaleFactor, isMain: index == 0)
        }
    }

    /// How the guest's desktop is laid over the Mac's displays now.
    static func desktopPlan(retina: Bool) -> GuestWindowLayout.DesktopPlan {
        GuestWindowLayout.plan(displays: displays(), retina: retina)
            ?? GuestWindowLayout.DesktopPlan(area: CGRect(x: 0, y: 0, width: 1440, height: 900), scale: 1,
                                             pixels: CGSize(width: 1440, height: 900), mainWorkArea: CGRect(x: 0, y: 0, width: 1440, height: 900))
    }

    /// The arrangement the guest's desktop is laid over; the session changes it when displays change.
    var plan: GuestWindowLayout.DesktopPlan
    /// Called when the Mac's displays change (one plugged in or out, arrangement, resolution).
    var onDisplaysChanged: (() -> Void)?
    private var screenObserver: NSObjectProtocol?

    init(client: RFBClient, link: GuestLinkHost, name: String, plan: GuestWindowLayout.DesktopPlan) {
        self.client = client
        self.link = link
        self.name = name
        self.plan = plan
        self.input = GuestInput(client: client)
        let size = client.size
        self.layout = GuestWindowLayout(desktop: CGSize(width: size.width, height: size.height), area: plan.area)
        self.dragOut = SeamlessDragOut(client: client, input: input, link: link)
        super.init()
    }

    /// Files dragged out of File Explorer windows onto the Mac.
    let dragOut: SeamlessDragOut

    /// Where a drag began, in guest pixels, when it is one that should leave the guest as files: it began
    /// in a File Explorer window, no window move or resize is under way, the button is still held, and
    /// the pointer has just left every guest window on the Mac.
    func dragOutCandidate() -> (x: Int, y: Int)? {
        guard move == nil, input.pointer.leftDown, let press = input.leftPressedAt else { return nil }
        let mouse = NSEvent.mouseLocation
        guard !windows.values.contains(where: { $0.frame.contains(mouse) }) else { return nil }
        let point = CGPoint(x: press.x, y: press.y)
        let source = reported.first { $0.state != .minimized && $0.kind != .taskbar
            && CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height).contains(point) }
        guard let source, source.class == "CabinetWClass" || source.class == "ExploreWClass" || GuestIntegration.isLinuxFileManager(source.class) else { return nil }
        return press
    }

    func start() {
        client.onUpdate = { [weak self] in self?.markDirty() }
        client.onResize = { [weak self] _ in self?.markDirty() }
        client.onCursor = { [weak self] cursor in Task { @MainActor in self?.setCursor(cursor) } }
        link.onWindowReport = { [weak self] list in Task { @MainActor in self?.apply(list) } }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.followDrag()
                self?.refreshIfNeeded()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onDisplaysChanged?() }
        }
        link.watchWindows(true)
    }

    func stop() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        dragOut.stop()
        link.watchWindows(false)
        link.onWindowReport = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        client.onUpdate = nil
        client.onResize = nil
        client.onCursor = nil
        input.releaseAll()
        for window in windows.values { window.delegate = nil; window.orderOut(nil) }
        windows = [:]
        order = []
        reported = []
        reportedRects = [:]
        move = nil
    }

    private nonisolated func markDirty() { dirtyLock.withLock { dirty = true } }

    // MARK: Picture

    /// Copying the guest's screen (5 MB, or 21 MB at Retina resolution) is done off the main thread, so
    /// dragging and typing never wait for it. At most one copy is under way; changes meanwhile are
    /// picked up by the next one.
    private let pictureQueue = DispatchQueue(label: "tandem.seamless.picture", qos: .userInteractive)
    private var pictureInFlight = false

    private func refreshIfNeeded() {
        guard !pictureInFlight else { return }
        let needed = dirtyLock.withLock { () -> Bool in let d = dirty; dirty = false; return d }
        guard needed else { return }
        pictureInFlight = true
        let client = self.client
        let space = Self.pictureColorSpace
        pictureQueue.async { [weak self] in
            let began = CACurrentMediaTime()
            let shot = client.snapshot()
            var picture: CGImage?
            if shot.size.width > 0, shot.size.height > 0, let provider = CGDataProvider(data: shot.pixels as CFData) {
                picture = CGImage(
                    width: shot.size.width, height: shot.size.height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: shot.size.width * 4, space: space,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            }
            let copySeconds = CACurrentMediaTime() - began
            let desktop = CGSize(width: shot.size.width, height: shot.size.height)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.show(picture, desktop: desktop, copySeconds: copySeconds) }
            }
        }
    }

    /// The guest's colours are shown as the display's own, so Core Animation does not convert every
    /// pixel of every frame (it did, from generic RGB, at 15 ms a frame at Retina resolution).
    private static var pictureColorSpace: CGColorSpace {
        (NSScreen.main ?? NSScreen.screens.first)?.colorSpace?.cgColorSpace ?? CGColorSpaceCreateDeviceRGB()
    }

    private func show(_ picture: CGImage?, desktop: CGSize, copySeconds: Double) {
        pictureInFlight = false
        guard refreshTimer != nil, let picture else { return }
        let began = CACurrentMediaTime()
        image = picture
        if desktop != layout.desktop {
            // The guest's screen changed size; the next window report brings matching positions.
            layout.desktop = desktop
            layout.area = GuestWindowLayout.pixelExactArea(desktop: desktop, screen: plan.area)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for window in windows.values { window.screenView.layer?.contents = picture }
        CATransaction.commit()
        stats.pictures += 1
        stats.pictureSeconds += copySeconds
        stats.mainSeconds += CACurrentMediaTime() - began
    }

    private func setCursor(_ cursor: RFBClient.Cursor) {
        self.cursor = cursor
        for window in windows.values { window.screenView.setGuestCursor(cursor) }
    }

    // MARK: Windows

    private func apply(_ list: GuestWindowList) {
        guard refreshTimer != nil else { return }
        layout.area = GuestWindowLayout.pixelExactArea(desktop: layout.desktop, screen: plan.area)
        reported = list.windows
        move = list.moving
        stats.reports += 1
        let shown = layout.shown(list.windows)
        onWindows?(list.windows)
        let ids = Set(shown.map(\.id))
        for (id, window) in windows where !ids.contains(id) {
            window.delegate = nil
            window.orderOut(nil)
            windows[id] = nil
            reportedRects[id] = nil
        }
        var created = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for guest in shown {
            guard let rect = layout.visibleRect(of: guest) else { continue }
            let window: SeamlessWindow
            if let existing = windows[guest.id] {
                window = existing
            } else {
                window = SeamlessWindow(guest: guest, client: client, input: input, controller: self)
                window.delegate = self
                window.screenView.layer?.contents = image
                if let cursor { window.screenView.setGuestCursor(cursor) }
                windows[guest.id] = window
                created = true
            }
            window.guest = guest
            window.title = guest.title.isEmpty ? name : guest.title
            if guest.kind == .app, window.miniwindowImage == nil { window.miniwindowImage = iconProvider?(guest) }
            reportedRects[guest.id] = rect
            place(window, reported: rect)
            // Program windows of Windows 11 have rounded corners, except when they fill the screen.
            let radius: CGFloat = guest.state == .maximized || guest.kind == .taskbar ? 0 : (guest.kind == .app ? 8 : 4)
            if window.screenView.layer?.cornerRadius != radius {
                window.screenView.layer?.cornerRadius = radius
                window.invalidateShadow()
            }
        }
        CATransaction.commit()

        let newOrder = shown.map(\.id)
        activeGuestWindow = shown.first(where: \.active)?.id
        if created || newOrder != order {
            order = newOrder
            restack()
        }
        // The window the guest made active takes the keys, if Tandem is the app in front. On entering the
        // mode it takes them from whichever Tandem window had them, so typing goes on where it was.
        if let id = activeGuestWindow, let window = windows[id], window.canBecomeKey, !window.isKeyWindow {
            if needsFirstKey {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            } else if NSApp.isActive, NSApp.keyWindow is SeamlessWindow || NSApp.keyWindow == nil {
                window.makeKey()
            }
        }
        if !windows.isEmpty { needsFirstKey = false }
    }

    /// Sets a window's frame and the part of the guest's screen it shows. A window being dragged is put
    /// where the pointer has taken it, and shows its picture from where the guest last drew it, so it
    /// moves with the pointer at the display's rate instead of jumping from report to report.
    private func place(_ window: SeamlessWindow, reported rect: CGRect) {
        var frameRect = rect
        let resizing = move?.edge != nil
        if predictDrags, let move, move.id == window.guest.id, resizing || (Int(rect.width) == move.width && Int(rect.height) == move.height) {
            let pointer = input.pointer
            if pointer.leftDown {
                // The press point counts only if it was on the window when the move began.
                let press = input.leftPressedAt.flatMap { p -> (x: Int, y: Int)? in
                    CGRect(x: move.x, y: move.y, width: move.width, height: move.height).contains(CGPoint(x: p.x, y: p.y)) ? p : nil
                }
                let dragged = GuestWindowLayout.draggedRect(move, pointer: (pointer.x, pointer.y), pressedAt: press)
                    .intersection(CGRect(origin: .zero, size: layout.desktop))
                if !dragged.isNull, dragged.width >= 1, dragged.height >= 1 { frameRect = dragged }
            }
        }
        // The picture: the reported rectangle, cut to the size of what is on screen of the frame. While a
        // window is resized it does not move on the guest's screen, so the frame's own rectangle is shown:
        // what the guest has drawn there so far, which it redraws as the window grows.
        var source = rect
        if resizing, move?.id == window.guest.id, frameRect != rect {
            source = frameRect
        } else if frameRect.size != rect.size {
            source = CGRect(origin: rect.origin, size: frameRect.size).intersection(CGRect(origin: .zero, size: layout.desktop))
            if source.size != frameRect.size { source = rect; frameRect = rect }
        }
        let frame = layout.macFrame(forGuestRect: frameRect)
        if window.frame != frame { window.setFrame(frame, display: false); stats.frameMoves += 1 }
        window.screenView.layer?.contentsRect = layout.unitRect(forGuestRect: source)
    }

    /// Between reports: moves the window being dragged with the pointer.
    private func followDrag() {
        guard predictDrags, let move, let window = windows[move.id], let rect = reportedRects[move.id] else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        place(window, reported: rect)
        CATransaction.commit()
    }

    /// Puts the Mac windows in the guest's order. The stack hangs from the front-most window, so the
    /// guest's windows stay together and do not jump in front of other apps while Tandem is in the back.
    private func restack() {
        var previous: NSWindow?
        let stack = order.compactMap { windows[$0] }
        for window in stack {
            if let previous {
                window.order(.below, relativeTo: previous.windowNumber)
            } else if !window.isVisible {
                if !NSApp.isActive, let anchor = stack.dropFirst().first(where: \.isVisible) {
                    window.order(.above, relativeTo: anchor.windowNumber)
                } else {
                    window.orderFront(nil)
                }
            } else if NSApp.isActive {
                window.orderFront(nil)
            }
            previous = window
        }
    }

    // MARK: For the menus

    /// The guest's program windows that have a title, front-most first, minimised ones included.
    var programWindows: [GuestWindow] { reported.filter { $0.kind == .app && !$0.title.isEmpty } }

    /// True for a Mac window that shows one of this VM's guest windows.
    func owns(_ window: NSWindow) -> Bool { windows.values.contains { $0 === window } }

    /// Brings a guest window to the front on both sides. A minimised one has no Mac window yet; the
    /// guest restores it and the next report brings it.
    func activate(_ id: UInt64) {
        NSApp.activate(ignoringOtherApps: true)
        activeGuestWindow = id
        link.windowAction(.activate, window: id)
        windows[id]?.makeKeyAndOrderFront(nil)
    }

    /// New icons arrived from the guest.
    func iconsChanged() {
        for window in windows.values where window.guest.kind == .app && window.miniwindowImage == nil {
            window.miniwindowImage = iconProvider?(window.guest)
        }
    }

    /// The guest pixel under the pointer, from its place on the Mac screen. Independent of the Mac
    /// window's own position, which lags behind while the guest moves a window.
    func guestPointUnderPointer() -> (x: Int, y: Int) {
        layout.guestPoint(forMacPoint: NSEvent.mouseLocation)
    }

    // MARK: Self-test

    /// What is on the Mac screen, front-most first, and each window's picture as a PNG file.
    func debugDump(to directory: URL?, tag: String) -> [String] {
        var lines = ["seamless: desktop \(Int(layout.desktop.width))x\(Int(layout.desktop.height)) over \(layout.area)"]
        for (index, id) in order.enumerated() {
            guard let window = windows[id] else { continue }
            let rect = window.screenView.layer?.contentsRect ?? .zero
            lines.append("  \(index) \(window.guest.kind.rawValue) id \(id) frame \(window.frame) visible \(window.isVisible) onScreen \(window.occlusionState.contains(.visible)) key \(window.isKeyWindow) guestActive \(window.guest.active) “\(window.guest.title)”")
            if let directory, let image, let crop = image.cropping(to: CGRect(
                x: rect.minX * CGFloat(image.width), y: rect.minY * CGFloat(image.height),
                width: rect.width * CGFloat(image.width), height: rect.height * CGFloat(image.height))) {
                let rep = NSBitmapImageRep(cgImage: crop)
                try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(tag)-\(index)-\(id).png"))
            }
        }
        return lines
    }

    /// For the drag trial: a window's Mac frame and the guest rectangle its picture comes from, in guest pixels.
    func debugGeometry(of id: UInt64) -> (frame: CGRect, source: CGRect)? {
        guard let window = windows[id], let layer = window.screenView.layer else { return nil }
        let f = window.frame, a = layout.area, d = layout.desktop
        let sx = d.width / a.width, sy = d.height / a.height
        let frame = CGRect(x: (f.minX - a.minX) * sx, y: (a.maxY - f.maxY) * sy, width: f.width * sx, height: f.height * sy)
        let c = layer.contentsRect
        return (frame, CGRect(x: c.minX * d.width, y: c.minY * d.height, width: c.width * d.width, height: c.height * d.height))
    }

    var debugInput: GuestInput { input }
    var debugReported: [GuestWindow] { reported }

    /// The top band of a window's picture (its title and menu bar, no document), `points` high, as the
    /// guest drew it: for comparing sharpness at 1x and at Retina resolution.
    func debugTopBand(of id: UInt64, points: CGFloat) -> CGImage? {
        guard let image, let rect = reportedRects[id] else { return nil }
        let scale = layout.desktop.width / max(layout.area.width, 1)
        return image.cropping(to: CGRect(x: rect.minX, y: rect.minY, width: min(rect.width, 420 * scale), height: points * scale))
    }
    var debugMove: GuestWindowMove? { move }

    /// Makes the Mac window of a guest window the key window, as a click in Mission Control would.
    func debugMakeKeyBackmost() {
        guard let id = order.last, let window = windows[id] else { return }
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: NSWindowDelegate

    /// A window chosen on the Mac side (Mission Control, the Window menu) becomes the guest's active window.
    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? SeamlessWindow, window.guest.id != activeGuestWindow else { return }
        activeGuestWindow = window.guest.id
        link.windowAction(.activate, window: window.guest.id)
    }

    func windowDidResignKey(_ notification: Notification) {
        if !(NSApp.keyWindow is SeamlessWindow) { input.releaseAll() }
    }
}

/// One guest window on the Mac: no Mac title bar, because the guest draws its own.
final class SeamlessWindow: NSWindow {
    var guest: GuestWindow
    let screenView: SeamlessScreenView

    init(guest: GuestWindow, client: RFBClient, input: GuestInput, controller: SeamlessController) {
        self.guest = guest
        self.screenView = SeamlessScreenView(client: client, input: input, controller: controller)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = guest.kind != .taskbar
        animationBehavior = .none
        // Menus and tool tips float over the program window and never show in Mission Control.
        if guest.kind == .popup {
            level = .floating
            collectionBehavior = [.transient, .ignoresCycle]
        } else {
            collectionBehavior = [.managed, .participatesInCycle]
        }
        isExcludedFromWindowsMenu = guest.kind != .app
        contentView = screenView
    }

    /// Keys go to program windows; a menu or tool tip must not take them away.
    /// The task bar can take them too: its search box is typed into.
    override var canBecomeKey: Bool { guest.kind != .popup }
    override var canBecomeMain: Bool { guest.kind == .app }
}

/// Shows a rectangle of the guest's screen and sends input at the matching guest position.
final class SeamlessScreenView: GuestScreenNSView {
    private weak var controller: SeamlessController?

    init(client: RFBClient, input: GuestInput, controller: SeamlessController) {
        self.controller = controller
        super.init(client: client, input: input, drawsScreen: false)
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.contentsGravity = .resize
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var pictureRect: NSRect { bounds }
    // Menus cannot become the key window, and hovering over a window in the back should still work.
    override var trackingActivity: NSTrackingArea.Options { .activeAlways }
    override func guestPoint(for event: NSEvent) -> (x: Int, y: Int)? {
        MainActor.assumeIsolated { controller?.guestPointUnderPointer() }
    }

    // A drag from File Explorer that leaves every guest window goes on as a drag of files on the Mac.
    override func mouseDragged(with event: NSEvent) {
        if let controller, controller.dragOut.dragged(event, in: self, controller: controller) { return }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if let controller, controller.dragOut.released() { return }
        super.mouseUp(with: event)
    }
}
