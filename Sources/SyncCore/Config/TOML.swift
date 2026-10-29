import Foundation

/// A parsed TOML value that remembers the line it was defined on.
public struct TOMLNode: Sendable, Equatable {
    public indirect enum Value: Sendable, Equatable {
        case string(String)
        case integer(Int)
        case float(Double)
        case boolean(Bool)
        case array([TOMLNode])
        case table(TOMLTable)
    }

    public var value: Value
    public var line: Int

    public init(_ value: Value, line: Int) {
        self.value = value
        self.line = line
    }

    public var typeName: String {
        switch value {
        case .string: "string"
        case .integer: "integer"
        case .float: "number"
        case .boolean: "true/false"
        case .array: "list"
        case .table: "table"
        }
    }
}

/// An ordered TOML table.
public struct TOMLTable: Sendable, Equatable {
    public private(set) var keys: [String] = []
    private var storage: [String: TOMLNode] = [:]
    /// Line of the table header, or of the first key for inline and root tables.
    public var line: Int

    public init(line: Int) {
        self.line = line
    }

    public subscript(key: String) -> TOMLNode? {
        get { storage[key] }
        set {
            if storage[key] == nil, newValue != nil { keys.append(key) }
            if newValue == nil { keys.removeAll { $0 == key } }
            storage[key] = newValue
        }
    }

    public var entries: [(key: String, node: TOMLNode)] {
        keys.compactMap { key in storage[key].map { (key, $0) } }
    }
}

public struct TOMLError: Error, Equatable, CustomStringConvertible {
    public var line: Int
    public var message: String

    public var description: String { "line \(line): \(message)" }
}

/// Parser for the subset of TOML 1.0 used by config files: tables, arrays of tables,
/// dotted keys, strings, integers, floats, booleans, arrays and inline tables.
/// Dates and times are not supported.
public struct TOMLParser {
    private let chars: [Character]
    private var pos = 0
    private var line = 1

    public static func parse(_ text: String) throws(TOMLError) -> TOMLTable {
        var parser = TOMLParser(text: text)
        return try parser.parseDocument()
    }

    private init(text: String) {
        chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n"))
    }

    // MARK: Document

    private mutating func parseDocument() throws(TOMLError) -> TOMLTable {
        var root = TOMLTable(line: 1)
        var currentPath: [String] = []
        var currentIsArrayItem = false
        var definedTables: Set<[String]> = []

        while true {
            skipWhitespaceCommentsAndNewlines()
            guard let c = peek() else { break }

            if c == "[" {
                let headerLine = line
                advance()
                let isArray = peek() == "["
                if isArray { advance() }
                skipInlineWhitespace()
                let path = try parseKeyPath()
                skipInlineWhitespace()
                try expect("]")
                if isArray { try expect("]") }
                try expectLineEnd()

                if isArray {
                    try appendArrayTable(&root, path: path, line: headerLine)
                    currentIsArrayItem = true
                } else {
                    if definedTables.contains(path) {
                        throw TOMLError(line: headerLine, message: "table [\(path.joined(separator: "."))] is defined twice")
                    }
                    definedTables.insert(path)
                    try ensureTable(&root, path: path, line: headerLine)
                    currentIsArrayItem = false
                }
                currentPath = path
            } else {
                let keyLine = line
                let keyPath = try parseKeyPath()
                skipInlineWhitespace()
                try expect("=")
                skipInlineWhitespace()
                let value = try parseValue()
                try expectLineEnd()
                try insert(&root, tablePath: currentPath, inArrayItem: currentIsArrayItem, keyPath: keyPath, node: value, line: keyLine)
            }
        }
        return root
    }

    // MARK: Table building

    private func ensureTable(_ root: inout TOMLTable, path: [String], line: Int) throws(TOMLError) {
        try Self.withTable(&root, path: path, line: line, inArrayItem: false) { _ throws(TOMLError) in }
    }

