import AppKit
import Foundation
import GuestLink
import Sharing
import TandemControl
import VMCore

/// Answers control requests (`tandem`, `tandem mcp`) on the main actor, through the same session
/// methods the app's own menus use. Every permission is decided here, in the app, never by the client:
/// the global "Allow AI tools" switch (`ControlGate`), and per VM the sharing policy (commands, folders).
@MainActor
final class ControlService {
    private weak var model: AppModel?
    let libraryRoot: URL

    init(model: AppModel, libraryRoot: URL) {
        self.model = model
        self.libraryRoot = libraryRoot
    }

    nonisolated func handle(_ request: ControlRequest) async -> ControlResponse {
        await MainActor.run { () -> Task<ControlResponse, Never> in
            Task { @MainActor in
                do {
                    try ControlGate.check(request, settings: ControlSettings.load(libraryRoot: self.libraryRoot))
                    return .success(request.id, try await self.perform(request))
                } catch let error as ControlError {
                    return .failure(request.id, error)
                } catch let error as VMError {
                    return .failure(request.id, .failed(error.message, detail: error.detail))
                } catch {
                    return .failure(request.id, .failed(error.localizedDescription))
                }
            }
        }.value
    }

    // MARK: Dispatch

    private func perform(_ r: ControlRequest) async throws -> JSON {
        guard let model else { throw ControlError("unavailable", "Tandem is shutting down.") }
        guard let op = r.operation else { throw ControlError("unknown-op", "Unknown operation “\(r.op)”.") }
        switch op {
        case .status:
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
            return .object(["app": "Tandem", "version": .string(version), "library": .string(libraryRoot.path),
                            "vms": JSON(model.sessions.count), "running": JSON(model.runningCount),
                            "allowAITools": JSON(ControlSettings.load(libraryRoot: libraryRoot).allowAITools)])
        case .list:
            return .array(model.sessions.map(summary))
        default: break
        }
        let session = try find(r.vm ?? "", in: model)
        let fromAI = r.client == .mcp
        switch op {
        case .info: return info(session)
        case .ip:
            let addresses = session.guestInfo?.ipAddresses ?? []
            guard !addresses.isEmpty else {
                throw ControlError.failed("“\(session.config.name)” has not reported an address.",
                                          detail: session.state == .running ? "Its guest tools are not connected yet." : "It is not running.")
            }
            return .object(["addresses": .array(addresses.map(JSON.string))])
        case .start: return try await start(session, r)
        case .resume: return try await resume(session, r)
        case .stop: return try await stop(session, r)
        case .suspend:
            guard session.canSuspend else { throw ControlError.failed("“\(session.config.name)” is not running.") }
            session.suspend()
            try await wait(for: session, timeout: Double(r.int("timeout") ?? 180), what: "suspending") { $0.state == .stopped && $0.isSuspended }
            return state(session)
        case .pause:
            guard session.can(.pause) else { throw ControlError.failed("“\(session.config.name)” is not running.") }
            session.pause()
            try await wait(for: session, timeout: 30, what: "pausing") { $0.state == .paused }
            return state(session)
        case .restart:
            guard session.canRestart else {
                throw ControlError.failed("“\(session.config.name)” cannot restart itself now.", detail: "Restart needs a running VM whose guest tools are connected; `reset` restarts it without asking the guest.")
            }
            session.restart()
            return state(session)
        case .reset:
            guard session.canReset else { throw ControlError.failed("“\(session.config.name)” cannot be reset (QEMU engine, running VMs only).") }
            session.reset()
            return state(session)
        case .snapshotList:
            let head = session.snapshotHead
            return .array(session.snapshots.map { s in
                .object(["id": .string(s.id.uuidString), "name": .string(s.name), "created": .string(ISO8601DateFormatter().string(from: s.created)),
                         "note": .optional(s.note), "current": JSON(s.id == head), "includesRunningState": JSON(session.snapshotIncludesRunningState(s))])
            })
        case .clone:
            let options = CloneOptions(name: r.string("name"), includeSnapshots: r.bool("includeSnapshots") ?? false,
                                       keepSuspendState: r.bool("keepSuspended") ?? false,
                                       keepHardwareIdentity: r.bool("keepIdentity") ?? false,
                                       resetGuestIdentity: r.bool("resetGuestIdentity") ?? true)
            let result = try await model.clone(session, options: options)
            var answer = summary(result.session)
            if case .object(var fields) = answer {
                fields["bytesUsed"] = JSON(Int(result.bytesUsed))
                fields["identity"] = .string(options.keepHardwareIdentity ? "kept" : "new")
                answer = .object(fields)
            }
            return answer
        case .snapshotTake:
            let name = r.string("name") ?? "Snapshot \(Date().formatted(date: .abbreviated, time: .shortened))"
            try await session.takeSnapshot(named: name, note: r.string("note") ?? "")
            guard let taken = session.snapshots.last(where: { $0.name == name }) else { return .object(["name": .string(name)]) }
            return .object(["id": .string(taken.id.uuidString), "name": .string(taken.name)])
        case .snapshotRevert:
            let snapshot = try findSnapshot(r.string("snapshot") ?? "", in: session)
            let wasActive = session.state.isActive
            try await session.goTo(snapshot, savingCurrentAs: nil)
            // A running VM is started again from the snapshot; answer once it runs.
            if wasActive { try await wait(for: session, timeout: 300, what: "starting from the snapshot") { $0.state == .running || $0.state == .error } }
            return .object(["reverted": .string(snapshot.name), "state": .string(session.state.rawValue)])
        case .snapshotDelete:
            let snapshot = try findSnapshot(r.string("snapshot") ?? "", in: session)
            try await session.deleteSnapshot(snapshot)
            return .object(["deleted": .string(snapshot.name)])
        case .screenshot:
            guard let image = session.guestImage() else {
                throw ControlError.failed("There is no picture of “\(session.config.name)”’s screen.",
                                          detail: session.state == .running ? "Screenshots are available for VMs on the QEMU engine." : "It is not running.")
            }
            guard let png = VMSession.png(image, maxWidth: r.int("maxWidth")) else { throw ControlError.failed("The screenshot could not be encoded.") }
            return .object(["png": .string(png.base64EncodedString()), "width": JSON(image.width), "height": JSON(image.height)])
        case .sharing:
            if let wanted = r.string("commands") {
                // Who may run commands is the user's decision: an AI tool may not widen its own access.
                if fromAI { throw ControlError.refused("AI tools cannot change who may run commands in a virtual machine.") }
                guard let access = CommandAccess(rawValue: wanted) else {
                    throw ControlError("bad-request", "Commands must be one of: \(CommandAccess.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
                var profile = decidingPolicy(session).profile
                profile.commands = access
                try session.setSharing(profile)
                return await settledSharing(session)
            }
            return sharing(session)
        case .share:
            try share(session, r, fromAI: fromAI)
            return await settledSharing(session)
        case .unshare:
            guard let key = r.string("folder"), !key.isEmpty else { throw ControlError("bad-request", "Name the folder to stop sharing (its name or its Mac path).") }
            try session.unshare(key)
            return await settledSharing(session)
        case .services:
            let statuses = session.serviceStatuses
            let services = statuses.isEmpty ? (session.config.publishedServices ?? []).map { ($0, nil as String?, false) }
                                            : statuses.map { ($0.service, $0.error, true) }
            return .array(services.map { service, error, running in
                .object(["name": .string(service.name), "guestPort": JSON(service.guestPort), "hostPort": JSON(service.hostPort),
                         "scope": .string(service.scope.rawValue), "listening": JSON(running && error == nil), "error": .optional(error)])
            })
        case .keepAwake:
            var settings = session.power
            settings.keepAwake = r.bool("on") ?? !settings.keepAwake
            session.setPower(settings)
            return .object(["keepAwake": JSON(settings.keepAwake)])
        case .programs:
            return .array(session.guestPrograms.map { .object(["name": .string($0.name), "id": .string($0.id)]) })
        case .launch:
            guard session.state == .running, session.agent != nil else { throw ControlError.failed("“\(session.config.name)” is not running with its guest tools connected.") }
            let wanted = r.string("program") ?? ""
            let programs = session.guestPrograms
            guard let program = programs.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame })
                    ?? programs.first(where: { $0.name.localizedCaseInsensitiveContains(wanted) }) else {
                throw ControlError.failed("No program named “\(wanted)” in “\(session.config.name)”.", detail: "`tandem programs <vm>` lists them.")
            }
            session.launch(program)
            return .object(["launched": .string(program.name)])
        case .exec: return try await exec(session, r, fromAI: fromAI)
        case .status, .list: return .null
        }
    }

