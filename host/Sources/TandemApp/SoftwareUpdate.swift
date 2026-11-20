import AppKit
import CryptoKit
import NetHelperClient
import SwiftUI
import Updater
import VMCore

/// Tandem's own updates, as the user sees them: Tandem > Check for Updates…, a daily check (Settings >
/// General), the update window, and installing in place of the running app. The feed, signatures, download
/// and the atomic swap are in the Updater library; this is the app's side of it.
///
/// An update is never installed while a VM runs (quitting would end it): the window offers to suspend the
/// VMs first, or to install as soon as they have stopped. After the swap Tandem starts again from the new
/// copy, and that copy restarts the helper once no VM uses it, so the helper runs the new version too.
@MainActor
final class SoftwareUpdate: ObservableObject {
    static let shared = SoftwareUpdate()

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateRelease)
        case downloading(UpdateRelease, Double)
        case ready(UpdateRelease, URL)
        case installing(UpdateRelease, String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// Installing as soon as the last VM has stopped.
    @Published private(set) var waitingForVMs = false
    @Published private(set) var lastChecked: Date?

    weak var model: AppModel?
    private var job: Task<Void, Never>?
    private var timer: Timer?

    enum Keys {
        static let autoCheck = "updatesAutoCheck"
        static let autoDownload = "updatesAutoDownload"
        static let feedURL = "updatesFeedURL"
        static let lastChecked = "updatesLastChecked"
        static let skipped = "updatesSkipped"
        static let restartHelper = "updatesRestartHelperAfterUpdate"
    }

    private var defaults: UserDefaults { .standard }
    /// What the updater remembers (last check, skipped versions, helper restart due). A test library
    /// (TANDEM_HOME) keeps its own, so a test copy never changes what the installed Tandem will do.
    private let state = UpdateState()

    private init() {
        lastChecked = state.date(Keys.lastChecked)
    }

    // MARK: Settings

    static var autoCheck: Bool { UserDefaults.standard.object(forKey: Keys.autoCheck) as? Bool ?? true }
    static var autoDownload: Bool { UserDefaults.standard.object(forKey: Keys.autoDownload) as? Bool ?? false }

    /// TANDEM_UPDATE_FEED (tests), then the one set in Settings, then the one this build names.
    var feedURL: URL {
        let env = ProcessInfo.processInfo.environment["TANDEM_UPDATE_FEED"]
        let custom = defaults.string(forKey: Keys.feedURL)?.trimmingCharacters(in: .whitespaces)
        for text in [env, custom, Bundle.main.object(forInfoDictionaryKey: UpdateClient.infoPlistFeedKey) as? String] {
            if let text, !text.isEmpty, let url = Self.url(text) { return url }
        }
        return UpdateClient.defaultFeedURL
    }

    static func url(_ text: String) -> URL? {
        if text.hasPrefix("/") || text.hasPrefix("~") { return URL(fileURLWithPath: (text as NSString).expandingTildeInPath) }
        guard let url = URL(string: text), url.scheme == "https" || url.isFileURL else { return nil }
        return url
    }

    var currentVersion: AppVersion { AppVersion.of(bundle: .main) ?? AppVersion(components: [0], build: 0) }

    private var client: UpdateClient? {
        guard let key = UpdateSignature.publicKey(of: .main) else { return nil }
        return UpdateClient(feedURL: feedURL, publicKey: key, current: currentVersion)
    }

    private var skipped: Set<String> { Set(state.strings(Keys.skipped)) }

    private var downloadsFolder: URL {
        URL(fileURLWithPath: model?.libraryRoot ?? VMLibrary.defaultRoot().path).appendingPathComponent("Updates", isDirectory: true)
    }

    // MARK: Launch

    /// At launch: finish an update that has just been installed, then check once a day if allowed.
    func start(model: AppModel) {
        self.model = model
        finishAfterUpdate()
        let app = Bundle.main.bundleURL
        Task.detached(priority: .background) { UpdateInstaller.removeLeftovers(nextTo: app) }
        // Self-tests and the development build's ad hoc copies do not check on their own.
        guard SelfTest.directory == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in SoftwareUpdate.shared.checkIfDue() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { self.checkIfDue() }
    }

    private func checkIfDue() {
        guard Self.autoCheck, client != nil, job == nil else { return }
        if let last = lastChecked, Date().timeIntervalSince(last) < 23 * 3600 { return }
        check(userInitiated: false)
    }

    // MARK: Checking

    /// Tandem > Check for Updates…: shows the window whatever the answer. In the background the window
    /// appears only when there is something to install.
    func check(userInitiated: Bool) {
        if userInitiated { AppDelegate.shared?.show("update", nil) }
        switch phase {
        case .downloading, .installing: return
        case .ready where !userInitiated: return
        default: break
        }
        guard let client else {
            phase = .failed("This copy of Tandem cannot update itself: it was built without Tandem’s update key. Development builds are updated by building them again.")
            return
        }
        job?.cancel()
        phase = .checking
        let skipped = userInitiated ? [] : skipped
        job = Task {
            defer { job = nil }
            do {
                let release = try await client.check(skipping: skipped)
                lastChecked = Date()
                state.set(lastChecked, Keys.lastChecked)
                guard let release else { phase = .upToDate; return }
                phase = .available(release)
                if Self.autoDownload { await download(release) }
                if !userInitiated { AppDelegate.shared?.show("update", nil) }
            } catch is CancellationError {
            } catch {
                phase = .failed(error.userFacingText)
            }
        }
    }

    func download() {
        guard case .available(let release) = phase, job == nil else { return }
        job = Task { defer { job = nil }; await download(release) }
    }

    private func download(_ release: UpdateRelease) async {
        guard let client else { return }
        phase = .downloading(release, 0)
        do {
            let archive = try await client.download(release, into: downloadsFolder) { fraction in
                Task { @MainActor in
                    if case .downloading(let r, _) = SoftwareUpdate.shared.phase, r == release { SoftwareUpdate.shared.phase = .downloading(r, fraction) }
                }
            }
            phase = .ready(release, archive)
        } catch is CancellationError {
            phase = .available(release)
        } catch {
            phase = .failed(error.userFacingText)
        }
    }

    func skip() {
        let release: UpdateRelease?
        switch phase {
        case .available(let r), .ready(let r, _): release = r
        default: release = nil
        }
        if let release { state.set(Array(skipped.union([release.appVersion.key])).sorted(), Keys.skipped) }
        phase = .idle
        waitingForVMs = false
        closeWindow()
    }

    func later() {
        waitingForVMs = false
        closeWindow()
    }

    private func closeWindow() {
        for window in NSApp.windows where window.title == "Software Update" { window.close() }
    }

    // MARK: Installing

    var runningVMs: [VMSession] { model?.sessions.filter { $0.state.isActive || $0.busy != nil } ?? [] }

    /// Install and Restart. Downloads first when needed.
    func install() {
        guard job == nil else { return }
        switch phase {
        case .available(let release):
            job = Task {
                await download(release)
                job = nil
                if case .ready = phase { install() }
            }
        case .ready(let release, let archive):
            guard runningVMs.isEmpty else { return }
            waitingForVMs = false
            job = Task { defer { job = nil }; await install(release, archive) }
        default:
            break
        }
    }

    /// Suspends every running VM (each must allow it), then installs.
    func suspendAllAndInstall() {
        let running = runningVMs
        guard running.allSatisfy(\.canSuspend) else { return }
        for session in running { session.suspend() }
        installWhenVMsStop()
    }

    var vmsThatCannotSuspend: [VMSession] { runningVMs.filter { !$0.canSuspend } }

    /// Waits for the last VM to stop (the user shuts them down, or they are being suspended), then installs.
    func installWhenVMsStop() {
        waitingForVMs = true
        Task {
            while waitingForVMs, !runningVMs.isEmpty { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            guard waitingForVMs else { return }
            waitingForVMs = false
            install()
        }
    }

    private func install(_ release: UpdateRelease, _ archive: URL) async {
        let target = Bundle.main.bundleURL
        phase = .installing(release, "Checking the update…")
        do {
            let staged = try await Task.detached {
                try UpdateInstaller.stage(archive: archive, release: release, replacing: target)
            }.value
            // The last moment to change our minds: a VM may have been started meanwhile.
            guard runningVMs.isEmpty else {
                UpdateInstaller.discard(staged)
                phase = .ready(release, archive)
                return
            }
            phase = .installing(release, "Installing…")
            // A release test throws its old test copy away instead of filling the Trash.
            try UpdateInstaller.install(staged, oldCopy: SelfTest.directory == nil ? .trash : .delete)
            try? FileManager.default.removeItem(at: archive)
            state.set(true, Keys.restartHelper)
            phase = .installing(release, "Restarting Tandem…")
            try await Task.sleep(nanoseconds: 500_000_000)
            relaunch(target)
        } catch {
            phase = .failed(error.userFacingText)
        }
    }

    /// Starts the new copy once this process has ended, then quits.
    private func relaunch(_ app: URL) {
        var openArguments = ["-n"]
        // A release test passes its test library on to the new copy, which then only reports and quits
        // (AppDelegate). Otherwise the new copy starts as from Finder.
        let env = ProcessInfo.processInfo.environment
        if let probe = env["TANDEM_UPDATE_TEST_PROBE"], SelfTest.directory != nil {
            openArguments += ["--env", "TANDEM_UPDATE_RELAUNCH_PROBE=\(probe)"]
            if let home = env["TANDEM_HOME"] { openArguments += ["--env", "TANDEM_HOME=\(home)"] }
        }
        openArguments.append(app.path)
        let script = "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; shift; exec /usr/bin/open \"$@\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", "\(getpid())"] + openArguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch {
            phase = .failed("Tandem was updated. Open it again from \(app.deletingLastPathComponent().path).")
            return
        }
        if SelfTest.directory != nil { exit(0) }
        NSApp.terminate(nil)
    }

    /// In the new copy, after an update: restart the helper so it runs the new version, as soon as no VM
    /// uses it. Gives up after ten minutes (Settings > Network > Restart Helper remains).
    private func finishAfterUpdate() {
        guard state.bool(Keys.restartHelper) else { return }
        guard HelperService.isAvailable else { state.set(nil, Keys.restartHelper); return }
        Task {
            let deadline = Date().addingTimeInterval(600)
            while Date() < deadline {
                if runningVMs.isEmpty {
                    let done = await Task.detached { () -> Bool in
                        guard let status = try? NetHelper.status() else { return true } // not installed: nothing to restart
                        guard status.fromBundle == true, status.canRestart else { return true }
                        guard status.busy == 0 else { return false }
                        return (try? NetHelper.restart()) != nil
                    }.value
                    if done { break }
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
            state.set(nil, Keys.restartHelper)
        }
    }
}

/// Standard user defaults, or a property list in the test library when TANDEM_HOME is set.
@MainActor
final class UpdateState {
    private let file: URL? = ProcessInfo.processInfo.environment["TANDEM_HOME"].map {
        URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("update-state.plist")
    }

    private func load() -> [String: Any] {
        guard let file else { return [:] }
        return NSDictionary(contentsOf: file) as? [String: Any] ?? [:]
    }

    func value(_ key: String) -> Any? { file == nil ? UserDefaults.standard.object(forKey: key) : load()[key] }
    func date(_ key: String) -> Date? { value(key) as? Date }
    func bool(_ key: String) -> Bool { value(key) as? Bool ?? false }
    func strings(_ key: String) -> [String] { value(key) as? [String] ?? [] }

    func set(_ value: Any?, _ key: String) {
        guard let file else {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            return
        }
        var all = load()
        all[key] = value
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        (all as NSDictionary).write(to: file, atomically: true)
    }
}

// MARK: - Window

struct SoftwareUpdateView: View {
    @ObservedObject private var updates = SoftwareUpdate.shared
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var current: String { updates.currentVersion.description }

    @ViewBuilder private var content: some View {
        switch updates.phase {
        case .idle, .checking:
            Text("Checking for updates…").font(.headline)
            ProgressView().progressViewStyle(.linear)
            Text("You have Tandem \(current).").foregroundStyle(.secondary)
        case .upToDate:
            Text("Tandem is up to date").font(.headline)
            Text("Tandem \(current) is the newest version.").foregroundStyle(.secondary)
            buttons { Button("OK") { updates.later() }.keyboardShortcut(.defaultAction) }
        case .failed(let message):
            Text("Tandem could not update").font(.headline)
            Text(message).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            buttons {
                Button("Try Again") { updates.check(userInitiated: true) }
                Button("OK") { updates.later() }.keyboardShortcut(.defaultAction)
            }
        case .available(let release), .ready(let release, _):
            offer(release, progress: nil)
        case .downloading(let release, let fraction):
            offer(release, progress: fraction)
        case .installing(let release, let step):
            Text("Installing Tandem \(release.version)").font(.headline)
            ProgressView().progressViewStyle(.linear)
            Text(step).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func offer(_ release: UpdateRelease, progress: Double?) -> some View {
        Text("Tandem \(release.version) is available").font(.headline)
        Text("You have \(current). The new version is \(release.appVersion)\(published(release)).")
            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if let notes = release.notes, !notes.isEmpty {
            ScrollView {
                Text(notes).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(8)
            }
            .frame(height: 150)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
        }
        if let progress {
            ProgressView(value: progress) { Text("Downloading… \(Int(progress * 100))% of \(size(release.length))").font(.callout) }
        }
        let running = updates.runningVMs
        if !running.isEmpty {
            vmsRunning(running)
        } else {
            buttons {
                Button("Skip This Version") { updates.skip() }
                Spacer()
                Button("Later") { updates.later() }
                Button("Install and Restart") { updates.install() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(progress != nil)
            }
        }
    }

    @ViewBuilder private func vmsRunning(_ running: [VMSession]) -> some View {
        let names = running.map { "“\($0.config.name)”" }.joined(separator: ", ")
        if updates.waitingForVMs {
            Label("Tandem will install the update when \(names) \(running.count == 1 ? "has" : "have") stopped.", systemImage: "clock")
                .fixedSize(horizontal: false, vertical: true)
            buttons {
                Spacer()
                Button("Cancel") { updates.later() }
            }
        } else {
            let blocked = updates.vmsThatCannotSuspend
            Label("Installing restarts Tandem, which would end \(names). Suspend \(running.count == 1 ? "it" : "them") first, or install once \(running.count == 1 ? "it has" : "they have") stopped.",
                  systemImage: "exclamationmark.triangle")
                .fixedSize(horizontal: false, vertical: true)
            if !blocked.isEmpty {
                Text("\(blocked.map { "“\($0.config.name)”" }.joined(separator: ", ")) cannot be suspended (3D graphics, or busy); shut \(blocked.count == 1 ? "it" : "them") down instead.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            buttons {
                Button("Skip This Version") { updates.skip() }
                Spacer()
                Button("Later") { updates.later() }
                Button("Install When Stopped") { updates.installWhenVMsStop() }
                Button("Suspend and Install") { updates.suspendAllAndInstall() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!blocked.isEmpty)
            }
        }
    }

    private func buttons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack { Spacer(); content() }.padding(.top, 6)
    }

    private func published(_ release: UpdateRelease) -> String {
        guard let text = release.published, let date = ISO8601DateFormatter().date(from: text) else { return "" }
        return ", released \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

// MARK: - Settings

/// Settings > General > Updates.
struct UpdateSettings: View {
    @AppStorage(SoftwareUpdate.Keys.autoCheck) private var autoCheck = true
    @AppStorage(SoftwareUpdate.Keys.autoDownload) private var autoDownload = false
    @AppStorage(SoftwareUpdate.Keys.feedURL) private var feed = ""
    @ObservedObject private var updates = SoftwareUpdate.shared

    var body: some View {
        Section("Updates") {
            Toggle("Check for updates automatically (daily)", isOn: $autoCheck)
            Toggle("Download updates automatically", isOn: $autoDownload).disabled(!autoCheck)
            LabeledContent("Update feed:") {
                TextField("", text: $feed, prompt: Text(defaultFeed)).textFieldStyle(.roundedBorder)
            }
            if !feed.isEmpty && SoftwareUpdate.url(feed) == nil {
                Text("Use an https:// address or a file path.").font(.callout).foregroundStyle(.red)
            }
            HStack {
                Text(lastChecked).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Check Now") { updates.check(userInitiated: true) }
            }
            Text("Tandem installs only updates signed with its release key and by the same developer, and never while a virtual machine runs.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var defaultFeed: String {
        (Bundle.main.object(forInfoDictionaryKey: UpdateClient.infoPlistFeedKey) as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? UpdateClient.defaultFeedURL.absoluteString
    }

    private var lastChecked: String {
        guard let date = updates.lastChecked else { return "Not checked yet." }
        return "Last checked \(date.formatted(date: .abbreviated, time: .shortened))."
    }
}