    private func appendArrayTable(_ root: inout TOMLTable, path: [String], line: Int) throws(TOMLError) {
        let parent = Array(path.dropLast())
        let name = path.last!
        try Self.withTable(&root, path: parent, line: line, inArrayItem: true) { (table: inout TOMLTable) throws(TOMLError) in
            var items: [TOMLNode] = []
            if let existing = table[name] {
                guard case .array(let current) = existing.value,
                      current.allSatisfy({ if case .table = $0.value { true } else { false } }) else {
                    throw TOMLError(line: line, message: "'\(name)' is already defined as a value, not a list of tables")
                }
                items = current
            }
            items.append(TOMLNode(.table(TOMLTable(line: line)), line: line))
            table[name] = TOMLNode(.array(items), line: table[name]?.line ?? line)
        }
    }

    private func insert(
        _ root: inout TOMLTable, tablePath: [String], inArrayItem: Bool,
        keyPath: [String], node: TOMLNode, line: Int
    ) throws(TOMLError) {
        let fullPath = tablePath + keyPath.dropLast()
        let key = keyPath.last!
        try Self.withTable(&root, path: fullPath, line: line, inArrayItem: inArrayItem, arrayDepth: tablePath.count) { (table: inout TOMLTable) throws(TOMLError) in
            if table[key] != nil {
                throw TOMLError(line: line, message: "'\(keyPath.joined(separator: "."))' is set twice")
            }
            table[key] = node
        }
    }

    /// Walks to the table at `path`, creating intermediate tables. When a path component is an
    /// array of tables, the last item is used (TOML semantics for `[[a]]` followed by `[a.b]`).
    private static func withTable(
        _ table: inout TOMLTable, path: [String], line: Int, inArrayItem: Bool, arrayDepth: Int? = nil,
        _ body: (inout TOMLTable) throws(TOMLError) -> Void
    ) throws(TOMLError) {
        guard let first = path.first else {
            try body(&table)
            return
        }
        let rest = Array(path.dropFirst())
        var node = table[first] ?? TOMLNode(.table(TOMLTable(line: line)), line: line)
        switch node.value {
        case .table(var child):
            try withTable(&child, path: rest, line: line, inArrayItem: inArrayItem, body)
            node.value = .table(child)
        case .array(var items):
            guard var lastNode = items.last, case .table(var child) = lastNode.value else {
                throw TOMLError(line: line, message: "'\(first)' is a value, not a table")
            }
            try withTable(&child, path: rest, line: line, inArrayItem: inArrayItem, body)
            lastNode.value = .table(child)
            items[items.count - 1] = lastNode
            node.value = .array(items)
        default:
            throw TOMLError(line: line, message: "'\(first)' is a value, not a table")
        }
        table[first] = node
    }

    // MARK: Keys

    private mutating func parseKeyPath() throws(TOMLError) -> [String] {
        var parts: [String] = []
        while true {
            skipInlineWhitespace()
            parts.append(try parseKey())
            skipInlineWhitespace()
            if peek() == "." {
                advance()
            } else {
                return parts
            }
        }
    }

    private mutating func parseKey() throws(TOMLError) -> String {
        guard let c = peek() else { throw error("expected a key") }
        if c == "\"" { return try parseBasicString() }
        if c == "'" { return try parseLiteralString() }
        var key = ""
        while let c = peek(), c.isLetter || c.isNumber || c == "_" || c == "-" {
            key.append(c)
            advance()
        }
        if key.isEmpty { throw error("expected a key, found '\(c)'") }
        return key
    }

    // MARK: Values

