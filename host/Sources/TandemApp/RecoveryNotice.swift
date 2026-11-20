import SwiftUI

/// Says once, after launch, that VMs were stopped because Tandem had quit unexpectedly (CrashRecovery).
struct RecoveryNoticeModifier: ViewModifier {
    @ObservedObject var model: AppModel

    func body(content: Content) -> some View {
        content.alert("Tandem quit unexpectedly", isPresented: Binding(get: { model.recoveryNotice != nil },
                                                                       set: { if !$0 { model.recoveryNotice = nil } })) {
            Button("OK") { model.recoveryNotice = nil }
        } message: {
            Text(model.recoveryNotice ?? "")
        }
    }
}
