import Foundation

/// A parsed TOML value, limited to the types the configuration file uses.
enum TOMLValue {
    case string(String)
    case integer(Int)
    case boolean(Bool)
    case array([TOMLValue])
    case table(TOMLTable)
}

/// One key of a table, with the line it was written on so a rejected value can point at the line
/// to fix.
struct TOMLEntry {
    let value: TOMLValue
    let line: Int
}

/// A parsed TOML document, or one of its `[sections]`.
struct TOMLTable {
    private var entries: [String: TOMLEntry] = [:]

    subscript(key: String) -> TOMLEntry? { self.entries[key] }

    /// Keys in the order they appear in the file, so warnings read top to bottom.
    var keys: [String] {
        self.entries.keys.sorted {
            let lhs = self.entries[$0]?.line ?? 0
            let rhs = self.entries[$1]?.line ?? 0
            return lhs == rhs ? $0 < $1 : lhs < rhs
        }
    }

    mutating func insert(_ value: TOMLValue, for key: String, line: Int) throws {
        guard self.entries[key] == nil else {
            throw TOMLParseError(line: line, message: "字段 \(key) 重复")
        }
        self.entries[key] = TOMLEntry(value: value, line: line)
    }
}

/// A value read out of a table, with the line it came from.
struct TOMLField<Value> {
    let value: Value
    let line: Int
}

/// A configuration file problem, with the line it was found on. Line 0 means the value did not
/// come from a line of the file, which happens when the previous JSON file is migrated.
struct TOMLParseError: LocalizedError {
    let line: Int
    let message: String

    var errorDescription: String? {
        self.line > 0 ? "第 \(self.line) 行：\(self.message)" : self.message
    }
}

extension TOMLTable {
    func string(_ key: String) throws -> TOMLField<String>? {
        guard let entry = self.entries[key] else { return nil }
        guard case let .string(value) = entry.value else {
            throw TOMLParseError(line: entry.line, message: "\(key) 必须是字符串")
        }
        return TOMLField(value: value, line: entry.line)
    }

    func integer(_ key: String) throws -> TOMLField<Int>? {
        guard let entry = self.entries[key] else { return nil }
        guard case let .integer(value) = entry.value else {
            throw TOMLParseError(line: entry.line, message: "\(key) 必须是整数")
        }
        return TOMLField(value: value, line: entry.line)
    }

    func boolean(_ key: String) throws -> TOMLField<Bool>? {
        guard let entry = self.entries[key] else { return nil }
        guard case let .boolean(value) = entry.value else {
            throw TOMLParseError(line: entry.line, message: "\(key) 必须是 true 或 false")
        }
        return TOMLField(value: value, line: entry.line)
    }

    func stringArray(_ key: String) throws -> TOMLField<[String]>? {
        guard let entry = self.entries[key] else { return nil }
        guard case let .array(elements) = entry.value else {
            throw TOMLParseError(line: entry.line, message: "\(key) 必须是数组")
        }
        var values: [String] = []
        for element in elements {
            guard case let .string(value) = element else {
                throw TOMLParseError(line: entry.line, message: "\(key) 的每一项都必须是字符串")
            }
            values.append(value)
        }
        return TOMLField(value: values, line: entry.line)
    }

    func table(_ key: String) throws -> TOMLField<TOMLTable>? {
        guard let entry = self.entries[key] else { return nil }
        guard case let .table(value) = entry.value else {
            throw TOMLParseError(line: entry.line, message: "\(key) 必须是配置段，写成 [\(key)]")
        }
        return TOMLField(value: value, line: entry.line)
    }

    /// Keys the app does not understand. They are reported as warnings and otherwise ignored, so a
    /// typo cannot take down every other setting in the file.
    func unknownKeys(_ allowed: Set<String>, prefix: String = "") -> [TOMLField<String>] {
        self.keys.compactMap { key in
            guard !allowed.contains(key), let entry = self.entries[key] else { return nil }
            return TOMLField(value: prefix + key, line: entry.line)
        }
    }
}

