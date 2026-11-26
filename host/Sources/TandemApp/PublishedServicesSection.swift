import AppKit
import Sharing
import SwiftUI
import VMCore

/// Configuration > Hardware > Network: guest services given a fixed port and name on this Mac.
/// Each row shows the address to use, the guest port behind it, and who can reach it.
struct PublishedServicesSection: View {
    @Binding var draft: VMConfig
    @ObservedObject var session: VMSession
    @EnvironmentObject private var model: AppModel
    @State private var newName = ""
    @State private var newGuestPort = ""
    @State private var newHostPort = ""
    @State private var message: String?
    @State private var namesInstalled = LocalNames.isInstalled

    private var services: [PublishedService] { draft.publishedServices ?? [] }
    /// Mac ports that published services of other VMs already have.
    private var takenElsewhere: Set<Int> {
        Set(model.sessions.filter { $0.id != session.id }.flatMap { $0.config.publishedServices ?? [] }.map(\.hostPort))
    }

    var body: some View {
        Section("Published services") {
            if services.isEmpty {
                Text("No services of this VM are published to the Mac.").foregroundStyle(.secondary)
            }
            ForEach(services) { service in
                row(service)
            }
            HStack(spacing: 6) {
                TextField("", text: $newName, prompt: Text("Name (web)")).labelsHidden().frame(width: 120)
                    .accessibilityLabel("Service name")
                TextField("", text: $newGuestPort, prompt: Text("VM port")).labelsHidden().frame(width: 72)
                    .accessibilityLabel("Port in the virtual machine")
                TextField("", text: $newHostPort, prompt: Text("Mac port (auto)")).labelsHidden().frame(width: 112)
                    .accessibilityLabel("Port on this Mac, automatic if empty")
                Button("Publish") { add() }.disabled(newName.isEmpty || Int(newGuestPort) == nil)
            }
            if let message { Text(message).font(.callout).foregroundStyle(.orange).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            Text(namesInstalled
                 ? "The address stays the same when the VM restarts or gets another network address. Names under \(PublishedServices.domain) resolve on this Mac."
                 : "The address stays the same when the VM restarts or gets another network address. Names under “localhost” work in browsers and curl. To use \(PublishedServices.hostName(forVMNamed: draft.name)) in every program, run this once in Terminal:")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !namesInstalled {
                HStack {
                    Text(LocalNames.installCommand).font(.caption.monospaced()).lineLimit(2).textSelection(.enabled)
                    Button("Copy") { copy(LocalNames.installCommand) }
                }
            }
        }
        .onAppear { namesInstalled = LocalNames.isInstalled }
    }

    private func row(_ service: PublishedService) -> some View {
        let address = LocalNames.address(for: service, vmName: draft.name, namesInstalled: namesInstalled)
        let status = session.serviceStatuses.first { $0.service == service }
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(service.name).bold()
                Text(address).font(.body.monospaced()).textSelection(.enabled)
                Text("→ VM port \(String(service.guestPort))").foregroundStyle(.secondary)
                Spacer()
                Button { copy(address) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy the address")
                    .accessibilityLabel("Copy the address of \(service.name)")
                Button { PublishedServices.unpublish(name: service.name, in: &draft); message = nil } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).help("Stop publishing “\(service.name)”")
                    .accessibilityLabel("Stop publishing \(service.name)")
            }
            HStack(spacing: 8) {
                Picker("Reachable from", selection: Binding(get: { service.scope }, set: { setScope($0, of: service) })) {
                    ForEach(PublishedService.Scope.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
                if let status {
                    Label(status.isListening ? "Serving on port \(String(service.hostPort))" : (status.error ?? "Not served"),
                          systemImage: status.isListening ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(status.isListening ? .green : .orange)
                } else {
                    Text(session.state.isActive ? "Served from the VM’s next start" : "Served while the VM runs").font(.callout).foregroundStyle(.secondary)
                }
            }
            if service.scope == .lan {
                Text("Other devices on the Mac’s network can connect to port \(String(service.hostPort)) of this Mac.").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func setScope(_ scope: PublishedService.Scope, of service: PublishedService) {
        guard var all = draft.publishedServices, let index = all.firstIndex(of: service) else { return }
        all[index].scope = scope
        draft.publishedServices = all
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        let wanted = Int(newHostPort.trimmingCharacters(in: .whitespaces))
        guard let guestPort = Int(newGuestPort.trimmingCharacters(in: .whitespaces)) else { return }
        if !newHostPort.trimmingCharacters(in: .whitespaces).isEmpty && wanted == nil { message = "The Mac port must be a number, or empty for an automatic choice."; return }
        do {
            let service = try PublishedServices.publish(name: name, guestPort: guestPort, hostPort: wanted, scope: .mac, in: &draft,
                                                        takenElsewhere: takenElsewhere, isFree: { ServiceRelay.portIsFree($0) })
            // An automatic choice that could not be the VM's own port number is said, not hidden.
            message = wanted == nil && service.hostPort != guestPort ? "Port \(guestPort) on the Mac is not available; “\(name)” uses port \(service.hostPort)." : nil
            newName = ""; newGuestPort = ""; newHostPort = ""
        } catch {
            message = [error.localizedDescription, (error as? VMError)?.detail].compactMap { $0 }.joined(separator: " ")
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
