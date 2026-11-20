import SwiftUI
import VMCore
import Virtualization

/// Hosts Apple's VM view. Keyboard and mouse go to the guest while the view has focus.
struct VirtualMachineView: NSViewRepresentable {
    let virtualMachine: VZVirtualMachine
    let dynamicResize: Bool

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = dynamicResize
        view.virtualMachine = virtualMachine
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        if view.virtualMachine !== virtualMachine { view.virtualMachine = virtualMachine }
        view.automaticallyReconfiguresDisplay = dynamicResize
    }
}

struct VMDisplayWindow: View {
    @ObservedObject var session: VMSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if session.isSeamless {
                // The guest's windows are on the Mac desktop; this window normally closes itself.
                VStack(spacing: 14) {
                    Text("“\(session.config.name)” is in Seamless Mode").font(.title3)
                    Text("Its programs are shown as separate Mac windows.").foregroundStyle(.secondary)
                    Button("Exit Seamless Mode") { session.exitSeamless(reopenWindow: false) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let vm = session.virtualMachine {
                VirtualMachineView(virtualMachine: vm, dynamicResize: session.config.display.dynamicResize)
            } else if let screen = session.screen {
                GeometryReader { geometry in
                    GuestScreenView(client: screen).id(ObjectIdentifier(screen))
                        .onChange(of: geometry.size) { _, size in session.windowResized(to: size) }
                        .onChange(of: session.agent != nil) { _, connected in if connected { session.windowResized(to: geometry.size) } }
                }
            } else {
                idleView
            }
        }
        // While the guest's screen is shown, problems appear on top of it; the idle view shows its own.
        .overlay(alignment: .top) {
            if let message = session.errorMessage, session.virtualMachine != nil || session.screen != nil {
                RuntimeErrorBanner(message: message) { session.errorMessage = nil }
            }
        }
        .navigationTitle(session.config.name)
        .focusedSceneValue(\.activeSession, session)
        .toolbar {
            ToolbarItemGroup {
                // Device strip, then the controls, then Configure at the far right.
                Menu {
                    Button("Ctrl + Alt + Del") { session.sendKeys([0x1D, 0x38, 0xD3]) }
                    Button("Windows Key") { session.sendKeys([0xDB]) }
                    Button("Alt + Tab") { session.sendKeys([0x38, 0x0F]) }
                    Button("Alt + F4") { session.sendKeys([0x38, 0x3E]) }
                } label: { Label("Keyboard", systemImage: "keyboard") }
                .help("Send a key combination to the VM").disabled(session.screen == nil)
                Button { configure("options/sharing") } label: {
                    Label("Shared Folders", systemImage: session.sharingPolicy.folders.isEmpty ? "folder" : "folder.fill.badge.person.crop")
                }
                .help(session.sharingPolicy.folders.isEmpty ? "No Mac folders are shared" : "Shared: " + session.sharingPolicy.folders.map(\.name).joined(separator: ", "))
                Button { configure("hardware/network") } label: { Label("Network", systemImage: "network") }.help("Network")
                if session.can(.pause) { Button { session.pause() } label: { Label("Pause", systemImage: "pause.fill") }.help("Pause") }
                if session.can(.resume) { Button { session.resume() } label: { Label("Resume", systemImage: "play.fill") }.help("Resume") }
                if session.can(.stop) {
                    Menu {
                        Button("Suspend") { session.suspend() }.disabled(!session.canSuspend)
                        Button("Shut Down") { session.stop() }
                        Button("Restart") { session.restart() }.disabled(!session.canRestart)
                        Button("Stop") { session.forceStop() }
                    } label: { Label("Power", systemImage: "power") } primaryAction: { session.stop() }
                    .help("Shut Down")
                }
                Button { configure(nil) } label: { Label("Configure", systemImage: "gearshape") }.help("Configure")
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        // In full screen the title bar and its buttons stay out of the way until the pointer reaches the top edge.
        .windowToolbarFullScreenVisibility(session.behavior.toolbarAlwaysVisibleInFullScreen ? .visible : .onHover)
        .background(VMWindowBehavior(session: session))
        // A VM that shuts down cleanly takes its window with it. Errors stay on screen.
        .onChange(of: session.isSeamless) { _, seamless in if seamless { dismiss() } }
        .onChange(of: session.state) { old, new in
            if new == .stopped, !session.isRestarting, session.behavior.afterShutdown != .keepWindow,
               old == .stopping || old == .running || old == .paused { dismiss() }
        }
    }

    private func configure(_ place: String?) {
        openWindow(id: "configuration", value: ConfigurationTarget(id: session.id, place: place))
    }

    /// What the window shows while the VM has no screen: a large play button over the last picture of
    /// the VM when it is stopped, a spinner and a status line while it starts or stops.
    private var idleView: some View {
        ZStack {
            Color(white: 0.1)
            if let image = session.thumbnail {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).opacity(0.25).blur(radius: 6)
            }
            VStack(spacing: 18) {
                if session.can(.start) || session.can(.resume) {
                    Button { if session.can(.resume) { session.resume() } else { session.start() } } label: {
                        Image(systemName: "play.fill").font(.system(size: 54)).foregroundStyle(.white)
                            .frame(width: 128, height: 128)
                            .background(Circle().fill(.white.opacity(0.14)))
                            .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(session.can(.resume) ? "Resume" : "Start")
                    .keyboardShortcut(.defaultAction)
                } else if let provisioning = session.provisioning {
                    // The system is being downloaded and prepared: a bar that fills, and what is happening.
                    ProgressView(value: provisioning.fraction).progressViewStyle(.linear).frame(width: 360).colorScheme(.dark)
                } else if session.setupInterrupted {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 54)).foregroundStyle(.white.opacity(0.8))
                } else {
                    ProgressView().controlSize(.large).colorScheme(.dark)
                }
                Text(session.statusLabel).font(.title3).foregroundStyle(.white.opacity(0.85))
                if let provisioning = session.provisioning {
                    if let detail = provisioning.detail { Text(detail).font(.callout).foregroundStyle(.white.opacity(0.65)).monospacedDigit() }
                    Button("Cancel") { session.cancelProvisioning?() }
                } else if session.setupInterrupted {
                    Text("Tandem stopped before this system was downloaded and prepared. Remove this virtual machine in Control Center and create it again; what was already downloaded is kept and used.")
                        .font(.callout).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center).frame(maxWidth: 520)
                }
                if let message = session.errorMessage {
                    Text(message).font(.callout.monospaced()).foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center).textSelection(.enabled).frame(maxWidth: 560)
                    Button("Show Logs in Finder") { NSWorkspace.shared.open(session.bundle.logsDirectory) }
                }
            }
            .padding(40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
