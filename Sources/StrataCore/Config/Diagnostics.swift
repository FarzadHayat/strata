/// A problem found while parsing or compiling a config file.
public struct Diagnostic: Sendable, Hashable, CustomStringConvertible {
    public enum Severity: String, Sendable, Hashable {
        case error, warning
    }

    public var severity: Severity
    public var message: String
    /// 1-based line.
    public var line: Int
    /// 1-based column in unicode scalars.
    public var column: Int
    /// UTF-8 byte range of the offending token(s) in the source text.
    public var range: Range<Int>

    public init(severity: Severity, message: String, line: Int, column: Int, range: Range<Int>) {
        self.severity = severity
        self.message = message
        self.line = line
        self.column = column
        self.range = range
    }

    public init(severity: Severity, message: String, range: Range<Int>, in map: SourceMap) {
        let loc = map.location(ofByte: range.lowerBound)
        self.init(severity: severity, message: message, line: loc.line, column: loc.column, range: range)
    }

    public var isError: Bool { severity == .error }

    /// Line and column as a `SourceLocation`.
    public var location: SourceLocation { SourceLocation(line: line, column: column) }

    /// `keymap.kbd:14:22: error: …`
    public func description(filename: String) -> String {
        "\(filename):\(line):\(column): \(severity.rawValue): \(message)"
    }

    /// `14:22: error: …`
    public var description: String { "\(line):\(column): \(severity.rawValue): \(message)" }
}

/// Outcome of compiling a config: the keymap (only when there were no errors) plus all diagnostics.
public struct CompileResult: Sendable {
    public var keymap: Keymap?
    public var diagnostics: [Diagnostic]

    public init(keymap: Keymap?, diagnostics: [Diagnostic]) {
        self.keymap = keymap
        self.diagnostics = diagnostics
    }

    public var errors: [Diagnostic] { diagnostics.filter { $0.severity == .error } }
    public var warnings: [Diagnostic] { diagnostics.filter { $0.severity == .warning } }
    public var hasErrors: Bool { diagnostics.contains { $0.severity == .error } }
}
