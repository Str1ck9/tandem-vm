import AppKit
import EngineQEMU
import Foundation
import Provisioning
import VMCore

/// "Free Systems" in the app: a VM whose system Tandem downloads and prepares.
///
/// The VM is created straight away and appears in Control Center with the download's progress in
/// place of its state. The work runs off the main thread and outlives the assistant that started it.
/// When it finishes the VM starts by itself (where the provider asks for that); when it fails or is
/// cancelled the half-made VM is removed, and what was downloaded stays in the cache for next time.
extension AppModel {
    /// Makes the VM and starts the job. Throws only for what can be known at once (no library, a
    /// name already taken, no QEMU); everything later is reported through `provisioningError`.
    @discardableResult
    func create(_ config: VMConfig, downloading option: SystemOption, from provider: any SystemProvider, account: SystemAccount?,
                startWhenReady: Bool = true) throws -> UUID {
        guard let library = vmLibrary else { throw VMError("The VM library is not available.") }
        var config = config
        provider.adjust(&config, for: option)
        let bundle = try library.create(config)
        var qemuImg = (try? QEMUToolchain.locate())?.qemuImg
        do {
            if config.engine == .qemu {
                let toolchain = try QEMUToolchain.locate()
                try QEMUEngine.prepare(bundle: bundle, toolchain: toolchain, paths: QEMURunPaths.forVM(bundle.id))
                qemuImg = toolchain.qemuImg
            }
            // From here on the bundle says of itself that its setup is not finished.
            try SystemCatalog.writeMarker(.init(slot: provider.slot, option: option.id, title: option.title), in: bundle)
        } catch {
            try? library.delete(bundle)
            throw error
        }
        reload()
        selection = bundle.id
        guard let session = sessions.first(where: { $0.id == bundle.id }) else { throw VMError("The new virtual machine did not appear in the library.") }
        let id = bundle.id
        session.setupInterrupted = false
        session.provisioning = ProvisioningProgress("Starting the download of \(option.title)")
        session.cancelProvisioning = { [weak self] in self?.provisioningTasks[id]?.cancel() }

        let virtio = ImportDefaults.existingPath(ImportDefaults.virtioISOKey)
        let context = ProvisioningContext(
            downloads: SystemCatalog.downloads(in: library.rootDirectory), account: account, qemuImg: qemuImg,
            windowsAgent: GuestTools.windowsAgent, virtioISO: virtio.isEmpty ? nil : URL(fileURLWithPath: virtio),
            bootUntilPowerOff: { bundle, timeout in try await HeadlessRun.untilPowerOff(bundle, timeout: timeout) },
            progress: { [weak self] progress in Task { @MainActor in self?.provisioningProgressed(id, progress) } })
        provisioningTasks[id] = Task.detached(priority: .userInitiated) { [weak self] in
            var working = bundle
            do {
                let outcome = try await SystemCatalog.provision(provider, option: option, bundle: &working, context: context)
                await self?.provisioningFinished(id, outcome: startWhenReady ? outcome : .ready)
            } catch {
                await self?.provisioningFailed(id, error)
            }
        }
        return id
    }

    private func provisioningProgressed(_ id: UUID, _ progress: ProvisioningProgress) {
        // Reports can arrive after the job has ended; those are dropped.
        guard provisioningTasks[id] != nil, let session = sessions.first(where: { $0.id == id }) else { return }
        session.provisioning = progress
    }

    private func provisioningFinished(_ id: UUID, outcome: ProvisioningOutcome) {
        provisioningTasks[id] = nil
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        session.provisioning = nil
        session.cancelProvisioning = nil
        // The provider changed the configuration on disk (media, install state); take it from there.
        reload()
        guard outcome == .startNow, session.can(.start) else { return }
        AppDelegate.shared?.show("vm", id)
        session.start()
    }

    private func provisioningFailed(_ id: UUID, _ error: Error) {
        provisioningTasks[id] = nil
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        let name = session.config.name
        session.provisioning = nil
        session.cancelProvisioning = nil
        // Leave no half-made VM behind. Downloads stay in the cache, so trying again carries on from there.
        do { try delete(session) } catch { session.setupInterrupted = true }
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        // A VMError's description already carries its detail.
        provisioningError = "“\(name)” was not created.\n\n" + error.localizedDescription
    }
}
