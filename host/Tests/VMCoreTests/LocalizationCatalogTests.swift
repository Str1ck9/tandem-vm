import XCTest

/// The string catalog (resources/Localizable.xcstrings): valid, English as the source, and no translation
/// that loses or changes a placeholder (a wrong one crashes or garbles a message).
final class LocalizationCatalogTests: XCTestCase {
    private func catalog() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("resources/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static let placeholder = try! NSRegularExpression(pattern: "%(?:[0-9]+\\$)?[-+ 0#]*[0-9.]*(?:lld|ld|d|u|@|f|s|%)")

    private func placeholders(_ text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return Self.placeholder.matches(in: text, range: range).map { String(text[Range($0.range, in: text)!]) }
            .filter { $0 != "%%" }
            // Position numbers ("%1$@") may be reordered; what matters is the kind of each.
            .map { $0.replacingOccurrences(of: "\\d+\\$", with: "", options: .regularExpression) }
    }

    func testTheCatalogIsEnglishFirstAndHasStrings() throws {
        let c = try catalog()
        XCTAssertEqual(c["sourceLanguage"] as? String, "en")
        XCTAssertGreaterThan((c["strings"] as? [String: Any])?.count ?? 0, 100)
    }

    func testEveryTranslationKeepsThePlaceholdersOfItsSource() throws {
        let strings = try XCTUnwrap(try catalog()["strings"] as? [String: [String: Any]])
        var translated = 0
        for (key, entry) in strings {
            let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
            for (language, localization) in localizations {
                guard let value = (localization["stringUnit"] as? [String: Any])?["value"] as? String else { continue }
                translated += 1
                XCTAssertFalse(value.trimmingCharacters(in: .whitespaces).isEmpty, "\(language): “\(key)” is empty")
                XCTAssertEqual(placeholders(value).sorted(), placeholders(key).sorted(), "\(language): “\(key)” → “\(value)” changes the placeholders")
            }
        }
        XCTAssertGreaterThan(translated, 50, "the Spanish proof set is in the catalog")
    }

    func testTheSpanishProofSetCoversTheMainWindowTheNewVMFlowAndTheMenus() throws {
        let strings = try XCTUnwrap(try catalog()["strings"] as? [String: [String: Any]])
        func spanish(_ key: String) -> String? {
            (((strings[key]?["localizations"] as? [String: Any])?["es"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
        }
        for (key, expected) in [("Control Center", "Centro de control"), ("Create New", "Crear nueva"), ("Cancel", "Cancelar"), ("Stopped", "Detenida"),
                                ("Take Snapshot…", "Tomar instantánea…"), ("Free Systems", "Sistemas gratuitos")] {
            XCTAssertEqual(spanish(key), expected, key)
        }
    }

    func testTheRunTimeOnlyTitlesAreKeptByHand() throws {
        let strings = try XCTUnwrap(try catalog()["strings"] as? [String: [String: Any]])
        // Titles that come from the downloading providers as plain text are looked up by key, and the compiler
        // cannot find them in the code, so they carry the "manual" mark that keeps a sync from dropping them.
        for key in ["Get Windows 11 from Microsoft", "Download macOS", "Download a Linux system"] {
            XCTAssertEqual(strings[key]?["extractionState"] as? String, "manual", key)
        }
    }
}
