import AppKit
import SwiftUI
import Provisioning
import VMCore

/// Development aid: lets the app render its own windows to PNG files, so the UI can be checked without
/// screen-recording permission. Driven by environment variables; does nothing when they are absent.
///
///   TANDEM_SNAPSHOT_DIR      folder for the PNG files (enables the self-test)
///   TANDEM_SNAPSHOT_START    name of a VM to start and show
///   TANDEM_SNAPSHOT_IMPORT   path of a Parallels VM to open the import sheet for
///   TANDEM_SNAPSHOT_SETTINGS "VM name=tab/pane;tab/pane…": open that VM's configuration at each place in turn
///   TANDEM_SNAPSHOT_OPEN     "snapshots;assistant;preferences": also open these windows (for the selected VM)
///   TANDEM_SNAPSHOT_SEAMLESS name of a VM to start, open two programs in, and show in Seamless Mode
///   TANDEM_SNAPSHOT_INSTALL  path of a Windows install disc: create a VM from it the way the assistant does,
///                            let it install itself, and report when the guest tools answer
///   TANDEM_SNAPSHOT_BEHAVIOR name of a VM to run the Startup and Shutdown settings against (SelfTestBehavior.swift)
///   TANDEM_SNAPSHOT_STARTUPVIEW name of a Windows VM that must start straight into Seamless Mode
///   TANDEM_SNAPSHOT_AUTOSTART set: let VMs that start with Tandem start, which a self-test otherwise prevents
///   TANDEM_SNAPSHOT_SHARING  "VM name=folder[=password]": start the VM (typing the password at the lock screen if
///                            given), share the folder until shutdown, restrict the VM, and print the policy each time
///   TANDEM_SNAPSHOT_SUSPEND  name of a VM with guest tools: start it, suspend it, resume it, and report
///   TANDEM_SNAPSHOT_WAIT     seconds to let the VM run before the second snapshot (default 60)
@MainActor
enum SelfTest {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["TANDEM_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func snapshotWindows(tag: String) {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (index, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let title = window.title.isEmpty ? "sheet" : window.title.replacingOccurrences(of: "/", with: "-")
            let url = directory.appendingPathComponent("\(tag)-\(index)-\(title).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }

    /// Finds an item in the menu bar by title, after letting each menu bring itself up to date.
    private static func menuItem(_ title: String) -> NSMenuItem? {
        for top in NSApp.mainMenu?.items ?? [] {
            guard let menu = top.submenu else { continue }
            // What opening the menu with the mouse does: SwiftUI fills in the items at that moment.
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.delegate?.menuWillOpen?(menu)
            menu.update()
            if let item = menu.items.first(where: { $0.title == title }) { return item }
        }
        return nil
    }

    /// The menu bar as it stands: every item of every menu, with whether it can be chosen.
    static func printMenus(_ tag: String) {
        for top in NSApp.mainMenu?.items ?? [] {
            guard let menu = top.submenu else { continue }
            // What opening the menu with the mouse does: SwiftUI fills in the items at that moment.
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.delegate?.menuWillOpen?(menu)
            menu.update()
            print("menu[\(tag)] \(top.title): " + menu.items.filter { !$0.isSeparatorItem }.map { "\($0.title)\($0.isEnabled ? "" : " (off)")" }.joined(separator: " | "))
        }
    }

    private static func chooseMenuItem(_ title: String) -> Bool {
        guard let item = menuItem(title), item.isEnabled, let menu = item.menu else { return false }
        menu.performActionForItem(at: menu.index(of: item))
        return true
    }

    private static func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    /// Starts the VM, opens Calculator and the Run dialog, enters Seamless Mode, activates the window
    /// in the back from the Mac side, leaves the mode again and shuts the VM down. Prints what it sees.
    private static func seamless(_ session: VMSession) async {
        func tap(_ codes: [UInt8]) async { session.sendKeys(codes); await pause(0.15) }
        func dump(_ tag: String) { session.seamless?.debugDump(to: directory, tag: tag).forEach { print($0) } }
        session.start()
        for _ in 0..<480 where !session.canSeamless { await pause(0.5) }
        print("selftest: canSeamless=\(session.canSeamless) agent=\(session.agent?.capabilities ?? 0)")
        guard session.canSeamless else { await session.forceStopAndWait(); return }
        await pause(40)
        // Win+R, "calc", Enter; then Win+R again, so a dialog is in front of Calculator.
        await tap([0xDB, 0x13]); await pause(5)
        for code: UInt8 in [0x2E, 0x1E, 0x26, 0x2E, 0x1C] { await tap([code]) }
        await pause(6)
        await tap([0xDB, 0x13]); await pause(3)
        printMenus("before")
        print("selftest: Enter Seamless Mode in the menu bar: \(chooseMenuItem("Enter Seamless Mode") ? "chosen" : "NOT FOUND")")
        if !session.isSeamless { session.enterSeamless() }
        await pause(10)
        print("selftest: seamless=\(session.isSeamless) vmWindows=\(NSApp.windows.filter { $0.isVisible && $0.title == session.config.name }.count)")
        dump("5-seamless")
        print("selftest: programs=\(session.guestPrograms.count) icons=\(session.guestIcons.count) first=\(session.guestPrograms.prefix(5).map(\.name))")
        for window in session.openGuestWindows {
            print("selftest: window “\(window.title)” app \(window.app) icon \(session.icon(for: window).map { "\($0.width)x\($0.height)" } ?? "none")")
        }
        printMenus("seamless")
        // Choose the window in the back on the Mac side; the guest should make it its active window.
        session.seamless?.debugMakeKeyBackmost()
        await pause(3)
        dump("6-activated")
        // Leave the way a user does: through the View menu, with a seamless window in front.
        let chosen = chooseMenuItem("Exit Seamless Mode")
        print("selftest: Exit Seamless Mode in the menu bar: \(chosen ? "chosen" : "NOT FOUND")")
        await pause(2)
        if session.isSeamless { print("selftest: the menu item did not leave the mode"); session.exitSeamless() }
        await pause(5)
        printMenus("after")
        print("selftest: Enter Seamless Mode offered again: \(menuItem("Enter Seamless Mode")?.isEnabled == true)")
        print("selftest: after exit seamless=\(session.isSeamless) windows=\(NSApp.windows.filter(\.isVisible).map(\.title))")
        // Close the Run dialog and Calculator (Escape, then Alt+F4), then shut down.
        await tap([0x01]); await pause(1); await tap([0x38, 0x3E]); await pause(2)
        session.stop()
        for _ in 0..<240 where session.state.isActive { await pause(0.5) }
        print("selftest: final state=\(session.state.rawValue)")
    }

    /// The assistant's own path: create, prepare the answer disc, start, and wait for the desktop.
    private static func install(_ model: AppModel, iso: String) async {
        var config = VMConfig(name: "selftest-install", guestOS: .windows11arm, engine: .qemu, cpuCount: 4, memoryMiB: 8192)
        config.removableMedia = [RemovableMedia(file: iso, kind: .installerISO)]
        let began = Date()
        do {
            try model.create(config, windows: WindowsUnattendOptions(computerName: "SELFTEST", userName: "tester", password: ""))
        } catch {
            print("selftest: create failed: \(error.localizedDescription) \((error as? VMError)?.detail ?? "")"); return
        }
        guard let session = model.selectedSession else { print("selftest: no session"); return }
        print("selftest: created with media \(session.config.removableMedia.map(\.kind.rawValue)) install=\(session.config.install.state.rawValue)")
        session.start()
        var lastLabel = ""
        for _ in 0..<1500 where session.config.install.state != .complete {
            if session.statusLabel != lastLabel { lastLabel = session.statusLabel; print("selftest: status “\(lastLabel)” after \(Int(Date().timeIntervalSince(began))) s") }
            if session.state == .error || session.state == .stopped && Date().timeIntervalSince(began) > 30 { break }
            await pause(1)
        }
        print("selftest: install=\(session.config.install.state.rawValue) after \(Int(Date().timeIntervalSince(began))) s, status “\(session.statusLabel)”, media \(session.config.removableMedia.map(\.kind.rawValue)), virtioGPU=\(String(describing: session.config.display.virtioGPU)), answer disc still there=\(FileManager.default.fileExists(atPath: session.bundle.url.appendingPathComponent(UnattendMediaBuilder.fileName).path)), error=\(session.errorMessage ?? "none")")
        // Tandem now restarts the VM by itself; wait for the tools to answer again on the new display.
        var sawStop = false
        for _ in 0..<400 {
            if session.state == .stopped || session.state == .starting { sawStop = true }
            // The plain display is 800x600; anything else means the VM is running on the new display device.
            if session.state == .running, session.agent != nil, !session.isRestarting, let size = session.screen?.size, size.width != 800 { break }
            await pause(1)
        }
        await pause(15)
        print("selftest: after the automatic restart (seen=\(sawStop)): state=\(session.state.rawValue) status “\(session.statusLabel)” agent=\(session.agent != nil) screen=\(session.screen.map { "\($0.size.width)x\($0.size.height)" } ?? "none") display report=\(session.displayReport.map { "\($0.width)x\($0.height)" } ?? "none") after \(Int(Date().timeIntervalSince(began))) s")
        session.stop()
        for _ in 0..<240 where session.state.isActive { await pause(0.5) }
        print("selftest: final state=\(session.state.rawValue)")
    }

    /// The settings panel's path through the session: a temporary folder, then the restricted preset,
    /// applied to a running VM. Prints what the session's policy and its folder server say after each.
    private static func sharing(_ model: AppModel, spec: String) async {
        let parts = spec.split(separator: "=").map(String.init)
        guard parts.count >= 2, let session = model.sessions.first(where: { $0.config.name == parts[0] }) else { print("selftest: sharing: no such VM"); return }
        func report(_ tag: String) {
            let p = session.sharingPolicy
            print("selftest: sharing[\(tag)] folders=\(p.folders.map { $0.name + ($0.temporary ? "(temporary)" : "") + ($0.folder.readOnly ? "(read-only)" : "") }) served=\(session.sharedFolders.names) port=\(session.sharedFolders.port) clipboard=\(p.clipboard.rawValue) usb=\(p.usbAllowed) inbound=\(p.allowsInboundServices) note=\(session.sharingNote ?? "none") stored=\(session.config.sharing.folders.map(\.name))")
        }
        model.selection = session.id
        report("stopped")
        session.start()
        for _ in 0..<60 where session.screen == nil { await pause(0.5) }
        if parts.count > 2 {
            // The lock screen: any key, then the password and Return, as scancodes.
            let codes: [Character: UInt8] = ["a": 0x1E, "b": 0x30, "c": 0x2E, "d": 0x20, "e": 0x12, "f": 0x21, "g": 0x22, "h": 0x23, "i": 0x17,
                                             "j": 0x24, "k": 0x25, "l": 0x26, "m": 0x32, "n": 0x31, "o": 0x18, "p": 0x19, "q": 0x10, "r": 0x13,
                                             "s": 0x1F, "t": 0x14, "u": 0x16, "v": 0x2F, "w": 0x11, "x": 0x2D, "y": 0x15, "z": 0x2C]
            for _ in 0..<40 where session.agent == nil {
                await pause(30)
                guard session.agent == nil else { break }
                session.sendKeys([0x39]); await pause(3)
                for c in parts[2] { if let code = codes[c] { session.sendKeys([code]); await pause(0.1) } }
                session.sendKeys([0x1C])
                await pause(30)
            }
        }
        for _ in 0..<480 where session.agent == nil { await pause(0.5) }
        print("selftest: sharing: agent=\(session.agent != nil)")
        await pause(8)
        report("running")
        NotificationCenter.default.post(name: .selfTestSettings, object: "options/sharing")
        do { try session.shareTemporarily(path: parts[1], readOnly: true) } catch { print("selftest: sharing: temporary share failed: \(error.localizedDescription)") }
        await pause(4)
        report("temporary folder")
        snapshotWindows(tag: "5-sharing-live")
        do { try session.setSharing(.restricted) } catch { print("selftest: sharing: restrict failed: \(error.localizedDescription)") }
        await pause(4)
        report("restricted")
        snapshotWindows(tag: "6-sharing-restricted")
        session.stop()
        for _ in 0..<240 where session.state.isActive { await pause(0.5) }
        report("after shutdown")
    }

    /// Suspend and resume through the session, as the Actions menu does (with shared folders released first).
    private static func suspendAndResume(_ model: AppModel, name: String) async {
        guard let session = model.sessions.first(where: { $0.config.name == name }) else { print("selftest: suspend: no such VM"); return }
        session.start()
        for _ in 0..<480 where session.agent == nil { await pause(0.5) }
        await pause(10)
        print("selftest: suspend: running agent=\(session.agent != nil) served=\(session.sharedFolders.names)")
        session.suspend()
        for _ in 0..<240 where session.state.isActive || session.busy != nil { await pause(0.5) }
        print("selftest: suspend: state=\(session.state.rawValue) suspended=\(session.isSuspended) error=\(session.errorMessage ?? "none")")
        guard session.isSuspended else { await session.forceStopAndWait(); return }
        session.start()
        for _ in 0..<240 where session.state != .running { await pause(0.5) }
        await pause(25)
        print("selftest: suspend: resumed state=\(session.state.rawValue) agent=\(session.agent != nil) served=\(session.sharedFolders.names) error=\(session.errorMessage ?? "none")")
        session.stop()
        for _ in 0..<240 where session.state.isActive { await pause(0.5) }
        if session.state.isActive { await session.forceStopAndWait() }
        print("selftest: suspend: final state=\(session.state.rawValue)")
    }

    static func run(model: AppModel) {
        guard directory != nil else { return }
        setvbuf(stdout, nil, _IOLBF, 0) // line by line even into a file, so a long trial can be followed
        let env = ProcessInfo.processInfo.environment
        let wait = Double(env["TANDEM_SNAPSHOT_WAIT"] ?? "") ?? 60
        if SelfTestRecovery.run(model: model) { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            snapshotWindows(tag: "1-launch")
            if env["TANDEM_SNAPSHOT_MENUS"] != nil { printMenus("launch") }
            if env["TANDEM_SNAPSHOT_ERRORBANNER"] != nil { RuntimeErrorBanner.renderForSelfTest() }
            if let path = env["TANDEM_SNAPSHOT_IMPORT"] {
                NotificationCenter.default.post(name: .selfTestImport, object: path)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                snapshotWindows(tag: "2-import")
            }
            if let spec = env["TANDEM_SNAPSHOT_SETTINGS"], let eq = spec.firstIndex(of: "="),
               let session = model.sessions.first(where: { $0.config.name == spec[..<eq] }) {
                model.selection = session.id
                try? await Task.sleep(nanoseconds: 500_000_000)
                for place in spec[spec.index(after: eq)...].split(separator: ";").map(String.init) {
                    NotificationCenter.default.post(name: .selfTestSettings, object: place)
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    snapshotWindows(tag: "2-config-" + place.replacingOccurrences(of: "/", with: "-"))
                }
            }
            if let spec = env["TANDEM_SNAPSHOT_OPEN"] {
                if let name = env["TANDEM_SNAPSHOT_SELECT"], let session = model.sessions.first(where: { $0.config.name == name }) { model.selection = session.id }
                for what in spec.split(separator: ";").map(String.init) {
                    NotificationCenter.default.post(name: .selfTestOpen, object: what)
                    // TANDEM_SNAPSHOT_OPEN_WAIT: seconds before the picture (a list read from the Internet takes longer).
                    try? await Task.sleep(nanoseconds: UInt64((Double(env["TANDEM_SNAPSHOT_OPEN_WAIT"] ?? "") ?? 1.5) * 1_000_000_000))
                    snapshotWindows(tag: "2-open-" + what)
                }
            }
            if let name = env["TANDEM_SNAPSHOT_START"], let session = model.sessions.first(where: { $0.config.name == name }) {
                model.selection = session.id
                session.start()
                NotificationCenter.default.post(name: .selfTestShow, object: session.id)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                snapshotWindows(tag: "3-running")
                if env["TANDEM_SNAPSHOT_MENUS"] != nil { printMenus("running") }
                print("selftest: state=\(session.state.rawValue) screen=\(session.screen != nil) error=\(session.errorMessage ?? "none")")
                session.stop()
                for _ in 0..<120 where session.state.isActive { try? await Task.sleep(nanoseconds: 500_000_000) }
                print("selftest: final state=\(session.state.rawValue)")
            }
            if let name = env["TANDEM_SNAPSHOT_SEAMLESS"], let session = model.sessions.first(where: { $0.config.name == name }) {
                model.selection = session.id
                await seamless(session)
            }
            if let iso = env["TANDEM_SNAPSHOT_INSTALL"] { await install(model, iso: iso) }
            if let name = env["TANDEM_SNAPSHOT_BEHAVIOR"] { await behavior(model, vm: name) }
            if env["TANDEM_SNAPSHOT_AUTOSTART"] != nil { await autostart(model) }
            if let name = env["TANDEM_SNAPSHOT_STARTUPVIEW"] { await startInSeamless(model, vm: name) }
            if env["TANDEM_SNAPSHOT_ASSISTANT_DOWNLOAD"] != nil { await assistantDownloadPages() }
            if let spec = env["TANDEM_SNAPSHOT_DOWNLOAD"] { await downloadTrial(model, spec: spec) }
            if let name = env["TANDEM_SNAPSHOT_LAUNCH"] { await launchTrial(model, vm: name) }
            if let name = env["TANDEM_SNAPSHOT_IDLE"] { await idleTrial(model, vm: name) }
            if let spec = env["TANDEM_SNAPSHOT_SHARING"] { await sharing(model, spec: spec) }
            if let name = env["TANDEM_SNAPSHOT_SUSPEND"] { await suspendAndResume(model, name: name) }
            if let name = env["TANDEM_SNAPSHOT_VZSCREEN"] { await vzScreen(model, name: name) }
            await SelfTestFileDrop.run(model)
            if let name = env["TANDEM_SNAPSHOT_DRAG"] { await dragTrial(model, name: name) }
            if let name = env["TANDEM_SNAPSHOT_SEAMLESS_EXTRAS"] { await seamlessExtrasTrial(model, name: name) }
            if let name = env["TANDEM_SNAPSHOT_WIN3D"] { await windows3DTrial(model, vm: name) }
            if let spec = env["TANDEM_SNAPSHOT_PACKAGING"] { await SelfTestPackaging.run(model, spec: spec) }
            if let spec = env["TANDEM_SNAPSHOT_UPDATE"] { await SelfTestUpdate.run(model, spec: spec) }
            snapshotWindows(tag: "4-end")
            await model.stopEverything()
            exit(0)
        }
    }
}

extension Notification.Name {
    static let selfTestImport = Notification.Name("tandem.selfTestImport")
    static let selfTestSettings = Notification.Name("tandem.selfTestSettings")
    static let selfTestShow = Notification.Name("tandem.selfTestShow")
    static let selfTestOpen = Notification.Name("tandem.selfTestOpen")
}
