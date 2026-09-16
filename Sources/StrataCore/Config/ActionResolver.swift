/// Turns action syntax into `Action` values, resolving `@alias` references (recursively, with
/// cycle detection) and layer names.
///
/// Grammar:
/// - `_` → transparent; `XX` / `none` / `nop` → block
/// - `@name` → alias reference
/// - key name (case-insensitive; `\\` is backslash), kmonad shifted symbols (`*` → shift+8, …)
/// - `M-` `C-` `A-` `S-` (`RM-` `RC-` `RA-` `RS-`) prefixes, stackable: `C-S-tab`
/// - `(chord mod… key)`, `(layer-while-held L)` / `(layer-toggle L)`, `(layer-switch L)`
/// - `(tap-hold [tap-ms [hold-ms]] tap hold)`, `-press`, `-release` / `-next-release` / `-next`, `-timeout`
///   (one integer = hold timeout; two integers = tap timeout then hold timeout)
/// - `(macro a b …)`
struct ActionResolver {
    enum Context {
        case top, tapHold, macro
    }

    private enum AliasState {
        case resolving
        case resolved(Action?)
    }

    var compiler: Compiler
    private let aliases: [String: (name: Atom, value: SyntaxNode)]
    private let layers: [String: Int]
    private var aliasStates: [String: AliasState] = [:]

    init(compiler: Compiler, aliases: [String: (name: Atom, value: SyntaxNode)], layers: [String: Int]) {
        self.compiler = compiler
        self.aliases = aliases
        self.layers = layers
    }

    private static let modifierPrefixes: [(String, HIDKey)] = [
        ("RM-", Keys.rightCommand), ("RC-", Keys.rightControl), ("RA-", Keys.rightOption), ("RS-", Keys.rightShift),
        ("M-", Keys.leftCommand), ("C-", Keys.leftControl), ("A-", Keys.leftOption), ("S-", Keys.leftShift),
    ]

    // MARK: - Entry points

    /// Resolves `node` in `context`, reporting diagnostics. Returns `nil` on error.
    mutating func resolve(_ node: SyntaxNode, context: Context) -> Action? {
        guard let action = resolveUnchecked(node, context: context) else { return nil }
        if case .tapHold = action {
            switch context {
            case .tapHold:
                compiler.error("nested tap-hold is not allowed", at: node.range)
                return nil
            case .macro:
                compiler.error("tap-hold is not allowed inside a macro", at: node.range)
                return nil
            case .top:
                break
            }
        }
        return action
    }

    /// Resolves an alias that no layer referenced so its definition still gets validated.
    mutating func resolveUnreferencedAlias(_ name: String) {
        guard aliasStates[name] == nil, let def = aliases[name] else { return }
        aliasStates[name] = .resolving
        let action = resolve(def.value, context: .top)
        aliasStates[name] = .resolved(action)
    }

    // MARK: - Atoms

    private mutating func resolveUnchecked(_ node: SyntaxNode, context: Context) -> Action? {
        switch node {
        case .string(let s):
            compiler.error("unexpected string \(s.rawText); actions are bare words or lists", at: s.range)
            return nil
        case .atom(let atom):
            return resolveAtom(atom)
        case .list(let list):
            return resolveList(list, context: context)
        }
    }

    private mutating func resolveAtom(_ atom: Atom) -> Action? {
        let text = atom.text
        if text == "_" { return .transparent }
        switch text.lowercased() {
        case "xx", "none", "nop": return .block
        default: break
        }
        if text.hasPrefix("@"), text.count > 1 {
            return resolveAlias(String(text.dropFirst()), reference: atom)
        }
        if let key = KeyNames.key(named: text) { return .key(key) }
        if let shifted = KeyNames.shiftedKey(named: text) {
            return .chord(modifiers: [Keys.leftShift], key: shifted)
        }
        switch chordShorthand(text) {
        case .chord(let mods, let key): return .chord(modifiers: mods, key: key)
        case .unknownKey(let rest):
            compiler.error("unknown key '\(rest)' in chord '\(text)'" + KeyNames.suggestionSuffix(for: rest),
                           at: atom.range)
            return nil
        case .notAChord: break
        }
        compiler.error("unknown key '\(text)'" + KeyNames.suggestionSuffix(for: text), at: atom.range)
        return nil
    }

    private enum Shorthand {
        case chord([HIDKey], HIDKey)
        case unknownKey(String)
        case notAChord
    }

    /// `M-c`, `C-S-tab`, `RA-x` … Prefixes are case-sensitive (upper case) and applied left to right.
    private func chordShorthand(_ text: String) -> Shorthand {
        var rest = Substring(text)
        var modifiers: [HIDKey] = []
        outer: while true {
            for (prefix, key) in Self.modifierPrefixes where rest.hasPrefix(prefix) && rest.count > prefix.count {
                rest = rest.dropFirst(prefix.count)
                if !modifiers.contains(key) { modifiers.append(key) }
                continue outer
            }
            break
        }
        guard !modifiers.isEmpty else { return .notAChord }
        let name = String(rest)
        if let key = KeyNames.key(named: name) { return .chord(modifiers, key) }
        if let key = KeyNames.shiftedKey(named: name) {
            if !modifiers.contains(Keys.leftShift), !modifiers.contains(Keys.rightShift) {
                modifiers.append(Keys.leftShift)
            }
            return .chord(modifiers, key)
        }
        return .unknownKey(name)
    }

