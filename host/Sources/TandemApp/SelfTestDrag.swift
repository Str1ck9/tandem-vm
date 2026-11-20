import AppKit
import EngineQEMU
import GuestLink
import VMCore

/// Self-test for Seamless Mode's drag and sharpness: `TANDEM_SNAPSHOT_DRAG=<vm name>` starts the VM,
/// opens Notepad, enters Seamless Mode, drags Notepad by its title bar twice through the guest's pointer
/// (once with the Mac window following reports only, once following the pointer), prints how often
/// the Mac window moved and how far it was from where the guest window was going, writes Notepad's
/// picture to the snapshot folder, leaves the mode and shuts the VM down.
/// `TANDEM_DRAG_RETINA=0` runs it without Retina resolution.
extension SelfTest {
    private static func wait(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    /// Resident memory of this process, in MiB.
    private static func residentMiB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return rc == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }

    static func dragTrial(_ model: AppModel, name: String) async {
        guard let session = model.sessions.first(where: { $0.config.name == name }) else { print("drag: no VM \(name)"); return }
        let env = ProcessInfo.processInfo.environment
        // Set either way: the VM saves its configuration while running, so a previous run's choice sticks.
        var behavior = session.bundle.config.behaviorOrDefault
        behavior.seamlessRetina = env["TANDEM_DRAG_RETINA"] != "0"
        session.bundle.config.behavior = behavior
        func tap(_ codes: [UInt8]) async { session.sendKeys(codes); await wait(0.15) }
        session.start()
        for _ in 0..<480 where !session.canSeamless { await wait(0.5) }
        print("drag: canSeamless=\(session.canSeamless) agent=\(session.agent?.capabilities ?? 0)")
        guard session.canSeamless else { await session.forceStopAndWait(); return }
        await wait(30)
        // Win+R, "notepad", Enter.
        await tap([0xDB, 0x13]); await wait(4)
        for code: UInt8 in [0x31, 0x18, 0x14, 0x12, 0x19, 0x1E, 0x20, 0x1C] { await tap([code]) }
        await wait(6)
        let memoryBefore = residentMiB()
        session.enterSeamless()
        await wait(14)
        guard let controller = session.seamless else { print("drag: not in Seamless Mode"); return }
        if env["TANDEM_DRAG_INTERRUPT"] == "1" {
            // Power off in the middle of Seamless Mode, start again: the guest tools must put the scale back.
            print("drag: scale \(session.seamlessScale); powering off in Seamless Mode")
            await session.forceStopAndWait()
            for _ in 0..<40 where session.state.isActive { await wait(0.5) }
            await wait(3)
            session.start()
            for _ in 0..<480 where session.agent == nil { await wait(0.5) }
            await wait(25)
            print("drag: restarted, agent \(session.agent != nil); see the guest log for the scale")
            session.stop()
            for _ in 0..<240 where session.state.isActive { await wait(0.5) }
            print("drag: final state=\(session.state.rawValue)")
            return
        }
        print("drag: scale \(session.seamlessScale), desktop \(controller.layout.desktop), memory \(Int(memoryBefore)) → \(Int(residentMiB())) MiB")
        guard let notepad = controller.programWindows.first(where: { $0.app.lowercased() == "notepad.exe" && $0.state == .normal }) else {
            print("drag: Notepad not found in \(controller.programWindows.map(\.title))")
            session.exitSeamless(reopenWindow: false); session.stop(); return
        }
        let scale = controller.layout.desktop.width / max(controller.layout.area.width, 1)
        print("drag: Notepad at \(notepad.x),\(notepad.y) \(notepad.width)x\(notepad.height) (guest px per point \(scale))")
        let pictures0 = controller.stats.pictures, seconds0 = controller.stats.pictureSeconds
        await wait(3)
        print(String(format: "drag: idle picture cost %.2f ms per frame over %d frames", 1000 * (controller.stats.pictureSeconds - seconds0) / Double(max(controller.stats.pictures - pictures0, 1)), controller.stats.pictures - pictures0))

        let input = controller.debugInput
        var current = (x: notepad.x, y: notepad.y)
        for (phase, predict) in [("reports only", false), ("pointer-following", true)] {
            controller.predictDrags = predict
            guard let now = controller.programWindows.first(where: { $0.id == notepad.id }), now.state == .normal,
                  now.width == notepad.width, now.height == notepad.height else {
                print("drag[\(phase)]: skipped: Notepad is no longer a normal window of its first size"); continue
            }
            current = (x: now.x, y: now.y)
            // Grab the title bar right of the tabs and drag towards the middle of the screen, staying
            // clear of the edges (a window dragged to an edge snaps and changes size).
            let start = (x: current.x + Int(Double(notepad.width) * 0.62), y: current.y + Int(14 * scale))
            let room = (x: Int(controller.layout.desktop.width) - notepad.width, y: Int(controller.layout.desktop.height) - notepad.height - Int(60 * scale))
            let dx = (room.x / 2 - current.x).signum() * min(Int(400 * scale), max(abs(room.x / 2 - current.x), Int(150 * scale)))
            let dy = (room.y / 2 - current.y).signum() * min(Int(150 * scale), abs(room.y / 2 - current.y))
            input.movePointer(toX: start.x, y: start.y); await wait(0.3)
            input.setButton(.left, down: true); await wait(0.3)
            controller.resetStats()
            var frameErrors: [Double] = [], sourceErrors: [Double] = []
            let steps = 90, began = CACurrentMediaTime()
            for i in 1...steps {
                let p = (x: start.x + dx * i / steps, y: start.y + dy * i / steps)
                input.movePointer(toX: p.x, y: p.y)
                await wait(1.0 / 60)
                // Where Windows is taking the window: its start, moved as far as the pointer has.
                let expected = CGPoint(x: current.x + p.x - start.x, y: current.y + p.y - start.y)
                if i > 6, let g = controller.debugGeometry(of: notepad.id) {
                    frameErrors.append(hypot(g.frame.minX - expected.x, g.frame.minY - expected.y))
                    sourceErrors.append(hypot(g.source.minX - expected.x, g.source.minY - expected.y))
                }
            }
            let duration = CACurrentMediaTime() - began
            let stats = controller.stats
            input.setButton(.left, down: false)
            await wait(1.5)
            for w in controller.programWindows.prefix(4) + (controller.debugReported.filter { $0.kind != .app }.prefix(4)) {
                print("drag[\(phase)]: after release: \(w.kind.rawValue) “\(w.title)” [\(w.class)] \(w.app) at \(w.x),\(w.y) \(w.width)x\(w.height)")
            }
            await wait(4)
            current = (x: current.x + dx, y: current.y + dy)
            if let now = controller.programWindows.first(where: { $0.id == notepad.id }) {
                if now.x != current.x || now.y != current.y { print("drag[\(phase)]: Notepad is at \(now.x),\(now.y), not \(current.x),\(current.y)") }
                current = (x: now.x, y: now.y)
            }
            let final = controller.debugGeometry(of: notepad.id)
            func mean(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
            print(String(format: "drag[%@]: %.2f s, window frame moved %.1f/s, reports %.1f/s, pictures %.1f/s (copy %.2f ms off the main thread, %.2f ms on it); frame behind the guest window: mean %.0f px (%.0f pt), max %.0f px; picture source behind: mean %.0f px",
                         phase, duration, Double(stats.frameMoves) / duration, Double(stats.reports) / duration, Double(stats.pictures) / duration,
                         1000 * stats.pictureSeconds / Double(max(stats.pictures, 1)), 1000 * stats.mainSeconds / Double(max(stats.pictures, 1)),
                         mean(frameErrors), mean(frameErrors) / scale, frameErrors.max() ?? 0, mean(sourceErrors)))
            if let final {
                print("drag[\(phase)]: after release frame \(final.frame.origin) source \(final.source.origin) expected \(current.x),\(current.y)")
            }
        }
        if let directory, let band = controller.debugTopBand(of: notepad.id, points: 64) {
            let url = directory.appendingPathComponent(scale > 1.5 ? "band-retina.png" : "band-1x.png")
            try? NSBitmapImageRep(cgImage: band).representation(using: .png, properties: [:])?.write(to: url)
            print("drag: wrote \(url.lastPathComponent) (\(band.width)x\(band.height) px)")
        }
        session.exitSeamless(reopenWindow: false)
        await wait(4)
        // Close Notepad without saving, then shut down.
        await tap([0x38, 0x3E]); await wait(2); await tap([0x31]); await wait(1)
        session.stop()
        for _ in 0..<240 where session.state.isActive { await wait(0.5) }
        print("drag: final state=\(session.state.rawValue)")
    }
}
