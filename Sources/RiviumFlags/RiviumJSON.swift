import Foundation

/// A JSON value as served by Rivium Flags (`json` flags, attributes, cached results).
///
/// Literal-friendly: `let fallback: RiviumJSON = ["layout": "grid", "columns": 3]`.
public enum RiviumJSON: Equatable, Hashable, Codable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([RiviumJSON])
    case object([String: RiviumJSON])

    // MARK: Accessors

    public var boolValue: Bool? { if case .bool(let v) = self { return v }; return nil }
    public var numberValue: Double? { if case .number(let v) = self { return v }; return nil }
    public var intValue: Int? { numberValue.flatMap { $0.rounded() == $0 && abs($0) < 9.0e15 ? Int($0) : nil } }
    public var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    public var arrayValue: [RiviumJSON]? { if case .array(let v) = self { return v }; return nil }
    public var objectValue: [String: RiviumJSON]? { if case .object(let v) = self { return v }; return nil }
    public var isNull: Bool { self == .null }

    public subscript(key: String) -> RiviumJSON? { objectValue?[key] }
    public subscript(index: Int) -> RiviumJSON? {
        guard let a = arrayValue, a.indices.contains(index) else { return nil }
        return a[index]
    }

    /// Foundation representation (`NSNull` for null, `[String: Any]`, `[Any]`, `Double`, `Bool`, `String`).
    public var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let v): return v
        case .number(let v): return v
        case .string(let v): return v
        case .array(let v): return v.map { $0.anyValue }
        case .object(let v): return v.mapValues { $0.anyValue }
        }
    }

    /// Decodes this value into a `Decodable` type.
    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Converts a Foundation / Swift value. Returns nil for unsupported values (dates, NaN, custom types).
    public init?(any value: Any?) {
        guard let value = value else { self = .null; return }
        if let j = value as? RiviumJSON { self = j; return }
        if value is NSNull { self = .null; return }
        // NSNumber bridging: tell booleans apart from numbers.
        if let n = value as? NSNumber, !(value is String) {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue); return }
            let d = n.doubleValue
            guard d.isFinite else { return nil }
            self = .number(d)
            return
        }
        if let b = value as? Bool { self = .bool(b); return }
        if let s = value as? String { self = .string(s); return }
        if let s = value as? Substring { self = .string(String(s)); return }
        if let i = value as? Int { self = .number(Double(i)); return }
        if let d = value as? Double { guard d.isFinite else { return nil }; self = .number(d); return }
        if let f = value as? Float { guard f.isFinite else { return nil }; self = .number(Double(f)); return }
        if let a = value as? [Any?] {
            var out: [RiviumJSON] = []
            for item in a { guard let j = RiviumJSON(any: item) else { return nil }; out.append(j) }
            self = .array(out)
            return
        }
        if let o = value as? [String: Any?] {
            var out: [String: RiviumJSON] = [:]
            for (k, v) in o { guard let j = RiviumJSON(any: v) else { return nil }; out[k] = j }
            self = .object(out)
            return
        }
        return nil
    }

    // MARK: Codable

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([RiviumJSON].self) { self = .array(a); return }
        if let o = try? c.decode([String: RiviumJSON].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

extension RiviumJSON: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: RiviumJSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, RiviumJSON)...) {
        var o: [String: RiviumJSON] = [:]
        for (k, v) in elements { o[k] = v }
        self = .object(o)
    }
}
