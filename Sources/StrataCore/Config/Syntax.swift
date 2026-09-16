/// Lossless concrete syntax tree for the `.kbd` S-expression dialect.
///
/// Every node records the UTF-8 byte range of its own token(s) in the original text plus the
/// *leading trivia* (whitespace and comments) that preceded it, so `SyntaxTree.text` reproduces
/// the source byte-for-byte. All types are plain values and `Sendable`.

/// 1-based line and column. Columns count unicode scalars, not bytes.
public struct SourceLocation: Sendable, Hashable, Comparable, CustomStringConvertible {
    public var line: Int
    public var column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }

    public static func < (lhs: SourceLocation, rhs: SourceLocation) -> Bool {
        (lhs.line, lhs.column) < (rhs.line, rhs.column)
    }

    public var description: String { "\(line):\(column)" }
}

/// Maps UTF-8 byte offsets of a text to line/column positions and back.
public struct SourceMap: Sendable {
    /// The text as UTF-8 bytes. Byte ranges in the CST index into this array.
    public let bytes: [UInt8]
    /// Byte offset at which each line starts (line 0 starts at 0).
    public let lineStarts: [Int]

    public init(text: String) {
        let bytes = Array(text.utf8)
        var starts = [0]
        for (i, b) in bytes.enumerated() where b == UInt8(ascii: "\n") {
            starts.append(i + 1)
        }
        self.bytes = bytes
        self.lineStarts = starts
    }

    public var lineCount: Int { lineStarts.count }

    /// Zero-based index of the line containing `offset` (offsets past the end map to the last line).
    public func lineIndex(ofByte offset: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Byte range of line `index` (zero-based), excluding the terminating newline.
    public func lineRange(_ index: Int) -> Range<Int> {
        let start = lineStarts[index]
        // The next line starts right after this line's "\n"; drop it (and a preceding "\r").
        var end = index + 1 < lineStarts.count ? lineStarts[index + 1] - 1 : bytes.count
        if end > start, bytes[end - 1] == UInt8(ascii: "\r") { end -= 1 }
        return start..<max(start, end)
    }

    /// 1-based line/column of a byte offset.
    public func location(ofByte offset: Int) -> SourceLocation {
        let clamped = min(max(offset, 0), bytes.count)
        let line = lineIndex(ofByte: clamped)
        var column = 1
        var i = lineStarts[line]
        while i < clamped {
            if bytes[i] & 0xC0 != 0x80 { column += 1 } // count non-continuation bytes = scalars
            i += 1
        }
        return SourceLocation(line: line + 1, column: column)
    }

    /// Number of unicode scalars in `range`.
    public func scalarWidth(_ range: Range<Int>) -> Int {
        var n = 0
        for i in range where i < bytes.count && bytes[i] & 0xC0 != 0x80 { n += 1 }
        return n
    }

    /// Decodes the bytes in `range` as a string.
    public func text(in range: Range<Int>) -> String {
        let r = max(0, range.lowerBound)..<min(bytes.count, max(range.lowerBound, range.upperBound))
        return String(decoding: bytes[r], as: UTF8.self)
    }
}

/// A bare word: anything that is not whitespace, `(`, `)` or `"`.
public struct Atom: Sendable, Hashable {
    /// Whitespace and comments preceding the atom.
    public var leadingTrivia: String
    /// The atom's text exactly as written.
    public var text: String
    /// Byte range of `text` in the original source.
    public var range: Range<Int>

    public init(leadingTrivia: String = "", text: String, range: Range<Int>) {
        self.leadingTrivia = leadingTrivia
        self.text = text
        self.range = range
    }
}

/// A `"…"` literal (`\"` and `\\` escapes are recognised).
public struct StringLiteral: Sendable, Hashable {
    public var leadingTrivia: String
    /// Source text including the quotes.
    public var rawText: String
    /// Unescaped content.
    public var value: String
    public var range: Range<Int>

