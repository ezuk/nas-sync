import Foundation

/// The config file as text, changed one setting at a time.
///
/// Every edit rewrites only the lines of the setting it touches, so comments, blank lines and the order of
/// everything else stay exactly as they were. Edits don't check the result; call `check()` and only save
/// a document whose check has no errors. The same checker reads the file when the app starts.
public struct ConfigDocument: Sendable, Equatable {
    public private(set) var text: String

    public init(text: String) {
        self.text = text
    }

    public init(contentsOf url: URL) throws {
        text = try String(contentsOf: url, encoding: .utf8)
    }

    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Reads the document with the same checker the app uses at startup.
    public func check(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ConfigLoadResult {
        ConfigLoader.parse(text, home: home)
    }

    // MARK: Types

    /// A section of the file.
    public enum Table: Hashable, Sendable, CustomStringConvertible {
        /// `[home]`, `[nas]`, `[battery]`, `[folders]` or `[github]`.
        case named(String)
        /// The nth `[[folder]]`, counting from zero.
        case folder(Int)

        public var description: String {
            switch self {
            case .named(let n): "[\(n)]"
            case .folder(let i): "[[folder]] #\(i + 1)"
            }
        }

        /// The prefix used in checker messages, like `nas` in `'nas.path'`.
        public var keyPrefix: String {
            switch self {
            case .named(let n): n
            case .folder: "folder"
            }
        }
    }

    /// A value to write.
    public enum Value: Sendable, Equatable {
        case string(String)
        case integer(Int)
        case boolean(Bool)
        case strings([String])
        /// An inline table of strings, like `{ "acme" = "work", "*" = "other" }`, in this order.
        case stringTable([Pair])

        public struct Pair: Sendable, Equatable {
            public var key: String
            public var value: String

            public init(_ key: String, _ value: String) {
                self.key = key
                self.value = value
            }
        }

        public var toml: String {
            switch self {
            case .string(let s): ConfigDocument.quote(s)
            case .integer(let i): String(i)
            case .boolean(let b): b ? "true" : "false"
            case .strings(let list): "[" + list.map(ConfigDocument.quote).joined(separator: ", ") + "]"
            case .stringTable(let pairs):
                pairs.isEmpty ? "{}" : "{ " + pairs.map { "\(ConfigDocument.quote($0.key)) = \(ConfigDocument.quote($0.value))" }.joined(separator: ", ") + " }"
            }
        }
    }

    public struct EditError: LocalizedError, Equatable {
        public var errorDescription: String?
    }

    /// Order sections are added in, when the file doesn't have them yet.
    static let sectionOrder = ["home", "nas", "battery", "folders", "folder", "github"]

    // MARK: Reading

    /// The 1-based line a setting starts on, if the file sets it.
    public func line(of key: String, in table: Table) -> Int? {
        let lines = Self.lines(text)
        let statements = Self.lex(lines)
        guard let range = Self.range(of: table, in: statements) else { return nil }
        return statements[range].first { $0.key == key }.map { $0.first + 1 }
    }

    /// The 1-based line of a section's header.
    public func line(of table: Table) -> Int? {
        let statements = Self.lex(Self.lines(text))
        return Self.headerIndex(of: table, in: statements).map { statements[$0].first + 1 }
    }

    /// Number of `[[folder]]` sections.
    public var folderCount: Int {
        Self.lex(Self.lines(text)).filter { $0.header == "folder" && $0.isArrayHeader }.count
    }

    // MARK: Editing

    /// Sets a value, or removes the setting when `value` is nil.
    ///
    /// An existing setting is changed in place and keeps its trailing comment. A missing one replaces a
    /// commented-out line for the same key if the section has one (as the starter file does), and is
    /// otherwise added after the section's last setting. A missing section is added in the usual order.
    public mutating func set(_ key: String, in table: Table, to value: Value?) throws {
        var lines = Self.lines(text)
        let statements = Self.lex(lines)

        guard let headerIdx = Self.headerIndex(of: table, in: statements) else {
            guard let value else { return }
            guard case .named(let name) = table else {
                throw EditError(errorDescription: "The config has no \(table).")
            }
            // The starter file has some sections commented out, like `# [github]`. Bring that one back so its
            // commented settings and their explanations are in place, then set the value inside it.
            if let i = lines.firstIndex(where: { Self.isCommentedHeader($0, name: name) }) {
                lines[i] = "[\(name)]" + (Self.lex([Self.stripComment(lines[i])]).first?.comment.map { "  " + $0 } ?? "")
                text = lines.joined(separator: "\n")
                try set(key, in: table, to: value)
                return
            }
            insertSection(name, body: ["\(Self.bareOrQuoted(key)) = \(value.toml)"], lines: &lines, statements: statements)
            text = lines.joined(separator: "\n")
            return
        }
        let range = Self.range(after: headerIdx, in: statements)

        if let s = statements[range].first(where: { $0.key == key }) {
            if let value {
                lines.replaceSubrange(s.first...s.last, with: Self.rewrite(s, lines: lines, value: value))
            } else {
                lines.removeSubrange(s.first...s.last)
            }
            text = lines.joined(separator: "\n")
            return
        }
        guard let value else { return }

        // A commented-out line for this key, like `# at_most_every = "1h"   # explanation`.
        let firstLine = statements[headerIdx].last + 1
        let endLine = range.isEmpty ? firstLine : statements[range].last!.last + 1
        if firstLine < endLine {
            for i in firstLine..<endLine {
                // A commented-out section below belongs to that section, not this one.
                if Self.isCommentedHeader(lines[i], name: nil) { break }
                if let replacement = Self.uncommented(lines[i], key: key, value: value) {
                    lines[i] = replacement
                    text = lines.joined(separator: "\n")
                    return
                }
            }
        }

        let lastSetting = statements[range].last { $0.key != nil || $0.isHeader }
        let insertAt = (lastSetting?.last ?? statements[headerIdx].last) + 1
        lines.insert("\(Self.bareOrQuoted(key)) = \(value.toml)", at: insertAt)
        text = lines.joined(separator: "\n")
    }

    /// Returns a copy with the value set.
    public func setting(_ key: String, in table: Table, to value: Value?) throws -> ConfigDocument {
        var copy = self
        try copy.set(key, in: table, to: value)
        return copy
    }

    /// Adds a `[[folder]]` after the last one and returns its index.
    @discardableResult
    public mutating func addFolder(name: String, source: String, dest: String) -> Int {
        var lines = Self.lines(text)
        let statements = Self.lex(lines)
        let body = ["name = \(Self.quote(name))", "source = \(Self.quote(source))", "dest = \(Self.quote(dest))"]
        let folderHeaders = statements.indices.filter { statements[$0].header == "folder" && statements[$0].isArrayHeader }
        if let last = folderHeaders.last {
            let end = Self.blockEnd(after: last, in: statements, lines: lines) + 1
            lines.insert(contentsOf: [""] + ["[[folder]]"] + body, at: end)
        } else {
            insertSection("folder", body: body, lines: &lines, statements: statements, isArray: true)
        }
        text = lines.joined(separator: "\n")
        return folderHeaders.count
    }

    /// Removes the nth `[[folder]]` with its settings and the blank lines after it.
    public mutating func removeFolder(_ index: Int) throws {
        var lines = Self.lines(text)
        let statements = Self.lex(lines)
        guard let headerIdx = Self.headerIndex(of: .folder(index), in: statements) else {
            throw EditError(errorDescription: "The config has no \(Table.folder(index)).")
        }
        var end = Self.blockEnd(after: headerIdx, in: statements, lines: lines)
        while end + 1 < lines.count, lines[end + 1].trimmingCharacters(in: .whitespaces).isEmpty { end += 1 }
        var start = statements[headerIdx].first
        // Drop the blank line before it too when the section is followed by nothing.
        if end == lines.count - 1, start > 0, lines[start - 1].trimmingCharacters(in: .whitespaces).isEmpty { start -= 1 }
        lines.removeSubrange(start...end)
        text = lines.joined(separator: "\n")
    }

    // MARK: Writing helpers

    /// The last line of a section's own block: its last setting plus any comment lines right under it.
    /// Comments after a blank line are left out, since they usually introduce what comes next.
    static func blockEnd(after header: Int, in statements: [Statement], lines: [String]) -> Int {
        let r = Self.range(after: header, in: statements)
        var end = (statements[r].last { $0.key != nil })?.last ?? statements[header].last
        while end + 1 < lines.count {
            let t = lines[end + 1].trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("#"), !isCommentedHeader(lines[end + 1], name: nil) else { break }
            end += 1
        }
        return end
    }

    /// `# [github]`, or any commented-out header when `name` is nil.
    static func isCommentedHeader(_ line: String, name: String?) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("#") else { return false }
        let inner = stripComment(line).trimmingCharacters(in: .whitespaces)
        guard inner.hasPrefix("["), let close = inner.firstIndex(of: "]") else { return false }
        let n = inner[inner.index(after: inner.startIndex)..<close]
        guard let name else { return !n.isEmpty }
        return normalizeKey(String(n)) == name
    }

