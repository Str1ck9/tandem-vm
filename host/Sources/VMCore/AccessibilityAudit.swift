import Foundation

/// One element of a window's accessibility tree, as VoiceOver meets it. The app's self-test reads these
/// from NSAccessibility (`TANDEM_SNAPSHOT_A11Y`); the rules below are plain so that they can be tested.
public struct AXNode: Equatable, Sendable {
    public var role: String
    public var label: String
    public var title: String
    public var value: String
    public var help: String
    public var depth: Int
    /// Where it is, for the report ("Window ▸ group ▸ button").
    public var path: String

    public init(role: String, label: String = "", title: String = "", value: String = "", help: String = "", depth: Int = 0, path: String = "") {
        self.role = role; self.label = label; self.title = title; self.value = value; self.help = help; self.depth = depth; self.path = path
    }

    /// What VoiceOver would say to name it.
    public var spokenName: String {
        [label, title].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
    }
}

public struct AXProblem: Equatable, Sendable {
    public var node: AXNode
    public var message: String
    public init(node: AXNode, message: String) { self.node = node; self.message = message }
}

public enum AccessibilityAudit {
    /// Roles that act on a click or key and so must say what they do.
    public static let controls: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
                                       "AXDisclosureTriangle", "AXSlider", "AXIncrementor", "AXComboBox"]
    /// Words that name a control by its picture, not by what it does.
    static let pictureNames: Set<String> = ["power", "gearshape", "plus", "minus", "xmark", "trash", "chevron up", "chevron down",
                                            "doc on doc", "play fill", "folder", "circle", "checkmark", "image", "button", "icon"]

    public static func problems(in nodes: [AXNode]) -> [AXProblem] {
        var found: [AXProblem] = []
        for node in nodes {
            let name = node.spokenName.trimmingCharacters(in: .whitespaces)
            if controls.contains(node.role) {
                if name.isEmpty {
                    found.append(AXProblem(node: node, message: "\(node.role) has no label: VoiceOver says only “button”."))
                } else if pictureNames.contains(name.lowercased()) {
                    found.append(AXProblem(node: node, message: "\(node.role) is named “\(name)”, which says what it looks like, not what it does."))
                }
            }
            if node.role == "AXProgressIndicator" || node.role == "AXLevelIndicator" {
                if node.value.isEmpty && name.isEmpty {
                    found.append(AXProblem(node: node, message: "progress indicator has neither a value nor a label."))
                }
            }
            if node.role == "AXTextField" || node.role == "AXTextArea" || node.role == "AXSecureTextField" {
                if name.isEmpty && node.help.isEmpty {
                    found.append(AXProblem(node: node, message: "text field has no label or help text."))
                }
            }
            if node.role == "AXImage", name.isEmpty {
                found.append(AXProblem(node: node, message: "image has no description and is not hidden from VoiceOver."))
            }
        }
        return found
    }

    /// A short report: one line per problem, then a count.
    public static func report(_ problems: [AXProblem], checked: Int) -> String {
        var lines = problems.map { "  ✘ \($0.node.path.isEmpty ? $0.node.role : $0.node.path): \($0.message)" }
        lines.append("  \(problems.count) problem\(problems.count == 1 ? "" : "s") in \(checked) elements")
        return lines.joined(separator: "\n")
    }
}
