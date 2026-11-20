import AppKit
import EngineQEMU
import GuestLink
import Sharing
import VMCore

/// Self-test for the Seamless Mode additions: `TANDEM_SNAPSHOT_SEAMLESS_EXTRAS=<vm name>` starts a Windows
/// VM, puts a file in Documents and opens it selected in File Explorer, opens Notepad, enters Seamless
/// Mode and checks: (1) the desktop plan for the Mac's displays (run with `TANDEM_SEAMLESS_DISPLAYS` to
/// stand in for a second display) and that a maximised window fills the main display's work area;
/// (2) a resize by Notepad's bottom-right corner, followed through the guest's pointer, with and without
/// prediction; (3) dragging out: the guest names the file selected in Explorer and uploads it for a drop
/// on the Mac, which arrives byte for byte. Then it leaves the mode and shuts the VM down.
extension SelfTest {
    private static func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    static func seamlessExtrasTrial(_ model: AppModel, name: String) async {
        guard let session = model.sessions.first(where: { $0.config.name == name }) else { print("extras: no VM \(name)"); return }
        session.start()
        for _ in 0..<480 where !session.canSeamless { await pause(0.5) }
        print("extras: canSeamless=\(session.canSeamless) agent=\(session.agent?.capabilities ?? 0) (bit 17: \((session.agent?.capabilities ?? 0) & (1 << 17) != 0))")
        guard session.canSeamless else { await session.forceStopAndWait(); return }
        await pause(25)

        // A 20 MB file of known content in Documents, shown selected in File Explorer; and Notepad.
        // Sent encoded, so cmd's own quoting and % signs cannot touch it.
        let script = #"$p = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'tandem-dragout.bin'; $b = New-Object byte[] 20971520; for ($i = 0; $i -lt $b.Length; $i += 4096) { $b[$i] = [byte](($i / 4096) % 251) }; [IO.File]::WriteAllBytes($p, $b); Start-Process explorer.exe -ArgumentList ('/select,"' + $p + '"'); Start-Sleep 2; Start-Process notepad.exe"#
        let encoded = script.data(using: .utf16LittleEndian)!.base64EncodedString()
        let setup = "powershell -NoProfile -EncodedCommand \(encoded)"
        do {
            let result = try await session.link.exec(GuestExecRequest(command: setup, timeoutSeconds: 90))
            print("extras: setup exit \(result.exitCode) \(String(decoding: result.stderr, as: UTF8.self).prefix(200))")
        } catch { print("extras: setup failed: \(error.localizedDescription)") }
        await pause(6)

        session.enterSeamless()
        await pause(16)
        guard let controller = session.seamless else { print("extras: not in Seamless Mode"); return }
        let plan = controller.plan
        print("extras: displays \(SeamlessController.displays().map { "\($0.visibleFrame) x\($0.scale)\($0.isMain ? " main" : "")" })")
        print("extras: plan area \(plan.area) scale \(plan.scale) pixels \(plan.pixels) main work area \(plan.mainWorkArea); guest desktop now \(controller.layout.desktop)")

        // 1. Maximise Notepad: it should fill the main display's work area, not the whole arrangement.
        if let notepad = controller.programWindows.first(where: { $0.app.lowercased() == "notepad.exe" }) {
            print("extras: Notepad at \(notepad.x),\(notepad.y) \(notepad.width)x\(notepad.height) state \(notepad.state.rawValue)")
            controller.activate(notepad.id)
            await pause(1.5)
            session.sendKeys([0xDB, 0xC8])          // Windows + Up: maximise
            await pause(3)
            if let now = controller.programWindows.first(where: { $0.id == notepad.id }) {
                print("extras: maximised Notepad at \(now.x),\(now.y) \(now.width)x\(now.height) state \(now.state.rawValue); work area \(plan.mainWorkArea)")
            }
            session.sendKeys([0xDB, 0xD0])          // Windows + Down: restore
            await pause(3)
        }

        // 2. Resize File Explorer by its bottom-right corner through the guest's pointer.
        if let explorer = controller.programWindows.first(where: { $0.class == "CabinetWClass" }) {
            controller.activate(explorer.id)
            await pause(1.5)
            let notepad = explorer
            if let start = controller.programWindows.first(where: { $0.id == notepad.id }), start.state == .normal {
                print("extras: Explorer at \(start.x),\(start.y) \(start.width)x\(start.height)")
                let input = controller.debugInput
                let scale = controller.layout.desktop.width / max(controller.layout.area.width, 1)
                for (phase, predict) in [("reports only", false), ("predicted", true)] {
                    controller.predictDrags = predict
                    guard let w = controller.programWindows.first(where: { $0.id == notepad.id }) else { break }
                    // The left edge, halfway down what is on the desktop: Windows 11's resize border on the
                    // left lies just outside the drawn frame. The window may reach past the right and bottom.
                    let corner = (x: w.x - Int(3 * scale), y: max(w.y, 0) + min(w.height, Int(controller.layout.desktop.height) - max(w.y, 0)) / 2)
                    input.movePointer(toX: corner.x, y: corner.y); await pause(0.4)
                    input.setButton(.left, down: true); await pause(0.4)
                    let d = Int(160 * scale)
                    var errors: [Double] = []
                    var edge: String = "none"
                    for i in 1...60 {
                        // Inwards: shrinking, so the window stays on the desktop.
                        let p = (x: corner.x + d * i / 60, y: corner.y)
                        input.movePointer(toX: p.x, y: p.y)
                        await pause(1.0 / 60)
                        if let e = controller.debugMove?.edge { edge = e.rawValue }
                        // The left edge follows the pointer; the others stay.
                        let expected = CGFloat(w.x + p.x - corner.x)
                        if i > 6, let g = controller.debugGeometry(of: notepad.id) {
                            errors.append(abs(g.frame.minX - expected))
                        }
                    }
                    input.setButton(.left, down: false)
                    await pause(2)
                    let mean = errors.isEmpty ? 0 : errors.reduce(0, +) / Double(errors.count)
                    let after = controller.programWindows.first(where: { $0.id == notepad.id })
                    print(String(format: "extras: resize[%@] edge %@, frame size behind the guest's: mean %.0f px, max %.0f px; now %dx%d",
                                 phase, edge, mean, errors.max() ?? 0, after?.width ?? 0, after?.height ?? 0))
                }
            }
        } else {
            print("extras: Notepad not found in \(controller.programWindows.map(\.title))")
        }

        // 3. Drag out: the guest names what is selected in Explorer and uploads it for a drop on the Mac.
        if let explorer = controller.programWindows.first(where: { $0.class == "CabinetWClass" }) {
            let point = (x: explorer.x + explorer.width / 2, y: explorer.y + explorer.height / 2)
            let link = session.link
            let saved = link.onDragOutItems
            let items: GuestDragOutItems? = await withCheckedContinuation { continuation in
                nonisolated(unsafe) var done = false
                link.onDragOutItems = { items in if !done { done = true; continuation.resume(returning: items) } }
                link.queryDragOut(x: point.x, y: point.y)
                DispatchQueue.main.asyncAfter(deadline: .now() + 45) { if !done { done = true; continuation.resume(returning: nil) } }
            }
            link.onDragOutItems = saved
            print("extras: drag out from “\(explorer.title)”: \(items?.paths ?? []) \(items?.message ?? "")")
            if let path = items?.paths.first {
                let target = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-dragout-\(UUID().uuidString.prefix(8))-\(GuestDragOutItems.fileName(path))")
                let fetch = GuestDragOutFetch(id: GuestDragOutFetch.idPrefix + UUID().uuidString.lowercased(), paths: [path])
                let inbox = FileDrop.inboxRoot(session.bundle)
                let began = Date()
                link.fetchDragOut(fetch)
                let error = await Task.detached { SeamlessDragOut.waitAndMove(fetch, inbox: inbox, to: target) }.value
                var ok = false
                if error == nil, let data = try? Data(contentsOf: target), data.count == 20_971_520 {
                    ok = (0..<data.count).stride(by: 4096).allSatisfy { data[$0] == UInt8(($0 / 4096) % 251) }
                }
                print(String(format: "extras: drag out fetch %@ in %.1f s, %@", error.map { "failed: \($0.localizedDescription)" } ?? "arrived",
                             Date().timeIntervalSince(began), ok ? "20 MB, content matches" : "content does NOT match"))
                try? FileManager.default.removeItem(at: target)
            }
        } else {
            print("extras: no File Explorer window in \(controller.programWindows.map(\.title))")
        }
        // The guest tools' own log, for what happened on the Windows side.
        let tail = "powershell -NoProfile -EncodedCommand " + #"Get-Content "$env:ProgramData\Tandem\agent.log" -Tail 12"#.data(using: .utf16LittleEndian)!.base64EncodedString()
        if let log = try? await session.link.exec(GuestExecRequest(command: tail, timeoutSeconds: 60)) {
            for line in String(decoding: log.stdout, as: UTF8.self).split(whereSeparator: \.isNewline).suffix(12) { print("extras: guest log: \(line)") }
        }

        session.exitSeamless(reopenWindow: false)
        await pause(4)
        session.stop()
        for _ in 0..<240 where session.state.isActive { await pause(0.5) }
        print("extras: final state=\(session.state.rawValue)")
    }
}

private extension Range where Bound == Int {
    func stride(by step: Int) -> StrideTo<Int> { Swift.stride(from: lowerBound, to: upperBound, by: step) }
}
