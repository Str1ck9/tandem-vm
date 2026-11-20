import Provisioning
import SwiftUI
import VMCore

/// Settings > Advanced > Templates: the prepared copies of downloaded Linux systems, with their size
/// and a Delete button. A template is made the first time a system is chosen in Create New, so the
/// next VM of it is ready in seconds.
struct TemplatesSettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var entries: [LinuxTemplateStore.Entry] = []
    @State private var problem: String?

    private var store: LinuxTemplateStore { LinuxTemplateStore(libraryRoot: URL(fileURLWithPath: model.libraryRoot)) }

    var body: some View {
        Section("Templates") {
            if entries.isEmpty {
                Text("None yet. The first time you download a Linux system, Tandem keeps a prepared copy, so the next one is ready in seconds.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(entries, id: \.manifest.option) { entry in
                LabeledContent {
                    Button("Delete") { delete(entry) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.manifest.title)
                        Text("\(ByteCountFormatter.string(fromByteCount: entry.allocatedBytes, countStyle: .file)) · made \(entry.manifest.created.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !entries.isEmpty {
                Text("Virtual machines made from a template share most of its space, so deleting one frees less while those machines exist. A deleted template is made again the next time that system is chosen.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let problem { Text(problem).foregroundStyle(.red).textSelection(.enabled) }
        }
        .onAppear(perform: reload)
    }

    private func reload() { entries = store.list() }

    private func delete(_ entry: LinuxTemplateStore.Entry) {
        do { try store.delete(option: entry.manifest.option); problem = nil } catch { problem = error.localizedDescription }
        reload()
    }
}