    // MARK: Lookup

    private func find(_ key: String, in model: AppModel) throws -> VMSession {
        let sessions = model.sessions
        if let exact = sessions.first(where: { $0.config.name == key }) { return exact }
        let matches = sessions.filter {
            $0.config.name.caseInsensitiveCompare(key) == .orderedSame || $0.id.uuidString.lowercased().hasPrefix(key.lowercased())
        }
        switch matches.count {
        case 1: return matches[0]
        case 0: throw ControlError("no-such-vm", "No virtual machine is called “\(key)”.", detail: "`tandem list` shows them.")
        default: throw ControlError("bad-request", "“\(key)” matches \(matches.count) virtual machines; use the full name or id.")
        }
    }

    private func findSnapshot(_ key: String, in session: VMSession) throws -> VMSnapshot {
        let all = session.snapshots
        let matches = all.filter { $0.name == key || $0.id.uuidString.lowercased().hasPrefix(key.lowercased()) && !key.isEmpty }
        guard matches.count == 1 else {
            throw ControlError(matches.isEmpty ? "failed" : "bad-request",
                               matches.isEmpty ? "No snapshot “\(key)” in “\(session.config.name)”." : "“\(key)” matches \(matches.count) snapshots; use its id.")
        }
        return matches[0]
    }

