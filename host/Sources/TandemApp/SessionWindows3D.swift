import Foundation
import GuestLink
import Provisioning
import VMCore

/// "3D acceleration (Windows, experimental)" set up by Tandem itself: the driver disc is fetched before the
/// first 3D start, and the guest tools install the driver when they connect.
extension VMSession {
    /// The library's download cache, where the guest tools release is kept once downloaded.
    static var downloadsCache: URL {
        let root = ProcessInfo.processInfo.environment["TANDEM_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? VMLibrary.defaultRoot()
        return root.appendingPathComponent("Downloads", isDirectory: true)
    }

    /// Windows on the QEMU engine with 3D on, and the driver not installed yet.
    var wantsWindows3DDriver: Bool {
        config.guestOS == .windows11arm && config.engine == .qemu
            && config.display.accelerated3D == true && config.display.windows3DDriver == nil
    }

    /// The driver disc must be made (or attached) before this start.
    var needsWindows3DDriverDisc: Bool {
        wantsWindows3DDriver && !(Windows3DDriver.discExists(in: bundle.url)
                                  && config.removableMedia.contains { $0.kind == .driverDisc })
    }

    /// Downloads the driver once, puts it on a disc for the VM, then starts. If that fails, the VM starts
    /// with the normal display and says why.
    func prepareWindows3DDriverThenStart() {
        busy = "Downloading the 3D driver…"
        let folder = bundle.url
        Task {
            do {
                try await Windows3DDriver.ensureDisc(in: folder, cache: Self.downloadsCache) { [weak self] progress in
                    let text = progress.fraction.map { "Downloading the 3D driver… \(Int($0 * 100))%" } ?? "Downloading the 3D driver…"
                    Task { @MainActor in if self?.busy?.hasPrefix("Downloading the 3D driver") == true { self?.busy = text } }
                }
                if !bundle.config.removableMedia.contains(where: { $0.kind == .driverDisc }) {
                    bundle.config.removableMedia.append(RemovableMedia(file: Windows3DDriver.discFileName, kind: .driverDisc))
                }
                try bundle.save()
                launchLog("3D: driver disc ready (\(Windows3DDriver.version))")
            } catch {
                turnOffWindows3D(because: "The 3D driver could not be downloaded: \(error.localizedDescription)")
            }
            busy = nil
            start()
        }
    }

    /// When the guest tools connect: install the driver from its disc, elevated, then restart if Windows asks.
    func installWindows3DDriverIfNeeded(capabilities: UInt32) {
        guard wantsWindows3DDriver, config.removableMedia.contains(where: { $0.kind == .driverDisc }) else { return }
        guard capabilities & (1 << 16) != 0 else {
            launchLog("3D: these guest tools cannot run commands yet; the driver is installed after they update")
            return
        }
        busy = "Installing the 3D driver…"
        launchLog("3D: installing the driver in Windows")
        Task {
            let outcome: Windows3DDriver.InstallOutcome
            do {
                let result = try await link.exec(GuestExecRequest(command: Windows3DDriver.installCommand, elevated: true,
                                                                  timeoutSeconds: 300))
                let output = String(decoding: result.stdout + result.stderr, as: UTF8.self)
                launchLog("3D: pnputil exit \(result.exitCode): \(output.split(whereSeparator: \.isNewline).suffix(4).joined(separator: " | "))")
                outcome = result.status == .completed
                    ? Windows3DDriver.outcome(exitCode: result.exitCode, output: output)
                    : .failed(result.message.isEmpty ? "the install command did not finish" : result.message)
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            busy = nil
            switch outcome {
            case .installed(let published, let restartNeeded):
                bundle.config.display.windows3DDriver = Windows3DDriverState(version: Windows3DDriver.version, publishedName: published)
                bundle.config.removableMedia.removeAll { $0.kind == .driverDisc }
                try? bundle.save()
                // QEMU may still have the disc open; removing the file is safe and frees it when the VM stops.
                try? FileManager.default.removeItem(at: bundle.url.appendingPathComponent(Windows3DDriver.discFileName))
                // Always restart: measured, Windows swaps the driver live (no restart asked for) and the screen
                // stays dark ("Display output is not active") until the next boot.
                launchLog("3D: driver installed (\(published ?? "name unknown"))\(restartNeeded ? "; Windows asked for a restart" : ""); restarting Windows")
                restartForWindows3D("Restarting Windows for the 3D driver…")
            case .failed(let why):
                turnOffWindows3D(because: "The 3D driver could not be installed in Windows: \(why)")
            }
        }
    }

    /// 3D off but the 3D driver still in Windows: the plain virtio display stays dark with it (measured:
    /// "Display output is not active" on every boot), so the tools take it out and Windows restarts once on
    /// its normal display driver.
    var windows3DDriverNeedsRemoving: Bool {
        config.guestOS == .windows11arm && config.engine == .qemu && config.display.accelerated3D != true
            && config.display.windows3DDriver?.publishedName != nil
    }

    func removeWindows3DDriverIfOff(capabilities: UInt32) {
        guard windows3DDriverNeedsRemoving, busy == nil else { return }
        guard capabilities & (1 << 16) != 0 else {
            launchLog("3D: these guest tools cannot run commands; the 3D driver stays until they update")
            return
        }
        launchLog("3D: 3D is off; taking the 3D driver out of Windows")
        Task {
            do {
                try await removeWindows3DDriver()
                launchLog("3D: driver removed; restarting Windows on the normal display")
                restartForWindows3D("Restarting Windows on the normal display…")
            } catch {
                launchLog("3D: driver not removed: \(error.localizedDescription)")
                errorMessage = "Windows still has the 3D driver, so the screen may stay dark with 3D off. Turn 3D back on, or remove the driver under Configure > Hardware > Graphics."
            }
        }
    }

    /// Asks Windows to restart and says so in the window until the tools answer again (or 4 minutes pass).
    private func restartForWindows3D(_ text: String) {
        restart()
        busy = text
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 240_000_000_000)
            if self?.busy == text { self?.busy = nil }
        }
    }

    /// Falls back to the normal display from the next start, and says why.
    func turnOffWindows3D(because reason: String) {
        bundle.config.display.accelerated3D = nil
        bundle.config.removableMedia.removeAll { $0.kind == .driverDisc }
        try? bundle.save()
        try? FileManager.default.removeItem(at: bundle.url.appendingPathComponent(Windows3DDriver.discFileName))
        launchLog("3D: turned off: \(reason)")
        errorMessage = "\(reason) 3D acceleration is off again; the VM uses the normal display from its next start."
    }

    /// Takes the driver out of Windows (the VM keeps running; Windows switches to its basic display driver).
    func removeWindows3DDriver() async throws {
        guard let name = config.display.windows3DDriver?.publishedName else { return }
        busy = "Removing the 3D driver…"
        defer { busy = nil }
        let result = try await link.exec(GuestExecRequest(command: Windows3DDriver.removeCommand(publishedName: name),
                                                          elevated: true, timeoutSeconds: 120))
        let output = String(decoding: result.stdout + result.stderr, as: UTF8.self)
        launchLog("3D: remove \(name): exit \(result.exitCode)")
        guard result.status == .completed, result.exitCode == 0 || result.exitCode == 3010 else {
            throw VMError("The 3D driver could not be removed.", detail: output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        bundle.config.display.windows3DDriver = nil
        try? bundle.save()
    }
}
