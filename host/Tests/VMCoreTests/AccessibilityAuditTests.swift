import XCTest
@testable import VMCore

final class AccessibilityAuditTests: XCTestCase {
    func testAButtonWithoutAnyNameIsAProblem() {
        let problems = AccessibilityAudit.problems(in: [AXNode(role: "AXButton")])
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].message.contains("no label"))
    }

    func testAButtonNamedByItsPictureIsAProblem() {
        XCTAssertEqual(AccessibilityAudit.problems(in: [AXNode(role: "AXButton", label: "gearshape")]).count, 1)
        XCTAssertEqual(AccessibilityAudit.problems(in: [AXNode(role: "AXButton", title: "Power")]).count, 1)
    }

    func testNamedControlsAreFine() {
        let nodes = [AXNode(role: "AXButton", label: "Configure Windows 11"), AXNode(role: "AXCheckBox", title: "Network cable connected"),
                     AXNode(role: "AXPopUpButton", title: "Source")]
        XCTAssertTrue(AccessibilityAudit.problems(in: nodes).isEmpty)
    }

    func testProgressNeedsAValueOrALabel() {
        XCTAssertEqual(AccessibilityAudit.problems(in: [AXNode(role: "AXProgressIndicator")]).count, 1)
        XCTAssertTrue(AccessibilityAudit.problems(in: [AXNode(role: "AXProgressIndicator", value: "42")]).isEmpty)
        XCTAssertTrue(AccessibilityAudit.problems(in: [AXNode(role: "AXProgressIndicator", label: "Download progress")]).isEmpty)
    }

    func testTextFieldsAndImages() {
        XCTAssertEqual(AccessibilityAudit.problems(in: [AXNode(role: "AXTextField")]).count, 1)
        XCTAssertTrue(AccessibilityAudit.problems(in: [AXNode(role: "AXTextField", title: "Name")]).isEmpty)
        XCTAssertEqual(AccessibilityAudit.problems(in: [AXNode(role: "AXImage")]).count, 1)
        XCTAssertTrue(AccessibilityAudit.problems(in: [AXNode(role: "AXImage", label: "Windows")]).isEmpty)
    }

    func testPlainRolesAreLeftAlone() {
        XCTAssertTrue(AccessibilityAudit.problems(in: [AXNode(role: "AXStaticText"), AXNode(role: "AXGroup"), AXNode(role: "AXScrollArea")]).isEmpty)
    }

    func testTheReportNamesWhereAndHowMany() {
        let node = AXNode(role: "AXButton", path: "Library ▸ list ▸ row 2 ▸ button")
        let text = AccessibilityAudit.report(AccessibilityAudit.problems(in: [node]), checked: 9)
        XCTAssertTrue(text.contains("row 2"))
        XCTAssertTrue(text.contains("1 problem in 9 elements"))
    }
}
