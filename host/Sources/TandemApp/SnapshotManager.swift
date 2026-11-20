import AppKit
import SwiftUI
import VMCore

/// The Snapshot Manager: every snapshot of one VM as a tree that grows to the right, each with a picture
/// of the screen at the time, ending in "Current State". New and Delete at the bottom left, Go To at the right.
struct SnapshotManagerWindow: View {
    @ObservedObject var session: VMSession
    @State private var selection: UUID?
    @State private var editing: Editing?
    @State private var name = ""
    @State private var note = ""
    @State private var goToTarget: VMSnapshot?
    @State private var deleteTarget: VMSnapshot?
    @State private var errorText: String?

    private enum Editing: Identifiable {
        case new, properties(VMSnapshot)
        var id: String { if case .properties(let s) = self { return s.id.uuidString } else { return "new" } }
    }

    private struct Node: Identifiable {
        var id: String
        var snapshot: VMSnapshot?
        var column: Int
        var row: Int
        var parent: String?
    }

    private static let cell = CGSize(width: 168, height: 132)
    private static let picture = CGSize(width: 120, height: 75)
    private static let currentID = "current"

    /// Columns are generations, rows are branches. A parent sits on the row of its first child.
    private func layout() -> [Node] {
        let snapshots = session.snapshots.sorted { $0.created < $1.created }
        let parents = session.snapshotParents
        let head = session.snapshotHead
        var children: [UUID?: [VMSnapshot]] = [:]
        for snapshot in snapshots { children[parents[snapshot.id] ?? nil, default: []].append(snapshot) }
        var nodes: [Node] = []
        var nextRow = 0

        func place(_ snapshot: VMSnapshot?, column: Int, parent: String?) -> Int {
            // nil stands for the current state, which never has children.
            guard let snapshot else {
                nodes.append(Node(id: Self.currentID, snapshot: nil, column: column, row: nextRow, parent: parent))
                nextRow += 1
                return nextRow - 1
            }
            let id = snapshot.id.uuidString
            var rows: [Int] = []
            for child in children[snapshot.id] ?? [] { rows.append(place(child, column: column + 1, parent: id)) }
            if head == snapshot.id { rows.append(place(nil, column: column + 1, parent: id)) }
            let row: Int
            if let first = rows.first { row = first } else { row = nextRow; nextRow += 1 }
            nodes.append(Node(id: id, snapshot: snapshot, column: column, row: row, parent: parent))
            return row
        }
        for root in children[nil] ?? [] { _ = place(root, column: 0, parent: nil) }
        if head == nil { _ = place(nil, column: 0, parent: nil) }
        return nodes
    }

    private func centre(_ node: Node) -> CGPoint {
        CGPoint(x: CGFloat(node.column) * Self.cell.width + Self.cell.width / 2 + 16,
                y: CGFloat(node.row) * Self.cell.height + Self.picture.height / 2 + 20)
    }

    private var selected: VMSnapshot? { session.snapshots.first { $0.id == selection } }

    var body: some View {
        let nodes = layout()
        let columns = (nodes.map(\.column).max() ?? 0) + 1
        let rows = (nodes.map(\.row).max() ?? 0) + 1
        VStack(spacing: 0) {
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    // Connectors: out of the parent's right edge, into the child's left edge.
                    Canvas { context, _ in
                        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
                        var path = Path()
                        for node in nodes {
                            guard let parentID = node.parent, let parent = byID[parentID] else { continue }
                            let from = CGPoint(x: centre(parent).x + Self.picture.width / 2 + 4, y: centre(parent).y)
                            let to = CGPoint(x: centre(node).x - Self.picture.width / 2 - 4, y: centre(node).y)
                            let middle = (from.x + to.x) / 2
                            path.move(to: from)
                            path.addLine(to: CGPoint(x: middle, y: from.y))
                            path.addLine(to: CGPoint(x: middle, y: to.y))
                            path.addLine(to: to)
                        }
                        context.stroke(path, with: .color(.secondary.opacity(0.7)), lineWidth: 1.5)
                    }
                    ForEach(nodes) { node in
                        cell(node)
                            .frame(width: Self.cell.width - 16, height: Self.cell.height - 8, alignment: .top)
                            .position(x: centre(node).x, y: centre(node).y + (Self.cell.height - 8 - Self.picture.height) / 2 - 4)
                    }
                }
                .frame(width: CGFloat(columns) * Self.cell.width + 32, height: CGFloat(rows) * Self.cell.height + 24, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay {
                if session.snapshots.isEmpty {
                    VStack(spacing: 4) {
                        Spacer()
                        Text("No snapshots available").font(.title3).foregroundStyle(.secondary)
                        Text("Click “New” to create a snapshot").font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 24)
                    .allowsHitTesting(false)
                }
            }
            .onTapGesture { selection = nil }
            Divider()
            HStack {
                Button("New") { beginNew() }.disabled(session.busy != nil)
                Button("Delete") { deleteTarget = selected }.disabled(selected == nil || session.busy != nil)
                if let errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(2).textSelection(.enabled)
                } else if let busy = session.busy {
                    ProgressView().controlSize(.small)
                    Text(busy).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Go To") { goToTarget = selected }.disabled(selected == nil || session.busy != nil)
            }
            .padding(12)
        }
        .frame(minWidth: 560, minHeight: 360)
        .navigationTitle("Snapshot Manager – \(session.config.name)")
        .sheet(item: $editing) { mode in parameters(mode) }
        .confirmationDialog(goToTarget.map { "You’re about to revert to “\($0.name)”. Save the current state as a new snapshot?" } ?? "",
                            isPresented: Binding(get: { goToTarget != nil }, set: { if !$0 { goToTarget = nil } }), titleVisibility: .visible) {
            Button("Save") { goTo(saving: true) }
            Button("Don’t Save", role: .destructive) { goTo(saving: false) }
            Button("Cancel", role: .cancel) { goToTarget = nil }
        } message: {
            Text(session.state.isActive
                 ? "The virtual machine is stopped first. To revert without saving, click “Don’t Save”: everything since the last snapshot is then lost."
                 : "To revert without saving, click “Don’t Save”: everything since the last snapshot is then lost.")
        }
        .confirmationDialog(deleteTarget.map { "Delete the snapshot “\($0.name)”?" } ?? "",
                            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let target = deleteTarget { attemptAsync { try await session.deleteSnapshot(target) }; if selection == target.id { selection = nil } }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("You can no longer go back to it. The virtual machine’s current state and its other snapshots are not affected. This cannot be undone.")
        }
    }

