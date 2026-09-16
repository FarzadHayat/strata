import StrataCore
import SwiftUI

/// `(defcfg …)` knobs and the alias list. Every control writes straight through `setSetting` / `setAlias`.
struct LayoutSettingsPanel: View {
    var model: AppModel

    var body: some View {
        GroupBox("Layout settings") {
            VStack(alignment: .leading, spacing: 14) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Tap-hold resolution")
                        Picker("Tap-hold resolution", selection: Binding(
                            get: { model.settings.resolution },
                            set: { model.setSetting("tap-hold-resolution", to: $0.rawValue) })) {
                            ForEach(TapHoldResolution.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                        Text(Self.explain(model.settings.resolution)).font(.caption).foregroundStyle(.secondary)
                    }
                    millisecondsRow("Tap timeout", key: "tap-timeout", value: model.settings.tapTimeoutMs,
                                    help: "Pressing the key again within this time after a tap repeats the tap action.")
                    millisecondsRow("Hold timeout", key: "hold-timeout", value: model.settings.holdTimeoutMs,
                                    help: "Held longer than this → the hold action.")
                    millisecondsRow("Prior idle", key: "prior-idle", value: model.settings.priorIdleMs,
                                    help: "Pressed less than this after another key → always a tap (fast-typing guard).")
                    GridRow {
                        Text("Function row")
                        Picker("Function row", selection: Binding(
                            get: { model.settings.functionRow },
                            set: { model.setSetting("fn-row", to: $0.rawValue) })) {
                            ForEach(FunctionRowMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                        Text(Self.explain(model.settings.functionRow)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.compileResult?.keymap == nil {
                    Label("Values shown are defaults until the file compiles without errors.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                AliasesEditor(model: model)
            }
            .padding(6)
        }
    }

    private func millisecondsRow(_ title: String, key: String, value: Int, help: String) -> some View {
        GridRow {
            Text(title)
            Stepper(value: Binding(get: { value }, set: { model.setSetting(key, to: String($0)) }), in: 0...2000, step: 10) {
                Text("\(value) ms").monospacedDigit()
            }
            .frame(width: 170, alignment: .leading)
            Text(help).font(.caption).foregroundStyle(.secondary)
        }
    }

    static func explain(_ r: TapHoldResolution) -> String {
        switch r {
        case .permissive: return "Hold if another key is pressed and released while this one is held, or after the hold timeout."
        case .holdOnPress: return "Hold as soon as any other key is pressed while this one is held."
        case .timeout: return "Hold only once the hold timeout elapses; releasing earlier taps."
        }
    }

    static func explain(_ m: FunctionRowMode) -> String {
        switch m {
        case .system: return "Follow the macOS setting “Use F1, F2, etc. keys as standard function keys”."
        case .media: return "F-keys send brightness/media functions unless fn is held."
        case .function: return "F-keys send F1–F12 unless fn is held."
        }
    }
}

/// `(defalias …)` entries: name, editable action text, preview, remove; plus an add row.
struct AliasesEditor: View {
    var model: AppModel
    @State private var newName = ""
    @State private var newText = ""

    private struct Row: Identifiable {
        let name: String
        let text: String
        var id: String { name }
    }

    private var rows: [Row] { model.document?.aliases.map { Row(name: $0.name, text: $0.text) } ?? [] }

    private var canAdd: Bool {
        !newName.isEmpty && !newText.isEmpty
            && newName.rangeOfCharacter(from: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "()\"@"))) == nil
            && !rows.contains { $0.name == newName }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Aliases").font(.headline)
            if rows.isEmpty {
                Text("No aliases yet. Aliases name an action once (e.g. ext) and are used as @ext on any layer.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    Text("@" + row.name).font(.body.monospaced()).frame(width: 90, alignment: .leading).lineLimit(1)
                    AliasTextField(text: row.text) { model.setAlias(row.name, to: $0) }
                    Text(ActionPretty.pretty(text: row.text, document: model.document))
                        .foregroundStyle(.secondary).frame(width: 130, alignment: .leading).lineLimit(1)
                    Button {
                        model.removeAlias(row.name)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove alias @\(row.name)")
                }
            }
            HStack(spacing: 8) {
                TextField("name", text: $newName).font(.body.monospaced()).frame(width: 90)
                TextField("action, e.g. M-c or (layer-while-held extend)", text: $newText).font(.body.monospaced())
                Button("Add") {
                    model.setAlias(newName, to: newText)
                    if model.editError == nil {
                        newName = ""
                        newText = ""
                    }
                }
                .disabled(!canAdd)
            }
            .textFieldStyle(.roundedBorder)
        }
    }
}

/// Text field that commits on Return and re-syncs when the underlying document changes.
struct AliasTextField: View {
    let text: String
    let onCommit: (String) -> Void
    @State private var draft = ""

    var body: some View {
        TextField("action", text: $draft)
            .font(.body.monospaced())
            .textFieldStyle(.roundedBorder)
            .onSubmit {
                let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty, value != text { onCommit(value) }
            }
            .onChange(of: text, initial: true) { _, new in draft = new }
    }
}
