import AppKit
import EngineQEMU
import EngineVZ
import SwiftUI
import VMCore

extension AppModel {
    /// Clones a stopped or suspended VM (VMCore/Clone.swift) and selects the copy. Returns the new session
    /// and the disk space the copy took at once (close to nothing: APFS shares blocks until they change).
    /// The copy runs off the main actor under the source's lease, so the app stays responsive on disks
    /// where it copies every byte; cancelling the calling task stops it and removes the partial copy.
    @discardableResult
    func clone(_ session: VMSession, options: CloneOptions,
               progress: (@Sendable (Double) -> Void)? = nil) async throws -> (session: VMSession, bytesUsed: Int64) {
        guard !session.state.isActive else {
            throw VMError("“\(session.config.name)” is running.", detail: "Shut it down or suspend it, then clone it.")
        }
        guard session.provisioning == nil else { throw VMError("“\(session.config.name)” is still being set up.") }
        guard let library = vmLibrary else { throw VMError("The VM library is not available.") }
        let folder = library.vmsDirectory
        let source = session.bundle, taken = Set(sessions.map(\.config.name))
        let hooks = CloneSupport.hooks(qemuImg: try? QEMUToolchain.locate().qemuImg)
        let before = VMCloner.freeBytes(at: folder)
        let bundle = try await BundleWork.run(source, purpose: "being cloned") {
            try VMCloner.clone(source, into: folder, taken: taken, options: options, hooks: hooks, progress: progress)
        }
        reload()
        selection = bundle.id
        guard let copy = sessions.first(where: { $0.id == bundle.id }) else { throw VMError("The copy could not be added to Control Center.") }
        return (copy, max(0, before - VMCloner.freeBytes(at: folder)))
    }
}

extension VMSession {
    /// A clone resets its guest's identity the first time its guest tools answer.
    func resetCloneIdentityIfNeeded(capabilities: UInt32) {
        guard bundle.config.pendingGuestIdentityReset == true else { return }
        Task { [weak self] in
            guard let self else { return }
            var copy = self.bundle
            let line = await self.link.resetCloneIdentityIfNeeded(&copy, capabilities: capabilities)
            self.bundle.config.pendingGuestIdentityReset = copy.config.pendingGuestIdentityReset
            if let line { self.appendGuestLog(level: 1, message: line) }
        }
    }
}

/// File > Clone…: a name and what the copy keeps from the original.
struct CloneSheet: View {
    let session: VMSession
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var keepIdentity = false
    @State private var includeSnapshots = false
    @State private var keepSuspended = false
    @State private var resetGuest = true
    @State private var errorText: String?
    @State private var done: String?
    @State private var cloning: Task<Void, Never>?
    @State private var fraction = 0.0

    private var isWindows: Bool { session.config.guestOS == .windows11arm }
    private var canResetGuest: Bool { session.config.guestOS == .linux || isWindows }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Clone “\(session.config.name)”").font(.title2)
            if let done {
                Text(done).fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            } else {
                Form {
                    TextField("Name:", text: $name, prompt: Text(VMCloner.defaultName(for: session.config.name, taken: Set(model.sessions.map(\.config.name)))))
                    Toggle(isWindows ? "Keep Windows activation identity" : "Keep the hardware identity", isOn: $keepIdentity)
                    Text(keepIdentity
                         ? (isWindows ? "The copy keeps the original's firmware ID and TPM, so Windows stays activated. Do not run both at the same time; Microsoft may treat them as one PC."
                                      : "The copy keeps the original's firmware ID and TPM. Do not run both at the same time.")
                         : "The copy is a new machine: new firmware ID, empty TPM and new network address."
                            + (isWindows ? " Windows may then ask to be activated again, and BitLocker, if it is on, asks for its recovery key." : ""))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if canResetGuest {
                        Toggle(isWindows ? "Give Windows a new computer name at first start" : "Reset the guest's machine ID, SSH keys and host name at first start",
                               isOn: $resetGuest)
                    }
                    if !session.snapshots.isEmpty { Toggle("Include snapshots (\(session.snapshots.count))", isOn: $includeSnapshots) }
                    if session.isSuspended {
                        Toggle("Keep the suspended state", isOn: $keepSuspended).accessibilityLabel("Keep the suspended state")
                        Text("Off: the copy starts fresh from its disk. On: it resumes where the original was suspended, with the original's network settings, until it restarts.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Text("The copy is made instantly and shares disk space with the original until either one changes.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .formStyle(.grouped)
                if let errorText { Text(errorText).foregroundStyle(.red).textSelection(.enabled) }
                if cloning != nil { ProgressView("Copying…", value: fraction).progressViewStyle(.linear) }
                HStack {
                    Spacer()
                    if let cloning {
                        Button("Stop", role: .cancel) { cloning.cancel() }.keyboardShortcut(.cancelAction)
                    } else {
                        Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    }
                    Button("Clone") { clone() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(cloning != nil)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func clone() {
        let options = CloneOptions(name: name, includeSnapshots: includeSnapshots, keepSuspendState: keepSuspended,
                                   keepHardwareIdentity: keepIdentity, resetGuestIdentity: resetGuest && canResetGuest)
        errorText = nil; fraction = 0
        cloning = Task {
            defer { cloning = nil }
            do {
                let result = try await model.clone(session, options: options) { value in Task { @MainActor in fraction = value } }
                let used = ByteCountFormatter.string(fromByteCount: result.bytesUsed, countStyle: .file)
                done = "“\(result.session.config.name)” is ready in Control Center. It used about \(used) of disk space so far; it grows only as the two VMs change."
            } catch is CancellationError {
                errorText = "Cloning was stopped. Nothing was kept of the partial copy."
            } catch {
                errorText = [error.localizedDescription, (error as? VMError)?.detail].compactMap { $0 }.joined(separator: "\n")
            }
        }
    }
}

extension Notification.Name {
    static let cloneVM = Notification.Name("tandem.cloneVM")
}

/// Control Center's part: the Clone sheet, opened from the menus by notification.
struct CloneHandling: ViewModifier {
    @Binding var cloning: VMSession?
    @EnvironmentObject private var model: AppModel

    func body(content: Content) -> some View {
        content
            .sheet(item: $cloning) { session in CloneSheet(session: session).environmentObject(model) }
            .onReceive(NotificationCenter.default.publisher(for: .cloneVM)) { note in
                if let id = note.object as? UUID { cloning = model.sessions.first { $0.id == id } }
            }
    }
}
