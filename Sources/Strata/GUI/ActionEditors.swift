import StrataCore
import SwiftUI

/// Grouped key chooser with search and a "press a key" recorder. `selection` is a canonical key name.
struct KeyPickerView: View {
    let selection: String
    var model: AppModel
    let onChange: (String) -> Void
    @State private var search = ""

    static let kindOrder: [KeyKind] = [.letter, .digit, .symbol, .modifier, .navigation, .editing, .function,
                                       .keypad, .media, .system, .lock, .international, .other]

    static let grouped: [(kind: KeyKind, entries: [KeyEntry])] = kindOrder.compactMap { kind in
        let entries = KeyTable.entries.filter { $0.kind == kind }
        return entries.isEmpty ? nil : (kind, entries)
    }

    static func title(_ kind: KeyKind) -> String {
        switch kind {
        case .letter: return "Letters"
        case .digit: return "Digits"
        case .symbol: return "Symbols"
        case .modifier: return "Modifiers"
        case .navigation: return "Navigation"
        case .editing: return "Editing"
        case .function: return "Function keys"
        case .keypad: return "Keypad"
        case .media: return "Media"
        case .system: return "System"
        case .lock: return "Locks"
        case .international: return "International"
        case .other: return "Other"
        }
    }

    private var filtered: [KeyEntry] {
        let q = search.lowercased()
        guard !q.isEmpty else { return [] }
        return KeyTable.entries.filter {
            $0.name.lowercased().contains(q) || $0.label.lowercased().contains(q) || $0.aliases.contains { $0.contains(q) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Menu {
                    ForEach(Self.grouped, id: \.kind) { group in
                        Menu(Self.title(group.kind)) {
                            ForEach(group.entries, id: \.name) { entry in
                                Button { onChange(entry.name) } label: { Text(entry.label == entry.name ? entry.name : "\(entry.label)   \(entry.name)") }
                            }
                        }
                    }
                } label: {
                    Text(currentTitle).frame(maxWidth: .infinity, alignment: .leading)
                }
                Button {
                    if model.isLearning { model.cancelLearn() } else { model.beginLearn { onChange($0) } }
                } label: {
                    Label(model.isLearning ? "Press a key…" : "Press a key", systemImage: "hand.tap")
                }
                .help("Record the next physical key press")
            }
            TextField("Search keys (name, label or alias)", text: $search).textFieldStyle(.roundedBorder)
            if !search.isEmpty {
                List(filtered, id: \.name) { entry in
                    Button {
                        onChange(entry.name)
                        search = ""
                    } label: {
                        HStack {
                            Text(entry.label).frame(width: 44, alignment: .leading)
                            Text(entry.name).font(.body.monospaced())
                            Spacer()
                            Text(Self.title(entry.kind)).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .frame(height: 160)
            }
        }
    }

    private var currentTitle: String {
        guard let entry = KeyTable.entry(named: selection) else { return selection }
        return entry.label == entry.name ? entry.name : "\(entry.label)   \(entry.name)"
    }
}

/// Modifier toggles plus a key picker → `M-C-A-S-key` (or `(chord …)` when right-side modifiers are used).
struct ChordEditor: View {
    let modifiers: [ChordModifier]
    let key: String
    var model: AppModel
    let onChange: (ActionSpec) -> Void
    @State private var showRight = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(ChordModifier.left, id: \.self) { modifierToggle($0) }
            }
            DisclosureGroup("Right-side modifiers", isExpanded: $showRight) {
                HStack(spacing: 6) {
                    ForEach(ChordModifier.right, id: \.self) { modifierToggle($0) }
                }
                .padding(.top, 4)
            }
            .font(.callout)
            Text("Key").font(.subheadline)
            KeyPickerView(selection: key, model: model) { onChange(.chord(modifiers: modifiers, key: $0)) }
            Text("Writes: " + ActionSpec.chord(modifiers: modifiers, key: key).text())
                .font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        .onAppear { showRight = modifiers.contains(where: \.isRight) }
    }

    private func modifierToggle(_ mod: ChordModifier) -> some View {
        Toggle(isOn: Binding(
            get: { modifiers.contains(mod) },
            set: { on in
                var mods = modifiers.filter { $0 != mod }
                if on { mods.append(mod) }
                onChange(.chord(modifiers: mods, key: key))
            })) {
            Text(mod.glyph).font(.title3).frame(width: 22)
        }
        .toggleStyle(.button)
        .help((mod.isRight ? "Right " : "") + mod.title)
    }
}

struct LayerPickerView: View {
    let title: String
    let layers: [String]
    let selection: String
    let onChange: (String) -> Void

