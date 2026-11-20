import AppKit
import Foundation
import GuestLink
import Provisioning
import VMCore

/// Self-test for "3D acceleration (Windows, experimental)" through the app's own path:
///
///   TANDEM_SNAPSHOT_WIN3D=<vm>        a stopped Windows VM: turn 3D on as the Graphics pane does, start it, let
///                                     Tandem fetch and install the driver by itself, picture the screen, run the
///                                     Direct3D test from TANDEM_SNAPSHOT_WIN3D_BENCH (a folder with d3dbench.exe),
///                                     then turn 3D off and check the plain display comes back
extension SelfTest {
    private static func w3dWait(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    private static func w3dLog(_ text: String) { print("selftest-win3d: \(text)") }

    /// Saves the guest's screen and returns its average brightness (0 black … 255 white).
    private static func w3dPicture(_ session: VMSession, tag: String) -> Double {
        guard let image = session.guestImage() else { return -1 }
        if let directory, let data = VMSession.png(image, maxWidth: 1280) {
            try? data.write(to: directory.appendingPathComponent("\(tag).png"))
        }
        guard let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let pixels = context.data else { return -1 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        let bytes = pixels.assumingMemoryBound(to: UInt8.self)
        var sum = 0
        for i in 0..<(64 * 64) { sum += Int(bytes[i * 4]) + Int(bytes[i * 4 + 1]) + Int(bytes[i * 4 + 2]) }
        return Double(sum) / Double(64 * 64 * 3)
    }

    private static func w3dWaitForTools(_ session: VMSession, seconds: Int) async -> Bool {
        for _ in 0..<seconds {
            if session.state == .running, session.agent != nil, session.busy == nil { return true }
            await w3dWait(1)
        }
        return false
    }

    /// Waits for the tools to disconnect (Windows going down for a restart).
    private static func w3dWaitForRestart(_ session: VMSession, seconds: Int) async -> Bool {
        // A warm restart takes the tools away for only seconds: look often.
        for _ in 0..<(seconds * 5) {
            if session.agent == nil { return true }
            await w3dWait(0.2)
        }
        return false
    }

    static func windows3DTrial(_ model: AppModel, vm name: String) async {
        guard let session = model.sessions.first(where: { $0.config.name == name }) else { return w3dLog("no VM named \(name)") }
        let began = Date()
        func elapsed() -> Int { Int(Date().timeIntervalSince(began)) }

        // 1. Turn 3D on, as the Graphics pane's switch does.
        var config = session.config
        config.display.accelerated3D = true
        do { try session.apply(config) } catch { return w3dLog("apply failed: \(error)") }
        w3dLog("3D on; driver recorded before start: \(String(describing: session.config.display.windows3DDriver))")

        // 2. Start: the driver is downloaded (or taken from the cache), the VM starts, the tools install it.
        session.start()
        var lastBusy = ""
        for _ in 0..<1500 {
            if let busy = session.busy, busy != lastBusy { lastBusy = busy; w3dLog("status “\(busy)” at \(elapsed()) s") }
            if session.config.display.windows3DDriver != nil || session.config.display.accelerated3D != true { break }
            if session.state == .error { break }
            await w3dWait(1)
        }
        w3dLog("after install: driver=\(String(describing: session.config.display.windows3DDriver)) 3D=\(String(describing: session.config.display.accelerated3D)) error=\(session.errorMessage ?? "none") media=\(session.config.removableMedia.map(\.kind.rawValue)) at \(elapsed()) s")
        guard session.config.display.windows3DDriver != nil else {
            await session.forceStopAndWait()
            return
        }

        // Tandem restarts Windows after the install: wait for the tools to go away and answer again.
        let restarted = await w3dWaitForRestart(session, seconds: 120)
        w3dLog("restart after install seen: \(restarted) at \(elapsed()) s")
        let ready = await w3dWaitForTools(session, seconds: 300)
        await w3dWait(20)
        let brightness = w3dPicture(session, tag: "win3d-on")
        w3dLog("3D desktop: tools=\(ready) screen=\(session.screen.map { "\($0.size.width)x\($0.size.height)" } ?? "none") brightness=\(Int(brightness)) at \(elapsed()) s")

        // 3. Direct3D 11 in the guest, if a test program was given.
        if let folder = ProcessInfo.processInfo.environment["TANDEM_SNAPSHOT_WIN3D_BENCH"] {
            do {
                try session.shareTemporarily(path: folder, readOnly: true)
                await w3dWait(15)
                let share = URL(fileURLWithPath: folder).lastPathComponent
                let script = """
                $exe = Get-ChildItem -Path Z:\\ -Recurse -Filter d3dbench.exe -ErrorAction SilentlyContinue | Where-Object { $_.FullName -like '*\(share)*' } | Select-Object -First 1
                if (-not $exe) { Write-Output 'no bench'; exit 9 }
                Copy-Item $exe.FullName "$env:TEMP\\d3dbench.exe" -Force
                # Start-Process with redirected output: run directly in the task's PowerShell, the program's
                # output and exit code were lost (it reported -1 although it ran).
                $p = Start-Process -FilePath "$env:TEMP\\d3dbench.exe" -ArgumentList 300 -NoNewWindow -Wait -PassThru -RedirectStandardOutput "$env:TEMP\\b.out" -RedirectStandardError "$env:TEMP\\b.err"
                Get-Content "$env:TEMP\\b.out"; Get-Content "$env:TEMP\\b.err"
                'bench exit: ' + $p.ExitCode
                Get-CimInstance Win32_VideoController | ForEach-Object { 'adapter: ' + $_.Name + ' / ' + $_.DriverVersion }
                """
                let result = try await session.link.exec(GuestExecRequest(command: Windows3DDriver.powerShell(script), timeoutSeconds: 180))
                let text = String(decoding: result.stdout + result.stderr, as: UTF8.self)
                w3dLog("d3dbench exit \(result.exitCode): " + text.split(whereSeparator: \.isNewline).suffix(6).joined(separator: " | "))
            } catch {
                w3dLog("d3dbench not run: \(error)")
            }
        }

        // 4. Turn 3D off and start again: the plain display must come back; the driver stays recorded.
        session.stop()
        for _ in 0..<240 where session.state.isActive { await w3dWait(1) }
        if session.state.isActive { await session.forceStopAndWait() }
        config = session.config
        config.display.accelerated3D = nil
        do { try session.apply(config) } catch { return w3dLog("apply (off) failed: \(error)") }
        session.start()
        _ = await w3dWaitForTools(session, seconds: 300)
        for _ in 0..<180 where session.config.display.windows3DDriver != nil { await w3dWait(1) }
        w3dLog("3D off: driver removed=\(session.config.display.windows3DDriver == nil) at \(elapsed()) s")
        let again = await w3dWaitForRestart(session, seconds: 120)
        _ = await w3dWaitForTools(session, seconds: 300)
        w3dLog("3D off: restart seen=\(again) at \(elapsed()) s")
        await w3dWait(20)
        let plain = w3dPicture(session, tag: "win3d-off")
        w3dLog("3D off: state=\(session.state.rawValue) screen=\(session.screen.map { "\($0.size.width)x\($0.size.height)" } ?? "none") brightness=\(Int(plain)) driver still recorded=\(session.config.display.windows3DDriver != nil) at \(elapsed()) s")
        session.stop()
        for _ in 0..<240 where session.state.isActive { await w3dWait(1) }
        w3dLog("final state=\(session.state.rawValue) at \(elapsed()) s")
    }
}
