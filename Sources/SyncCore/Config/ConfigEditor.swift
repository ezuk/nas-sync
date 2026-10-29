import Foundation

/// Small, comment-preserving edits to the config file.
public enum ConfigEditor {
    public struct EditError: LocalizedError {
        public var errorDescription: String?
    }

    public static func addRemoteOnly(_ repo: String, in url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        let updated = try addRemoteOnly(repo, to: text)
        try updated.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Adds `owner/repo` to `github.remote_only`. The result is checked by parsing it before it's returned.
    public static func addRemoteOnly(_ repo: String, to text: String) throws -> String {
        var lines = text.components(separatedBy: "\n")
        guard let header = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[github]") }) else {
            throw EditError(errorDescription: "The config has no [github] section. Add one first.")
        }
        var end = lines.count
        for i in (header + 1)..<lines.count where lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("[") {
            end = i
            break
        }
        let quoted = "\"\(repo)\""
        if let i = (header + 1..<end).first(where: { key(of: lines[$0]) == "remote_only" }) {
            let line = lines[i]
            if line.contains(quoted) { return text }
            if let close = closingBracket(in: line) {
                let open = line.firstIndex(of: "[")!
                let inner = line[line.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
                let insert = inner.isEmpty ? quoted : (inner.hasSuffix(",") ? " " : ", ") + quoted
                var l = line
                l.insert(contentsOf: insert, at: inner.isEmpty ? close : l[..<close].lastIndex { !$0.isWhitespace }.map { l.index(after: $0) } ?? close)
                lines[i] = l
            } else {
                // Multi-line array: add before the line that closes it.
                guard let closeLine = (i + 1..<end).first(where: { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("]") }) else {
                    throw EditError(errorDescription: "Couldn't find the end of remote_only in the config.")
                }
                let indent = closeLine > i + 1 ? String(lines[i + 1].prefix { $0 == " " || $0 == "\t" }) : "  "
                if closeLine > i + 1 {
                    let prev = closeLine - 1
                    let trimmed = lines[prev].trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty, !trimmed.hasSuffix(","), !trimmed.hasPrefix("#") { lines[prev] += "," }
                }
                lines.insert("\(indent)\(quoted),", at: closeLine)
            }
        } else {
            var insertAt = end
            while insertAt > header + 1, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty { insertAt -= 1 }
            lines.insert("remote_only = [\(quoted)]", at: insertAt)
        }
        let result = lines.joined(separator: "\n")
        let check = ConfigLoader.parse(result)
        guard check.errors.isEmpty, check.config?.github?.remoteOnly.contains(repo) == true else {
            throw EditError(errorDescription: "Adding the repo would make the config invalid, so nothing was changed.")
        }
        return result
    }

    private static func key(of line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { return nil }
        return t[..<eq].trimmingCharacters(in: .whitespaces)
    }

    /// The `]` that closes an array opened on this line, ignoring brackets inside strings and comments.
    private static func closingBracket(in line: String) -> String.Index? {
        var depth = 0
        var inString = false
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            if inString {
                if c == "\\" { i = line.index(after: i) } else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "#" {
                return nil
            } else if c == "[" {
                depth += 1
            } else if c == "]" {
                depth -= 1
                if depth == 0 { return i }
            }
            if i < line.endIndex { i = line.index(after: i) }
        }
        return nil
    }
}
