import Foundation
import os

/// A JSON document fragment this build does not understand, kept so it can be re-emitted
/// with its value preserved (numbers are re-serialized in canonical form, e.g. `1e3`
/// becomes `1000`) (#70). `Decimal`, not `Double`, so `12` stays `12` and an id-sized
/// integer keeps every digit.
enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Decimal)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() { self = .null; return }
        if let b = try? single.decode(Bool.self) { self = .bool(b); return }
        if let s = try? single.decode(String.self) { self = .string(s); return }
        if let n = try? single.decode(Decimal.self) { self = .number(n); return }
        if let a = try? single.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? single.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                debugDescription: "not a JSON value"))
    }

    func encode(to encoder: any Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case .null: try single.encodeNil()
        case .bool(let b): try single.encode(b)
        case .number(let n): try single.encode(n)
        case .string(let s): try single.encode(s)
        case .array(let a): try single.encode(a)
        case .object(let o): try single.encode(o)
        }
    }
}

/// Any key at all — for reading the keys a typed `CodingKeys` does not name.
struct AnyCodingKey: CodingKey, Hashable {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension KeyedDecodingContainer where Key == AnyCodingKey {
    /// Every key not claimed by `known`, decoded as raw JSON. A number outside `Decimal`'s
    /// range (e.g. `1e400`) fails to decode and its key is DROPPED — the one narrow loss
    /// this preserves-unknowns design accepts, because refusing the whole record would be
    /// worse.
    func unknownFields<Known: CodingKey & CaseIterable>(except known: Known.Type) -> [String: JSONValue] {
        let claimed = Set(Known.allCases.map(\.stringValue))
        var out: [String: JSONValue] = [:]
        for key in allKeys where !claimed.contains(key.stringValue) {
            if let value = try? decode(JSONValue.self, forKey: key) {
                out[key.stringValue] = value
            } else {
                Logger(subsystem: "org.pianohouseproject.raconte", category: "coders")
                    .notice("coders: dropped unknown key \(key.stringValue, privacy: .public) — value not representable")
            }
        }
        return out
    }
}

extension KeyedEncodingContainer where Key == AnyCodingKey {
    /// Skips claimed keys, so a caller that stuffs `id`/`name` into `unknownFields`
    /// cannot overwrite an identity field (last write wins in the container).
    mutating func encodeUnknownFields<Known: CodingKey & CaseIterable>(_ fields: [String: JSONValue], except known: Known.Type) throws {
        let claimed = Set(Known.allCases.map(\.stringValue))
        for (name, value) in fields where !claimed.contains(name) {
            try encode(value, forKey: AnyCodingKey(name))
        }
    }
}
