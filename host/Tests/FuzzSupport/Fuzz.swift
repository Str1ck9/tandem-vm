import Foundation

/// SplitMix64: small, fast and seedable, so a failing fuzz case can be replayed from its seed.
public struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    public mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &self) }
    public mutating func int(_ range: Range<Int>) -> Int { Int.random(in: range, using: &self) }
    public mutating func chance(_ probability: Double) -> Bool { Double.random(in: 0..<1, using: &self) < probability }
    public mutating func pick<T>(_ items: [T]) -> T { items[int(0..<items.count)] }

    public mutating func bytes(_ count: Int) -> Data {
        var data = Data(count: count)
        for i in 0..<count { data[i] = UInt8(truncatingIfNeeded: next()) }
        return data
    }

    /// A 32-bit value that is usually one of the boundary cases parsers get wrong.
    public mutating func interesting32() -> UInt32 {
        chance(0.7) ? pick(Fuzz.interesting32) : UInt32(truncatingIfNeeded: next())
    }

    /// An integer that is usually a boundary case: zero, ±1, powers of two, the extremes.
    public mutating func interestingInt() -> Int {
        chance(0.75) ? pick(Fuzz.interestingInts) : Int(truncatingIfNeeded: next())
    }

    /// Text that trips up quoting and parsing: quotes, backslashes, control characters, markup,
    /// shell and YAML syntax, non-ASCII, very long runs.
    public mutating func awkwardString(maxLength: Int = 64) -> String {
        var s = ""
        for _ in 0..<int(0...maxLength) {
            if chance(0.5) { s += pick(Fuzz.awkwardPieces) }
            else { s.unicodeScalars.append(Unicode.Scalar(UInt8(int(0x20...0x7E)))) }
            if s.count > maxLength { break }
        }
        return s
    }
}

public enum Fuzz {
    /// How many cases a test runs: `base`, times `TANDEM_FUZZ_SCALE` for long runs
    /// (`TANDEM_FUZZ_SCALE=200 swift test --filter Fuzz`).
    public static func iterations(_ base: Int) -> Int {
        let scale = ProcessInfo.processInfo.environment["TANDEM_FUZZ_SCALE"].flatMap(Int.init) ?? 1
        return max(1, base * max(1, scale))
    }

    /// The base seed; `TANDEM_FUZZ_SEED` replays a reported failure.
    public static var seed: UInt64 {
        ProcessInfo.processInfo.environment["TANDEM_FUZZ_SEED"].flatMap { UInt64($0) } ?? 0x7A4D_2026
    }

    /// Runs `body` once per case, each with its own generator, and names the seed of a failing case.
    public static func cases(_ base: Int, _ body: (inout SeededRandom, _ seed: UInt64) throws -> Void) rethrows {
        let start = seed
        for i in 0..<iterations(base) {
            let caseSeed = start &+ UInt64(i) &* 0x2545_F491_4F6C_DD1D
            var rng = SeededRandom(seed: caseSeed)
            try body(&rng, caseSeed)
        }
    }

    public static let interesting32: [UInt32] = [
        0, 1, 2, 3, 4, 7, 8, 15, 16, 31, 32, 63, 64, 127, 128, 255, 256, 1023, 1024, 4095, 4096, 65535, 65536,
        0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFE, 0xFFFF_FFFF, 16 << 20, (16 << 20) + 1, (16 << 20) - 1,
    ]

    public static let interestingInts: [Int] = [
        0, 1, -1, 2, -2, 255, 256, 65535, 65536, -65536, 1 << 31, -(1 << 31), (1 << 32) - 1, 1 << 32,
        Int(Int32.max), Int(Int32.min), Int.max, Int.min, Int.max - 1, Int.min + 1,
    ]

    public static let awkwardPieces: [String] = [
        "\"", "'", "\\", "\\\"", "`", "$", "$(", "${", ")", "&", "&amp;", "<", ">", "</", "<![CDATA[", "]]>", "\n", "\r\n",
        "\t", "\0", "\u{1}", "\u{7F}", ":", ": ", "#", "- ", "|", "{", "}", "[", "]", ",", "%", "%00", "%2e%2e", "..", "/", "../",
        "é", "ß", "日本", "🙂", "\u{202E}", "\u{FEFF}", "\u{200B}", ";", "*", "?", "!", "~", "=", "--", "-", " ", "  ",
        String(repeating: "A", count: 300),
    ]

