import AppKit
import EngineQEMU
import GuestLink
import Sharing
import VMCore

/// Self-test for drag and drop (`TANDEM_SNAPSHOT_FILEDROP=<Windows VM name>`): starts the VM, opens
/// Documents in Explorer and Notepad, drops two files (one of 200 MB) on each through the drop code the
/// window's drag destination calls, sends one back with `send-to-mac`, refuses a drop under the
/// restricted preset, and prints what happened.
@MainActor
enum SelfTestFileDrop {
    private static func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    private static func type(_ text: String, _ input: GuestInput) async {
        for character in text {
            guard let stroke = KeyMap.keystroke(for: character) else { print("selftest-drop: cannot type “\(character)”"); continue }
            if stroke.shift { input.key(macKeyCode: 0x38, down: true) }
            input.key(macKeyCode: stroke.code, down: true); await pause(0.03)
            input.key(macKeyCode: stroke.code, down: false)
            if stroke.shift { input.key(macKeyCode: 0x38, down: false) }
            await pause(0.03)
        }
    }

    /// Win+R, a command, Return.
    private static func run(_ command: String, _ session: VMSession, _ input: GuestInput) async {
        session.sendKeys([0xDB, 0x13]); await pause(2)
        await type(command, input); await pause(0.3)
        session.sendKeys([0x1C]); await pause(5)
    }

    static func run(_ model: AppModel) async {
        guard let name = ProcessInfo.processInfo.environment["TANDEM_SNAPSHOT_FILEDROP"],
              let session = model.sessions.first(where: { $0.config.name == name }) else { return }
        let directory = SelfTest.directory ?? FileManager.default.temporaryDirectory
        model.selection = session.id
        session.start()
        // The agent updates itself to this build's on the first connect; wait for the capability.
        for _ in 0..<600 where !(session.agent.map { $0.capabilities & GuestCapability.fileDrop != 0 } ?? false) { await pause(1) }
        print("selftest-drop: agent capabilities \(session.agent?.capabilities ?? 0)")
        guard let screen = session.screen, session.agent.map({ $0.capabilities & GuestCapability.fileDrop != 0 }) == true else {
            print("selftest-drop: the guest tools never offered file drops"); await stop(session); return
        }
        let input = GuestInput(client: screen)
        await pause(25)

        // Two files to drop: a small text file and 200 MB of non-repeating bytes.
        let mac = directory.appendingPathComponent("drop-src")
        try? FileManager.default.removeItem(at: mac)
        try? FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
        let small = mac.appendingPathComponent("hello from the Mac.txt")
        try? Data("Dropped from the Mac\r\n".utf8).write(to: small)
        let big = mac.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: big) {
            var block = [UInt8](repeating: 0, count: 1 << 20)
            for i in 0..<200 {
                for j in stride(from: 0, to: block.count, by: 4) { block[j] = UInt8(truncatingIfNeeded: i &* 31 &+ j / 4) }
                handle.write(Data(block))
            }
            try? handle.close()
        }

        // The guest's windows, to aim at.
        var windows: [GuestWindow] = []
        session.link.onWindowReport = { list in Task { @MainActor in windows = list.windows } }
        session.link.watchWindows(true)

        // 1. Onto an Explorer window showing Documents.
        await run("explorer shell:Personal", session, input)
        await pause(4)
        if let explorer = windows.first(where: { $0.class == "CabinetWClass" }) {
            let point = (x: explorer.x + explorer.width / 2, y: explorer.y + explorer.height * 2 / 3)
            print("selftest-drop: Explorer “\(explorer.title)” at \(explorer.x),\(explorer.y) \(explorer.width)x\(explorer.height); dropping at \(point)")
            await drop([small, big], session, point, "explorer")
        } else {
            print("selftest-drop: no Explorer window found: \(windows.map { "\($0.class) “\($0.title)”" })")
        }
        await pause(2)
        snapshotGuest(session, directory, "drop-1-explorer")