    private mutating func parseValue() throws(TOMLError) -> TOMLNode {
        let valueLine = line
        guard let c = peek() else { throw error("expected a value") }
        switch c {
        case "\"":
            if lookahead("\"\"\"") { return TOMLNode(.string(try parseMultilineBasicString()), line: valueLine) }
            return TOMLNode(.string(try parseBasicString()), line: valueLine)
        case "'":
            if lookahead("'''") { return TOMLNode(.string(try parseMultilineLiteralString()), line: valueLine) }
            return TOMLNode(.string(try parseLiteralString()), line: valueLine)
        case "[":
            return TOMLNode(.array(try parseArray()), line: valueLine)
        case "{":
            return TOMLNode(.table(try parseInlineTable()), line: valueLine)
        case "t", "f":
            if lookahead("true") { advance(4); return TOMLNode(.boolean(true), line: valueLine) }
            if lookahead("false") { advance(5); return TOMLNode(.boolean(false), line: valueLine) }
            throw error("unexpected value; strings need quotes")
        default:
            return try parseNumber(line: valueLine)
        }
    }

    private mutating func parseNumber(line valueLine: Int) throws(TOMLError) -> TOMLNode {
        var text = ""
        while let c = peek(), c.isNumber || "+-._eExobabcdefABCDEF".contains(c) || c == "i" || c == "n" {
            text.append(c)
            advance()
        }
        let clean = text.replacingOccurrences(of: "_", with: "")
        if clean.isEmpty { throw error("unexpected value; strings need quotes") }
        if clean.hasPrefix("0x"), let v = Int(clean.dropFirst(2), radix: 16) { return TOMLNode(.integer(v), line: valueLine) }
        if clean.hasPrefix("0o"), let v = Int(clean.dropFirst(2), radix: 8) { return TOMLNode(.integer(v), line: valueLine) }
        if clean.hasPrefix("0b"), let v = Int(clean.dropFirst(2), radix: 2) { return TOMLNode(.integer(v), line: valueLine) }
        if let v = Int(clean) { return TOMLNode(.integer(v), line: valueLine) }
        if clean.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }), let v = Double(clean) {
            return TOMLNode(.float(v), line: valueLine)
        }
        throw TOMLError(line: valueLine, message: "'\(text)' is not a valid value; strings need quotes")
    }

    private mutating func parseArray() throws(TOMLError) -> [TOMLNode] {
        try expect("[")
        var items: [TOMLNode] = []
        while true {
            skipWhitespaceCommentsAndNewlines()
            if peek() == "]" { advance(); return items }
            items.append(try parseValue())
            skipWhitespaceCommentsAndNewlines()
            if peek() == "," {
                advance()
            } else if peek() == "]" {
                advance()
                return items
            } else {
                throw error("expected ',' or ']' in list")
            }
        }
    }

    private mutating func parseInlineTable() throws(TOMLError) -> TOMLTable {
        let tableLine = line
        try expect("{")
        var table = TOMLTable(line: tableLine)
        skipInlineWhitespace()
        if peek() == "}" { advance(); return table }
        while true {
            skipInlineWhitespace()
            let keyLine = line
            let path = try parseKeyPath()
            skipInlineWhitespace()
            try expect("=")
            skipInlineWhitespace()
            let value = try parseValue()
            try Self.withTable(&table, path: Array(path.dropLast()), line: keyLine, inArrayItem: false) { (t: inout TOMLTable) throws(TOMLError) in
                if t[path.last!] != nil { throw TOMLError(line: keyLine, message: "'\(path.joined(separator: "."))' is set twice") }
                t[path.last!] = value
            }
            skipInlineWhitespace()
            if peek() == "," {
                advance()
            } else if peek() == "}" {
                advance()
                return table
            } else {
                throw error("expected ',' or '}' in inline table")
            }
        }
    }

    // MARK: Strings

    private mutating func parseBasicString() throws(TOMLError) -> String {
        try expect("\"")
        var s = ""
        while true {
            guard let c = peek() else { throw error("unterminated string") }
            if c == "\n" { throw error("unterminated string") }
            advance()
            if c == "\"" { return s }
            if c == "\\" { s.append(try parseEscape()) } else { s.append(c) }
        }
    }

    private mutating func parseMultilineBasicString() throws(TOMLError) -> String {
        advance(3)
        if peek() == "\n" { advance() }
        var s = ""
        while true {
            if lookahead("\"\"\"") {
                advance(3)
                return s
            }
            guard let c = peek() else { throw error("unterminated multi-line string") }
            advance()
            if c == "\\" {
                if let n = peek(), n == "\n" || n == " " || n == "\t" {
                    while let w = peek(), w == "\n" || w == " " || w == "\t" { advance() }
                } else {
                    s.append(try parseEscape())
                }
            } else {
                s.append(c)
            }
        }
    }

    private mutating func parseLiteralString() throws(TOMLError) -> String {
        try expect("'")
        var s = ""
        while true {
            guard let c = peek(), c != "\n" else { throw error("unterminated string") }
            advance()
            if c == "'" { return s }
            s.append(c)
        }
    }

    private mutating func parseMultilineLiteralString() throws(TOMLError) -> String {
        advance(3)
        if peek() == "\n" { advance() }
        var s = ""
        while true {
            if lookahead("'''") {
                advance(3)
                return s
            }
            guard let c = peek() else { throw error("unterminated multi-line string") }
            advance()
            s.append(c)
        }
    }

    private mutating func parseEscape() throws(TOMLError) -> Character {
        guard let c = peek() else { throw error("unterminated escape") }
        advance()
        switch c {
        case "n": return "\n"
        case "t": return "\t"
        case "r": return "\r"
        case "b": return "\u{08}"
        case "f": return "\u{0C}"
        case "\"": return "\""
        case "\\": return "\\"
        case "u", "U":
            let count = c == "u" ? 4 : 8
            var hex = ""
            for _ in 0..<count {
                guard let h = peek(), h.isHexDigit else { throw error("invalid unicode escape") }
                hex.append(h)
                advance()
            }
            guard let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) else {
                throw error("invalid unicode escape")
            }
            return Character(scalar)
        default:
            throw error("unknown escape '\\\(c)'")
        }
    }

    // MARK: Low-level

    private func peek() -> Character? {
        pos < chars.count ? chars[pos] : nil
    }

    private func lookahead(_ s: String) -> Bool {
        var i = pos
        for c in s {
            guard i < chars.count, chars[i] == c else { return false }
            i += 1
        }
        return true
    }

    private mutating func advance(_ n: Int = 1) {
        for _ in 0..<n where pos < chars.count {
            if chars[pos] == "\n" { line += 1 }
            pos += 1
        }
    }

    private mutating func expect(_ c: Character) throws(TOMLError) {
        guard peek() == c else {
            if let found = peek(), found != "\n" {
                throw error("expected '\(c)', found '\(found)'")
            }
            throw error("expected '\(c)'")
        }
        advance()
    }

    private mutating func expectLineEnd() throws(TOMLError) {
        skipInlineWhitespace()
        if peek() == "#" { skipComment() }
        if peek() == "\r" { advance() }
        guard peek() == nil || peek() == "\n" else {
            throw error("unexpected text after value: '\(restOfLine())'")
        }
    }

    private mutating func skipInlineWhitespace() {
        while let c = peek(), c == " " || c == "\t" { advance() }
    }

    private mutating func skipComment() {
        while let c = peek(), c != "\n" { advance() }
    }

    private mutating func skipWhitespaceCommentsAndNewlines() {
        while let c = peek() {
            if c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\r\n" {
                advance()
            } else if c == "#" {
                skipComment()
            } else {
                return
            }
        }
    }

    private func restOfLine() -> String {
        var s = ""
        var i = pos
        while i < chars.count, chars[i] != "\n" {
            s.append(chars[i])
            i += 1
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private func error(_ message: String) -> TOMLError {
        TOMLError(line: line, message: message)
    }
}
