import AppKit
import SwiftUI
import TandemControl

/// Preferences > Advanced: the `tandem` command-line tool and the switch for AI tools (MCP).
struct CommandLineSettings: View {
    @State private var linkTarget = ControlAPI.installedTarget
    @State private var message: String?
    @State private var allowAI = ControlSettings.load(libraryRoot: ControlAPI.libraryRoot).allowAITools

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
            Toggle("Allow AI tools (MCP) to control Tandem", isOn: Binding(get: { allowAI }, set: { setAI($0) }))
            Text("Lets an AI assistant connected with `tandem mcp` list, start, stop and snapshot virtual machines and share folders with them. Running commands inside a virtual machine also needs that VM’s permission (Configure > Options > Sharing). Off by default.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
