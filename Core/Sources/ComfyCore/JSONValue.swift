import Foundation

public enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case integer(Int64)
    case unsigned(UInt64)
    case decimal(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(UInt64.self) { self = .unsigned(value) }
        else if let value = try? container.decode(Double.self) { self = .decimal(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .unsigned(let value): try container.encode(value)
        case .decimal(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public var object: [String: JSONValue]? { if case .object(let value) = self { return value }; return nil }
    public var array: [JSONValue]? { if case .array(let value) = self { return value }; return nil }
    public var bool: Bool? { if case .bool(let value) = self { return value }; return nil }
    public var double: Double? {
        switch self {
        case .integer(let value): return Double(value)
        case .unsigned(let value): return Double(value)
        case .decimal(let value): return value
        default: return nil
        }
    }
    public var string: String? { if case .string(let value) = self { return value }; return nil }
    public var text: String {
        switch self {
        case .string(let value): return value
        case .integer(let value): return String(value)
        case .unsigned(let value): return String(value)
        case .decimal(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        default: return ""
        }
    }
    public var isLink: Bool {
        guard case .array(let values) = self, values.count == 2 else { return false }
        guard values[0].string != nil, let port = values[1].double, port.isFinite, port >= 0, port.rounded() == port else { return false }
        return port < Double(Int.max)
    }
    public subscript(_ key: String) -> JSONValue? { object?[key] }
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
public enum ComfyError: LocalizedError {
    case invalid(String)
    case server(Int, String)
    case uncertainSubmission
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .server(let status, let message): return "服务器返回 \(status)：\(message)"
        case .uncertainSubmission: return "服务器可能已收到任务，但未能确认。请先检查电脑队列，不要直接重复生成。"
        }
    }
}
