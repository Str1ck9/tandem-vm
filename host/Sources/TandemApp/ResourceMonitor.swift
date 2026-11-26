import SwiftUI
import VMCore

/// The idle timer and the Keep Awake switch, as fields for any form. The Resource Monitor binds them to
/// a running VM (they take effect at once); the configuration window binds them to its draft.
struct PowerSettingsFields: View {
    @Binding var settings: PowerSettings

    var body: some View {
        Toggle("Suspend when idle", isOn: Binding(
            get: { settings.idleSuspendMinutes != nil },
            set: { on in settings.idleSuspendMinutes = on ? 15 : nil }))
        if settings.idleSuspendMinutes != nil {
            Picker("After:", selection: Binding(get: { settings.idleSuspendMinutes ?? 15 }, set: { settings.idleSuspendMinutes = $0 })) {
                ForEach(PowerSettings.idleChoices, id: \.self) { minutes in
                    Text(minutes < 60 ? "\(minutes) minutes" : (minutes == 60 ? "1 hour" : "\(minutes / 60) hours")).tag(minutes)
                }
            }
        }
        Toggle("Keep awake", isOn: $settings.keepAwake).accessibilityLabel("Keep awake")
        Text("An idle virtual machine is suspended to give its memory back to the Mac; opening one of its programs from the Mac resumes it. It is never suspended while it is in use: while you work in it, while its processor is busy, while something inside it asked to stay awake (in the guest: tandem-agent keep-awake -- <command>), or while Keep awake is on. Closing its window does not suspend it.")
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// The same fields for one VM, applied as they are changed.
struct PowerSettingsSection: View {
    @ObservedObject var session: VMSession

    var body: some View {
        PowerSettingsFields(settings: Binding(get: { session.power }, set: { session.setPower($0) }))
    }
}

/// "Resource Monitor": every VM with what it uses, whether it is idle, and what keeps it awake.
struct ResourceMonitorWindow: View {
    @EnvironmentObject private var model: AppModel
    @State private var expanded: Set<UUID> = []

    static func memory(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    static func percent(_ value: Double?) -> String { value.map { "\(Int($0.rounded()))%" } ?? "—" }

    var body: some View {
        // The readings change every few seconds without the sessions announcing it; redraw on a clock.
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            List {
                if model.sessions.isEmpty { Text("No virtual machines").foregroundStyle(.secondary) }
                ForEach(model.sessions) { session in row(session) }
                Section {
                    let active = model.sessions.filter { $0.state.isActive }
                    let total = active.compactMap { $0.usage?.memoryBytes }.reduce(0, +)
                    LabeledContent("Memory in use by running virtual machines:", value: active.isEmpty ? "None" : Self.memory(total))
                }
            }
            .listStyle(.inset)
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 300, idealHeight: 420)
        .navigationTitle("Resource Monitor")
    }

    @ViewBuilder private func row(_ session: VMSession) -> some View {
        let usage = session.usage
        DisclosureGroup(isExpanded: Binding(get: { expanded.contains(session.id) },
                                            set: { open in if open { expanded.insert(session.id) } else { expanded.remove(session.id) } })) {
            Form { PowerSettingsSection(session: session) }
                .formStyle(.columns)
                .padding(.vertical, 6)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(session.config.name).font(.headline)
                    Text(session.statusLabel).foregroundStyle(.secondary)
                    Spacer()
                    if session.state.isActive {
                        // The guest's own figure when its tools report one; otherwise the Mac's for the VM's process.
                        Label(usage?.guestCPUPercent != nil ? "\(Self.percent(usage?.guestCPUPercent)) in the VM" : "\(Self.percent(usage?.hostCPUPercent)) of a core",
                              systemImage: "cpu").help("Processor use")
                        Label(Self.memory(usage?.memoryBytes), systemImage: "memorychip").help("Mac memory the virtual machine holds")
                            .frame(minWidth: 86, alignment: .trailing)
                    } else {
                        Text("Uses no memory").foregroundStyle(.secondary)
                    }
                }
                if let summary = session.powerSummary {
                    Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                } else if session.state == .running {
                    Text(session.power.idleSuspendMinutes == nil ? "Idle timer off: stays running until you suspend it or shut it down" : "In use")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}
