import AppKit
import VMCore
import SwiftUI

/// Tandem > About Tandem: larger and easier to read than the standard panel.
struct AboutView: View {
    private var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }
    private var version: String { info["CFBundleShortVersionString"] as? String ?? "–" }
    private var build: String { info["CFBundleVersion"] as? String ?? "–" }
    private var commit: String? { info["TandemCommit"] as? String }
    private var built: String? { info["TandemBuildDate"] as? String }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .accessibilityHidden(true)
            Text("Tandem")
                .font(.system(size: 34, weight: .semibold))
            Text("Version \(version) (build \(build))")
                .font(.title3)
                .textSelection(.enabled)
            Text("Windows, Linux and macOS virtual machines on Apple silicon.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Divider().padding(.vertical, 4)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                row("Developer", TandemIdentity.developerName)
                if let built { row("Built", built) }
                if let commit { row("Source", commit) }
                row("Engines", "Apple Virtualization and QEMU")
            }
            .font(.body)
            Text("© 2026 \(TandemIdentity.developerName). Licensed under the Apache License 2.0. QEMU, virglrenderer, DXMT, the virtio-win drivers and other open-source components keep their own licences (see THIRD_PARTY_NOTICES.md).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 28)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label + ":").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled)
        }
    }
}
