/// A config file held as text plus its lossless CST. Immutable; edits (see `Editor.swift`) return
/// new documents. The GUI reads structure through the queries here and writes through the mutations.
public struct ConfigDocument: Sendable {
    /// The exact file contents.
    public let text: String
    /// Concrete syntax tree of `text` (`tree.text == text`).
    public let tree: SyntaxTree
    /// Byte-offset ↔ line/column mapping for `text`.
    public let sourceMap: SourceMap
    /// Syntax errors found while parsing (empty for well-formed files).
    public let parseDiagnostics: [Diagnostic]

    public init(text: String) {
        self.text = text
        let map = SourceMap(text: text)
        let (tree, diagnostics) = Parser.parse(map: map)
        self.tree = tree
        self.sourceMap = map
        self.parseDiagnostics = diagnostics
    }

    /// Compiles the document (parse diagnostics included in the result).
    public func compile() -> CompileResult {
        ConfigCompiler.compile(tree: tree, map: sourceMap, parseDiagnostics: parseDiagnostics)
    }

    // MARK: - Forms

    /// The first `(defsrc …)` form, if any.
    public var sourceForm: ListNode? { tree.forms(named: "defsrc").first }

    /// All `(deflayer …)` forms in file order.
    public var layerForms: [ListNode] { tree.forms(named: "deflayer") }

    /// The `(deflayer name …)` form for `name` (exact match).
    public func layerForm(named name: String) -> ListNode? {
        layerForms.first { $0.arguments.first?.asAtom?.text == name }
    }

    // MARK: - Structural queries

    /// Layer names in file order (the first is the base layer).
    public var layerNames: [String] {
        layerForms.compactMap { $0.arguments.first?.asAtom?.text }
    }

    /// `defsrc` entries with their byte ranges.
    public var sourceKeys: [(name: String, range: Range<Int>)] {
        guard let form = sourceForm else { return [] }
        return form.arguments.map { ($0.tokenText, $0.range) }
    }

    /// The action token at `position` (defsrc index) on `layer`, or `nil` if either does not exist.
    public func action(layer: String, position: Int) -> (text: String, range: Range<Int>)? {
        guard let node = actionNode(layer: layer, position: position) else { return nil }
        return (node.tokenText, node.range)
    }

    func actionNode(layer: String, position: Int) -> SyntaxNode? {
        guard let form = layerForm(named: layer) else { return nil }
        let actions = form.arguments.dropFirst()
        let index = actions.startIndex + position
        guard position >= 0, index < actions.endIndex else { return nil }
        return actions[index]
    }

    /// Action tokens of `layer` in position order.
    public func actionTexts(layer: String) -> [String]? {
        layerForm(named: layer).map { $0.arguments.dropFirst().map(\.tokenText) }
    }

    /// Every alias definition: name (without `@`), the action's source text and the action's byte range.
    public var aliases: [(name: String, text: String, range: Range<Int>)] {
        aliasPairs.map { ($0.name, $0.value.tokenText, $0.value.range) }
    }

    var aliasPairs: [(name: String, nameAtom: Atom, value: SyntaxNode, form: ListNode)] {
        var out: [(String, Atom, SyntaxNode, ListNode)] = []
        for form in tree.forms(named: "defalias") {
            let args = Array(form.arguments)
            var i = 0
            while i + 1 < args.count {
                if let atom = args[i].asAtom {
                    let name = atom.text.hasPrefix("@") ? String(atom.text.dropFirst()) : atom.text
                    out.append((name, atom, args[i + 1], form))
                }
                i += 2
            }
        }
        return out
    }

    /// Raw `(defcfg …)` pairs: key, value source text and the value's byte range.
    public var settings: [(key: String, text: String, range: Range<Int>)] {
        settingPairs.map { ($0.key.text, $0.value.tokenText, $0.value.range) }
    }

    var settingPairs: [(key: Atom, value: SyntaxNode, form: ListNode)] {
        var out: [(Atom, SyntaxNode, ListNode)] = []
        for form in tree.forms(named: "defcfg") {
            let args = Array(form.arguments)
            var i = 0
            while i + 1 < args.count {
                if let atom = args[i].asAtom { out.append((atom, args[i + 1], form)) }
                i += 2
            }
        }
        return out
    }

    // MARK: - Grid

    /// Line structure of `defsrc`, used to lay out layers. `nil` without a `defsrc`.
    public var gridLayout: GridLayout? {
        guard let form = sourceForm else { return nil }
        let args = Array(form.arguments)
        let openLine = sourceMap.lineIndex(ofByte: form.openRange.lowerBound)
        var rows: [[Int]] = []
        var lastLine = -1
        for (p, node) in args.enumerated() {
            let line = sourceMap.lineIndex(ofByte: node.range.lowerBound)
            if line != lastLine { rows.append([]) }
            rows[rows.count - 1].append(p)
            lastLine = line
        }
        let firstRowInline = args.first.map { sourceMap.lineIndex(ofByte: $0.range.lowerBound) == openLine } ?? false
        let closeOnOwnLine = form.closeTrivia.contains("\n")
        return GridLayout(rows: rows, firstRowInline: firstRowInline, closeOnOwnLine: closeOnOwnLine,
                          indent: Self.indent(of: form))
    }

    /// Widest token per defsrc position across `defsrc` and every layer.
    public var gridWidths: [Int] {
        var rows = [sourceKeys.map(\.name)]
        for form in layerForms { rows.append(form.arguments.dropFirst().map(\.tokenText)) }
        return Formatter.columnWidths(rows)
    }

    /// Indentation used by the first child of `form` that starts a new line (default two spaces).
    static func indent(of form: ListNode) -> String {
        for child in form.children.dropFirst() {
            let trivia = child.leadingTrivia
            if let nl = trivia.lastIndex(of: "\n") {
                let after = trivia[trivia.index(after: nl)...]
                return after.allSatisfy({ $0 == " " || $0 == "\t" }) ? String(after) : "  "
            }
        }
        return "  "
    }

    /// Whether the form spreads over several lines.
    static func isMultiline(_ form: ListNode) -> Bool {
        form.children.dropFirst().contains { $0.leadingTrivia.contains("\n") } || form.closeTrivia.contains("\n")
    }
}
