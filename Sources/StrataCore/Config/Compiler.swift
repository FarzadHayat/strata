/// Compiles a `.kbd` source text into a `Keymap`.
///
/// Recognised top-level forms: `(defcfg key value …)`, `(defsrc key …)`, `(defalias name action …)`,
/// `(deflayer name action …)`. See `ActionResolver` for the action grammar.
public func compile(text: String) -> CompileResult {
    ConfigCompiler.compile(text: text)
}

/// Namespace for the compiler entry points.
public enum ConfigCompiler {
    /// Parses and compiles `text`.
    public static func compile(text: String) -> CompileResult {
        let map = SourceMap(text: text)
        let (tree, parseDiagnostics) = Parser.parse(map: map)
        return compile(tree: tree, map: map, parseDiagnostics: parseDiagnostics)
    }

    /// Compiles an already-parsed tree. `parseDiagnostics` are merged into the result.
    public static func compile(tree: SyntaxTree, map: SourceMap, parseDiagnostics: [Diagnostic] = []) -> CompileResult {
        var compiler = Compiler(tree: tree, map: map)
        compiler.diagnostics = parseDiagnostics
        return compiler.run()
    }
}

/// Names of every key the config format accepts, including the kmonad spellings that
/// `KeyTable` does not know about.
public enum KeyNames {
    /// Resolves a plain (unshifted) key name. Accepts `\\` as the backslash key because kmonad files
    /// escape it.
    public static func key(named text: String) -> HIDKey? {
        if text == "\\\\" { return KeyTable.key(named: "\\") }
        return KeyTable.key(named: text)
    }

    /// kmonad-style shifted symbols: `*` is shift+8, `+` is shift+=, and so on. `(` and `)` cannot be
    /// atoms, so they are spelled `lparen` / `rparen`; `"` starts a string and has no shifted spelling.
    /// Returns the *unshifted* key; the caller adds left shift.
    public static func shiftedKey(named text: String) -> HIDKey? {
        guard let base = shifted[text] else { return nil }
        return KeyTable.key(named: base)
    }

    private static let shifted: [String: String] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8",
        "<": ",", ">": ".", ":": ";", "~": "`", "|": "\\", "{": "[", "}": "]", "+": "=", "?": "/",
        "lparen": "9", "rparen": "0",
    ]

    /// A `did you mean` suffix for an unknown key name, or an empty string.
    static func suggestionSuffix(for text: String) -> String {
        guard let s = KeyTable.suggestion(for: text) else { return "" }
        return " (did you mean '\(s)'?)"
    }
}

struct Compiler {
    let tree: SyntaxTree
    let map: SourceMap
    var diagnostics: [Diagnostic] = []

    private var settings = Settings()
    private var source: [HIDKey] = []
    private var sourceForm: ListNode?
    private var layerForms: [(name: Atom, form: ListNode)] = []
    private var layerIndex: [String: Int] = [:]
    private var aliasDefinitions: [String: (name: Atom, value: SyntaxNode)] = [:]

    init(tree: SyntaxTree, map: SourceMap) {
        self.tree = tree
        self.map = map
    }

    // MARK: - Diagnostics

    mutating func error(_ message: String, at range: Range<Int>) {
        diagnostics.append(Diagnostic(severity: .error, message: message, range: range, in: map))
    }

    mutating func warning(_ message: String, at range: Range<Int>) {
        diagnostics.append(Diagnostic(severity: .warning, message: message, range: range, in: map))
    }

    // MARK: - Driver

    mutating func run() -> CompileResult {
        for node in tree.nodes { collect(node) }

        if sourceForm == nil {
            error("missing (defsrc …) form", at: 0..<0)
        }
        if layerForms.isEmpty {
            error("no (deflayer …) forms defined; the first deflayer is the base layer", at: 0..<0)
        }

        var resolver = ActionResolver(compiler: self, aliases: aliasDefinitions, layers: layerIndex)
        var layers: [Layer] = []
        for (nameAtom, form) in layerForms {
            let actionNodes = Array(form.arguments.dropFirst())
            if sourceForm != nil, actionNodes.count != source.count {
                resolver.compiler.error(
                    "layer '\(nameAtom.text)' has \(actionNodes.count) actions but defsrc has \(source.count) keys",
                    at: nameAtom.range)
            }
            let actions = actionNodes.map { resolver.resolve($0, context: .top) }
            layers.append(Layer(name: nameAtom.text, actions: actions))
        }
        // Resolve aliases that were never referenced so their errors are still reported.
        for name in aliasDefinitions.keys.sorted() { resolver.resolveUnreferencedAlias(name) }

        diagnostics = resolver.compiler.diagnostics
        let keymap = diagnostics.contains { $0.isError }
            ? nil : Keymap(settings: settings, source: source, layers: layers)
        return CompileResult(keymap: keymap, diagnostics: diagnostics)
    }

    // MARK: - Top-level forms

