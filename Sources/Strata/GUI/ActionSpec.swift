import Foundation
import StrataCore

/// A modifier that can take part in a chord. Left-hand modifiers have the `M- C- A- S-` shorthand.
enum ChordModifier: String, CaseIterable, Hashable, Sendable {
    case lmet, lctl, lalt, lsft, rmet, rctl, ralt, rsft

    static let left: [ChordModifier] = [.lmet, .lctl, .lalt, .lsft]
    static let right: [ChordModifier] = [.rmet, .rctl, .ralt, .rsft]

    var isRight: Bool { ChordModifier.right.contains(self) }

    /// Shorthand prefix (`M-`, `RM-` …). Left modifiers are emitted in the order `M- C- A- S-`.
    var prefix: String {
        switch self {
        case .lmet: return "M-"
        case .lctl: return "C-"
        case .lalt: return "A-"
        case .lsft: return "S-"
        case .rmet: return "RM-"
        case .rctl: return "RC-"
        case .ralt: return "RA-"
        case .rsft: return "RS-"
        }
    }

    var glyph: String {
        switch self {
        case .lmet, .rmet: return "⌘"
        case .lctl, .rctl: return "⌃"
        case .lalt, .ralt: return "⌥"
        case .lsft, .rsft: return "⇧"
        }
    }

    var title: String {
        switch self {
        case .lmet, .rmet: return "Command"
        case .lctl, .rctl: return "Control"
        case .lalt, .ralt: return "Option"
        case .lsft, .rsft: return "Shift"
        }
    }

    /// Display order used by macOS: ⌃ ⌥ ⇧ ⌘.
    static func displaySorted(_ mods: [ChordModifier]) -> [ChordModifier] {
        let rank: [ChordModifier: Int] = [.lctl: 0, .rctl: 1, .lalt: 2, .ralt: 3, .lsft: 4, .rsft: 5, .lmet: 6, .rmet: 7]
        return mods.sorted { (rank[$0] ?? 9) < (rank[$1] ?? 9) }
    }

    init?(keyName: String) {
        guard let key = KeyTable.key(named: keyName), let canonical = KeyTable.canonicalName(for: key) else { return nil }
        self.init(rawValue: canonical)
    }
}

/// The kinds of action the inspector can edit structurally.
enum ActionKind: String, CaseIterable, Identifiable {
    case transparent, block, key, chord, layerWhileHeld, layerSwitch, tapHold, alias, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transparent: return "Transparent"
        case .block: return "Block"
        case .key: return "Key"
        case .chord: return "Chord"
        case .layerWhileHeld: return "Layer while held"
        case .layerSwitch: return "Layer switch"
        case .tapHold: return "Tap-hold"
        case .alias: return "Alias"
        case .advanced: return "Advanced"
        }
    }

    /// Kinds allowed inside a tap-hold.
    static let tapHoldSubKinds: [ActionKind] = [.key, .chord, .layerWhileHeld, .layerSwitch, .block]
}

