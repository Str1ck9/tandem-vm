import Foundation

/// Any JSON value. The control protocol and the MCP server pass loosely shaped data around; this keeps
/// it typed enough to read safely and to encode without `JSONSerialization`'s `Any`.
public enum JSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            // Whole numbers go out without a fraction, so ids and counts read naturally.
            if n.rounded() == n, abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    // MARK: Reading

    public subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var double: Double? { if case .number(let n) = self { return n }; return nil }
    /// The number as an integer, or nil when it has no integer value (`1e300`, which `Int(_:)` would
    /// trap on: a client could crash the app with `"timeout": 1e300`).
    public var int: Int? { double.flatMap { $0.isFinite && abs($0) < 9.2e18 ? Int($0) : nil } }
    public var array: [JSON]? { if case .array(let a) = self { return a }; return nil }
    public var object: [String: JSON]? { if case .object(let o) = self { return o }; return nil }

    // MARK: Building

    public init(_ s: String) { self = .string(s) }
    public init(_ b: Bool) { self = .bool(b) }
    public init(_ n: Int) { self = .number(Double(n)) }
    public init(_ n: Double) { self = .number(n) }
    public init(_ a: [JSON]) { self = .array(a) }
    public init(_ o: [String: JSON]) { self = .object(o) }
    public static func optional(_ s: String?) -> JSON { s.map(JSON.string) ?? .null }

    /// Compact, key-sorted JSON on one line.
    public func encodedLine() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }

    public func pretty() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    public static func decode(_ data: Data) throws -> JSON { try JSONDecoder().decode(JSON.self, from: data) }
}
