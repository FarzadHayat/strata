import StrataCore
import SwiftUI

/// The editor: toolbar with layer controls, keyboard canvas, optional layout-settings panel, inspector
/// on the right and the daemon status bar at the bottom.
struct EditorWindow: View {
    static let sceneID = "editor"

    @Bindable var model: AppModel
    @State private var showAddLayer = false
    @State private var showRename = false
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if model.document != nil { editorBody } else { missingConfig }
                Divider()
                DaemonStatusBar(model: model)
            }
            Divider()
            InspectorView(model: model).frame(width: 300)
        }
        .frame(minWidth: 860, minHeight: 540)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showAddLayer) { AddLayerSheet(model: model) }
        .sheet(isPresented: $showRename) { RenameLayerSheet(model: model) }
        .sheet(isPresented: onboardingBinding) { OnboardingView(model: model) }
        .confirmationDialog("Delete layer “\(model.selectedLayer ?? "")”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let layer = model.selectedLayer { model.deleteLayer(layer) }
            }
        } message: {
            Text("Keys on other layers that reference this layer are left in place and reported as errors.")
        }
        .alert("Layer deleted, but it is still referenced", isPresented: diagnosticsBinding) {
            Button("OK") { model.layerDiagnostics = [] }
        } message: {
            Text(model.layerDiagnostics.map(\.description).joined(separator: "\n"))
        }
        .onDisappear { model.cancelLearn() }
    }

    // MARK: - Body parts

    private var editorBody: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    KeyboardView(model: model)
                    if model.showLayoutSettings { LayoutSettingsPanel(model: model) }
                }
                .padding(16)
            }
            if let error = model.editError {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.white)
                    Spacer()
                    Button { model.editError = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.white)
                }
                .padding(8)
                .background(Color.red)
            }
        }
    }

    private var missingConfig: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.badge.plus").font(.system(size: 40)).foregroundStyle(.secondary)
            Text(model.fileError ?? "No config").foregroundStyle(.secondary)
            Button("Create starter config") { model.createStarterConfig() }.buttonStyle(.borderedProminent)
            if let error = model.editError { Text(error).foregroundStyle(.red) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            layerPicker
            Button { showAddLayer = true } label: { Label("Add layer", systemImage: "plus") }
                .help("Add layer")
                .disabled(model.document == nil)
            Button { showRename = true } label: { Label("Rename layer", systemImage: "pencil") }
                .help("Rename layer")
                .disabled(model.selectedLayer == nil)
            Button { confirmDelete = true } label: { Label("Delete layer", systemImage: "trash") }
                .help("Delete layer")
                .disabled(model.selectedLayer == nil || model.layerNames.count <= 1)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                if model.isLearning { model.cancelLearn() } else { model.beginLearn { selectKey(named: $0) } }
            } label: {
                Label(model.isLearning ? "Press a key…" : "Select by pressing a key", systemImage: model.isLearning ? "hand.tap.fill" : "hand.tap")
            }
            .help(model.connected ? "Press a physical key to select it" : "Press a key (daemon offline: only works while this window is focused)")
            .disabled(model.document == nil)
            Toggle(isOn: $model.showLayoutSettings) {
                Label("Layout settings", systemImage: "slider.horizontal.3")
            }
            .help("Show defcfg settings and aliases")
        }
    }

    @ViewBuilder
    private var layerPicker: some View {
        let names = model.layerNames
        let binding = Binding<String>(
            get: { model.selectedLayer ?? names.first ?? "" },
            set: { model.selectedLayer = $0 })
        if names.count <= 5 {
            Picker("Layer", selection: binding) {
                ForEach(names, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
        } else {
            Picker("Layer", selection: binding) {
                ForEach(names, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
        }
    }

    // MARK: - Helpers

    private var onboardingBinding: Binding<Bool> {
        Binding(get: { model.needsOnboarding && !model.onboardingDismissed },
                set: { if !$0 { model.onboardingDismissed = true } })
    }

    private var diagnosticsBinding: Binding<Bool> {
        Binding(get: { !model.layerDiagnostics.isEmpty }, set: { if !$0 { model.layerDiagnostics = [] } })
    }

    private func selectKey(named name: String) {
        guard let key = KeyNames.key(named: name), let position = model.sourcePositions[key] else {
            model.editError = "Key “\(name)” is not in defsrc, so it cannot be remapped. Add it to (defsrc …) first."
            return
        }
        model.selectedPosition = position
    }
}

/// Bottom bar: did the daemon accept the file on disk, and does the GUI's own compile agree?
struct DaemonStatusBar: View {
    var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            daemonPart
            Spacer()
            localPart
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var daemonPart: some View {
        if !model.connected {
            Label("Daemon not connected — edits are saved to disk but not applied", systemImage: "bolt.slash")
                .foregroundStyle(.orange)
        } else if let cfg = model.status?.config {
            if let error = cfg.errors.first {
                Label("Daemon rejected config: \(error)", systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(1)
            } else {
                Label("Daemon: config loaded (\(cfg.layers.count) layers)" + (cfg.lastLoad.map { " at " + $0.formatted(date: .omitted, time: .standard) } ?? ""),
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        } else {
            Label("Waiting for daemon status…", systemImage: "hourglass").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var localPart: some View {
        if let result = model.compileResult {
            if let error = result.errors.first {
                Text("\(result.errors.count) error\(result.errors.count == 1 ? "" : "s"): \(error.description)")
                    .foregroundStyle(.red).lineLimit(1)
            } else if !result.warnings.isEmpty {
                Text("\(result.warnings.count) warning\(result.warnings.count == 1 ? "" : "s")").foregroundStyle(.orange)
            } else {
                Text("File OK").foregroundStyle(.secondary)
            }
        }
    }
}

struct AddLayerSheet: View {
    var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var copyFrom = ""

    private var valid: Bool {
        !name.isEmpty && name.rangeOfCharacter(from: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "()\"@"))) == nil
            && !model.layerNames.contains(name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add layer").font(.headline)
            Form {
                TextField("Name", text: $name)
                Picker("Copy actions from", selection: $copyFrom) {
                    Text("None (all transparent)").tag("")
                    ForEach(model.layerNames, id: \.self) { Text($0).tag($0) }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    model.addLayer(name, copyFrom: copyFrom.isEmpty ? nil : copyFrom)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

struct RenameLayerSheet: View {
    var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""

    private var valid: Bool {
        guard let current = model.selectedLayer else { return false }
        return !newName.isEmpty && newName != current
            && newName.rangeOfCharacter(from: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "()\"@"))) == nil
            && !model.layerNames.contains(newName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename layer “\(model.selectedLayer ?? "")”").font(.headline)
            TextField("New name", text: $newName)
            Text("References such as (layer-while-held …) are updated too.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename") {
                    if let current = model.selectedLayer { model.renameLayer(current, to: newName) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { newName = model.selectedLayer ?? "" }
    }
}
