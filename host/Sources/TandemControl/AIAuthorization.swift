import Foundation
import VMCore

/// What an AI tool (a request with `client: mcp`) may do with a VM, decided by the VM's AI level
/// (`AITier`). The app applies it to every request that arrives on the control socket, so a program that
/// talks to the socket and calls itself `mcp` is held to the same rules as the MCP server; hiding tools in
/// the MCP server would not be enough.
///
/// The `tandem` command (client `cli`) is the Mac user's own tool and is not limited by the level.
public enum AIAuthorization {
    public enum Requirement: Equatable, Sendable {
        /// Not about a particular VM (`status`, `list`): the global switch is all that applies.
        case none
        /// The VM's AI level must be at least this.
        case tier(AITier)
        /// Never for an AI tool, at any level.
        case never
    }

    /// The level an operation needs. `args` matter for the few operations whose danger depends on them.
    public static func requirement(op: ControlOp, args: [String: JSON] = [:]) -> Requirement {
        switch op {
        case .status, .list:
            return .none
        case .info, .ip, .snapshotList, .screenshot, .services, .programs:
            return .tier(.observe)
        case .sharing:
            // Reading the sharing settings is looking; changing who may use the VM is the owner's decision.
            return args["commands"] != nil || args["aiTier"] != nil ? .never : .tier(.observe)
        case .start, .resume, .suspend, .pause, .restart, .snapshotTake, .unshare, .keepAwake, .launch, .exec:
            return .tier(.operate)
        case .stop:
            return .tier(args["force"]?.bool == true ? .full : .operate)
        case .share:
            // An AI tool shares folders read-only unless it asks otherwise.
            return .tier(args["readOnly"]?.bool ?? true ? .operate : .full)
        case .reset, .snapshotRevert, .clone:
            return .tier(.full)
        case .snapshotDelete, .snapshotBaseline:
            return .never
        }
    }

    /// Where the person finds the setting, for the messages.
    public static let settingPath = "Configure > Options > Sharing > AI tools"

    /// Throws `ControlError.refused` unless a request from an AI tool is allowed for a VM at `tier`.
    public static func authorize(_ request: ControlRequest, vmName: String?, tier: AITier) throws {
        guard request.client == .mcp, let op = request.operation else { return }
        switch requirement(op: op, args: request.args) {
        case .none:
            return
        case .never:
            if op == .snapshotDelete {
                throw ControlError.refused("AI tools cannot delete snapshots.",
                                           detail: "Deleting a snapshot is for the person at the Mac: Snapshot Manager, or `tandem snapshot delete`.")
            }
            if op == .snapshotBaseline {
                throw ControlError.refused("AI tools cannot choose a virtual machine’s baseline snapshot.",
                                           detail: "The person at the Mac sets it in Snapshot Manager, or with `tandem snapshot baseline`.")
            }
            throw ControlError.refused("AI tools cannot change who may use a virtual machine.",
                                       detail: "That is set by the person at the Mac, under \(settingPath).")
        case .tier(let needed):
            guard tier >= needed else { throw refusal(op: op, vmName: vmName, tier: tier, needed: needed) }
        }
    }

    static func refusal(op: ControlOp, vmName: String?, tier: AITier, needed: AITier) -> ControlError {
        let name = vmName.map { "“\($0)”" } ?? "This virtual machine"
        let enable = "The person at the Mac can allow it under \(settingPath), or with `tandem sharing <vm> --ai-tier \(needed.rawValue)`."
        if tier == .off {
            return .refused("\(name) is closed to AI tools (AI level: Off).", detail: enable)
        }
        return .refused("\(name) allows AI tools only to \(tier.label) (AI level), and “\(op.rawValue)” needs \(needed.label).", detail: enable)
    }

    /// A revert by an AI tool. When the VM has a baseline snapshot, that is the only state AI tools may go back
    /// to: a bad run cannot roll back past the safety net it was given. Without a baseline, any snapshot will do.
    public static func authorizeRevert(_ request: ControlRequest, vmName: String, target: UUID, targetName: String,
                                       baseline: UUID?, baselineName: String?) throws {
        guard request.client == .mcp, let baseline, baseline != target else { return }
        throw ControlError.refused("“\(vmName)” has a baseline snapshot, and AI tools may only go back to that one.",
                                   detail: "“\(targetName)” is not the baseline" + (baselineName.map { " (“\($0)”)." } ?? ".")
                                   + " The person at the Mac can revert to other snapshots in Snapshot Manager.")
    }

    /// A sentence on the level an operation needs, for tool descriptions. Empty for operations that need none.
    public static func levelNote(for op: ControlOp, args: [String: JSON] = [:]) -> String {
        switch requirement(op: op, args: args) {
        case .none: return ""
        case .never: return "Never available to AI tools."
        case .tier(let tier): return "Needs the virtual machine's AI level to be \(tier.label) or higher."
        }
    }
}
