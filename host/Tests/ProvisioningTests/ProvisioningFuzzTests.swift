import FuzzSupport
import VMCore
import XCTest
@testable import Provisioning

/// What the user types (account names, passwords) ends up inside YAML, XML and PowerShell. Whatever
/// it is, it must come out the other side unchanged or be refused up front.
final class ProvisioningFuzzTests: XCTestCase {
    private func password(_ rng: inout SeededRandom) -> String {
        var s = rng.awkwardString(maxLength: 24)
        // The characters that broke something once, often.
        if rng.chance(0.3) { s += rng.pick(["\u{7F}", "\u{85}", "\u{9F}", "\u{2028}", "\u{2029}", "\u{FEFF}", "\u{2019}", "\u{2018}", "\u{201A}", "\u{201B}", "'", "\"", "\\", "\u{1}"]) }
        return s
    }

    private func linuxName(_ rng: inout SeededRandom) -> String {
        let first = "abcdefghijklmnopqrstuvwxyz_"
        let rest = "abcdefghijklmnopqrstuvwxyz0123456789_-"
        return String(first.randomElement(using: &rng)!) + String((0..<rng.int(0...20)).map { _ in rest.randomElement(using: &rng)! })
    }

    /// `quoted` is valid JSON for any text, decodes back to it, and leaves no character raw that YAML refuses.
    func testQuotedRoundTripsAndIsYAMLSafe() throws {
        try Fuzz.cases(4000) { rng, seed in
            let text = rng.chance(0.2) ? String(decoding: rng.bytes(rng.int(0...40)), as: UTF8.self) : password(&rng)
            let quoted = LinuxSeed.quoted(text)
            XCTAssertEqual(try JSONDecoder().decode(String.self, from: Data(quoted.utf8)), text, "seed \(seed)")
            for scalar in quoted.unicodeScalars {
                let v = scalar.value
                XCTAssertFalse(v < 0x20 || (0x7F...0x9F).contains(v) || v == 0x2028 || v == 0x2029, "seed \(seed): raw U+\(String(v, radix: 16))")
            }
        }
    }

    /// The whole user-data document, read by a real YAML 1.1 parser (libyaml, through the Ruby that
    /// ships with macOS): the account and password come back as typed.
    func testCloudInitUserDataParsesWithAnyPassword() throws {
        let ruby = URL(fileURLWithPath: "/usr/bin/ruby")
        guard FileManager.default.isExecutableFile(atPath: ruby.path),
              (try? ToolRun.run(ruby, ["-ryaml", "-rjson", "-e", "1"], timeout: 30))?.succeeded == true else {
            throw XCTSkip("no Ruby with YAML on this Mac")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-yaml-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var expected: [(user: String, password: String, host: String, seed: UInt64)] = []
        try Fuzz.cases(150) { rng, seed in
            let account = SystemAccount(userName: linuxName(&rng), password: rng.chance(0.1) ? "" : password(&rng), autoLogin: rng.chance(0.5))
            // What the assistant refuses never reaches the setup disc.
            guard LinuxCloudImages().accountProblems(account).isEmpty else { return }
            let host = LinuxSeed.hostName(from: rng.awkwardString(maxLength: 30))
            let firstBoot = rng.pick([LinuxSeed.FirstBoot.none, .kali, .kaliDesktop, .ubuntuDesktop(.gnome), .ubuntuDesktop(.mate), .ubuntuDesktop(.xfce)])
            let text = LinuxSeed.userData(hostName: host, account: account, firstBoot: firstBoot)
            try Data(text.utf8).write(to: folder.appendingPathComponent(String(format: "%05d.yaml", expected.count)))
            expected.append((account.userName, account.password, host, seed))
        }
        // One Ruby run for every document: each line is the document as JSON, or the parse error.
        let script = """
        Dir[File.join(ARGV[0], '*.yaml')].sort.each do |f|
          begin
            d = YAML.safe_load(File.read(f))
            u = d['users'][0]
            puts JSON.generate({'ok' => true, 'user' => u['name'], 'password' => u['plain_text_passwd'] || '', 'host' => d['hostname'], 'runcmd' => d['runcmd'].length})
          rescue Exception => e
            puts JSON.generate({'ok' => false, 'error' => e.message})
          end
        end
        """
        let result = try ToolRun.run(ruby, ["-ryaml", "-rjson", "-e", script, folder.path], timeout: 120)
        XCTAssertTrue(result.succeeded, result.errorText)
        let lines = result.outputText.split(separator: "\n")
        XCTAssertEqual(lines.count, expected.count)
        for (line, want) in zip(lines, expected) {
            let parsed = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] ?? [:]
            XCTAssertEqual(parsed["ok"] as? Bool, true, "seed \(want.seed): \(parsed["error"] ?? "")")
            XCTAssertEqual(parsed["user"] as? String, want.user, "seed \(want.seed)")
            XCTAssertEqual(parsed["password"] as? String, want.password, "seed \(want.seed)")
            XCTAssertEqual(parsed["host"] as? String, want.host, "seed \(want.seed)")
        }
    }

