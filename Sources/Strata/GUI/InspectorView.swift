import StrataCore
import SwiftUI

/// Right-hand panel: edits the action of the selected key on the selected layer.
struct InspectorView: View {
    var model: AppModel
    @State private var draft = ""

    private struct Selection {
        let layer: String
        let position: Int
        let sourceName: String
        let sourceKey: HIDKey?
        /// Raw token, or `nil` when the layer has no entry at this position.
        let raw: String?
        var spec: ActionSpec { ActionSpec.parse(raw ?? "_") }
        var canonicalSource: String { sourceKey.flatMap { KeyTable.canonicalName(for: $0) } ?? sourceName }
    }

    private var selection: Selection? {
        guard let layer = model.selectedLayer, let position = model.selectedPosition, let document = model.document,
              position < document.sourceKeys.count else { return nil }
        let name = document.sourceKeys[position].name
        return Selection(layer: layer, position: position, sourceName: name, sourceKey: KeyNames.key(named: name),
                         raw: document.action(layer: layer, position: position)?.text)
    }

    private var otherLayers: [String] { model.layerNames.filter { $0 != model.selectedLayer } }
    private var aliasNames: [String] { model.document?.aliases.map(\.name) ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let selection {
                    header(selection)
                    if selection.raw == nil {
                        Label("Layer “\(selection.layer)” has no entry at position \(selection.position). Its (deflayer …) form is shorter than defsrc; fix the file in a text editor.",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        kindPicker(selection)
                        editor(selection)
                        Divider()
                        advanced(selection)
                    }
                } else {
                    Text("Select a key on the keyboard, or use “Select by pressing a key”.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
        }
        .onChange(of: selection?.raw, initial: true) { _, raw in draft = raw ?? "" }
    }

    // MARK: - Sections

    private func header(_ s: Selection) -> some View {
        HStack(spacing: 12) {
            Text(s.sourceKey.map { KeyTable.label(for: $0) } ?? s.sourceName)
                .font(.title2.weight(.medium))
                .frame(minWidth: 52, minHeight: 44)
                .padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                Text(s.sourceName).font(.headline)
                Text("Position \(s.position) · layer “\(s.layer)”").font(.caption).foregroundStyle(.secondary)
                if let raw = s.raw {
                    Text(ActionPretty.pretty(text: raw, document: model.document)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func kindPicker(_ s: Selection) -> some View {
        Picker("Kind", selection: Binding<ActionKind>(
            get: { s.spec.kind },
            set: { kind in
                commit(s.spec.converted(to: kind, sourceKey: s.canonicalSource, layers: otherLayers, aliases: aliasNames))
            })) {
            ForEach(ActionKind.allCases) { kind in
                if kind != .advanced || s.spec.kind == .advanced { Text(kind.title).tag(kind) }
            }
        }
    }

    @ViewBuilder
    private func editor(_ s: Selection) -> some View {
        switch s.spec {
        case .transparent:
            Text("Falls through to the layer below. On the base layer the key keeps its hardware behaviour.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .block:
            Text("The key does nothing on this layer.").font(.callout).foregroundStyle(.secondary)
        case .key(let name):
            KeyPickerView(selection: name, model: model) { commit(.key($0)) }
        case .chord(let mods, let key):
            ChordEditor(modifiers: mods, key: key, model: model) { commit($0) }
        case .layerWhileHeld(let layer):
            LayerPickerView(title: "Layer held while pressed", layers: otherLayers, selection: layer) { commit(.layerWhileHeld($0)) }
        case .layerSwitch(let layer):
            LayerPickerView(title: "Switch base layer to", layers: otherLayers, selection: layer) { commit(.layerSwitch($0)) }
        case .tapHold(let tap, let hold, let tapMs, let holdMs):
            TapHoldEditor(tap: tap, hold: hold, tapMs: tapMs, holdMs: holdMs, model: model,
                          sourceKey: s.canonicalSource, layers: otherLayers) { commit($0) }
        case .alias(let name):
            AliasPickerView(aliases: aliasNames, selection: name, model: model) { commit(.alias($0)) }
        case .raw:
            Text("This action is not covered by the structured editors (macro, shifted symbol or tap-hold variant). Edit the text below.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func advanced(_ s: Selection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Advanced").font(.headline)
            TextField("Action text, e.g. M-c or (tap-hold esc (layer-while-held extend))", text: $draft)
                .font(.body.monospaced())
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitRaw() }
            HStack {
                Text("Press Return to apply.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if draft != (s.raw ?? "") {
                    Button("Apply") { commitRaw() }.controlSize(.small)
                }
            }
            ForEach(model.selectedActionDiagnostics, id: \.self) { diagnostic in
                Label(diagnostic.message, systemImage: diagnostic.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(diagnostic.isError ? Color.red : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Commits

    private func commit(_ spec: ActionSpec) {
        model.setSelectedAction(spec.text(defaultHoldMs: model.settings.holdTimeoutMs))
    }

    private func commitRaw() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let (_, diagnostics) = Parser.parse(text)
        if let first = diagnostics.first {
            model.editError = "Not a valid action: \(first.message)"
            return
        }
        model.setSelectedAction(text)
    }
}
