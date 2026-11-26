import EngineQEMU
import SwiftUI
import VMCore

extension SupportLevel {
    var symbol: String {
        switch self {
        case .supported: return "checkmark.circle.fill"
        case .needsPrerequisite: return "wrench.and.screwdriver.fill"
        case .experimental: return "flask.fill"
        case .unverified: return "questionmark.circle.fill"
        case .notSupported: return "minus.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .supported: return .green
        case .needsPrerequisite: return .orange
        case .experimental: return .purple
        case .unverified: return .yellow
        case .notSupported: return .secondary
        }
    }
}

/// One form row: whether this VM can be made on this Mac, with the full list behind "Details…".
/// Shown in the Create New assistant and the Parallels import sheet.
struct CompatibilityRow: View {
    let report: CompatibilityReport
    var title = "Compatibility:"
    @State private var showingDetails = false

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Image(systemName: report.canProceed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(report.canProceed ? .green : .red)
                    .accessibilityLabel(report.canProceed ? "Compatible" : "Not compatible")
                Text(report.summary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Button("Details…") { showingDetails = true }
                    .popover(isPresented: $showingDetails, arrowEdge: .trailing) { CompatibilityDetails(report: report) }
                    // Self-test: show the details without a click.
                    .onAppear { if ProcessInfo.processInfo.environment["TANDEM_SNAPSHOT_COMPAT_DETAILS"] != nil { showingDetails = true } }
            }
        }
    }
}

/// What stands in the way, in full, for the foot of a form. Empty when nothing does.
struct CompatibilityBlockers: View {
    let report: CompatibilityReport

    var body: some View {
        ForEach(report.blockers) { finding in
            VStack(alignment: .leading, spacing: 2) {
                Label(finding.detail, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                if let fix = finding.fix { Text(fix).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Every capability with its level, one sentence, and what to do about it where something can be done.
struct CompatibilityDetails: View {
    let report: CompatibilityReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What this Mac supports for this virtual machine").font(.headline)
            Text("\(report.host.chip) · macOS \(report.host.macOSVersion) · \(report.host.memoryGiB) GB memory · \(report.host.freeDiskGiB) GB free")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(report.findings) { finding in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: finding.blocking ? "xmark.octagon.fill" : finding.level.symbol)
                                .foregroundStyle(finding.blocking ? .red : finding.level.tint).frame(width: 18)
                                .accessibilityLabel(finding.blocking ? "Blocks this virtual machine" : finding.level.label)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(finding.title).bold()
                                    Text(finding.level.label).font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(finding.level.tint.opacity(0.18), in: Capsule())
                                }
                                Text(finding.detail).font(.callout).fixedSize(horizontal: false, vertical: true)
                                if let fix = finding.fix {
                                    Text(fix).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
            }
            Text("“Unverified” means written or offered by macOS but never run by Tandem with the real thing. “Experimental” works in a first form.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(width: 520, height: 520)
    }
}

extension AppModel {
    /// The facts about this Mac, gathered once per use of an assistant (it runs `qemu --version`).
    func hostFacts() -> HostFacts {
        let disc = ImportDefaults.existingPath(ImportDefaults.virtioISOKey)
        return HostProbe.current(vmFolder: URL(fileURLWithPath: libraryPath), driverDisc: disc.isEmpty ? nil : URL(fileURLWithPath: disc))
    }
}