    /// Regression (fuzzer): JSONEncoder left DEL raw, and libyaml refuses the whole document for it.
    func testPasswordWithDeleteCharacterIsEscaped() {
        XCTAssertEqual(LinuxSeed.quoted("a\u{7F}b\u{2028}"), #""a\u007Fb\u2028""#)
    }

    /// Host names made from any VM name are what Linux accepts.
    func testHostNamesAreAlwaysValid() {
        Fuzz.cases(3000) { rng, seed in
            let host = LinuxSeed.hostName(from: rng.awkwardString(maxLength: 80))
            XCTAssertNotNil(host.range(of: "^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", options: .regularExpression), "seed \(seed): \(host)")
        }
        // A name whose 63rd character is a hyphen.
        XCTAssertEqual(LinuxSeed.hostName(from: String(repeating: "a", count: 62) + " b"), String(repeating: "a", count: 62))
    }

    // MARK: Windows

    /// PowerShell's single-quoted string, as its tokenizer reads it: any of ' ‘ ’ ‚ ‛ closes it unless
    /// another follows, which stands for the first. Returns the value and what is left after the literal.
    private func readPowerShellLiteral(_ text: String) -> (value: String, rest: String)? {
        let marks = AutounattendBuilder.psQuoteMarks
        var scalars = Array(text.unicodeScalars)[...]
        guard let open = scalars.first, marks.contains(open) else { return nil }
        scalars = scalars.dropFirst()
        var value = String.UnicodeScalarView()
        while let c = scalars.first {
            scalars = scalars.dropFirst()
            if marks.contains(c) {
                if let next = scalars.first, marks.contains(next) { value.append(c); scalars = scalars.dropFirst(); continue }
                return (String(value), String(String.UnicodeScalarView(scalars)))
            }
            value.append(c)
        }
        return nil
    }

    func testPowerShellLiteralsHoldAnyPassword() {
        Fuzz.cases(4000) { rng, seed in
            let text = password(&rng)
            let literal = AutounattendBuilder.psQuoted(text)
            let read = readPowerShellLiteral(literal)
            XCTAssertEqual(read?.value, text, "seed \(seed)")
            XCTAssertEqual(read?.rest, "", "seed \(seed): the literal ended early; the rest would run as script")
        }
    }

    /// Regression (fuzzer): a password with ’ (what a Mac types for an apostrophe) ended the string early.
    func testTypographicApostropheIsDoubled() {
        XCTAssertEqual(AutounattendBuilder.psQuoted("it’s"), "'it’’s'")
        let script = AutounattendBuilder.firstLogonScript(for: WindowsUnattendOptions(userName: "u", password: "a’; Remove-Item C:\\ -Recurse; ’"))
        XCTAssertTrue(script.contains("-Value 'a’’; Remove-Item C:\\ -Recurse; ’’'"))
    }

    /// Any answers that pass validation give an answer file that is well-formed XML and carries the
    /// account exactly; anything else is refused with a reason.
    func testAnswerFileIsWellFormedForAnyAcceptedAccount() throws {
        var accepted = 0
        try Fuzz.cases(1500) { rng, seed in
            let user = rng.chance(0.3) ? rng.pick(["Tandem", "u", "José", "日本"]) : rng.awkwardString(maxLength: 22)
            let options = WindowsUnattendOptions(userName: user, password: password(&rng), autoLogin: rng.chance(0.5))
            guard options.validate().isEmpty else {
                XCTAssertThrowsError(try AutounattendBuilder.xml(options), "seed \(seed)")
                return
            }
            accepted += 1
            let xml = try AutounattendBuilder.xml(options)
            let document = try XCTUnwrap(try? XMLDocument(xmlString: xml), "seed \(seed): not well-formed")
            let values = try document.nodes(forXPath: "//*[local-name()='Password']/*[local-name()='Value']").map { $0.stringValue ?? "" }
            XCTAssertFalse(values.isEmpty, "seed \(seed)")
            for value in values { XCTAssertEqual(value, options.password, "seed \(seed)") }
            let names = try document.nodes(forXPath: "//*[local-name()='Username']").map { $0.stringValue ?? "" }
            XCTAssertEqual(names, [options.userName], "seed \(seed)")
        }
        XCTAssertGreaterThan(accepted, 100, "too few generated accounts were valid")
    }

    /// Regressions (fuzzer): a password starting with U+FEFF came back empty from both the YAML and
    /// the XML parser, and a user name of spaces read back as none.
    func testControlCharactersInThePasswordAreRefused() {
        XCTAssertFalse(WindowsUnattendOptions(userName: "u", password: "a\u{1}b").validate().isEmpty)
        XCTAssertFalse(WindowsUnattendOptions(userName: "u", password: "\u{FEFF}x").validate().isEmpty)
        XCTAssertFalse(WindowsUnattendOptions(userName: " ", password: "x").validate().isEmpty)
        XCTAssertFalse(LinuxCloudImages().accountProblems(SystemAccount(userName: "u", password: "\u{FEFF}")).isEmpty)
        XCTAssertFalse(LinuxCloudImages().accountProblems(SystemAccount(userName: "u", password: "a\u{7F}")).isEmpty)
        XCTAssertTrue(LinuxCloudImages().accountProblems(SystemAccount(userName: "u", password: "it’s \"fine\" \\ \u{2028}")).isEmpty)
        XCTAssertTrue(WindowsUnattendOptions(userName: "u", password: "a’b \"<&>\"").validate().isEmpty)
    }
}
