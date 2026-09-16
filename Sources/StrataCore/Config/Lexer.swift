/// Tokeniser for the `.kbd` dialect. Works on UTF-8 bytes; every token carries the trivia
/// (whitespace, `;;` line comments, `#| … |#` block comments) that preceded it.
struct Token: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case open, close, atom, string, eof
    }

    var kind: Kind
    var leadingTrivia: String
    /// Source text of the token itself (for strings: including quotes).
    var text: String
    /// For strings: the unescaped value. Otherwise equal to `text`.
    var value: String
    var range: Range<Int>
}

struct Lexer {
    private let bytes: [UInt8]
    private let map: SourceMap
    private var pos = 0
    private(set) var diagnostics: [Diagnostic] = []

    init(map: SourceMap) {
        self.map = map
        self.bytes = map.bytes
    }

    private static let space = UInt8(ascii: " "), tab = UInt8(ascii: "\t"), lf = UInt8(ascii: "\n")
    private static let cr = UInt8(ascii: "\r"), vt: UInt8 = 0x0B, ff: UInt8 = 0x0C
    private static let open = UInt8(ascii: "("), close = UInt8(ascii: ")"), quote = UInt8(ascii: "\"")
    private static let semi = UInt8(ascii: ";"), hash = UInt8(ascii: "#"), bar = UInt8(ascii: "|")
    private static let backslash = UInt8(ascii: "\\")

    static func isWhitespace(_ b: UInt8) -> Bool {
        b == space || b == tab || b == lf || b == cr || b == vt || b == ff
    }

    static func isDelimiter(_ b: UInt8) -> Bool {
        isWhitespace(b) || b == open || b == close || b == quote
    }

    private func byte(at i: Int) -> UInt8? { i < bytes.count ? bytes[i] : nil }

    /// Consumes whitespace and comments, returning them verbatim.
    private mutating func skipTrivia() -> String {
        let start = pos
        while pos < bytes.count {
            let b = bytes[pos]
            if Lexer.isWhitespace(b) {
                pos += 1
            } else if b == Lexer.semi, byte(at: pos + 1) == Lexer.semi {
                while pos < bytes.count, bytes[pos] != Lexer.lf { pos += 1 }
            } else if b == Lexer.hash, byte(at: pos + 1) == Lexer.bar {
                skipBlockComment()
            } else {
                break
            }
        }
        return String(decoding: bytes[start..<pos], as: UTF8.self)
    }

    /// `#| … |#`, nestable. Unterminated comments swallow the rest of the file and report an error.
    private mutating func skipBlockComment() {
        let start = pos
        var depth = 0
        while pos < bytes.count {
            if bytes[pos] == Lexer.hash, byte(at: pos + 1) == Lexer.bar {
                depth += 1
                pos += 2
            } else if bytes[pos] == Lexer.bar, byte(at: pos + 1) == Lexer.hash {
                depth -= 1
                pos += 2
                if depth == 0 { return }
            } else {
                pos += 1
            }
        }
        diagnostics.append(Diagnostic(severity: .error, message: "unterminated block comment (missing '|#')",
                                      range: start..<(start + 2), in: map))
    }

    mutating func next() -> Token {
        let trivia = skipTrivia()
        guard pos < bytes.count else {
            return Token(kind: .eof, leadingTrivia: trivia, text: "", value: "", range: pos..<pos)
        }
        let start = pos
        let b = bytes[pos]
        switch b {
        case Lexer.open:
            pos += 1
            return Token(kind: .open, leadingTrivia: trivia, text: "(", value: "(", range: start..<pos)
        case Lexer.close:
            pos += 1
            return Token(kind: .close, leadingTrivia: trivia, text: ")", value: ")", range: start..<pos)
        case Lexer.quote:
            return lexString(trivia: trivia)
        default:
            while pos < bytes.count, !Lexer.isDelimiter(bytes[pos]) { pos += 1 }
            let text = String(decoding: bytes[start..<pos], as: UTF8.self)
            return Token(kind: .atom, leadingTrivia: trivia, text: text, value: text, range: start..<pos)
        }
    }

    private mutating func lexString(trivia: String) -> Token {
        let start = pos
        pos += 1 // opening quote
        var value: [UInt8] = []
        var terminated = false
        while pos < bytes.count {
            let b = bytes[pos]
            if b == Lexer.backslash, let n = byte(at: pos + 1) {
                if n == Lexer.quote || n == Lexer.backslash {
                    value.append(n)
                } else {
                    value.append(b)
                    value.append(n)
                }
                pos += 2
            } else if b == Lexer.quote {
                pos += 1
                terminated = true
                break
            } else {
                value.append(b)
                pos += 1
            }
        }
        if !terminated {
            diagnostics.append(Diagnostic(severity: .error, message: "unterminated string literal",
                                          range: start..<(start + 1), in: map))
        }
        let text = String(decoding: bytes[start..<pos], as: UTF8.self)
        return Token(kind: .string, leadingTrivia: trivia, text: text,
                     value: String(decoding: value, as: UTF8.self), range: start..<pos)
    }
}
