import AppKit
import NetHelperClient
import SwiftUI

/// A problem reported while the VM runs (a USB device that could not be connected, a failed screenshot,
/// a refused action): a bar across the top of the VM window until it is dismissed. Without it such errors
/// were only shown once the VM had stopped, so a failed action looked as if nothing had happened.
struct RuntimeErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    /// The first line is the headline; the rest is detail.
    private var lines: (title: String, detail: String?) {
        let parts = message.split(separator: "\n", maxSplits: 1).map(String.init)
        return (parts.first ?? message, parts.count > 1 ? parts[1] : nil)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(lines.title).font(.callout.weight(.semibold))
                if let detail = lines.detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .textSelection(.enabled)
            Spacer(minLength: 8)
            Button("Dismiss", action: dismiss).keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.yellow.opacity(0.6)))
        .shadow(radius: 6, y: 2)
        .padding(12)
        .frame(maxWidth: 720)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Problem: \(message)")
    }

    /// Self-test (`TANDEM_SNAPSHOT_ERRORBANNER`): the banner with a typical USB error, as a PNG in the
    /// snapshot folder, over a dark stand-in for the guest's screen.
    @MainActor static func renderForSelfTest() {
        guard let directory = SelfTest.directory else { return }
        let sample = "“USB Flash Drive” could not be connected to the VM.\nmacOS did not let the helper open /dev/rdisk5 (Operation not permitted). \(NetHelper.fullDiskAccessAdvice)"
        let view = ZStack(alignment: .top) {
            Color(white: 0.15)
            RuntimeErrorBanner(message: sample) {}
        }
        .frame(width: 900, height: 260)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? png.write(to: directory.appendingPathComponent("error-banner.png"))
        print("selftest: error banner rendered")
    }

    /// For when no VM window is open (Seamless Mode): the same message as an alert, shown after the
    /// current event so it never runs inside a SwiftUI update.
    @MainActor static func alert(_ message: String, vm: String) {
        let parts = message.split(separator: "\n", maxSplits: 1).map(String.init)
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = parts.first ?? message
            alert.informativeText = (parts.count > 1 ? parts[1] + "\n\n" : "") + "Virtual machine: \(vm)"
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
