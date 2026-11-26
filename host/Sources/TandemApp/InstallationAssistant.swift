import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Provisioning
import VMCore

private let hostCPUCount = ProcessInfo.processInfo.processorCount

/// "Create New": choose what to do, choose the installer image, then name the virtual machine.
/// The same three steps, in the same order, as the assistant this app is modelled on.
struct InstallationAssistant: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    /// Called when the user picks "import": the caller shows the Parallels import instead.
    var importExisting: () -> Void

    private enum Page { case scenario, source, options, name }
    @State private var page: Page = .scenario
    @State private var isoPath = ""
    @State private var withoutSource = false
    @State private var guestOS: GuestOS = .windows11arm
    @State private var name = ""
    @State private var cpuCount = min(4, hostCPUCount)
    @State private var memoryMiB = 8192
    @State private var diskGiB = 64
    @State private var customize = false
    @State private var dropTargeted = false
    @State private var errorText: String?
    // Unattended Windows install
    @State private var automatic = true
    /// Self-tests (screenshots) show a neutral account name instead of this Mac's (TANDEM_SNAPSHOT_ACCOUNT).
    @State private var userName = ProcessInfo.processInfo.environment["TANDEM_SNAPSHOT_ACCOUNT"] ?? NSUserName()
    @State private var password = ""
    /// Go straight to the desktop at every start.
    @State private var autoLogin = true
    @State private var edition = "Windows 11 Pro"
    @State private var creating = false
    // A system Tandem downloads (Provisioning/SystemProvider.swift): which source, and what it offers.
    @State private var provider: (any SystemProvider)?
    @State private var options: [SystemOption] = []
    @State private var option: SystemOption?
    @State private var optionsError: String?
    @State private var loadingOptions = false
    @State private var minimumDiskGiB = 1
    /// The flavour last picked for systems that come in several (Ubuntu Desktop: MATE, Xfce, GNOME).
    @AppStorage("preferredSystemVariant") private var preferredVariant = LinuxDesktop.standard.title
    // Compatibility: what this Mac can do for the VM being made (VMCore/Compatibility.swift).
    @State private var host: HostFacts?
    @State private var imageArchitecture: GuestArchitecture?
    @State private var imageEvidence: String?

    private var compatibility: CompatibilityReport? {
        guard let host else { return nil }
        // Both systems are created on the QEMU engine (see `create`). A new disk starts near empty;
        // an installed system needs roughly this much at once.
        return Compatibility.evaluate(host: host, request: CompatibilityRequest(
            guestOS: guestOS, architecture: isoPath.isEmpty || withoutSource ? .arm64 : (imageArchitecture ?? .arm64),
            engine: provider?.engine ?? .qemu,
            memoryMiB: memoryMiB, cpuCount: cpuCount, neededDiskGiB: guestOS == .windows11arm ? 20 : 8))
    }
    private var imageIsIntel: Bool { imageArchitecture == .x86_64 && !isoPath.isEmpty && !withoutSource }

    /// Self-tests (screenshots): a taller window so a whole list fits (TANDEM_SNAPSHOT_ASSISTANT_HEIGHT, points).
    private static let selfTestHeight: CGFloat? = ProcessInfo.processInfo.environment["TANDEM_SNAPSHOT_ASSISTANT_HEIGHT"]
        .flatMap(Double.init).map { CGFloat($0) }

    /// Windows from an install disc can install itself; anything else is installed by hand.
    private var canInstallAutomatically: Bool { provider == nil && guestOS == .windows11arm && !isoPath.isEmpty && !withoutSource }

    private var defaultName: String {
        let base = option.flatMap { provider?.defaults(for: $0).name } ?? guestOS.label
        let taken = Set(model.sessions.map(\.config.name))
        if !taken.contains(base) { return base }
        return (2...99).lazy.map { "\(base) \($0)" }.first { !taken.contains($0) } ?? base
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case .scenario: scenario
                case .source: source
                case .options: optionsPage
                case .name: nameAndLocation
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(24)
            Divider()
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                if let errorText { Text(errorText).foregroundStyle(.red).lineLimit(2).textSelection(.enabled) }
                Spacer()
                if page != .scenario {
                    Button("Go Back") {
                        errorText = nil
                        if page == .name { page = provider == nil ? .source : .options } else { page = .scenario; provider = nil; option = nil }
                    }
                }
                switch page {
                case .scenario: EmptyView()
                case .source:
                    Button("Continue") { page = .name }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                        .disabled((isoPath.isEmpty && !withoutSource) || imageIsIntel)
                case .options:
                    Button("Continue") { if let option { choose(option) } }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                        .disabled(option == nil)
                case .name:
                    Button(creating ? "Creating…" : "Create") { create() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                        .disabled(creating || compatibility?.canProceed == false)
                }
            }
            .padding(14)
        }
        .frame(width: 640, height: Self.selfTestHeight ?? (page == .name && ((canInstallAutomatically && automatic) || provider?.wantsAccount == true) ? 660 : 510))
        .onAppear {
            if host == nil { host = model.hostFacts() }
            // Self-test: open straight at the last page with this install disc chosen.
            // Self-test: open at the list of a downloadable system, or at the last page with its first choice.
            if let slot = ProcessInfo.processInfo.environment["TANDEM_SNAPSHOT_ASSISTANT_DOWNLOAD"], provider == nil,
               let found = SystemCatalog.provider(for: slot) {
                begin(found, thenName: ProcessInfo.processInfo.environment["TANDEM_SNAPSHOT_ASSISTANT_PAGE"] == "name")
            }
            if let iso = ProcessInfo.processInfo.environment["TANDEM_SNAPSHOT_ASSISTANT_ISO"], isoPath.isEmpty {
                use(URL(fileURLWithPath: iso))
                page = ProcessInfo.processInfo.environment["TANDEM_SNAPSHOT_ASSISTANT_PAGE"] == "source" ? .source : .name
            }
        }
    }

    // MARK: 1. Create New

    private var scenario: some View {
        VStack(spacing: 18) {
            Text("Create New").font(.system(size: 26, weight: .light))
            HStack(spacing: 14) {
                tile("Install Windows, Linux or another OS from an image file", symbol: "opticaldisc", enabled: true) { page = .source }
                tile("Import a virtual machine from Parallels", symbol: "square.and.arrow.down.on.square", enabled: true) {
                    dismiss()
                    importExisting()
                }
            }
            Text("Free Systems").font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            HStack(spacing: 14) {
                downloadTile(SystemCatalog.windows, "Get Windows 11 from Microsoft", symbol: "arrow.down.circle")
                downloadTile(SystemCatalog.macOS, "Download macOS", symbol: "apple.logo")
                downloadTile(SystemCatalog.linux, "Download a Linux system", symbol: "terminal")
            }
            Text("Tandem downloads the system from its maker, checks the download, and sets the virtual machine up for you.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A tile for a system Tandem can download: live when this build has a provider for it that works on this Mac.
    @ViewBuilder private func downloadTile(_ slot: String, _ fallbackTitle: String, symbol: String) -> some View {
        if let found = SystemCatalog.provider(for: slot) {
            if case .unavailable(let why) = found.availability {
                tile(found.title, symbol: symbol, enabled: false, note: why) {}
            } else {
                tile(found.title, symbol: symbol, enabled: true) { begin(found, thenName: false) }
            }
        } else {
            tile(fallbackTitle, symbol: symbol, enabled: false) {}
        }
    }

    private func tile(_ title: String, symbol: String, enabled: Bool, note: String = "Not available yet", action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 34, weight: .light)).accessibilityHidden(true)
                // The titles of downloadable systems come from the providers as plain text; they are looked up too.
                Text(LocalizedStringKey(title)).font(.callout).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                if !enabled { Text(LocalizedStringKey(note)).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            }
            .frame(maxWidth: .infinity, minHeight: 104)
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
    }

    // MARK: 2. Choose a system to download

    private var optionsPage: some View {
        VStack(spacing: 12) {
            Text(provider?.title ?? "").font(.system(size: 22, weight: .light))
            Text(provider?.sourceNote ?? "").font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if loadingOptions {
                Spacer()
                ProgressView("Asking what is available…")
                Spacer()
            } else if let optionsError {
                Spacer()
                Label(optionsError, systemImage: "wifi.exclamationmark").foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).textSelection(.enabled)
                Button("Try Again") { loadOptions(thenName: false) }
                Spacer()
            } else {
                List(listed, selection: Binding(get: { option?.id }, set: { id in option = options.first { $0.id == id } })) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                            Text(item.detail).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(item.downloadBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "")
                            .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(.vertical, 3)
                    .tag(item.id)
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                if let group = option?.variantGroup {
                    let variants = options.filter { $0.variantGroup == group }
                    Picker("Desktop:", selection: Binding(get: { option?.variant ?? "" }, set: { name in
                        guard let picked = variants.first(where: { $0.variant == name }) else { return }
                        option = picked
                        preferredVariant = name
                    })) {
                        ForEach(variants) { Text($0.variant ?? $0.title).tag($0.variant ?? "") }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
        }
    }

    /// The options as listed: a system offered in several flavours appears once, as the flavour last
    /// picked (or the first one offered).
    private var listed: [SystemOption] { SystemOption.listing(options, preferring: preferredVariant, selected: option) }

    /// Starts the download path: remembers the source and asks it what it offers.
    private func begin(_ found: any SystemProvider, thenName: Bool) {
        provider = found
        isoPath = ""
        withoutSource = false
        guestOS = found.guestOS
        option = nil
        page = .options
        loadOptions(thenName: thenName)
    }

    private func loadOptions(thenName: Bool) {
        guard let provider else { return }
        loadingOptions = true
        optionsError = nil
        let downloads = SystemCatalog.downloads(in: URL(fileURLWithPath: model.libraryRoot))
        Task {
            do {
                let found = try await provider.options(using: downloads)
                options = found
                let first = SystemOption.listing(found, preferring: preferredVariant, selected: nil).first
                option = first
                if thenName, let first { choose(first) }
            } catch {
                options = []
                optionsError = [error.localizedDescription, (error as? VMError)?.detail].compactMap { $0 }.joined(separator: "\n")
            }
            loadingOptions = false
        }
    }

    /// Takes the chosen system's own defaults to the last page.
    private func choose(_ chosen: SystemOption) {
        guard let provider else { return }
        option = chosen
        let defaults = provider.defaults(for: chosen)
        cpuCount = min(defaults.cpuCount, hostCPUCount)
        memoryMiB = defaults.memoryMiB
        diskGiB = defaults.diskGiB
        minimumDiskGiB = defaults.minimumDiskGiB
        page = .name
    }

    // MARK: 2. Select source

    private var source: some View {
        VStack(spacing: 16) {
            Text("Install from an Image File").font(.system(size: 22, weight: .light))
            VStack(spacing: 8) {
                Image(systemName: isoPath.isEmpty ? "opticaldisc" : "opticaldisc.fill").font(.system(size: 44, weight: .light)).accessibilityHidden(true)
                if isoPath.isEmpty {
                    Text("Drag the image file here.")
                    Text("Tandem supports .iso files for ARM64 (Apple silicon) systems.").font(.callout).foregroundStyle(.secondary)
                } else {
                    Text(URL(fileURLWithPath: isoPath).lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Text((guestOS == .windows11arm ? "Looks like Windows" : "Will be installed as Linux")
                         + (imageArchitecture.map { " for \($0.label) processors" } ?? ""))
                        .font(.callout).foregroundStyle(.secondary)
                    if imageIsIntel {
                        Label("This image is for Intel processors and cannot run on this Mac. Download the ARM64 edition instead.", systemImage: "xmark.octagon.fill")
                            .font(.callout).foregroundStyle(.red).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 24)
                    }
                }
                Button("Choose…") { chooseISO() }
            }
            .frame(maxWidth: .infinity, minHeight: 190)
            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5),
                                                                        style: StrokeStyle(lineWidth: 2, dash: [7, 5])))
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.pathExtension.lowercased() == "iso" else { return }
                    Task { @MainActor in use(url) }
                }
                return true
            }
            Toggle("Continue without a source", isOn: $withoutSource).accessibilityLabel("Continue without a source")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Without a source the virtual machine is created empty; attach an installer later under Configure > Hardware > CD/DVD.")
                .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chooseISO() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .diskImage]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an ARM64 installer image"
        if panel.runModal() == .OK, let url = panel.url { use(url) }
    }

    /// Windows installers say so in their file name; anything else is taken to be Linux.
    private func use(_ url: URL) {
        isoPath = url.path
        withoutSource = false
        // The disc's own boot files say which processor it is for; the file name is the fallback.
        let guess = InstallerImage.inspect(url)
        imageArchitecture = guess.architecture
        imageEvidence = guess.evidence
        let lower = url.lastPathComponent.lowercased()
        setSystem(lower.contains("win") ? .windows11arm : .linux)
    }

    private func setSystem(_ os: GuestOS) {
        guestOS = os
        memoryMiB = os == .windows11arm ? 8192 : 4096
    }

    // MARK: 3. Name and Location

    private var nameAndLocation: some View {
        VStack(spacing: 10) {
            Text("Name and Location").font(.system(size: 22, weight: .light))
            Form {
                TextField("Name:", text: $name, prompt: Text(defaultName))
                if let option {
                    LabeledContent("System:", value: option.title + (option.downloadBytes.map { " (" + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) + " to download)" } ?? ""))
                } else {
                    Picker("System:", selection: Binding(get: { guestOS }, set: { setSystem($0) })) {
                        Text("Windows 11 (ARM64)").tag(GuestOS.windows11arm)
                        Text("Linux (ARM64)").tag(GuestOS.linux)
                    }
                }
                LabeledContent("Save to:", value: model.libraryPath)
                if let compatibility {
                    CompatibilityRow(report: compatibility)
                    CompatibilityBlockers(report: compatibility)
                }
                if canInstallAutomatically {
                    Toggle("Install Windows automatically", isOn: $automatic).accessibilityLabel("Install Windows automatically")
                    if automatic {
                        Picker("Edition:", selection: $edition) {
                            ForEach(WindowsUnattendOptions.genericKeys.keys.sorted().reversed(), id: \.self) { Text($0).tag($0) }
                        }
                        TextField("Account name:", text: $userName)
                        SecureField("Password:", text: $password, prompt: Text("Optional"))
                        Toggle("Sign in automatically", isOn: $autoLogin).accessibilityLabel("Sign in automatically")
                        Text("Windows is set up without questions: the disk, this account, drivers and Tandem’s guest tools. It takes about ten minutes. The password is kept on a setup disc inside the virtual machine until the installation has finished, then that disc is deleted.\(accountNote)")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let provider, provider.wantsAccount {
                    TextField("Account name:", text: $userName)
                    SecureField("Password:", text: $password, prompt: Text(provider.allowsEmptyPassword ? "Optional" : "Required"))
                    Toggle("Sign in automatically", isOn: $autoLogin).accessibilityLabel("Sign in automatically")
                    Text("Tandem makes this account in the new system. The password is kept on a setup disc inside the virtual machine until its first start has finished, then that disc is deleted.\(accountNote)")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HardwareFields(cpuCount: $cpuCount, memoryMiB: $memoryMiB, diskGiB: $diskGiB, minimumDiskGiB: provider == nil ? 1 : minimumDiskGiB)
                if provider == nil { Toggle("Customize settings before installation", isOn: $customize) }
                Text("The disk only takes up the space the system actually uses, up to \(diskGiB) GiB.\(guestOS == .windows11arm ? " Windows needs your own licence." : "")")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
        }
    }

    /// What the password and sign-in choices mean, in one or two sentences.
    private var accountNote: String {
        var parts: [String] = []
        if password.isEmpty {
            parts.append("Without a password the account signs in and runs admin tasks without one. Do not put such a virtual machine on your network (bridged networking or published services).")
        }
        parts.append(autoLogin ? "It goes straight to the desktop at every start; the password is still asked for admin tasks."
                               : "It asks you to sign in at every start.")
        return " " + parts.joined(separator: " ")
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        // Both systems go to the QEMU engine: it has the embedded display and every sharing feature.
        // A downloaded system says itself which engine it needs.
        var config = VMConfig(name: trimmed.isEmpty ? defaultName : trimmed, guestOS: guestOS, engine: provider?.engine ?? .qemu,
                              cpuCount: cpuCount, memoryMiB: memoryMiB)
        config.disks[0].sizeGiB = diskGiB
        if let provider, let option {
            var account: SystemAccount?
            if provider.wantsAccount {
                let wanted = SystemAccount(userName: userName.trimmingCharacters(in: .whitespaces), password: password, autoLogin: autoLogin)
                let problems = provider.accountProblems(wanted)
                guard problems.isEmpty else { errorText = problems.joined(separator: " "); return }
                account = wanted
            }
            do {
                // The VM appears at once with the download's progress; its window shows the same.
                let created = try model.create(config, downloading: option, from: provider, account: account)
                dismiss()
                openWindow(id: "vm", value: created)
            } catch {
                errorText = [error.localizedDescription, (error as? VMError)?.detail].compactMap { $0 }.joined(separator: " ")
            }
            return
        }
        if !isoPath.isEmpty && !withoutSource { config.removableMedia = [RemovableMedia(file: isoPath, kind: .installerISO)] }
        var windows: WindowsUnattendOptions?
        if canInstallAutomatically && automatic {
            // A computer name from the VM's name: letters, digits and hyphens, 15 at most.
            let letters = config.name.uppercased().map { $0.isLetter && $0.isASCII || $0.isNumber ? $0 : "-" }
            let computer = String(String(letters).split(separator: "-").joined(separator: "-").prefix(15))
            let options = WindowsUnattendOptions(computerName: computer.isEmpty ? "TANDEM-VM" : computer,
                                                 userName: userName.trimmingCharacters(in: .whitespaces), password: password, edition: edition,
                                                 autoLogin: autoLogin)
            let problems = options.validate()
            guard problems.isEmpty else { errorText = problems.joined(separator: " "); return }
            windows = options
        }
        creating = true
        defer { creating = false }
        do {
            try model.create(config, windows: windows)
            let created = model.selection
            dismiss()
            if customize, let created {
                openWindow(id: "configuration", value: ConfigurationTarget(id: created, place: nil))
            } else if windows != nil, let created, let session = model.sessions.first(where: { $0.id == created }) {
                // Start installing straight away, with the VM's window showing Setup at work.
                openWindow(id: "vm", value: created)
                session.start()
            }
        } catch {
            errorText = [error.localizedDescription, (error as? VMError)?.detail].compactMap { $0 }.joined(separator: " ")
        }
    }
}
