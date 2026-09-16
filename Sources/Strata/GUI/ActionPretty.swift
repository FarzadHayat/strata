import Foundation
import StrataCore

/// What a keycap shows for the selected layer, and how prominently.
struct KeyDisplay: Equatable {
    enum Style: Equatable {
        /// Bound on the selected layer.
        case bound
        /// `_` on the selected layer; the value comes from a lower layer.
        case inherited
        /// Transparent all the way down: the hardware default.
        case hardware
        /// `XX`.
        case blocked
    }

    var text: String
    var style: Style
}

/// Human-friendly rendering of action tokens (`M-c` → "⌘C", `(layer-while-held extend)` → "▸extend").
enum ActionPretty {
    static let blockedGlyph = "∅"
    static let layerHeldGlyph = "▸"
    static let layerSwitchGlyph = "⇒"
    static let tapHoldSeparator = " ⁄ "

    /// Label of a key by canonical or alias name (falls back to the name itself).
    static func keyLabel(_ name: String) -> String {
        guard let key = KeyNames.key(named: name) else { return name }
        return KeyTable.label(for: key)
    }

    static func pretty(text: String, document: ConfigDocument?) -> String {
        pretty(ActionSpec.parse(text), document: document, depth: 0)
    }

    static func pretty(_ spec: ActionSpec, document: ConfigDocument?, depth: Int = 0) -> String {
        switch spec {
        case .transparent: return "_"
        case .block: return blockedGlyph
        case .key(let name): return keyLabel(name)
        case .chord(let mods, let key):
            return ChordModifier.displaySorted(mods).map(\.glyph).joined() + keyLabel(key)
        case .layerWhileHeld(let layer): return layerHeldGlyph + layer
        case .layerSwitch(let layer): return layerSwitchGlyph + layer
        case .tapHold(let tap, let hold, _, _):
            return pretty(tap, document: document, depth: depth + 1) + tapHoldSeparator + pretty(hold, document: document, depth: depth + 1)
        case .alias(let name):
            guard depth < 8, let def = document?.aliases.first(where: { $0.name == name }) else { return "@" + name }
            return pretty(ActionSpec.parse(def.text), document: document, depth: depth + 1)
        case .raw(let text):
            return prettyRaw(text, document: document, depth: depth)
        }
    }

    /// Best effort for tokens the structured model does not cover: shifted symbols show as themselves,
    /// macros as their steps, tap-hold variants as tap ⁄ hold.
    private static func prettyRaw(_ text: String, document: ConfigDocument?, depth: Int) -> String {
        let (tree, diagnostics) = Parser.parse(text)
        guard diagnostics.isEmpty, tree.nodes.count == 1, let list = tree.nodes.first?.asList, let head = list.head else {
            if text == "lparen" { return "(" }
            if text == "rparen" { return ")" }
            return text
        }
        let args = Array(list.arguments)
        switch head.text.lowercased() {
        case "macro":
            return args.map { pretty(ActionSpec.parse($0.tokenText), document: document, depth: depth + 1) }.joined(separator: " ")
        case let h where h.hasPrefix("tap-hold"):
            let actions = args.filter { $0.asAtom.flatMap { Int($0.text) } == nil }
            guard actions.count == 2 else { return text }
            return pretty(ActionSpec.parse(actions[0].tokenText), document: document, depth: depth + 1) + tapHoldSeparator
                + pretty(ActionSpec.parse(actions[1].tokenText), document: document, depth: depth + 1)
        default:
            return text
        }
    }

    /// Whether `text` (after alias resolution) is transparent.
    static func isTransparent(_ text: String, document: ConfigDocument?, depth: Int = 0) -> Bool {
        switch ActionSpec.parse(text) {
        case .transparent: return true
        case .alias(let name):
            guard depth < 8, let def = document?.aliases.first(where: { $0.name == name }) else { return false }
            return isTransparent(def.text, document: document, depth: depth + 1)
        default: return false
        }
    }

    /// The hardware default of a physical key: its own label, or the media function for F1–F12 when the
    /// function row is not in "function" mode.
    static func hardwareLabel(sourceKey: HIDKey, functionRow: FunctionRowMode) -> String {
        if functionRow != .function, let media = Keys.mediaFunctionRow[sourceKey] {
            return KeyTable.label(for: media)
        }
        return KeyTable.label(for: sourceKey)
    }

    /// Resolves what `position` does on `layerNames[layerIndex]`, looking through `_` down to the base layer
    /// and finally the hardware default.
    static func effective(document: ConfigDocument, layerNames: [String], layerIndex: Int, position: Int,
                          sourceKey: HIDKey?, functionRow: FunctionRowMode) -> KeyDisplay {
        var index = min(layerIndex, layerNames.count - 1)
        while index >= 0 {
            let tokens = document.actionTexts(layer: layerNames[index]) ?? []
            let token = position < tokens.count ? tokens[position] : "_"
            if !isTransparent(token, document: document) {
                let text = pretty(text: token, document: document)
                let style: KeyDisplay.Style = text == blockedGlyph ? .blocked : (index == layerIndex ? .bound : .inherited)
                return KeyDisplay(text: text, style: style)
            }
            index -= 1
        }
        guard let sourceKey else { return KeyDisplay(text: "?", style: .hardware) }
        return KeyDisplay(text: hardwareLabel(sourceKey: sourceKey, functionRow: functionRow), style: .hardware)
    }
}