    // MARK: Descriptions

    private func summary(_ s: VMSession) -> JSON {
        .object(["id": .string(s.id.uuidString), "name": .string(s.config.name), "os": .string(s.config.guestOS.rawValue),
                 "engine": .string(s.config.engine.rawValue), "state": .string(s.state.rawValue), "status": .string(s.statusLabel),
                 "suspended": JSON(s.isSuspended), "ip": .optional(s.guestInfo?.ipAddresses?.first)])
    }

    private func state(_ s: VMSession) -> JSON {
        .object(["name": .string(s.config.name), "state": .string(s.state.rawValue), "status": .string(s.statusLabel), "suspended": JSON(s.isSuspended)])
    }

    private func info(_ s: VMSession) -> JSON {
        guard case .object(var o) = summary(s) else { return .null }
        o["cpus"] = JSON(s.config.cpuCount)
        o["memoryMiB"] = JSON(s.config.memoryMiB)
        o["diskGiB"] = JSON(s.config.disks.first?.sizeGiB ?? 0)
        o["bundle"] = .string(s.bundle.url.path)
        o["tools"] = .object(["connected": JSON(s.agent != nil), "version": .optional(s.agent?.agentVersion),
                              "canRunCommands": JSON((s.agent?.capabilities ?? 0) & guestExecCapability != 0)])
        if let g = s.guestInfo {
            o["guest"] = .object(["hostname": .optional(g.hostname), "os": .optional([g.osName, g.osVersion].compactMap { $0 }.joined(separator: " ")),
                                  "addresses": .array((g.ipAddresses ?? []).map(JSON.string))])
        }
        o["commands"] = .string(s.sharingPolicy.commands.rawValue)
        o["snapshots"] = JSON(s.snapshots.count)
        o["keepAwake"] = JSON(s.power.keepAwake)
        if let error = s.errorMessage { o["error"] = .string(error) }
        return .object(o)
    }

