/// Builds a lossless `SyntaxTree` from source text. Never fails: malformed input yields a
/// best-effort tree plus diagnostics (stray `)` become atoms; unclosed lists end at EOF).
public struct Parser {
    /// Parses `text`. The returned tree re-serialises to exactly `text`.
    public static func parse(_ text: String) -> (tree: SyntaxTree, diagnostics: [Diagnostic]) {
        parse(map: SourceMap(text: text))
    }

    /// Parses the text behind `map`.
    public static func parse(map: SourceMap) -> (tree: SyntaxTree, diagnostics: [Diagnostic]) {
        var parser = Parser(map: map)
        let tree = parser.parseTree()
        return (tree, parser.lexer.diagnostics + parser.diagnostics)
    }

    private let map: SourceMap
    private var lexer: Lexer
    private var diagnostics: [Diagnostic] = []
    private var lookahead: Token

    private init(map: SourceMap) {
        self.map = map
        self.lexer = Lexer(map: map)
        self.lookahead = self.lexer.next()
    }

    private mutating func advance() -> Token {
        let t = lookahead
        if t.kind != .eof { lookahead = lexer.next() }
        return t
    }

    private mutating func error(_ message: String, _ range: Range<Int>) {
        diagnostics.append(Diagnostic(severity: .error, message: message, range: range, in: map))
    }

    private mutating func parseTree() -> SyntaxTree {
        var nodes: [SyntaxNode] = []
        while true {
            let t = advance()
            switch t.kind {
            case .eof:
                return SyntaxTree(nodes: nodes, trailingTrivia: t.leadingTrivia)
            case .close:
                error("unexpected ')' with no matching '('", t.range)
                nodes.append(.atom(Atom(leadingTrivia: t.leadingTrivia, text: ")", range: t.range)))
            case .open:
                nodes.append(.list(parseList(open: t)))
            case .atom:
                nodes.append(.atom(Atom(leadingTrivia: t.leadingTrivia, text: t.text, range: t.range)))
            case .string:
                nodes.append(.string(StringLiteral(leadingTrivia: t.leadingTrivia, rawText: t.text,
                                                   value: t.value, range: t.range)))
            }
        }
    }

    private mutating func parseList(open: Token) -> ListNode {
        var children: [SyntaxNode] = []
        while true {
            let t = advance()
            switch t.kind {
            case .close:
                return ListNode(leadingTrivia: open.leadingTrivia, openRange: open.range, children: children,
                                closeTrivia: t.leadingTrivia, closeRange: t.range)
            case .eof:
                error("unclosed '(' (missing ')')", open.range)
                // The trailing trivia now belongs to this list; make sure nobody else re-emits it.
                lookahead.leadingTrivia = ""
                return ListNode(leadingTrivia: open.leadingTrivia, openRange: open.range, children: children,
                                closeTrivia: t.leadingTrivia, closeRange: nil)
            case .open:
                children.append(.list(parseList(open: t)))
            case .atom:
                children.append(.atom(Atom(leadingTrivia: t.leadingTrivia, text: t.text, range: t.range)))
            case .string:
                children.append(.string(StringLiteral(leadingTrivia: t.leadingTrivia, rawText: t.text,
                                                      value: t.value, range: t.range)))
            }
        }
    }
}