    /// The text after the leading `#` marks of a comment line.
    static func stripComment(_ line: String) -> String {
        var rest = Substring(line.drop { $0 == " " || $0 == "\t" })
        while rest.first == "#" { rest = rest.dropFirst() }
        return String(rest.drop { $0 == " " || $0 == "\t" })
    }

    private mutating func insertSection(_ name: String, body: [String], lines: inout [String], statements: [Statement], isArray: Bool = false) {
        let header = isArray ? "[[\(name)]]" : "[\(name)]"
        let rank = Self.sectionOrder.firstIndex(of: name.split(separator: ".").first.map(String.init) ?? name) ?? Self.sectionOrder.count
        let later = statements.first { s in
            guard let h = s.header, let base = h.split(separator: ".").first.map(String.init) else { return false }
            return (Self.sectionOrder.firstIndex(of: base) ?? Self.sectionOrder.count) > rank
        }
        var block = [header] + body
        if var at = later?.first {
            // Keep comments directly above the next section with it.
            while at > 0, lines[at - 1].trimmingCharacters(in: .whitespaces).hasPrefix("#") { at -= 1 }
            block.append("")
            if at > 0, !lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty { block.insert("", at: 0) }
            lines.insert(contentsOf: block, at: at)
        } else {
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            if !lines.isEmpty { block.insert("", at: 0) }
            lines.append(contentsOf: block)
            lines.append("")
        }
    }

