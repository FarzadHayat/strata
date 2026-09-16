/// Errors from structural edits.
public enum EditError: Error, Sendable, Equatable {
    case unknownLayer(String)
    case layerAlreadyExists(String)
    case positionOutOfRange(Int)
    case missingDefsrc
    case unknownAlias(String)
}

/// A byte-range replacement in the document text.
struct ByteEdit: Sendable, Hashable {
    var range: Range<Int>
    var replacement: String
}

/// Lossless mutations. Each returns a new document; only the described bytes change.
///
/// Token replacements follow the grid rule: a shorter token is padded with spaces so the tokens
/// after it on the same line stay in place; a longer token first consumes spare spaces (leaving
/// at least one) from the whitespace run that follows it before pushing the rest of the line right.
extension ConfigDocument {
    // MARK: - Primitive edits

    /// Applies non-overlapping edits (in any order) and re-parses.
    func applying(_ edits: [ByteEdit]) -> ConfigDocument {
        var bytes = sourceMap.bytes
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            bytes.replaceSubrange(edit.range, with: Array(edit.replacement.utf8))
        }
        return ConfigDocument(text: String(decoding: bytes, as: UTF8.self))
    }

    func inserting(_ text: String, at offset: Int) -> ConfigDocument {
        applying([ByteEdit(range: offset..<offset, replacement: text)])
    }

    /// Replacement of a token's bytes with `newText`, applying the grid alignment rule.
    func alignedEdit(replacing range: Range<Int>, with newText: String) -> ByteEdit {
        let bytes = sourceMap.bytes
        let oldWidth = sourceMap.scalarWidth(range)
        let newWidth = Formatter.width(newText)
        var i = range.upperBound
        while i < bytes.count, bytes[i] == UInt8(ascii: " ") { i += 1 }
        let spaceRun = i - range.upperBound
        let followedByToken = i < bytes.count && bytes[i] != UInt8(ascii: "\n") && bytes[i] != UInt8(ascii: "\r")
            && bytes[i] != UInt8(ascii: ")")
        if newWidth < oldWidth, followedByToken {
            return ByteEdit(range: range, replacement: newText + String(repeating: " ", count: oldWidth - newWidth))
        }
        if newWidth > oldWidth, spaceRun > 1 {
            let consumed = min(newWidth - oldWidth, spaceRun - 1)
            return ByteEdit(range: range.lowerBound..<(range.upperBound + consumed), replacement: newText)
        }
        return ByteEdit(range: range, replacement: newText)
    }

    /// Number of leading bytes of `trivia` to keep when deleting the node it precedes: everything up
    /// to (excluding) the last newline, or up to the last non-whitespace byte if it has no newline.
    static func keptTriviaBytes(_ trivia: String) -> Int {
        let bytes = Array(trivia.utf8)
        if let nl = bytes.lastIndex(of: UInt8(ascii: "\n")) { return nl }
        var end = bytes.count
        while end > 0, Lexer.isWhitespace(bytes[end - 1]) { end -= 1 }
        return end
    }

    /// Start of the range that removes `node` together with the whitespace that introduced it
    /// (comments in its leading trivia are kept).
    func removalStart(for node: SyntaxNode) -> Int {
        node.range.lowerBound - node.leadingTrivia.utf8.count + Self.keptTriviaBytes(node.leadingTrivia)
    }

    /// Byte range that removes a top-level `form` and its own line(s): the whitespace before it and,
    /// when the form had a line to itself, the newline that follows it.
    func removalRange(forForm form: ListNode) -> Range<Int> {
        let start = removalStart(for: .list(form))
        var end = form.range.upperBound
        if form.leadingTrivia.contains("\n"), end < sourceMap.bytes.count, sourceMap.bytes[end] == UInt8(ascii: "\n") {
            end += 1
        }
        return start..<end
    }

    /// Offset just after the last child of `form` (before its close trivia and `)`).
    static func appendOffset(in form: ListNode) -> Int {
        (form.closeRange?.lowerBound ?? form.range.upperBound) - form.closeTrivia.utf8.count
    }

    /// Text inserted before the `)` of `form` for a new `name value` pair.
    static func pairInsertion(_ name: String, _ value: String, in form: ListNode) -> String {
        isMultiline(form) ? "\n" + indent(of: form) + name + " " + value : " " + name + " " + value
    }

    // MARK: - Actions

    /// Replaces the action token at `position` on `layer` with `text`, keeping the rest of the line aligned.
    public func setAction(layer: String, position: Int, to text: String) throws -> ConfigDocument {
        guard layerForm(named: layer) != nil else { throw EditError.unknownLayer(layer) }
        guard let node = actionNode(layer: layer, position: position) else {
            throw EditError.positionOutOfRange(position)
        }
        return applying([alignedEdit(replacing: node.range, with: text)])
    }

    // MARK: - Aliases

    /// Replaces the action of alias `name`, or appends `name action` to the last `defalias` form
    /// (creating one after `defsrc` if the file has none).
    public func setAlias(name: String, to text: String) -> ConfigDocument {
        if let pair = aliasPairs.first(where: { $0.name == name }) {
            return applying([alignedEdit(replacing: pair.value.range, with: text)])
        }
        if let form = tree.forms(named: "defalias").last {
            return inserting(Self.pairInsertion(name, text, in: form), at: Self.appendOffset(in: form))
        }
        return insertForm("(defalias\n  \(name) \(text)\n)", after: sourceForm)
    }

    /// Removes the definition of alias `name` (its whole line, if it had one to itself).
    public func removeAlias(name: String) throws -> ConfigDocument {
        guard let pair = aliasPairs.first(where: { $0.name == name }) else { throw EditError.unknownAlias(name) }
        let start = removalStart(for: .atom(pair.nameAtom))
        return applying([ByteEdit(range: start..<pair.value.range.upperBound, replacement: "")])
    }

    // MARK: - Settings

    /// Replaces the value of defcfg `key`, or appends `key value` to the first `defcfg`
    /// (creating one at the top of the file if there is none).
    public func setSetting(key: String, to text: String) -> ConfigDocument {
        if let pair = settingPairs.first(where: { $0.key.text.lowercased() == key.lowercased() }) {
            return applying([alignedEdit(replacing: pair.value.range, with: text)])
        }
        if let form = tree.forms(named: "defcfg").first {
            return inserting(Self.pairInsertion(key, text, in: form), at: Self.appendOffset(in: form))
        }
        let body = "(defcfg\n  \(key) \(text)\n)"
        guard let first = tree.nodes.first else { return inserting(body + "\n", at: sourceMap.bytes.count) }
        return inserting(body + "\n\n", at: first.range.lowerBound)
    }

    // MARK: - Layers

    /// Appends `(deflayer name …)` laid out on the `defsrc` grid. Actions are copied from `copyFrom`
    /// (missing positions become `_`) or are all `_`.
    public func addLayer(name: String, copyFrom: String? = nil) throws -> ConfigDocument {
        guard let layout = gridLayout else { throw EditError.missingDefsrc }
        guard layerForm(named: name) == nil else { throw EditError.layerAlreadyExists(name) }
        let count = sourceKeys.count
        var tokens = [String](repeating: "_", count: count)
        if let copyFrom {
            guard let source = actionTexts(layer: copyFrom) else { throw EditError.unknownLayer(copyFrom) }
            for (i, t) in source.prefix(count).enumerated() { tokens[i] = t }
        }
        let form = Formatter.layerForm(name: name, tokens: tokens, layout: layout, widths: gridWidths)
        return appendingForm(form)
    }

    /// Renames a layer and every `(layer-while-held …)` / `(layer-toggle …)` / `(layer-switch …)` reference to it.
    public func renameLayer(_ name: String, to newName: String) throws -> ConfigDocument {
        guard let form = layerForm(named: name), let nameAtom = form.arguments.first?.asAtom else {
            throw EditError.unknownLayer(name)
        }
        guard name == newName || layerForm(named: newName) == nil else { throw EditError.layerAlreadyExists(newName) }
        var edits = [alignedEdit(replacing: nameAtom.range, with: newName)]
        for ref in layerReferences(to: name) { edits.append(alignedEdit(replacing: ref.range, with: newName)) }
        return applying(edits)
    }

    /// Deletes a layer. References to it are left in place and reported as error diagnostics
    /// (positions refer to the returned document).
    public func deleteLayer(_ name: String) throws -> (document: ConfigDocument, diagnostics: [Diagnostic]) {
        guard let form = layerForm(named: name) else { throw EditError.unknownLayer(name) }
        let updated = applying([ByteEdit(range: removalRange(forForm: form), replacement: "")])
        let diagnostics = updated.layerReferences(to: name).map { ref in
            Diagnostic(severity: .error, message: "layer '\(name)' was deleted but is still referenced here",
                       range: ref.range, in: updated.sourceMap)
        }
        return (updated, diagnostics)
    }

    /// Rewrites only the whitespace of `layer` so its actions sit on the `defsrc` grid. Comments inside
    /// the form are preserved verbatim.
    public func realign(layer name: String) throws -> ConfigDocument {
        guard let layout = gridLayout else { throw EditError.missingDefsrc }
        guard let form = layerForm(named: name) else { throw EditError.unknownLayer(name) }
        let actions = Array(form.arguments.dropFirst())
        var preserved: [Int: String] = [:]
        for (p, node) in actions.enumerated() where Formatter.containsComment(node.leadingTrivia) {
            preserved[p] = node.leadingTrivia
        }
        let closeTrivia = Formatter.containsComment(form.closeTrivia) ? form.closeTrivia : nil
        let text = Formatter.layerForm(name: name, tokens: actions.map(\.tokenText), layout: layout,
                                       widths: gridWidths, preservedTrivia: preserved, closeTrivia: closeTrivia)
        return applying([ByteEdit(range: form.range, replacement: text)])
    }

    /// Name atoms of every layer reference to `name` anywhere in the tree.
    func layerReferences(to name: String) -> [Atom] {
        var out: [Atom] = []
        func walk(_ node: SyntaxNode) {
            guard let list = node.asList else { return }
            if let head = list.head, ["layer-while-held", "layer-toggle", "layer-switch"].contains(head.text.lowercased()),
               let target = list.arguments.first?.asAtom, target.text == name {
                out.append(target)
            }
            for child in list.children { walk(child) }
        }
        for node in tree.nodes { walk(node) }
        return out
    }

    // MARK: - Form insertion

    /// Appends a top-level form at the end of the file, separated by one blank line.
    func appendingForm(_ form: String) -> ConfigDocument {
        let bytes = sourceMap.bytes
        var trailingNewlines = 0
        while trailingNewlines < bytes.count, bytes[bytes.count - 1 - trailingNewlines] == UInt8(ascii: "\n") {
            trailingNewlines += 1
        }
        let separator = bytes.count == trailingNewlines ? "" : String(repeating: "\n", count: max(0, 2 - trailingNewlines))
        return inserting(separator + form + "\n", at: bytes.count)
    }

    /// Inserts a top-level form after `anchor` (or appends it when `anchor` is `nil`).
    func insertForm(_ form: String, after anchor: ListNode?) -> ConfigDocument {
        guard let anchor else { return appendingForm(form) }
        return inserting("\n\n" + form, at: anchor.range.upperBound)
    }
}
