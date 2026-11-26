import AppKit
import SwiftUI
import TandemControl

/// Preferences > Advanced: the `tandem` command-line tool and the switch for AI tools (MCP).
struct CommandLineSettings: View {
    @State private var linkTarget = ControlAPI.installedTarget
    @State private var message: String?
    @State private var allowAI = ControlSettings.load(libraryRoot: ControlAPI.libraryRoot).allowAITools
    @State private var activity: [AIActivityEntry] = []

    private func activityRow(_ entry: AIActivityEntry) -> some View {
        let symbol = entry.outcome == "allowed" ? "checkmark.circle" : (entry.outcome == "denied" ? "hand.raised.fill" : "exclamationmark.triangle")
        let colour: Color = entry.outcome == "allowed" ? .green : (entry.outcome == "denied" ? .orange : .red)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(colour).frame(width: 16)
            Text(entry.time.formatted(date: .omitted, time: .standard)).monospacedDigit().foregroundStyle(.secondary)
            Text(entry.tool).fontWeight(.medium)
            if let vm = entry.vm { Text(vm).foregroundStyle(.secondary) }
            Text(entry.message ?? entry.summary ?? "").lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary)
        }
        .font(.callout)
        .help([entry.summary, entry.message].compactMap { $0 }.joined(separator: "\n"))
    }

    var body: some View {
        Group {
            LabeledContent("Command-line tool:") {
                HStack {
                    Text(linkTarget != nil ? ControlAPI.installedLink.path : "Not installed").textSelection(.enabled)
                    Button(linkTarget != nil ? "Reinstall" : "Install Command-Line Tool") { install() }
                        .disabled(ControlAPI.bundledTool == nil)
                }
            }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            Text("Links `tandem` into \(ControlAPI.installFolder.path), no administrator password needed. `tandem help` lists its commands; it controls the virtual machines of this app.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Allow AI tools (MCP) to control Tandem", isOn: Binding(get: { allowAI }, set: { setAI($0) })).accessibilityLabel("Allow AI tools (MCP) to control Tandem")
            Text("Lets an AI assistant connected with `tandem mcp` work with your virtual machines, as far as each VM’s AI level allows (Configure > Options > Sharing > AI tools): Observe looks, Operate starts, stops and snapshots, Full can also revert, clone and power off. Running commands inside a VM needs its “Commands from the Mac” permission too. Off by default.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("AI activity") {
                VStack(alignment: .leading, spacing: 4) {
                    if activity.isEmpty {
                        Text("No AI tool has called Tandem yet.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(activity.prefix(25)) { entry in activityRow(entry) }
                    HStack {
                        Button("Refresh") { activity = AIActivityLog.recent(libraryRoot: ControlAPI.libraryRoot, limit: 50) }
                        Button("Show Log in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([AIActivityLog.url(libraryRoot: ControlAPI.libraryRoot)])
                        }
                    }
                    Text("Every call an AI tool makes is written down here, whether it was allowed or refused. What each VM allows is set under Configure > Options > Sharing > AI tools.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            }
            .onAppear { activity = AIActivityLog.recent(libraryRoot: ControlAPI.libraryRoot, limit: 50) }
            if let error = ControlAPI.startError {
                Text("The control connection is not available: \(error)").font(.callout).foregroundStyle(.red)
            }
        }
    }

    private func install() {
        do {
            let link = try ControlAPI.installTool()
            linkTarget = ControlAPI.installedTarget
            message = ControlAPI.folderIsOnPath(link.deletingLastPathComponent())
                ? "Installed. Open a new Terminal window and run `tandem list`."
                : "Installed. \(link.deletingLastPathComponent().path) is not on your PATH yet: add it in your shell’s profile, or run \(link.path) directly."
        } catch {
            message = error.localizedDescription
        }
    }

    private func setAI(_ on: Bool) {
        do {
            try ControlSettings(allowAITools: on).save(libraryRoot: ControlAPI.libraryRoot)
            allowAI = on
        } catch {
            message = "The setting could not be saved: \(error.localizedDescription)"
        }
    }
}