/// Editable, structured form of one action token. `raw` keeps anything the structured editors do not
/// model (macros, shifted symbols, tap-hold variants with an explicit resolution …) verbatim.
indirect enum ActionSpec: Equatable, Sendable {
    case transparent
    case block
    /// Canonical key name.
    case key(String)
    case chord(modifiers: [ChordModifier], key: String)
    case layerWhileHeld(String)
    case layerSwitch(String)
    case tapHold(tap: ActionSpec, hold: ActionSpec, tapMs: Int?, holdMs: Int?)
    case alias(String)
    case raw(String)

    var kind: ActionKind {
        switch self {
        case .transparent: return .transparent
        case .block: return .block
        case .key: return .key
        case .chord: return .chord
        case .layerWhileHeld: return .layerWhileHeld
        case .layerSwitch: return .layerSwitch
        case .tapHold: return .tapHold
        case .alias: return .alias
        case .raw: return .advanced
        }
    }

    // MARK: - Serialisation

    /// Config text for this action. `defaultHoldMs` fills the hold timeout when only a tap timeout is set
    /// (the grammar needs both in that case).
    func text(defaultHoldMs: Int = Settings().holdTimeoutMs) -> String {
        switch self {
        case .transparent: return "_"
        case .block: return "XX"
        case .key(let name): return name
        case .chord(let mods, let key):
            if mods.contains(where: \.isRight) {
                return "(chord " + (mods.map(\.rawValue) + [key]).joined(separator: " ") + ")"
            }
            let ordered = ChordModifier.left.filter { mods.contains($0) }
            return ordered.map(\.prefix).joined() + key
        case .layerWhileHeld(let layer): return "(layer-while-held \(layer))"
        case .layerSwitch(let layer): return "(layer-switch \(layer))"
        case .tapHold(let tap, let hold, let tapMs, let holdMs):
            var parts = ["tap-hold"]
            if let tapMs { parts += [String(tapMs), String(holdMs ?? defaultHoldMs)] } else if let holdMs { parts.append(String(holdMs)) }
            parts += [tap.text(defaultHoldMs: defaultHoldMs), hold.text(defaultHoldMs: defaultHoldMs)]
            return "(" + parts.joined(separator: " ") + ")"
        case .alias(let name): return "@" + name
        case .raw(let text): return text
        }
    }

    // MARK: - Parsing

    /// Parses one action token. Anything unrecognised (or malformed) becomes `.raw(text)`.
    static func parse(_ text: String) -> ActionSpec {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let (tree, diagnostics) = Parser.parse(trimmed)
        guard diagnostics.isEmpty, tree.nodes.count == 1, let node = tree.nodes.first else { return .raw(trimmed) }
        return from(node) ?? .raw(trimmed)
    }

    private static func from(_ node: SyntaxNode) -> ActionSpec? {
        switch node {
        case .string: return nil
        case .atom(let atom): return fromAtom(atom.text)
        case .list(let list): return fromList(list)
        }
    }

    private static func canonical(_ name: String) -> String? {
        guard let key = KeyNames.key(named: name) else { return nil }
        return KeyTable.canonicalName(for: key)
    }

    private static func fromAtom(_ text: String) -> ActionSpec? {
        if text == "_" { return .transparent }
        if ["xx", "none", "nop"].contains(text.lowercased()) { return .block }
        if text.hasPrefix("@"), text.count > 1 { return .alias(String(text.dropFirst())) }
        if let name = canonical(text) { return .key(name) }
        // Chord shorthand: right-hand prefixes first so `RM-` is not read as `R` + `M-`.
        var rest = Substring(text)
        var mods: [ChordModifier] = []
        let prefixes = ChordModifier.right + ChordModifier.left
        scan: while true {
            for mod in prefixes where rest.hasPrefix(mod.prefix) && rest.count > mod.prefix.count {
                rest = rest.dropFirst(mod.prefix.count)
                if !mods.contains(mod) { mods.append(mod) }
                continue scan
            }
            break
        }
        if !mods.isEmpty, let name = canonical(String(rest)) { return .chord(modifiers: mods, key: name) }
        return nil
    }

    private static func fromList(_ list: ListNode) -> ActionSpec? {
        guard let head = list.head else { return nil }
        let args = Array(list.arguments)
        switch head.text.lowercased() {
        case "chord":
            guard args.count >= 2 else { return nil }
            var mods: [ChordModifier] = []
            for arg in args.dropLast() {
                guard let atom = arg.asAtom, let mod = ChordModifier(keyName: atom.text) else { return nil }
                mods.append(mod)
            }
            guard let last = args.last?.asAtom, let key = canonical(last.text) else { return nil }
            return .chord(modifiers: mods, key: key)
        case "layer-while-held", "layer-toggle":
            guard args.count == 1, let name = args[0].asAtom?.text else { return nil }
            return .layerWhileHeld(name)
        case "layer-switch":
            guard args.count == 1, let name = args[0].asAtom?.text else { return nil }
            return .layerSwitch(name)
        case "tap-hold":
            var tapMs: Int?
            var holdMs: Int?
            var rest = args[...]
            switch args.count {
            case 2: break
            case 3:
                guard let h = args[0].asAtom.flatMap({ Int($0.text) }) else { return nil }
                holdMs = h
                rest = args[1...]
            case 4:
                guard let t = args[0].asAtom.flatMap({ Int($0.text) }), let h = args[1].asAtom.flatMap({ Int($0.text) }) else { return nil }
                tapMs = t
                holdMs = h
                rest = args[2...]
            default: return nil
            }
            guard let tap = from(rest[rest.startIndex]), let hold = from(rest[rest.startIndex + 1]),
                  tap.kind != .tapHold, hold.kind != .tapHold else { return nil }
            return .tapHold(tap: tap, hold: hold, tapMs: tapMs, holdMs: holdMs)
        default:
            return nil
        }
    }

    // MARK: - Kind changes

    /// A sensible starting value when the user switches the inspector to `kind`, reusing as much of
    /// the current action as possible. `sourceKey` is the physical key's name; `layers` the other layers.
    func converted(to kind: ActionKind, sourceKey: String, layers: [String], aliases: [String]) -> ActionSpec {
        let firstLayer = layers.first ?? sourceKey
        switch kind {
        case .transparent: return .transparent
        case .block: return .block
        case .key:
            if case .chord(_, let key) = self { return .key(key) }
            if case .tapHold(let tap, _, _, _) = self, case .key = tap { return tap }
            return .key(sourceKey)
        case .chord:
            if case .key(let key) = self { return .chord(modifiers: [.lmet], key: key) }
            if case .tapHold(let tap, _, _, _) = self, case .chord = tap { return tap }
            return .chord(modifiers: [.lmet], key: sourceKey)
        case .layerWhileHeld:
            if case .layerSwitch(let l) = self { return .layerWhileHeld(l) }
            if case .tapHold(_, let hold, _, _) = self, case .layerWhileHeld = hold { return hold }
            return .layerWhileHeld(firstLayer)
        case .layerSwitch:
            if case .layerWhileHeld(let l) = self { return .layerSwitch(l) }
            return .layerSwitch(firstLayer)
        case .tapHold:
            let tap: ActionSpec
            switch self {
            case .key, .chord: tap = self
            default: tap = .key(sourceKey)
            }
            return .tapHold(tap: tap, hold: .layerWhileHeld(firstLayer), tapMs: nil, holdMs: nil)
        case .alias:
            return .alias(aliases.first ?? "")
        case .advanced:
            return .raw(text())
        }
    }
}