    private func sharing(_ s: VMSession) -> JSON {
        let policy = s.sharingPolicy
        return .object([
            "folders": .array(policy.folders.map { f in
                .object(["name": .string(f.name), "path": .string(f.folder.hostPath), "readOnly": JSON(f.folder.readOnly), "temporary": JSON(f.temporary)])
            }),
            "clipboard": .string(policy.clipboard.rawValue), "usb": JSON(policy.usbAllowed),
            "network": .object(["outbound": JSON(policy.network.outbound), "inbound": JSON(policy.network.inbound), "bridged": JSON(policy.network.bridged)]),
            "commands": .string(policy.commands.rawValue), "preset": .optional(policy.profile.preset?.rawValue),
            "summary": .array(SharedFolderService.summaryLines(policy.summary(network: s.config.network), pendingNote: s.state.isActive ? s.sharingNote : nil).map(JSON.string)),
            // What a running VM only gets at its next start (QEMU attaches Linux folders when it starts).
            "pending": .optional(s.state.isActive ? s.sharingNote : nil),
        ])
    }

    // MARK: Lifecycle

    private func start(_ s: VMSession, _ r: ControlRequest) async throws -> JSON {
        if s.state == .paused { s.resume() }
        else if s.state == .stopped || s.state == .error {
            guard s.can(.start) else { throw ControlError.failed("“\(s.config.name)” cannot start now: \(s.statusLabel).") }
            s.start()
        }
        let timeout = Double(r.int("timeout") ?? 300)
        if r.bool("wait") ?? true {
            try await wait(for: s, timeout: timeout, what: "starting") { $0.state == .running || $0.state == .error }
            if s.state == .error { throw ControlError.failed("“\(s.config.name)” failed to start.", detail: s.errorMessage) }
        }
        if r.bool("waitForTools") ?? false {
            try await wait(for: s, timeout: timeout, what: "waiting for the guest tools") { $0.agent != nil }
        }
        return state(s)
    }

    private func resume(_ s: VMSession, _ r: ControlRequest) async throws -> JSON {
        guard s.state == .paused || (s.state == .stopped && s.isSuspended) else {
            throw ControlError.failed("“\(s.config.name)” is not paused or suspended.")
        }
        return try await start(s, r)
    }

    private func stop(_ s: VMSession, _ r: ControlRequest) async throws -> JSON {
        guard s.state.isActive else {
            if s.isSuspended && r.bool("force") == true { s.discardSuspendedState(); return state(s) }
            throw ControlError.failed("“\(s.config.name)” is not running.")
        }
        if r.bool("force") == true { s.forceStop() } else {
            guard s.can(.stop) else { throw ControlError.failed("“\(s.config.name)” cannot shut down now: \(s.statusLabel).") }
            s.stop()
        }
        if r.bool("wait") ?? true {
            try await wait(for: s, timeout: Double(r.int("timeout") ?? 180), what: "shutting down") { !$0.state.isActive }
        }
        return state(s)
    }