/// A reader for the TOML subset the configuration file uses: `#` comments, `[section]` headers,
/// bare or quoted keys, basic and literal strings including their multi-line forms, booleans,
/// integers and arrays. Anything outside that subset is rejected with the line it appears on
/// rather than silently accepted.
struct TOMLParser {
    private var scanner: TOMLScanner
    private var tables: [String: TOMLTable] = ["": TOMLTable()]
    private var declaredTables: Set<String> = [""]
    private var tableLines: [String: Int] = ["": 1]
    private var childPaths: [String: [String]] = [:]
    private var currentTable = ""

    static func parse(_ text: String) throws -> TOMLTable {
        var parser = TOMLParser(text: text)
        try parser.run()
        return try parser.build(path: "")
    }

    private init(text: String) {
        self.scanner = TOMLScanner(text: text)
    }

    private mutating func run() throws {
        while true {
            self.scanner.skipSpaces()
            guard let next = self.scanner.peek() else { return }
            if self.scanner.consumeLineBreak() { continue }
            if next == "#" {
                self.scanner.skipComment()
                continue
            }
            if next == "[" {
                try self.readTableHeader()
                continue
            }
            try self.readKeyValue()
        }
    }

    private mutating func readTableHeader() throws {
        let line = self.scanner.line
        self.scanner.advance()
        guard self.scanner.peek() != "[" else {
            throw TOMLParseError(line: line, message: "不支持数组表 [[…]]")
        }
        let path = try self.scanner.readKeyPath()
        guard self.scanner.advance() == "]" else {
            throw TOMLParseError(line: self.scanner.line, message: "配置段名称缺少 ]")
        }
        let name = path.joined(separator: ".")
        guard !self.declaredTables.contains(name) else {
            throw TOMLParseError(line: line, message: "配置段 [\(name)] 重复")
        }
        var components: [String] = []
        for component in path {
            components.append(component)
            let partial = components.joined(separator: ".")
            if partial != name { self.createTable(partial, line: line) }
        }
        self.createTable(name, line: line)
        self.declaredTables.insert(name)
        self.currentTable = name
        try self.scanner.expectLineEnd()
    }

    private mutating func readKeyValue() throws {
        let line = self.scanner.line
        let keyPath = try self.scanner.readKeyPath()
        let name = keyPath.joined(separator: ".")
        guard self.scanner.advance() == "=" else {
            throw TOMLParseError(line: self.scanner.line, message: "\(name) 后面缺少 =")
        }
        self.scanner.skipSpaces()
        let value = try self.scanner.readValue()
        var components = self.currentTable.isEmpty ? [] : self.currentTable.split(separator: ".").map(String.init)
        components += keyPath
        var parents: [String] = []
        for component in components.dropLast() {
            parents.append(component)
            self.createTable(parents.joined(separator: "."), line: line)
        }
        let parent = Self.parentPath(of: components.joined(separator: "."))
        guard self.tables[parent] != nil else {
            throw TOMLParseError(line: line, message: "\(parent) 不是一个配置段")
        }
        try self.tables[parent]?.insert(value, for: components.last ?? "", line: line)
        try self.scanner.expectLineEnd()
    }

    private mutating func createTable(_ path: String, line: Int) {
        guard self.tables[path] == nil else { return }
        self.tables[path] = TOMLTable()
        self.tableLines[path] = line
        self.childPaths[Self.parentPath(of: path), default: []].append(path)
    }

    private func build(path: String) throws -> TOMLTable {
        var table = self.tables[path] ?? TOMLTable()
        for child in self.childPaths[path] ?? [] {
            let name = String(child.dropFirst(path.isEmpty ? 0 : path.count + 1))
            let childLine = self.tableLines[child] ?? 0
            guard table[name] == nil else {
                throw TOMLParseError(line: childLine, message: "\(name) 同时被当作字段和配置段")
            }
            let childTable = try self.build(path: child)
            try table.insert(.table(childTable), for: name, line: childLine)
        }
        return table
    }

    private static func parentPath(of path: String) -> String {
        guard let dot = path.lastIndex(of: ".") else { return "" }
        return String(path[path.startIndex..<dot])
    }
}

/// Character-level cursor over a TOML file that keeps track of the current line.
private struct TOMLScanner {
    private let characters: [Character]
    private var index = 0
    private(set) var line = 1

