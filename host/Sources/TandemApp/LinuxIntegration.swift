import SwiftUI
import VMCore

/// Settings for what Linux virtual machines get from the guest tools besides the clipboard and shared
/// folders: their programs on the Mac, files dragged onto them and out of them, and an experimental
/// Seamless Mode. The rules themselves are `VMCore.GuestIntegration`.
enum LinuxIntegration {
    /// Settings > Advanced > "Seamless Mode for Linux". Off until the user turns it on: the first version
    /// shows each guest window as a Mac window cut out of the guest's screen picture.
    static let seamlessKey = "linuxSeamlessMode"
    static var seamlessEnabled: Bool { UserDefaults.standard.bool(forKey: seamlessKey) }
}

/// Settings > Advanced > Linux virtual machines.
struct LinuxIntegrationSettings: View {
    @AppStorage(LinuxIntegration.seamlessKey) private var seamless = false

    var body: some View {
        Section("Linux virtual machines") {
            Toggle("Seamless Mode for Linux (experimental)", isOn: $seamless)
            Text("Shows each window of a Linux desktop as a Mac window. It works with desktops that run on X11 (MATE and Xfce, and GNOME set to X11) and needs the guest tools. Each window is a cut-out of the guest’s screen, so a window covered by another one in the guest shows what covers it.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