    private func wait(for s: VMSession, timeout: Double, what: String, until done: (VMSession) -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !done(s) {
            if Date() > deadline { throw ControlError("timeout", "“\(s.config.name)” is still \(what) after \(Int(timeout)) seconds.", detail: "Status: \(s.statusLabel)") }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    // MARK: Sharing

    /// The policy to decide by: what the bundle's files say now. A running session notices a change made
    /// elsewhere (`vmctl sharing`, the settings panel of another process) up to a second later, and a
    /// permission taken away must not be honoured in that second.
    private func decidingPolicy(_ s: VMSession) -> SharingPolicy {
        guard let stored = try? VMBundle.load(from: s.bundle.url) else { return s.sharingPolicy }
        return SharingPolicy(stored.config, temporary: s.state.isActive ? TemporarySharingFile.load(stored) : TemporaryGrants())
    }

    /// A running VM takes a sharing change through its bundle files, a moment later; answer with the result.
    private func settledSharing(_ s: VMSession) async -> JSON {
        if s.state.isActive, let stored = try? VMBundle.load(from: s.bundle.url) {
            let wanted = SharingPolicy(stored.config, temporary: TemporarySharingFile.load(stored))
            for _ in 0..<30 where s.sharingPolicy != wanted { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        return sharing(s)
    }

    private func share(_ s: VMSession, _ r: ControlRequest, fromAI: Bool) throws {
        guard let path = r.string("path"), !path.isEmpty else { throw ControlError("bad-request", "Give the Mac folder to share.") }
        if fromAI && decidingPolicy(s).profile.preset == .restricted {
            throw ControlError.refused("“\(s.config.name)” is restricted, so AI tools cannot share folders with it.",
                                       detail: "Change its sharing in Configure > Options > Sharing if you want it to have folders.")
        }
        if fromAI, let refusal = SharingEdit.aiShareRefusal(path: path, home: FileManager.default.homeDirectoryForCurrentUser, libraryRoot: libraryRoot) {
            throw ControlError.refused(refusal, detail: "You can share it yourself in Configure > Options > Sharing.")
        }
        let readOnly = r.bool("readOnly") ?? false
        if r.bool("temporary") ?? false {
            try s.shareTemporarily(path: path, readOnly: readOnly)
        } else {
            let current = decidingPolicy(s)
            var profile = current.profile
            let taken = current.folders.map(\.name)
            let folder = try SharingEdit.folder(path: path, name: r.string("name"), readOnly: readOnly, taken: taken)
            profile.folders.append(folder)
            try s.setSharing(profile)
        }
    }

    // MARK: Guest commands

    private func exec(_ s: VMSession, _ r: ControlRequest, fromAI: Bool) async throws -> JSON {
        guard let command = r.string("command"), !command.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ControlError("bad-request", "Give the command to run.")
        }
        do { try decidingPolicy(s).requireCommands(fromAI: fromAI) }
        catch let error as VMError { throw ControlError.refused(error.message, detail: error.detail) }
        guard s.state == .running else { throw ControlError.failed("“\(s.config.name)” is not running.") }
        // Just started or resumed: give the guest tools a moment to connect.
        if s.agent == nil {
            do { try await wait(for: s, timeout: 45, what: "waiting for its guest tools") { $0.agent != nil } }
            catch { throw ControlError.failed("“\(s.config.name)”’s guest tools are not connected.", detail: "They connect a few seconds after the guest has started; `tandem start <vm> --wait-tools` waits for them.") }
        }
        let request = GuestExecRequest(command: command, user: r.string("user"), elevated: r.bool("elevated") ?? false,
                                       timeoutSeconds: r.int("timeout") ?? GuestExecRequest.defaultTimeout,
                                       maxOutputBytes: r.int("maxOutput") ?? GuestExecRequest.defaultMaxOutput)
        s.launchLog("command from the Mac (\(fromAI ? "AI tool" : "command line")): \(command)")
        let result = try await s.link.exec(request)
        let status: String
        switch result.status {
        case .completed: status = "completed"
        case .timedOut: status = "timed-out"
        case .failedToStart: status = "failed-to-start"
        case .notSupported: status = "not-supported"
        }
        return .object(["status": .string(status), "exitCode": JSON(Int(result.exitCode)),
                        "stdout": .string(String(decoding: result.stdout, as: UTF8.self)),
                        "stderr": .string(String(decoding: result.stderr, as: UTF8.self)),
                        "stdoutTruncated": JSON(result.stdoutTruncated), "stderrTruncated": JSON(result.stderrTruncated),
                        "message": .string(result.message)])
    }
}