        // 2. Onto Notepad: nothing that holds files, so Downloads.
        await run("notepad", session, input)
        await pause(3)
        if let notepad = windows.first(where: { $0.app.lowercased() == "notepad.exe" && $0.kind == .app }) {
            let point = (x: notepad.x + notepad.width / 2, y: notepad.y + notepad.height / 2)
            print("selftest-drop: Notepad at \(notepad.x),\(notepad.y); dropping at \(point)")
            await drop([small], session, point, "notepad")
        } else {
            print("selftest-drop: no Notepad window found")
        }
        snapshotGuest(session, directory, "drop-2-notepad")

        // 3. Back to the Mac: the dropped big file through Send to > Mac.
        await run("\"C:\\Program Files\\Tandem\\tandem-agent.exe\" send-to-mac \"%USERPROFILE%\\Documents\\big.bin\"", session, input)
        for _ in 0..<120 where FileTransferCenter.shared.lastArrivals[session.id] == nil { await pause(1) }
        if let arrived = FileTransferCenter.shared.lastArrivals[session.id] {
            for url in arrived {
                let same = FileManager.default.contentsEqual(atPath: url.path, andPath: big.path)
                print("selftest-drop: back on the Mac: \(url.path) \((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) ?? "?") bytes, identical to the original: \(same)")
                try? FileManager.default.removeItem(at: url)
            }
        } else {
            print("selftest-drop: nothing came back from send-to-mac")
        }

        // 4. Restricted: drops are refused on the Mac and the hidden share is gone.
        let before = session.bundle.config.sharing
        try? SharingStore.setProfile(.restricted, bundleURL: session.bundle.url)
        for _ in 0..<20 where session.sharingPolicy.allowsFilesToGuest { await pause(0.5) }
        print("selftest-drop: restricted: refusal “\(FileTransferCenter.shared.refusal(session) ?? "none")”, transfer shares \(session.sharedFolders.transferShares.map(\.name))")
        try? SharingStore.setProfile(before, bundleURL: session.bundle.url)
        for _ in 0..<20 where !session.sharingPolicy.allowsFilesToGuest { await pause(0.5) }
        print("selftest-drop: restored: transfer shares \(session.sharedFolders.transferShares.map(\.name))")

        session.link.watchWindows(false)
        session.link.onWindowReport = nil
        try? FileManager.default.removeItem(at: mac)
        await stop(session)
    }

    private static func drop(_ urls: [URL], _ session: VMSession, _ point: (x: Int, y: Int), _ label: String) async {
        let began = Date()
        let screenPoint = CGPoint(x: (NSScreen.main?.frame.midX ?? 400), y: (NSScreen.main?.frame.midY ?? 300))
        FileTransferCenter.shared.drop(urls, on: session, at: point, screenPoint: screenPoint)
        await pause(1)
        for _ in 0..<300 where FileTransferCenter.shared.isBusy(session) { await pause(0.5) }
        let result = FileTransferCenter.shared.lastResult[session.id]
        print("selftest-drop: \(label): \(result.map { "\($0.status.rawValue), \($0.files) files to \($0.folder) \($0.message ?? "")" } ?? "no result") in \(Int(Date().timeIntervalSince(began))) s; panel “\(DropHUD.shared.lastText)”")
    }

    private static func snapshotGuest(_ session: VMSession, _ directory: URL, _ tag: String) {
        guard let screen = session.screen else { return }
        let shot = screen.snapshot()
        guard shot.size.width > 0, let provider = CGDataProvider(data: shot.pixels as CFData),
              let image = CGImage(width: shot.size.width, height: shot.size.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: shot.size.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(tag).png"))
    }

    private static func stop(_ session: VMSession) async {
        session.stop()
        for _ in 0..<240 where session.state.isActive { await pause(0.5) }
        print("selftest-drop: final state=\(session.state.rawValue)")
    }
}
