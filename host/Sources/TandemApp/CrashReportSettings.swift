import SwiftUI
import VMCore

/// Settings > Advanced > Crash reports: whether Tandem asks, after a crash, to send a report, and where
/// the report page is. Nothing is ever sent without the user's own action.
struct CrashReportSettings: View {
    @AppStorage(CrashReports.offerKey) private var offer = true
    @AppStorage(CrashReports.repositoryKey) private var repository = ""

    var body: some View {
        Section("Crash reports") {
            Toggle("Offer to send crash reports", isOn: $offer)
            TextField("Report page:", text: $repository, prompt: Text(CrashReports.defaultRepository))
            Text("After a crash, Tandem asks once whether to send a report. If you agree, it collects its diagnostics, shows the file in Finder and opens a pre-filled GitHub issue or e-mail for you to attach it to. Tandem never sends anything by itself.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
