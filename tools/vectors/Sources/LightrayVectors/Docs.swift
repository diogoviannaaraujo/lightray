import Foundation

public struct DocIssue: Sendable, CustomStringConvertible {
    public let file: String
    public let line: Int
    public let message: String

    public var description: String { "\(file):\(line): \(message)" }
}

/// Keeps the documents honest. A fenced block preceded by `<!-- vector: name -->` must match
/// that vector exactly, and every relative link must name a file, and a heading, that exists.
public enum Docs {
    public struct Report: Sendable {
        public var issues: [DocIssue] = []
        public var blocksChecked = 0
        public var namesUsed: Set<String> = []
        public var filesUpdated: [String] = []
    }

    /// Checks every Markdown file in `directory`. With `update`, a mismatched block is rewritten
    /// from its vector instead of being reported.
    public static func process(directory: URL, blocks: [String: String], update: Bool) throws -> Report {
        var report = Report()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var headings = HeadingCache()
        for file in files {
            let name = file.lastPathComponent
            let text = try String(contentsOf: file, encoding: .utf8)
            var lines = text.components(separatedBy: "\n")
            var changed = false
            var inFence = false
            var index = 0
            while index < lines.count {
                let line = lines[index]
                if !inFence, let vector = marker(line) {
                    report.namesUsed.insert(vector)
                    var open = index + 1
                    while open < lines.count, lines[open].trimmingCharacters(in: .whitespaces).isEmpty { open += 1 }
                    guard open < lines.count, isFence(lines[open]) else {
                        report.issues.append(DocIssue(file: name, line: index + 1, message: "marker for \(vector) is not followed by a code block"))
                        index += 1
                        continue
                    }
                    var close = open + 1
                    while close < lines.count, !isFence(lines[close]) { close += 1 }
                    guard close < lines.count else {
                        report.issues.append(DocIssue(file: name, line: open + 1, message: "code block for \(vector) is never closed"))
                        break
                    }
                    let found = lines[(open + 1)..<close].map(trimTrailing).joined(separator: "\n")
                    report.blocksChecked += 1
                    if let expected = blocks[vector] {
                        if found != expected {
                            if update {
                                let replacement = expected.components(separatedBy: "\n")
                                lines.replaceSubrange((open + 1)..<close, with: replacement)
                                close = open + 1 + replacement.count
                                changed = true
                            } else {
                                report.issues.append(DocIssue(file: name, line: open + 2, message: "block differs from vector \(vector)"))
                            }
                        }
                    } else {
                        report.issues.append(DocIssue(file: name, line: index + 1, message: "unknown vector \(vector)"))
                    }
                    index = close + 1
                    continue
                }
                if isFence(line) {
                    inFence.toggle()
                } else if !inFence {
                    for target in links(in: line) {
                        if let problem = checkLink(target, from: file, headings: &headings) {
                            report.issues.append(DocIssue(file: name, line: index + 1, message: problem))
                        }
                    }
                }
                index += 1
            }
            if changed {
                try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
                report.filesUpdated.append(name)
            }
        }
        return report
    }

    static func marker(_ line: String) -> String? {
        let pattern = #/^\s*<!--\s*vector:\s*([A-Za-z0-9._-]+)\s*-->\s*$/#
        guard let match = line.wholeMatch(of: pattern) else { return nil }
        return String(match.1)
    }

    static func isFence(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
    }

    static func trimTrailing(_ line: String) -> String {
        var line = line
        while let last = line.last, last.isWhitespace { line.removeLast() }
        return line
    }

    /// The targets of the inline links on a line, ignoring anything inside code spans.
    static func links(in line: String) -> [String] {
        let withoutCode = line.replacing(#/`[^`]*`/#, with: "")
        return withoutCode.matches(of: #/\]\(([^)\s]+)(?:\s+"[^"]*")?\)/#).map { String($0.1) }
    }

    static func checkLink(_ target: String, from file: URL, headings: inout HeadingCache) -> String? {
        if target.contains("://") || target.hasPrefix("mailto:") { return nil }
        let parts = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(parts[0])
        let anchor = parts.count > 1 ? String(parts[1]) : nil
        let resolved = path.isEmpty
            ? file
            : URL(fileURLWithPath: path, relativeTo: file.deletingLastPathComponent()).standardizedFileURL
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            return "broken link: \(target)"
        }
        if let anchor, resolved.pathExtension == "md", !headings.slugs(of: resolved).contains(anchor) {
            return "broken anchor: \(target)"
        }
        return nil
    }

    /// GitHub's heading anchor: lowercase, punctuation dropped, spaces turned into hyphens.
    public static func slug(_ heading: String) -> String {
        let text = heading.replacing(#/\[([^\]]*)\]\([^)]*\)/#) { String($0.1) }
        var out = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                out.append(character)
            } else if character == " " {
                out.append("-")
            }
        }
        return out
    }

    struct HeadingCache {
        private var cache: [URL: Set<String>] = [:]

        mutating func slugs(of file: URL) -> Set<String> {
            if let known = cache[file] { return known }
            var slugs = Set<String>()
            var counts: [String: Int] = [:]
            var inFence = false
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            for line in text.components(separatedBy: "\n") {
                if Docs.isFence(line) {
                    inFence.toggle()
                    continue
                }
                guard !inFence, let match = line.wholeMatch(of: #/#{1,6}\s+(.*?)\s*#*\s*/#) else { continue }
                let base = Docs.slug(String(match.1))
                let count = counts[base, default: 0]
                counts[base] = count + 1
                slugs.insert(count == 0 ? base : "\(base)-\(count)")
            }
            cache[file] = slugs
            return slugs
        }
    }
}
