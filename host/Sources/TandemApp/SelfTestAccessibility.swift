import AppKit
import VMCore

/// `TANDEM_SNAPSHOT_A11Y=1`: with every snapshot, walks the accessibility tree of each visible window the way
/// VoiceOver does and prints the elements that would be read badly (VMCore/AccessibilityAudit.swift has the
/// rules). The tree is also written to `a11y-<tag>.txt` in the snapshot folder.
@MainActor
enum SelfTestAccessibility {
    static var enabled: Bool { ProcessInfo.processInfo.environment["TANDEM_SNAPSHOT_A11Y"] != nil }

    static func audit(tag: String) {
        guard enabled, let directory = SelfTest.directory else { return }
        // SwiftUI builds its accessibility tree only when something that needs it is attached (VoiceOver, a
        // script); this is what such a client does.
        for attribute in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
            NSApp.accessibilitySetOverrideValue(true, forAttribute: NSAccessibility.Attribute(rawValue: attribute))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        var nodes: [AXNode] = []
        var lines: [String] = []
        for window in NSApp.windows where window.isVisible {
            let name = window.title.isEmpty ? "sheet" : window.title
            lines.append("== \(name)")
            var seen = Set<ObjectIdentifier>()
            for child in window.accessibilityChildren() ?? [] {
                walk(child, path: name, depth: 1, insideNamedControl: false, nodes: &nodes, lines: &lines, seen: &seen)
            }
        }
        let problems = AccessibilityAudit.problems(in: nodes)
        print("a11y[\(tag)] " + AccessibilityAudit.report(problems, checked: nodes.count))
        try? lines.joined(separator: "\n").write(to: directory.appendingPathComponent("a11y-\(tag).txt"), atomically: true, encoding: .utf8)
    }

    private static func walk(_ element: Any, path: String, depth: Int, insideNamedControl: Bool, nodes: inout [AXNode], lines: inout [String], seen: inout Set<ObjectIdentifier>) {
        guard depth < 40, let object = element as? NSObject else { return }
        let id = ObjectIdentifier(object)
        guard seen.insert(id).inserted else { return }
        let ax = object as NSObjectProtocol
        guard let element = ax as? NSAccessibilityProtocol else { return }
        // Hidden from VoiceOver on purpose: nothing to check, and nothing inside is read either.
        if element.isAccessibilityElement() == false, children(of: element).isEmpty { return }
        let role = element.accessibilityRole()?.rawValue ?? ""
        // Scroll bars are AppKit's own, with their own spoken names.
        if role == "AXScrollBar" { return }
        // The traffic lights have their own names from AppKit.
        if let subrole = element.accessibilitySubrole()?.rawValue, subrole.hasSuffix("Button"), subrole != "AXSortButton" { return }
        let label = element.accessibilityLabel() ?? ""
        // A form row's caption is a separate text element that the control points to; VoiceOver reads that.
        var title = element.accessibilityTitle() ?? ""
        if title.isEmpty, let captionElement = element.accessibilityTitleUIElement() as? NSAccessibilityProtocol {
            title = captionElement.accessibilityLabel() ?? captionElement.accessibilityValue().map { "\($0)" } ?? ""
        }
        let value = element.accessibilityValue().map { "\($0)" } ?? ""
        let help = element.accessibilityHelp() ?? ""
        let here = path + " ▸ " + (role.isEmpty ? "?" : role.replacingOccurrences(of: "AX", with: "")) + (label.isEmpty ? (title.isEmpty ? "" : " “\(title)”") : " “\(label)”")
        // A control inside a named control is its own part (a toolbar button's inner button): VoiceOver reads the outer name.
        let named = AccessibilityAudit.controls.contains(role) && !(label + title).trimmingCharacters(in: .whitespaces).isEmpty
        if element.isAccessibilityElement(), !(insideNamedControl && AccessibilityAudit.controls.contains(role)) {
            nodes.append(AXNode(role: role, label: label, title: title, value: value, help: help, depth: depth, path: here))
            lines.append(String(repeating: "  ", count: depth) + here + (value.isEmpty ? "" : " = \(value)"))
        }
        for child in children(of: element) {
            walk(child, path: here, depth: depth + 1, insideNamedControl: insideNamedControl || named, nodes: &nodes, lines: &lines, seen: &seen)
        }
    }

    /// Children as VoiceOver reaches them: SwiftUI hosting views answer to one of several accessors.
    private static func children(of element: NSAccessibilityProtocol) -> [Any] {
        var all = element.accessibilityChildren() ?? []
        if all.isEmpty { all = element.accessibilityChildrenInNavigationOrder() ?? [] }
        if all.isEmpty { all = element.accessibilityVisibleChildren() ?? [] }
        if all.isEmpty, let table = element as? NSAccessibilityTable { all = table.accessibilityRows() ?? [] }
        if all.isEmpty, let view = element as? NSView { all = view.subviews }
        return all
    }
}
