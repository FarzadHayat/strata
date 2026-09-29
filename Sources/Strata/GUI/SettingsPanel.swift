import StrataCore
import StrataHID
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
                Divider()
                KeyboardsEditor(model: model)
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

/// One row of the Keyboards section: a product name, whether Strata currently remaps it, and why.
private struct KeyboardRow: Identifiable {
    let name: String
    /// How many connected keyboards share this product name (toggling affects all of them).
    let connectedCount: Int
    let detail: String
    let excluded: Bool
    var id: String { name }
}

/// Per-keyboard on/off. Off writes the product name into `(defcfg exclude-devices …)`; the daemon picks
/// the change up on its next config reload, no restart needed.
struct KeyboardsEditor: View {
    var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keyboards").font(.headline)
            if model.compileResult?.keymap == nil {
                Text("Fix the config errors first; keyboard switches are read from the compiled file.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if rows.isEmpty {
                Text("No keyboards found yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    Toggle(isOn: Binding(
                        get: { !row.excluded },
                        set: { model.setDeviceExcluded(name: row.name, excluded: !$0) })) {
                        HStack(spacing: 6) {
                            Text(row.name).lineLimit(1).truncationMode(.middle)
                            if row.connectedCount > 1 {
                                Text("\(row.connectedCount) connected").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(model.document == nil)
                    .help(row.excluded ? "Strata ignores this keyboard; turn on to remap it again."
                                       : "Turn off to let this keyboard bypass Strata.")
                    Text(row.detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if model.status == nil, model.compileResult?.keymap != nil {
                Label("Daemon not connected; changes are saved and apply when it reconnects.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Connected keyboards plus config entries for keyboards that are not plugged in, so an exclusion can
    /// always be turned back on. Identical product names collapse into one row.
    private var rows: [KeyboardRow] {
        var connected: [String: (count: Int, seized: Bool, note: String?)] = [:]
        for device in model.status?.devices ?? [] where !device.name.isEmpty {
            let note = device.note
            let skipped = note?.hasPrefix("skipped:") == true && note != HIDInput.excludedNote
            guard !skipped && (device.seized || note != nil) else { continue }
            var entry = connected[device.name] ?? (0, false, nil)
            entry.count += 1
            entry.seized = entry.seized || device.seized
            entry.note = entry.note ?? note
            connected[device.name] = entry
        }

        var out: [KeyboardRow] = connected.map { name, entry in
            let excluded = DeviceExclusions.matches(product: name, excludes: model.excludedDeviceNames)
            let detail: String
            if excluded {
                detail = "Strata ignores this keyboard."
            } else if entry.seized {
                detail = "Strata remaps this keyboard."
            } else {
                detail = entry.note.map { "Not seized: \($0)" } ?? "Not seized."
            }
            return KeyboardRow(name: name, connectedCount: entry.count, detail: detail, excluded: excluded)
        }
        for name in model.excludedDeviceNames where !name.isEmpty
            && !out.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            out.append(KeyboardRow(name: name, connectedCount: 0,
                                   detail: model.status == nil ? "Status unknown (daemon not connected)." : "Not connected.",
                                   excluded: true))
        }
        return out.sorted { ($0.connectedCount == 0 ? 1 : 0, $0.name.lowercased()) < ($1.connectedCount == 0 ? 1 : 0, $1.name.lowercased()) }
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
