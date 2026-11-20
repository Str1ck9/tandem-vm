import AppKit
import Foundation
import Provisioning
import VMCore

/// Self-test trials for downloaded systems ("Free Systems"). Driven by environment variables:
///
///   TANDEM_SNAPSHOT_ASSISTANT_DOWNLOAD  a slot ("linux"): open the assistant at that system's list and render it;
///                                       with TANDEM_SNAPSHOT_ASSISTANT_PAGE=name, at the last page with the first choice
///   TANDEM_SNAPSHOT_DOWNLOAD            "slot:option" ("linux:debian-13"): create a VM the way the assistant does,
///                                       follow the download in Control Center, let the VM start by itself, wait for
///                                       the guest tools, shut down
///   TANDEM_SNAPSHOT_DOWNLOAD_HOLD       with the above: seconds to keep the VM running after the tools answer
///   TANDEM_SNAPSHOT_DOWNLOAD_CANCEL     with the above: cancel once the download is under way instead; the VM must
///                                       go and the partial file must stay
///   TANDEM_SNAPSHOT_DOWNLOAD_FAIL       with the above: the preparation fails after the download; the VM must go and
///                                       the reason must be shown
extension SelfTest {
    private static func wait(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    static func assistantDownloadPages() async {
        NotificationCenter.default.post(name: .selfTestOpen, object: "assistant")
        // The list comes from the vendors' servers.
        await wait(10)
        snapshotWindows(tag: "5-assistant-download")
    }

    /// A provider whose preparation fails after a real download, to exercise the failure path.
    private struct Failing: SystemProvider {
        let inner: any SystemProvider
        var slot: String { inner.slot }
        var title: String { inner.title }
        var sourceNote: String { inner.sourceNote }
        var guestOS: GuestOS { inner.guestOS }
        var engine: EngineKind { inner.engine }
        var wantsAccount: Bool { inner.wantsAccount }
        func options(using downloads: Downloader) async throws -> [SystemOption] { try await inner.options(using: downloads) }
        func defaults(for option: SystemOption) -> SystemDefaults { inner.defaults(for: option) }
        func fetch(_ option: SystemOption, context: ProvisioningContext) async throws -> [URL] { try await inner.fetch(option, context: context) }
        func prepare(_ option: SystemOption, bundle: inout VMBundle, context: ProvisioningContext) async throws -> ProvisioningOutcome {
            _ = try await inner.fetch(option, context: context)
            throw VMError("The disk could not be prepared (simulated by the self-test).", detail: "qemu-img said no.")
        }
    }

    static func downloadTrial(_ model: AppModel, spec: String) async {
        let env = ProcessInfo.processInfo.environment
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        guard var provider = SystemCatalog.provider(for: parts[0]) else { print("download: no provider “\(parts[0])”"); return }
        let downloads = SystemCatalog.downloads(in: URL(fileURLWithPath: model.libraryRoot))
        let options: [SystemOption]
        do { options = try await provider.options(using: downloads) } catch { print("download: options failed: \(error.localizedDescription)"); return }
        guard let option = parts.count > 1 ? options.first(where: { $0.id == parts[1] }) : options.first else {
            print("download: “\(spec)” is not offered: \(options.map(\.id))"); return
        }
        let cancel = env["TANDEM_SNAPSHOT_DOWNLOAD_CANCEL"] != nil, fail = env["TANDEM_SNAPSHOT_DOWNLOAD_FAIL"] != nil
        if fail { provider = Failing(inner: provider) }

        let defaults = provider.defaults(for: option)
        // Small for server systems; a desktop gets what the assistant would give it (capped at 8 GB).
        let desktop = defaults.minimumDiskGiB >= 32
        var config = VMConfig(name: "selftest-download", guestOS: provider.guestOS, engine: provider.engine,
                              cpuCount: desktop ? defaults.cpuCount : 2, memoryMiB: desktop ? min(defaults.memoryMiB, 8192) : 2048)
        config.disks[0].sizeGiB = desktop ? defaults.minimumDiskGiB : 16
        let began = Date()
        func elapsed() -> Int { Int(Date().timeIntervalSince(began)) }
        let id: UUID
        do {
            id = try model.create(config, downloading: option, from: provider, account: provider.wantsAccount ? SystemAccount(userName: "tester", password: "tandem-pw") : nil)
        } catch { print("download: create failed: \(error.localizedDescription)"); return }
        guard let session = model.sessions.first(where: { $0.id == id }) else { print("download: no session"); return }
        print("download: created “\(session.config.name)” for \(option.title); can start now: \(session.can(.start))")

        var last = "", shot = false, cancelled = false
        for _ in 0..<3600 {
            guard model.sessions.contains(where: { $0.id == id }) else { break }
            let label = session.statusLabel
            // One line per phase and per ten percent.
            let key = session.provisioning.map { $0.phase + ($0.fraction.map { " \(Int($0 * 10) * 10)%" } ?? "") } ?? label
            if key != last { last = key; print("download: status “\(label)” after \(elapsed()) s\(session.provisioning?.detail.map { " (\($0))" } ?? "")") }
            if let fraction = session.provisioning?.fraction, fraction > 0.2, fraction < 1, !shot {
                shot = true
                NotificationCenter.default.post(name: .selfTestShow, object: id)
                await wait(1)
                snapshotWindows(tag: "5-downloading")
                if cancel, !cancelled {
                    cancelled = true
                    print("download: cancelling at \(Int(fraction * 100))%")
                    session.cancelProvisioning?()
                }
            }
            if session.provisioning == nil { break }
            await wait(0.2)
        }

        if cancel || fail {
            await wait(2)
            let gone = !model.sessions.contains(where: { $0.id == id })
            let onDisk = FileManager.default.fileExists(atPath: session.bundle.url.path)
            let cache = (try? FileManager.default.contentsOfDirectory(atPath: downloads.cache.path))?.sorted() ?? []
            print("download: after \(cancel ? "cancel" : "failure"): VM gone from the list=\(gone), bundle still on disk=\(onDisk), cache=\(cache), error shown=\(model.provisioningError?.replacingOccurrences(of: "\n", with: " | ") ?? "none")")
            snapshotWindows(tag: "6-after")
            return
        }

        print("download: finished after \(elapsed()) s; state=\(session.state.rawValue) error=\(model.provisioningError ?? "none") media=\(session.config.removableMedia.map(\.kind.rawValue))")
        // The VM starts by itself; first boot sets the system up and installs the guest tools.
        for _ in 0..<600 where session.agent == nil && model.sessions.contains(where: { $0.id == id }) { await wait(0.5) }
        await wait(3)
        print("download: guest tools \(session.agent == nil ? "did NOT answer" : "answered") after \(elapsed()) s; guest=\(session.guestInfo?.hostname ?? "?") \(session.guestInfo?.osName ?? "?") \(session.guestInfo?.osVersion ?? ""); install=\(session.config.install.state.rawValue); media=\(session.config.removableMedia.map(\.kind.rawValue)); setup disc on disk=\(FileManager.default.fileExists(atPath: session.bundle.url.appendingPathComponent(LinuxSeed.fileName).path)); status “\(session.statusLabel)”")
        snapshotWindows(tag: "6-running")
        // TANDEM_SNAPSHOT_DOWNLOAD_HOLD=<seconds>: keep the VM running so its console can be checked from outside.
        if let hold = Double(env["TANDEM_SNAPSHOT_DOWNLOAD_HOLD"] ?? "") {
            print("download: holding the VM for \(Int(hold)) s")
            await wait(hold)
        }
        session.stop()
        for _ in 0..<240 where session.state.isActive { await wait(0.5) }
        print("download: final state=\(session.state.rawValue)")
    }
}