    var body: some View {
        let options = layers.contains(selection) ? layers : layers + [selection]
        Picker(title, selection: Binding(get: { selection }, set: { onChange($0) })) {
            ForEach(options, id: \.self) { Text($0).tag($0) }
        }
        if layers.isEmpty {
            Text("Add another layer first (toolbar +).").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct AliasPickerView: View {
    let aliases: [String]
    let selection: String
    var model: AppModel
    let onChange: (String) -> Void

    var body: some View {
        if aliases.isEmpty {
            Text("No aliases defined. Add them under Layout settings.").font(.callout).foregroundStyle(.secondary)
        } else {
            let options = aliases.contains(selection) ? aliases : aliases + [selection]
            Picker("Alias", selection: Binding(get: { selection }, set: { onChange($0) })) {
                ForEach(options, id: \.self) { Text("@" + $0).tag($0) }
            }
            if let def = model.document?.aliases.first(where: { $0.name == selection }) {
                Text("\(def.text)  →  \(ActionPretty.pretty(text: def.text, document: model.document))")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
    }
}

/// `(tap-hold [tap hold] TAP HOLD)` with sub-editors for each half and optional per-key timeouts.
struct TapHoldEditor: View {
    let tap: ActionSpec
    let hold: ActionSpec
    let tapMs: Int?
    let holdMs: Int?
    var model: AppModel
    let sourceKey: String
    let layers: [String]
    let onChange: (ActionSpec) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Tap") {
                SubActionEditor(spec: tap, model: model, sourceKey: sourceKey, layers: layers) {
                    onChange(.tapHold(tap: $0, hold: hold, tapMs: tapMs, holdMs: holdMs))
                }
            }
            GroupBox("Hold") {
                SubActionEditor(spec: hold, model: model, sourceKey: sourceKey, layers: layers) {
                    onChange(.tapHold(tap: tap, hold: $0, tapMs: tapMs, holdMs: holdMs))
                }
            }
            GroupBox("Timeouts") {
                VStack(alignment: .leading, spacing: 6) {
                    OptionalMillisecondsStepper(title: "Tap timeout", value: tapMs, defaultValue: model.settings.tapTimeoutMs) {
                        onChange(.tapHold(tap: tap, hold: hold, tapMs: $0, holdMs: holdMs))
                    }
                    OptionalMillisecondsStepper(title: "Hold timeout", value: holdMs, defaultValue: model.settings.holdTimeoutMs) {
                        onChange(.tapHold(tap: tap, hold: hold, tapMs: tapMs, holdMs: $0))
                    }
                    Text("Off = use the defcfg defaults.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct OptionalMillisecondsStepper: View {
    let title: String
    let value: Int?
    let defaultValue: Int
    let onChange: (Int?) -> Void

    var body: some View {
        HStack {
            Toggle(isOn: Binding(get: { value != nil }, set: { onChange($0 ? defaultValue : nil) })) { Text(title) }
            Spacer()
            if let value {
                Stepper(value: Binding(get: { value }, set: { onChange($0) }), in: 0...2000, step: 10) {
                    Text("\(value) ms").monospacedDigit()
                }
            } else {
                Text("default \(defaultValue) ms").foregroundStyle(.secondary)
            }
        }
    }
}

/// Editor for one half of a tap-hold: a restricted kind picker plus the matching editor.
struct SubActionEditor: View {
    let spec: ActionSpec
    var model: AppModel
    let sourceKey: String
    let layers: [String]
    let onChange: (ActionSpec) -> Void

    private var kind: ActionKind { ActionKind.tapHoldSubKinds.contains(spec.kind) ? spec.kind : .advanced }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Kind", selection: Binding<ActionKind>(
                get: { kind },
                set: { onChange(spec.converted(to: $0, sourceKey: sourceKey, layers: layers, aliases: [])) })) {
                ForEach(ActionKind.tapHoldSubKinds) { Text($0.title).tag($0) }
                if kind == .advanced { Text("Advanced").tag(ActionKind.advanced) }
            }
            .labelsHidden()
            switch spec {
            case .key(let name):
                KeyPickerView(selection: name, model: model) { onChange(.key($0)) }
            case .chord(let mods, let key):
                ChordEditor(modifiers: mods, key: key, model: model, onChange: onChange)
            case .layerWhileHeld(let layer):
                LayerPickerView(title: "Layer", layers: layers, selection: layer) { onChange(.layerWhileHeld($0)) }
            case .layerSwitch(let layer):
                LayerPickerView(title: "Layer", layers: layers, selection: layer) { onChange(.layerSwitch($0)) }
            case .block:
                Text("Does nothing.").font(.caption).foregroundStyle(.secondary)
            default:
                Text(spec.text()).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