    /// The new lines for a setting, keeping its key spelling, indentation and trailing comment.
    static func rewrite(_ s: Statement, lines: [String], value: Value) -> [String] {
        let first = lines[s.first]
        let eq = s.equalsOffset ?? first.count
        let prefix = String(first.prefix(eq)) + "= "
        let comment = s.comment
        if s.first != s.last, case .strings(let list) = value {
            // Keep a list that was written one item per line that way.
            let inner = s.first + 1 < s.last ? lines[s.first + 1] : ""
            var indent = String(inner.prefix { $0 == " " || $0 == "\t" })
            if indent.isEmpty { indent = "  " }
            let closingIndent = String(first.prefix { $0 == " " || $0 == "\t" })
            var out = [prefix + "["]
            out += list.map { indent + quote($0) + "," }
            out.append(closingIndent + "]" + (comment.map { "  " + $0 } ?? ""))
            return out
        }
        return [withComment(prefix + value.toml, comment: comment, column: s.commentColumn)]
    }

    static func withComment(_ code: String, comment: String?, column: Int?) -> String {
        guard let comment else { return code }
        let pad = column.map { $0 - code.count } ?? 2
        return code + String(repeating: " ", count: max(pad, 2)) + comment
    }

    /// `# key = old   # note` becomes `key = new   # note`.
    static func uncommented(_ line: String, key: String, value: Value) -> String? {
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        var rest = Substring(line.dropFirst(indent.count))
        guard rest.hasPrefix("#") else { return nil }
        while rest.first == "#" { rest = rest.dropFirst() }
        rest = rest.drop { $0 == " " || $0 == "\t" }
        let candidate = String(rest)
        let statements = lex([candidate])
        guard statements.count == 1, let s = statements.first, s.key == key else { return nil }
        // Ignore lines that only look like a setting, such as prose with an equals sign.
        guard (try? TOMLParser.parse(candidate.prefix(s.commentOffset ?? candidate.count).description)) != nil else { return nil }
        let keyText = candidate.prefix(s.equalsOffset ?? candidate.count).trimmingCharacters(in: .whitespaces)
        let code = indent + keyText + " = " + value.toml
        let column = s.commentColumn.map { $0 + (line.count - candidate.count) }
        return withComment(code, comment: s.comment, column: column)
    }