    private mutating func resolveAlias(_ name: String, reference: Atom) -> Action? {
        guard let def = aliases[name] else {
            var message = "unknown alias '@\(name)'"
            if let s = closestAlias(to: name) { message += " (did you mean '@\(s)'?)" }
            compiler.error(message, at: reference.range)
            return nil
        }
        switch aliasStates[name] {
        case .resolving?:
            compiler.error("alias '@\(name)' refers to itself (cycle)", at: reference.range)
            return nil
        case .resolved(let action)?:
            return action
        case nil:
            aliasStates[name] = .resolving
            let action = resolve(def.value, context: .top)
            aliasStates[name] = .resolved(action)
            return action
        }
    }

    private func closestAlias(to name: String) -> String? {
        var best: (String, Int)?
        for candidate in aliases.keys where abs(candidate.count - name.count) <= 2 {
            let d = KeyTable.levenshtein(name.lowercased(), candidate.lowercased())
            if d <= 2, best == nil || d < best!.1 { best = (candidate, d) }
        }
        return best?.0
    }

    // MARK: - Lists

    private mutating func resolveList(_ list: ListNode, context: Context) -> Action? {
        guard let head = list.head else {
            compiler.error("expected an action name after '('", at: list.openRange)
            return nil
        }
        let args = Array(list.arguments)
        switch head.text.lowercased() {
        case "chord":
            return resolveChord(args, list: list)
        case "layer-while-held", "layer-toggle":
            return resolveLayerReference(args, list: list, head: head).map(Action.layerWhileHeld)
        case "layer-switch":
            return resolveLayerReference(args, list: list, head: head).map(Action.layerSwitch)
        case "tap-hold":
            return resolveTapHold(args, list: list, head: head, resolution: nil)
        case "tap-hold-press":
            return resolveTapHold(args, list: list, head: head, resolution: .holdOnPress)
        case "tap-hold-release", "tap-hold-next-release", "tap-hold-next":
            return resolveTapHold(args, list: list, head: head, resolution: .permissive)
        case "tap-hold-timeout":
            return resolveTapHold(args, list: list, head: head, resolution: .timeout)
        case "macro":
            var steps: [Action] = []
            var failed = false
            for arg in args {
                if let a = resolve(arg, context: .macro) { steps.append(a) } else { failed = true }
            }
            if args.isEmpty { compiler.error("macro needs at least one action", at: list.range) }
            return failed || args.isEmpty ? nil : .macro(steps)
        default:
            compiler.error("unknown action '\(head.text)'", at: head.range)
            return nil
        }
    }

    private mutating func resolveChord(_ args: [SyntaxNode], list: ListNode) -> Action? {
        guard args.count >= 2 else {
            compiler.error("(chord …) needs at least one modifier and a key", at: list.range)
            return nil
        }
        var keys: [HIDKey] = []
        for arg in args {
            guard let atom = arg.asAtom, let key = KeyNames.key(named: atom.text) else {
                let text = arg.tokenText
                compiler.error("unknown key '\(text)'" + KeyNames.suggestionSuffix(for: text), at: arg.range)
                return nil
            }
            keys.append(key)
        }
        for (arg, key) in zip(args.dropLast(), keys.dropLast()) where !key.isModifier {
            compiler.error("'\(arg.tokenText)' is not a modifier key", at: arg.range)
            return nil
        }
        return .chord(modifiers: Array(keys.dropLast()), key: keys[keys.count - 1])
    }

    private mutating func resolveLayerReference(_ args: [SyntaxNode], list: ListNode, head: Atom) -> LayerID? {
        guard args.count == 1, let atom = args[0].asAtom else {
            compiler.error("(\(head.text) …) takes exactly one layer name", at: list.range)
            return nil
        }
        guard let id = layers[atom.text] else {
            compiler.error("unknown layer '\(atom.text)'", at: atom.range)
            return nil
        }
        return id
    }

    private mutating func resolveTapHold(_ args: [SyntaxNode], list: ListNode, head: Atom,
                                         resolution: TapHoldResolution?) -> Action? {
        var tapTimeout: Int?
        var holdTimeout: Int?
        var rest = args[...]
        switch args.count {
        case 2:
            break
        case 3:
            guard let ms = integer(args[0], what: "hold timeout") else { return nil }
            holdTimeout = ms
            rest = args[1...]
        case 4:
            guard let tap = integer(args[0], what: "tap timeout"),
                  let hold = integer(args[1], what: "hold timeout") else { return nil }
            tapTimeout = tap
            holdTimeout = hold
            rest = args[2...]
        default:
            compiler.error("(\(head.text) [tap-ms [hold-ms]] tap hold) expects 2 to 4 arguments, found \(args.count)",
                           at: list.range)
            return nil
        }
        let tap = resolve(rest[rest.startIndex], context: .tapHold)
        let hold = resolve(rest[rest.startIndex + 1], context: .tapHold)
        guard let tap, let hold else { return nil }
        return .tapHold(Action.TapHold(tap: tap, hold: hold, tapTimeoutMs: tapTimeout,
                                       holdTimeoutMs: holdTimeout, resolution: resolution))
    }

    private mutating func integer(_ node: SyntaxNode, what: String) -> Int? {
        guard let text = node.asAtom?.text, let value = Int(text), value >= 0 else {
            compiler.error("expected \(what) in milliseconds, found '\(node.tokenText)'", at: node.range)
            return nil
        }
        return value
    }
}