    init(text: String) {
        // Work in line-feed form: Swift reads a CRLF pair as one Character, which would never match
        // the "\n" checks below.
        var characters = Array(
            text.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n"))
        // A byte order mark is not part of the document.
        if characters.first == "\u{FEFF}" { characters.removeFirst() }
        self.characters = characters
    }

    var isAtEnd: Bool { self.index >= self.characters.count }

    func peek(_ offset: Int = 0) -> Character? {
        let position = self.index + offset
        return position < self.characters.count ? self.characters[position] : nil
    }

    @discardableResult
    mutating func advance() -> Character? {
        guard self.index < self.characters.count else { return nil }
        let character = self.characters[self.index]
        self.index += 1
        if character == "\n" { self.line += 1 }
        return character
    }

    mutating func skipSpaces() {
        while let character = self.peek(), character == " " || character == "\t" { self.advance() }
    }

    /// Spaces, line breaks and comments, for the positions inside an array where all three are
    /// insignificant.
    mutating func skipInsignificant() {
        while let character = self.peek() {
            if character == " " || character == "\t" || character == "\r" || character == "\n" {
                self.advance()
            } else if character == "#" {
                self.skipComment()
            } else {
                return
            }
        }
    }

    mutating func skipWhitespaceAndLineBreaks() {
        while let character = self.peek() {
            guard character == " " || character == "\t" || character == "\r" || character == "\n" else { return }
            self.advance()
        }
    }

    mutating func skipComment() {
        guard self.peek() == "#" else { return }
        while let character = self.peek(), character != "\n" { self.advance() }
    }

    @discardableResult
    mutating func consumeLineBreak() -> Bool {
        guard let character = self.peek() else { return false }
        if character == "\n" {
            self.advance()
            return true
        }
        if character == "\r" {
            self.advance()
            if self.peek() == "\n" { self.advance() }
            return true
        }
        return false
    }

    mutating func expectLineEnd() throws {
        self.skipSpaces()
        self.skipComment()
        if self.isAtEnd || self.consumeLineBreak() { return }
        throw TOMLParseError(line: self.line, message: "这一行有多余的内容")
    }

    mutating func readKeyPath() throws -> [String] {
        var components: [String] = []
        while true {
            self.skipSpaces()
            let next = self.peek()
            let component: String
            if next == "\"" || next == "'" {
                component = try self.readString()
            } else {
                var bare = ""
                while let character = self.peek(), Self.isBareKeyCharacter(character) {
                    bare.append(self.advance() ?? " ")
                }
                guard !bare.isEmpty else {
                    throw TOMLParseError(line: self.line, message: "缺少字段名")
                }
                component = bare
            }
            components.append(component)
            self.skipSpaces()
            guard self.peek() == "." else { return components }
            self.advance()
        }
    }

    mutating func readValue() throws -> TOMLValue {
        guard let character = self.peek() else {
            throw TOMLParseError(line: self.line, message: "缺少值")
        }
        switch character {
        case "\"", "'":
            return .string(try self.readString())
        case "[":
            return try self.readArray()
        case "t", "f":
            return .boolean(try self.readBoolean())
        case "+", "-":
            return .integer(try self.readInteger())
        case "{":
            throw TOMLParseError(line: self.line, message: "不支持行内表 {…}，请改用 [配置段] 分段书写")
        default:
            guard character.isNumber else {
                throw TOMLParseError(line: self.line, message: "无法识别的值，支持字符串、整数、true/false 和数组")
            }
            return .integer(try self.readInteger())
        }
    }

    mutating func readBoolean() throws -> Bool {
        let line = self.line
        var word = ""
        while let character = self.peek(), character.isLetter {
            word.append(self.advance() ?? " ")
        }
        switch word {
        case "true": return true
        case "false": return false
        default: throw TOMLParseError(line: line, message: "\(word) 不是有效的布尔值，只能写 true 或 false")
        }
    }

    mutating func readInteger() throws -> Int {
        let line = self.line
        var text = ""
        if let sign = self.peek(), sign == "+" || sign == "-" {
            text.append(self.advance() ?? " ")
        }
        while let character = self.peek(), character.isNumber || character == "_" {
            text.append(self.advance() ?? " ")
        }
        if let next = self.peek(), next == "." || next == "-" || next == ":" || next.isNumber || next.isLetter {
            throw TOMLParseError(line: line, message: "不支持的值 \(text)\(next)…，本文件只使用整数")
        }
        guard let value = Int(text.replacingOccurrences(of: "_", with: "")) else {
            throw TOMLParseError(line: line, message: "整数 \(text) 无效")
        }
        return value
    }

    mutating func readArray() throws -> TOMLValue {
        let line = self.line
        self.advance()
        var elements: [TOMLValue] = []
        while !self.isAtEnd {
            self.skipInsignificant()
            if self.isAtEnd { break }
            if self.peek() == "]" {
                self.advance()
                return .array(elements)
            }
            elements.append(try self.readValue())
            self.skipInsignificant()
            if self.isAtEnd { break }
            if self.peek() == "," {
                self.advance()
                continue
            }
            if self.peek() == "]" {
                self.advance()
                return .array(elements)
            }
            throw TOMLParseError(line: self.line, message: "数组的每一项后面需要 , 或 ]")
        }
        throw TOMLParseError(line: line, message: "数组缺少结束的 ]")
    }

    mutating func readString() throws -> String {
        guard let quote = self.peek() else {
            throw TOMLParseError(line: self.line, message: "缺少字符串")
        }
        let isBasic = quote == "\""
        if self.peek(1) == quote, self.peek(2) == quote {
            return try self.readMultiLineString(isBasic: isBasic)
        }
        let line = self.line
        self.advance()
        var result = ""
        while true {
            guard let character = self.advance(), character != "\n" else {
                throw TOMLParseError(line: line, message: "字符串缺少结束的 \(quote)")
            }
            if character == quote { return result }
            if character == "\\", isBasic {
                result.append(try self.readEscape())
            } else {
                result.append(character)
            }
        }
    }

    private mutating func readMultiLineString(isBasic: Bool) throws -> String {
        let quote: Character = isBasic ? "\"" : "'"
        let line = self.line
        self.advance()
        self.advance()
        self.advance()
        // A line break right after the opening quotes is not part of the value.
        self.consumeLineBreak()
        var result = ""
        while true {
            if self.peek() == quote, self.peek(1) == quote, self.peek(2) == quote {
                self.advance()
                self.advance()
                self.advance()
                return result
            }
            guard let character = self.advance() else {
                throw TOMLParseError(line: line, message: "字符串缺少结束的 \(quote)\(quote)\(quote)")
            }
            if character == "\\", isBasic {
                if self.consumeLineContinuation() { continue }
                result.append(try self.readEscape())
            } else {
                result.append(character)
            }
        }
    }

    /// A backslash as the last character of a line drops the line break and the whitespace after
    /// it, so a long value can be wrapped.
    private mutating func consumeLineContinuation() -> Bool {
        let startIndex = self.index
        let startLine = self.line
        self.skipSpaces()
        guard self.consumeLineBreak() else {
            self.index = startIndex
            self.line = startLine
            return false
        }
        self.skipWhitespaceAndLineBreaks()
        return true
    }

    private mutating func readEscape() throws -> Character {
        guard let character = self.advance() else {
            throw TOMLParseError(line: self.line, message: "转义符不完整")
        }
        switch character {
        case "b": return "\u{08}"
        case "t": return "\t"
        case "n": return "\n"
        case "f": return "\u{0C}"
        case "r": return "\r"
        case "\"": return "\""
        case "\\": return "\\"
        case "u": return try self.readUnicodeEscape(digits: 4)
        case "U": return try self.readUnicodeEscape(digits: 8)
        default:
            throw TOMLParseError(line: self.line, message: "不支持的转义 \\\(character)")
        }
    }

    private mutating func readUnicodeEscape(digits: Int) throws -> Character {
        var code = ""
        for _ in 0..<digits {
            guard let character = self.advance(), character.isHexDigit else {
                throw TOMLParseError(line: self.line, message: "\\u 转义需要 \(digits) 位十六进制数字")
            }
            code.append(character)
        }
        guard let value = UInt32(code, radix: 16), let scalar = Unicode.Scalar(value) else {
            throw TOMLParseError(line: self.line, message: "\\u\(code) 不是有效的字符编码")
        }
        return Character(scalar)
    }

    private static func isBareKeyCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "-"
    }
}
