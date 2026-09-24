/// Just enough JSON for `vectors.json`: object keys keep their order, so the file is stable.
public indirect enum JSONValue: Sendable {
    case string(String)
    case int(UInt64)
    case hex(Bytes)
    case array([JSONValue])
    case object([(String, JSONValue)])

    public func rendered(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        let inner = String(repeating: "  ", count: indent + 1)
        switch self {
        case .string(let text):
            return Self.quoted(text)
        case .int(let value):
            return String(value)
        case .hex(let bytes):
            return Self.quoted(bytes.hex)
        case .array(let items):
            if items.isEmpty { return "[]" }
            let body = items.map { inner + $0.rendered(indent: indent + 1) }.joined(separator: ",\n")
            return "[\n" + body + "\n" + pad + "]"
        case .object(let members):
            if members.isEmpty { return "{}" }
            let body = members.map { key, value in
                inner + Self.quoted(key) + ": " + value.rendered(indent: indent + 1)
            }.joined(separator: ",\n")
            return "{\n" + body + "\n" + pad + "}"
        }
    }

    private static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case _ where scalar.value < 0x20:
                out += "\\u" + String(repeating: "0", count: 4 - String(scalar.value, radix: 16).count)
                    + String(scalar.value, radix: 16)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