    public init(leadingTrivia: String = "", rawText: String, value: String, range: Range<Int>) {
        self.leadingTrivia = leadingTrivia
        self.rawText = rawText
        self.value = value
        self.range = range
    }
}

/// A parenthesised list `( … )`.
public struct ListNode: Sendable, Hashable {
    public var leadingTrivia: String
    /// Byte range of the `(`.
    public var openRange: Range<Int>
    public var children: [SyntaxNode]
    /// Trivia between the last child (or `(`) and the `)`.
    public var closeTrivia: String
    /// Byte range of the `)`; `nil` when the list was never closed (parse error).
    public var closeRange: Range<Int>?

    public init(leadingTrivia: String = "", openRange: Range<Int>, children: [SyntaxNode],
                closeTrivia: String = "", closeRange: Range<Int>?) {
        self.leadingTrivia = leadingTrivia
        self.openRange = openRange
        self.children = children
        self.closeTrivia = closeTrivia
        self.closeRange = closeRange
    }

    /// Byte range from `(` to `)` inclusive (to the end of the last child if unclosed).
    public var range: Range<Int> {
        if let close = closeRange { return openRange.lowerBound..<close.upperBound }
        let end = children.last?.range.upperBound ?? openRange.upperBound
        return openRange.lowerBound..<(end + closeTrivia.utf8.count)
    }

    /// The first child if it is an atom (the "head" of a form), e.g. `defsrc`.
    public var head: Atom? {
        if case .atom(let a)? = children.first { return a }
        return nil
    }

    /// Children after the head.
    public var arguments: ArraySlice<SyntaxNode> { children.dropFirst() }
}

/// One node of the CST.
public indirect enum SyntaxNode: Sendable, Hashable {
    case atom(Atom)
    case string(StringLiteral)
    case list(ListNode)

    public var leadingTrivia: String {
        switch self {
        case .atom(let a): return a.leadingTrivia
        case .string(let s): return s.leadingTrivia
        case .list(let l): return l.leadingTrivia
        }
    }

    /// Byte range of the node's own text (excluding leading trivia).
    public var range: Range<Int> {
        switch self {
        case .atom(let a): return a.range
        case .string(let s): return s.range
        case .list(let l): return l.range
        }
    }

    /// Source text of the node without its leading trivia.
    public var tokenText: String {
        switch self {
        case .atom(let a): return a.text
        case .string(let s): return s.rawText
        case .list(let l):
            var out = "("
            for c in l.children { out += c.text }
            out += l.closeTrivia
            if l.closeRange != nil { out += ")" }
            return out
        }
    }

    /// Source text including leading trivia.
    public var text: String { leadingTrivia + tokenText }

    public var asAtom: Atom? {
        if case .atom(let a) = self { return a }
        return nil
    }

    public var asList: ListNode? {
        if case .list(let l) = self { return l }
        return nil
    }

    /// The textual value for atoms and strings (`nil` for lists).
    public var scalarText: String? {
        switch self {
        case .atom(let a): return a.text
        case .string(let s): return s.value
        case .list: return nil
        }
    }
}

/// Root of a parsed file: top-level nodes plus the trivia after the last one.
public struct SyntaxTree: Sendable, Hashable {
    public var nodes: [SyntaxNode]
    public var trailingTrivia: String

    public init(nodes: [SyntaxNode], trailingTrivia: String = "") {
        self.nodes = nodes
        self.trailingTrivia = trailingTrivia
    }

    /// Re-serialises the tree; equals the original source text.
    public var text: String {
        var out = ""
        for n in nodes { out += n.text }
        out += trailingTrivia
        return out
    }

    /// Top-level lists whose head atom equals `name` (case-insensitive).
    public func forms(named name: String) -> [ListNode] {
        nodes.compactMap { node in
            guard let l = node.asList, let h = l.head, h.text.lowercased() == name.lowercased() else { return nil }
            return l
        }
    }
}