    @ViewBuilder private func cell(_ node: Node) -> some View {
        let isSelected = node.snapshot != nil && node.snapshot?.id == selection
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.16))
                if let image = node.snapshot.map({ session.snapshotThumbnail($0) }) ?? session.thumbnail {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: session.config.guestOS.symbol).font(.system(size: 26)).foregroundStyle(.white.opacity(0.55))
                }
            }
            .frame(width: Self.picture.width, height: Self.picture.height)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: isSelected ? 3 : 1))
            if let snapshot = node.snapshot {
                Text(snapshot.name).font(.callout).lineLimit(2).multilineTextAlignment(.center)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(isSelected ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 4))
            } else {
                Text("Current State").font(.callout.weight(.semibold)).foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { selection = node.snapshot?.id }
        .help(node.snapshot.map { [$0.created.formatted(date: .abbreviated, time: .shortened), $0.note].compactMap { $0 }.joined(separator: "\n") } ?? "The virtual machine as it is now")
        .contextMenu {
            Button("Create New Snapshot") { beginNew() }
            if let snapshot = node.snapshot {
                Button("Go to Snapshot") { selection = snapshot.id; goToTarget = snapshot }
                Button("Delete Snapshot") { selection = snapshot.id; deleteTarget = snapshot }
                Divider()
                Button("Snapshot Properties…") { name = snapshot.name; note = snapshot.note ?? ""; editing = .properties(snapshot) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(node.snapshot.map { "Snapshot \($0.name)" } ?? "Current state")
    }

    private func parameters(_ mode: Editing) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Snapshot Parameters").font(.headline)
            LabeledContent("Snapshot Name:") { TextField("", text: $name).labelsHidden().frame(width: 300) }
            LabeledContent("Description:") { TextField("", text: $note, axis: .vertical).labelsHidden().lineLimit(4...6).frame(width: 300) }
            if case .properties(let snapshot) = mode {
                let size = session.snapshotSize(snapshot)
                LabeledContent("Created:", value: snapshot.created.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Size:", value: ByteCountFormatter.string(fromByteCount: size.total, countStyle: .file)
                               + " (\(ByteCountFormatter.string(fromByteCount: size.exclusive, countStyle: .file)) extra on disk)"
                               + (session.snapshotIncludesRunningState(snapshot) ? ", taken while running" : ""))
            } else if session.state.isActive {
                Text("The virtual machine pauses for a few seconds while its memory is saved.").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { editing = nil }.keyboardShortcut(.cancelAction)
                Button("OK") {
                    let (newName, newNote) = (name, note)
                    editing = nil
                    switch mode {
                    case .new:
                        Task {
                            do { try await session.takeSnapshot(named: newName, note: newNote); errorText = nil }
                            catch { errorText = error.localizedDescription }
                        }
                    case .properties(let snapshot):
                        attempt { try session.renameSnapshot(snapshot, name: newName, note: newNote) }
                    }
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(width: 460)
    }

    private func beginNew() {
        name = "Snapshot \(session.snapshots.count + 1)"
        note = ""
        editing = .new
    }

    private func goTo(saving: Bool) {
        guard let target = goToTarget else { return }
        goToTarget = nil
        let saveName = saving ? "Before going to “\(target.name)”" : nil
        Task {
            do { try await session.goTo(target, savingCurrentAs: saveName); errorText = nil }
            catch { errorText = error.localizedDescription }
        }
    }

    private func attempt(_ work: () throws -> Void) {
        do { try work(); errorText = nil } catch { errorText = error.localizedDescription }
    }

    private func attemptAsync(_ work: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do { try await work(); errorText = nil } catch { errorText = error.localizedDescription }
        }
    }
}
