import Darwin
import Foundation

/// Shared validation for the launcher and CLI; malformed ports never fall back silently.
public struct ConnectionTarget: Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public enum ParseError: Error { case invalidHost, invalidPort }
    public var address: String { "\(host.contains(":") ? "[\(host)]" : host):\(port)" }

    public init(_ text: String, defaultPort: UInt16 = 7373) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 300, !text.contains(where: { $0.isWhitespace }), !text.utf8.contains(0) else { throw ParseError.invalidHost }
        var host = text
        var port = defaultPort
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { throw ParseError.invalidHost }
            host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            if !rest.isEmpty {
                guard rest.hasPrefix(":"), let parsed = UInt16(rest.dropFirst()), parsed != 0 else { throw ParseError.invalidPort }
                port = parsed
            }
            guard host.contains(":") else { throw ParseError.invalidHost }
        } else if text.filter({ $0 == ":" }).count == 1, let colon = text.firstIndex(of: ":") {
            host = String(text[..<colon])
            guard let parsed = UInt16(text[text.index(after: colon)...]), parsed != 0 else { throw ParseError.invalidPort }
            port = parsed
        }
        if host.contains(":") {
            let parts = host.split(separator: "%", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { throw ParseError.invalidHost }
            var value = in6_addr()
            guard inet_pton(AF_INET6, String(parts[0]), &value) == 1 else { throw ParseError.invalidHost }
            if parts.count == 2 {
                guard !parts[1].isEmpty, parts[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == ".") }) else { throw ParseError.invalidHost }
            }
        } else {
            guard !host.isEmpty, host.utf8.count <= 253 else { throw ParseError.invalidHost }
            let labels = host.hasSuffix(".") ? host.dropLast().split(separator: ".", omittingEmptySubsequences: false) : host.split(separator: ".", omittingEmptySubsequences: false)
            guard labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 && $0.first != "-" && $0.last != "-" && $0.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) }) else { throw ParseError.invalidHost }
            if labels.count == 4, labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
                var value = in_addr()
                guard labels.allSatisfy({ UInt8($0).map { String($0) } == String($0) }), inet_pton(AF_INET, host, &value) == 1 else { throw ParseError.invalidHost }
            }
        }
        guard port != 0 else { throw ParseError.invalidPort }
        self.host = host
        self.port = port
    }
}
