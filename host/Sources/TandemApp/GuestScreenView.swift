import AppKit
import EngineQEMU
import SwiftUI

/// Shows a QEMU guest's screen and sends it keyboard and mouse input.
class GuestScreenNSView: NSView {
    let client: RFBClient
    let input: GuestInput
    private var dirty = true
    private let dirtyLock = NSLock()
    private var refreshTimer: Timer?
    private var guestCursor: NSCursor?
    /// Fractions of a wheel notch not yet sent.
    private var scrollRemainder: CGFloat = 0

    /// `drawsScreen` false leaves the picture to the owner (a seamless window shows a part of the screen
    /// that its controller hands it); the view then only carries input, with the controller's `input`.
    init(client: RFBClient, input: GuestInput? = nil, drawsScreen: Bool = true) {
        self.client = client
        self.input = input ?? GuestInput(client: client)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .trilinear
        // Finder files dropped here are copied into the guest (SessionFileDrop.swift).
        registerForDraggedTypes([.fileURL])
        guard drawsScreen else { return }

        client.onUpdate = { [weak self] in self?.markDirty() }
        client.onResize = { [weak self] _ in self?.markDirty() }
        client.onCursor = { [weak self] cursor in
            DispatchQueue.main.async { self?.setGuestCursor(cursor) }
        }
        // Draw at most 60 times a second however often the guest updates.
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.refreshIfNeeded() }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        refreshIfNeeded()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { refreshTimer?.invalidate() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func markDirty() { dirtyLock.withLock { dirty = true } }

    private func refreshIfNeeded() {
        let needed = dirtyLock.withLock { () -> Bool in let d = dirty; dirty = false; return d }
        guard needed else { return }
        let shot = client.snapshot()
        guard shot.size.width > 0, shot.size.height > 0, let provider = CGDataProvider(data: shot.pixels as CFData) else { return }
        applyScaling(framebuffer: shot.size)
        layer?.contents = CGImage(
            width: shot.size.width, height: shot.size.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: shot.size.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// How the picture sits in the view, from the VM's scaling setting (Configure > Options > Full Screen).
    private func applyScaling(framebuffer: RFBClient.Size) {
        let gravity: CALayerContentsGravity
        switch client.inputSettings.scaling {
        case .fit: gravity = .resizeAspect
        case .stretch: gravity = .resize
        case .actualSize:
            // One guest pixel per point while it fits; a smaller view scales the picture down to fit.
            let fits = CGFloat(framebuffer.width) <= bounds.width && CGFloat(framebuffer.height) <= bounds.height
            gravity = fits ? .center : .resizeAspect
        }
        guard layer?.contentsGravity != gravity else { return }
        layer?.contentsGravity = gravity
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Cursor

    func setGuestCursor(_ cursor: RFBClient.Cursor) {
        guard cursor.width > 0, cursor.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cursor.width, pixelsHigh: cursor.height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bitmapFormat: .alphaNonpremultiplied, bytesPerRow: cursor.width * 4, bitsPerPixel: 32),
              let target = rep.bitmapData else { guestCursor = nil; window?.invalidateCursorRects(for: self); return }
        cursor.rgba.copyBytes(to: target, count: min(cursor.rgba.count, cursor.width * cursor.height * 4))
        let image = NSImage(size: NSSize(width: cursor.width, height: cursor.height))
        image.addRepresentation(rep)
        guestCursor = NSCursor(image: image, hotSpot: NSPoint(x: cursor.hotX, y: cursor.hotY))
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        addCursorRect(pictureRect, cursor: guestCursor ?? .arrow)
    }

    /// The part of the view that shows the guest's screen.
    var pictureRect: NSRect {
        GuestInput.screenRect(viewSize: bounds.size, framebuffer: client.size, scaling: client.inputSettings.scaling)
    }
    /// When the pointer is followed: only in the key window, except where a subclass says otherwise.
    var trackingActivity: NSTrackingArea.Options { .activeInKeyWindow }
    /// The guest pixel a mouse event points at.
    func guestPoint(for event: NSEvent) -> (x: Int, y: Int)? {
        GuestInput.framebufferPoint(viewPoint: convert(event.locationInWindow, from: nil), viewSize: bounds.size,
                                    framebuffer: client.size, scaling: client.inputSettings.scaling)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .inVisibleRect, trackingActivity], owner: self))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Mouse

    private func move(_ event: NSEvent) {
        guard let p = guestPoint(for: event) else { return }
        input.movePointer(toX: p.x, y: p.y)
    }

    private func button(_ event: NSEvent, _ button: RFBClient.Buttons, down: Bool) {
        if down, window?.canBecomeKey == true { window?.makeFirstResponder(self) }
        move(event)
        input.setButton(button, down: down)
    }

    override func mouseMoved(with event: NSEvent) { move(event) }
    override func mouseDragged(with event: NSEvent) { move(event) }
    override func rightMouseDragged(with event: NSEvent) { move(event) }
    override func otherMouseDragged(with event: NSEvent) { move(event) }
    override func mouseDown(with event: NSEvent) {
        // Control-click is a right click on a Mac.
        button(event, event.modifierFlags.contains(.control) ? .right : .left, down: true)
    }
    override func mouseUp(with event: NSEvent) { move(event); input.setButton(.left, down: false); input.setButton(.right, down: false) }
    override func rightMouseDown(with event: NSEvent) { button(event, .right, down: true) }
    override func rightMouseUp(with event: NSEvent) { button(event, .right, down: false) }
    override func otherMouseDown(with event: NSEvent) { button(event, .middle, down: true) }
    override func otherMouseUp(with event: NSEvent) { button(event, .middle, down: false) }

    override func scrollWheel(with event: NSEvent) {
        // Trackpads report points, mice report lines. One guest wheel notch per 10 points or 1 line.
        scrollRemainder += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 10 : event.scrollingDeltaY
        var notches = Int(scrollRemainder.rounded(.towardZero))
        scrollRemainder -= CGFloat(notches)
        notches = min(max(notches, -10), 10)
        if client.inputSettings.invertScrolling { notches = -notches }
        for _ in 0..<abs(notches) { input.scroll(up: notches > 0) }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) { input.key(macKeyCode: event.keyCode, down: true) }
    override func keyUp(with event: NSEvent) { input.key(macKeyCode: event.keyCode, down: false) }

    /// Command shortcuts go to the guest while its screen has focus, the same as every other key.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return false }
        // Control-Command combinations stay with the Mac: they are Tandem's own shortcuts (leave Seamless Mode).
        if event.modifierFlags.contains([.control, .command]) { return false }
        // The VM's setting can leave every Command shortcut to the Mac's menus (Quit, Hide, Close…).
        if !client.inputSettings.commandShortcutsToGuest { return false }
        // AppKit sends no keyUp while Command is held, so press and release here.
        if input.key(macKeyCode: event.keyCode, down: true) { input.key(macKeyCode: event.keyCode, down: false) }
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        let code = event.keyCode
        if code == 0x39 { // Caps Lock toggles: tap it
            input.key(macKeyCode: code, down: true); input.key(macKeyCode: code, down: false)
            return
        }
        let flag: NSEvent.ModifierFlags? = switch code {
        case 0x38, 0x3C: .shift
        case 0x3B, 0x3E: .control
        case 0x3A, 0x3D: .option
        case 0x36, 0x37: .command
        default: nil
        }
        guard let flag else { return }
        // The event carries which key changed but not its direction: it went up if it was down, or if its modifier is now off.
        let down = event.modifierFlags.contains(flag) && !input.isDown(macKeyCode: code)
        input.key(macKeyCode: code, down: down)
    }

    override func resignFirstResponder() -> Bool {
        input.releaseAll()
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window, window.canBecomeKey {
            DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(self) }
        } else {
            input.releaseAll()
        }
    }
}

struct GuestScreenView: NSViewRepresentable {
    let client: RFBClient

    func makeNSView(context: Context) -> GuestScreenNSView { GuestScreenNSView(client: client) }
    func updateNSView(_ view: GuestScreenNSView, context: Context) {}
}