    public static func quote(_ s: String) -> String {
        var out = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if c.value < 0x20 || c.value == 0x7f {
                    out += String(format: "\\u%04X", c.value)
                } else {
                    out.unicodeScalars.append(c)
                }
            }
        }
        return out + "\""
    }

    static func bareOrQuoted(_ key: String) -> String {
        let bare = !key.isEmpty && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
        return bare ? key : quote(key)
    }

    // MARK: Lexing

    /// The file split into lines, as edits count them.
    public static func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    /// One TOML statement: a header, a setting (which can span lines), or a blank or comment line.
    struct Statement: Equatable {
        /// First and last line, 0-based.
        var first: Int
        var last: Int
        /// Table name for a header, such as `github` or `folder`.
        var header: String?
        var isArrayHeader = false
        /// Key for a setting. Dotted keys keep their dots.
        var key: String?
        /// Offset of the `=` in the first line.
        var equalsOffset: Int?
        /// The trailing comment on the last line, starting with `#`.
        var comment: String?
        /// Offset of that comment in the last line.
        var commentOffset: Int?

        var isHeader: Bool { header != nil }
        var commentColumn: Int? { commentOffset }
    }

    private enum StringState: Equatable { case none, basic, literal, multiBasic, multiLiteral }

    /// Splits lines into statements, following strings and brackets so multi-line lists stay together.
    static func lex(_ lines: [String]) -> [Statement] {
        var out: [Statement] = []
        var i = 0
        while i < lines.count {
            let chars = Array(lines[i])
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                out.append(Statement(first: i, last: i))
                i += 1
                continue
            }
            if trimmed.hasPrefix("[") {
                var s = Statement(first: i, last: i)
                let isArray = trimmed.hasPrefix("[[")
                var body = trimmed.dropFirst(isArray ? 2 : 1)
                if let close = body.firstIndex(of: "]") { body = body[..<close] }
                s.header = normalizeKey(String(body))
                s.isArrayHeader = isArray
                let (_, comment) = scan(chars, from: 0, depth: 0, state: .none)
                if let comment { s.comment = String(chars[comment...]); s.commentOffset = comment }
                out.append(s)
                i += 1
                continue
            }
            // key = value
            var s = Statement(first: i, last: i)
            var k = 0
            var quote: Character?
            while k < chars.count {
                let c = chars[k]
                if let q = quote {
                    if c == q { quote = nil }
                } else if c == "\"" || c == "'" {
                    quote = c
                } else if c == "=" {
                    break
                }
                k += 1
            }
            guard k < chars.count else {
                out.append(Statement(first: i, last: i))
                i += 1
                continue
            }
            s.key = normalizeKey(String(chars[..<k]))
            s.equalsOffset = k
            var (state, comment) = scan(chars, from: k + 1, depth: 0, state: .none)
            var line = i
            while state.depth > 0 || state.string == .multiBasic || state.string == .multiLiteral, line + 1 < lines.count {
                line += 1
                let next = Array(lines[line])
                (state, comment) = scan(next, from: 0, depth: state.depth, state: state.string)
            }
            s.last = line
            if let comment {
                let lastChars = Array(lines[line])
                s.comment = String(lastChars[comment...])
                s.commentOffset = comment
            }
            out.append(s)
            i = line + 1
        }
        return out
    }

    /// Scans part of a line. Returns the bracket depth and string state at its end, and where a comment
    /// starts if the line ends outside every bracket.
    private static func scan(_ chars: [Character], from start: Int, depth: Int, state: StringState) -> ((depth: Int, string: StringState), Int?) {
        var depth = depth
        var string = state
        var k = start
        var comment: Int?
        func at(_ s: String) -> Bool {
            let a = Array(s)
            return k + a.count <= chars.count && Array(chars[k..<k + a.count]) == a
        }
        while k < chars.count {
            let c = chars[k]
            switch string {
            case .basic:
                if c == "\\" { k += 1 } else if c == "\"" { string = .none }
            case .literal:
                if c == "'" { string = .none }
            case .multiBasic:
                if c == "\\" { k += 1 } else if at("\"\"\"") { string = .none; k += 2 }
            case .multiLiteral:
                if at("'''") { string = .none; k += 2 }
            case .none:
                if at("\"\"\"") { string = .multiBasic; k += 2 }
                else if at("'''") { string = .multiLiteral; k += 2 }
                else if c == "\"" { string = .basic }
                else if c == "'" { string = .literal }
                else if c == "[" || c == "{" { depth += 1 }
                else if c == "]" || c == "}" { depth -= 1 }
                else if c == "#" {
                    comment = k
                    k = chars.count
                    continue
                }
            }
            k += 1
        }
        // A single-line string can't continue on the next line.
        if string == .basic || string == .literal { string = .none }
        return ((max(depth, 0), string), depth <= 0 ? comment : nil)
    }

    /// `"a" . b` becomes `a.b`.
    static func normalizeKey(_ raw: String) -> String {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        for c in raw {
            if let q = quote {
                if c == q { quote = nil } else { current.append(c) }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "." {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(c)
            }
        }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        return parts.joined(separator: ".")
    }

    static func headerIndex(of table: Table, in statements: [Statement]) -> Int? {
        switch table {
        case .named(let name):
            return statements.firstIndex { $0.header == name && !$0.isArrayHeader }
        case .folder(let n):
            let headers = statements.indices.filter { statements[$0].header == "folder" && statements[$0].isArrayHeader }
            return n >= 0 && n < headers.count ? headers[n] : nil
        }
    }

    /// Statements after a header, up to the next header.
    static func range(after header: Int, in statements: [Statement]) -> Range<Int> {
        let end = statements[(header + 1)...].firstIndex { $0.isHeader } ?? statements.count
        return (header + 1)..<end
    }

    static func range(of table: Table, in statements: [Statement]) -> Range<Int>? {
        headerIndex(of: table, in: statements).map { range(after: $0, in: statements) }
    }
}