    /// Applies one to four random edits: bit flips, interesting bytes, inserted or removed runs,
    /// truncation, duplication.
    public static func mutate(_ input: Data, using rng: inout SeededRandom) -> Data {
        var data = input
        for _ in 0..<rng.int(1...4) {
            switch rng.int(0..<7) {
            case 0 where !data.isEmpty:
                let i = rng.int(0..<data.count); data[data.startIndex + i] ^= UInt8(1 << rng.int(0..<8))
            case 1 where !data.isEmpty:
                let i = rng.int(0..<data.count); data[data.startIndex + i] = rng.pick([0, 1, 0x7F, 0x80, 0xFF, 0x22, 0x5C, 0x0A])
            case 2:
                let at = rng.int(0...data.count); data.insert(contentsOf: rng.bytes(rng.int(1...16)), at: data.startIndex + at)
            case 3 where !data.isEmpty:
                let at = rng.int(0..<data.count); let n = min(rng.int(1...16), data.count - at)
                data.removeSubrange(data.startIndex + at..<data.startIndex + at + n)
            case 4:
                data = data.prefix(rng.int(0...data.count))
            case 5 where !data.isEmpty:
                let at = rng.int(0..<data.count); let n = min(rng.int(1...32), data.count - at)
                data.insert(contentsOf: data[data.startIndex + at..<data.startIndex + at + n], at: data.startIndex + at)
            case 6 where data.count >= 4:
                // A little-endian 32-bit field replaced by a boundary value.
                let at = rng.int(0...(data.count - 4)); var v = rng.interesting32().littleEndian
                withUnsafeBytes(of: &v) { data.replaceSubrange(data.startIndex + at..<data.startIndex + at + 4, with: $0) }
            default:
                break
            }
        }
        return data
    }

    /// JSON-aware mutation of a valid document: numbers become extremes, strings become awkward,
    /// values change type, keys go missing or repeat, arrays grow. `rate` is the chance for each value
    /// to change; `mutatedJSONData` sets it so a document gets a few edits and mostly still decodes.
    public static func mutateJSON(_ value: Any, using rng: inout SeededRandom, rate: Double = 0.1) -> Any {
        func replacement() -> Any {
            switch rng.int(0..<9) {
            case 0: return NSNull()
            case 1: return rng.chance(0.5)
            case 2: return rng.interestingInt()
            case 3: return rng.pick([1e300, -1e300, 0.5, -0.0, 1e-300, 4294967296.5, 9.3e18, -9.3e18])
            case 4: return rng.awkwardString()
            case 5: return [] as [Any]
            case 6: return [String: Any]()
            case 7: return Array(repeating: rng.awkwardString(maxLength: 8), count: rng.int(0...20))
            default: return String(repeating: "x", count: rng.int(0...5000))
            }
        }
        switch value {
        case let object as [String: Any]:
            if rng.chance(rate / 4) { return replacement() }
            var out: [String: Any] = [:]
            for (key, child) in object {
                if rng.chance(rate / 4) { continue }
                out[rng.chance(rate / 4) ? rng.awkwardString(maxLength: 8) : key] = mutateJSON(child, using: &rng, rate: rate)
            }
            if rng.chance(rate / 2) { out[rng.awkwardString(maxLength: 12)] = replacement() }
            return out
        case let array as [Any]:
            if rng.chance(rate / 4) { return replacement() }
            var out = array.map { mutateJSON($0, using: &rng, rate: rate) }
            if rng.chance(rate / 2), let first = out.first { out.append(contentsOf: Array(repeating: first, count: rng.int(1...50))) }
            if rng.chance(rate / 2), !out.isEmpty { out.removeLast() }
            return out
        default:
            guard rng.chance(rate) else { return value }
            // Mostly the same type with a nastier value, so the document still decodes and the code
            // behind the decoder gets the value; sometimes another type altogether.
            guard rng.chance(0.8) else { return replacement() }
            switch value {
            case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): return rng.chance(0.5)
            case is NSNumber: return rng.chance(0.85) ? rng.interestingInt() : rng.pick([1e300, -1e300, 0.5, -0.0, 9.3e18])
            case is String: return rng.awkwardString()
            default: return replacement()
            }
        }
    }

    static func countValues(_ value: Any) -> Int {
        switch value {
        case let object as [String: Any]: return 1 + object.values.reduce(0) { $0 + countValues($1) }
        case let array as [Any]: return 1 + array.reduce(0) { $0 + countValues($1) }
        default: return 1
        }
    }

    /// A mutated copy of a JSON document, as bytes: structurally (`mutateJSON`) or byte-wise (`mutate`).
    public static func mutatedJSONData(_ document: Data, using rng: inout SeededRandom) -> Data {
        if rng.chance(0.7), let value = try? JSONSerialization.jsonObject(with: document, options: [.fragmentsAllowed]) {
            // About one, two or four edits in the whole document.
            let rate = min(0.5, rng.pick([1.0, 2.0, 4.0]) / Double(countValues(value)))
            let mutated = mutateJSON(value, using: &rng, rate: rate)
            if let data = try? JSONSerialization.data(withJSONObject: mutated, options: [.fragmentsAllowed]) {
                return rng.chance(0.1) ? mutate(data, using: &rng) : data
            }
        }
        if rng.chance(0.05) {
            // Deep nesting.
            let depth = rng.int(100...3000)
            return Data((String(repeating: "[", count: depth) + String(repeating: "]", count: depth)).utf8)
        }
        return mutate(document, using: &rng)
    }
}