    private mutating func collect(_ node: SyntaxNode) {
        guard let list = node.asList else {
            if node.tokenText == ")" { return } // already reported by the parser
            error("expected a form such as (defsrc …), (deflayer …), (defalias …) or (defcfg …)", at: node.range)
            return
        }
        guard let head = list.head else {
            error("expected a form name after '('", at: list.openRange)
            return
        }
        switch head.text.lowercased() {
        case "defcfg": collectSettings(list)
        case "defsrc": collectSource(list, head: head)
        case "defalias": collectAliases(list)
        case "deflayer": collectLayer(list, head: head)
        default:
            error("unknown form '\(head.text)'", at: head.range)
        }
    }

    private mutating func collectSource(_ list: ListNode, head: Atom) {
        if sourceForm != nil {
            error("duplicate (defsrc …); only one is allowed", at: head.range)
            return
        }
        sourceForm = list
        var seen: [HIDKey: Atom] = [:]
        for node in list.arguments {
            guard let atom = node.asAtom else {
                error("defsrc entries must be plain key names", at: node.range)
                continue
            }
            guard let key = KeyNames.key(named: atom.text) else {
                error("unknown key '\(atom.text)'" + KeyNames.suggestionSuffix(for: atom.text), at: atom.range)
                continue
            }
            if let first = seen[key] {
                warning("duplicate key '\(atom.text)' in defsrc (first at \(map.location(ofByte: first.range.lowerBound)))",
                        at: atom.range)
            } else {
                seen[key] = atom
            }
            source.append(key)
        }
    }

    private mutating func collectLayer(_ list: ListNode, head: Atom) {
        guard let nameAtom = list.arguments.first?.asAtom else {
            error("deflayer needs a layer name", at: list.arguments.first?.range ?? head.range)
            return
        }
        if layerIndex[nameAtom.text] != nil {
            error("duplicate layer name '\(nameAtom.text)'", at: nameAtom.range)
            return
        }
        layerIndex[nameAtom.text] = layerForms.count
        layerForms.append((nameAtom, list))
    }

    private mutating func collectAliases(_ list: ListNode) {
        let args = Array(list.arguments)
        var i = 0
        while i < args.count {
            guard let nameAtom = args[i].asAtom else {
                error("alias name must be a plain word", at: args[i].range)
                i += 1
                continue
            }
            guard i + 1 < args.count else {
                error("alias '\(nameAtom.text)' has no action", at: nameAtom.range)
                break
            }
            let name = nameAtom.text.hasPrefix("@") ? String(nameAtom.text.dropFirst()) : nameAtom.text
            if aliasDefinitions[name] != nil {
                error("duplicate alias '\(name)'", at: nameAtom.range)
            } else {
                aliasDefinitions[name] = (nameAtom, args[i + 1])
            }
            i += 2
        }
    }

    // MARK: - defcfg

    private mutating func collectSettings(_ list: ListNode) {
        let args = Array(list.arguments)
        var i = 0
        while i < args.count {
            guard let keyAtom = args[i].asAtom else {
                error("defcfg expects key/value pairs; found a non-word key", at: args[i].range)
                i += 1
                continue
            }
            guard i + 1 < args.count else {
                error("defcfg key '\(keyAtom.text)' has no value", at: keyAtom.range)
                break
            }
            applySetting(key: keyAtom, value: args[i + 1])
            i += 2
        }
    }

    private mutating func applySetting(key: Atom, value: SyntaxNode) {
        switch key.text.lowercased() {
        case "tap-hold-resolution":
            if let text = value.scalarText, let r = TapHoldResolution(rawValue: text.lowercased()) {
                settings.resolution = r
            } else {
                error("tap-hold-resolution must be one of permissive | hold-on-press | timeout", at: value.range)
            }
        case "tap-timeout":
            if let ms = milliseconds(value) { settings.tapTimeoutMs = ms }
        case "hold-timeout":
            if let ms = milliseconds(value) { settings.holdTimeoutMs = ms }
        case "prior-idle":
            if let ms = milliseconds(value) { settings.priorIdleMs = ms }
        case "fn-row":
            if let text = value.scalarText, let m = FunctionRowMode(rawValue: text.lowercased()) {
                settings.functionRow = m
            } else {
                error("fn-row must be one of system | media | function", at: value.range)
            }
        case "exclude-devices":
            if let list = value.asList {
                for item in list.children {
                    if let text = item.scalarText {
                        settings.excludeDevices.append(text)
                    } else {
                        error("exclude-devices entries must be device names", at: item.range)
                    }
                }
            } else if let text = value.scalarText {
                settings.excludeDevices.append(text)
            }
        default:
            warning("unknown defcfg key '\(key.text)' (ignored)", at: key.range)
        }
    }

    private mutating func milliseconds(_ node: SyntaxNode) -> Int? {
        guard let text = node.scalarText, let ms = Int(text), ms >= 0 else {
            error("expected a non-negative number of milliseconds", at: node.range)
            return nil
        }
        return ms
    }
}
