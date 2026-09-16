import AppKit
import StrataCore
import SwiftUI

/// The popover-style panel under the menu bar icon.
struct MenuBarView: View {
    var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var visualizerOptionsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            StatusChecklist(items: model.checklist)
            Divider()
            configStatus
            Divider()
            buttons
            Divider()
            visualizerSection
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 300)
        .onAppear {
            model.refreshPermissions()
            model.requestStatus()
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "keyboard").font(.title3)
            Text("Strata").font(.headline)
            Spacer()
            if model.connected {
                Label(model.topLayer.map { "Layer: \($0)" } ?? "Base layer", systemImage: "square.3.layers.3d")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label("Daemon offline", systemImage: "bolt.slash").font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var configStatus: some View {
        let summary = model.configSummary
        return VStack(alignment: .leading, spacing: 3) {
            Text(model.abbreviatedConfigPath).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(summary.text)
                    .foregroundStyle(summary.isError ? Color.red : Color.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if summary.warnings > 0 {
                    Text("\(summary.warnings) warning\(summary.warnings == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private var buttons: some View {
        VStack(spacing: 6) {
            Button {
                openEditor()
            } label: {
                Label("Open Editor", systemImage: "square.and.pencil").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            HStack(spacing: 6) {
                Button {
                    model.loadConfig()
                    model.reloadDaemon()
                } label: {
                    Label("Reload Config", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                }
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: model.configPath))
                } label: {
                    Label("Text Editor", systemImage: "doc.text").frame(maxWidth: .infinity)
                }
                .help("Open in Text Editor")
            }
            HStack(spacing: 6) {
                Button {
                    NSWorkspace.shared.selectFile(model.configPath, inFileViewerRootedAtPath: "")
                } label: {
                    Label("Reveal in Finder", systemImage: "folder").frame(maxWidth: .infinity)
                }
                Button(role: .destructive) {
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit Strata", systemImage: "power").frame(maxWidth: .infinity)
                }
            }
        }
        .controlSize(.small)
    }

    private var visualizerSection: some View {
        let settings = model.visualizerSettings
        return VStack(alignment: .leading, spacing: 6) {
            Toggle("Show keyboard visualizer", isOn: Bindable(settings).enabled)
                .toggleStyle(.switch)
            DisclosureGroup("Visualizer options", isExpanded: $visualizerOptionsExpanded) {
                VisualizerOptions(settings: settings).padding(.top, 4)
            }
            .font(.caption)
            .disabled(!settings.enabled)
        }
        .controlSize(.small)
    }

    private var footer: some View {
        HStack {
            Text("Strata \(StrataCore.version)")
            if let daemon = model.status?.version, daemon != StrataCore.version {
                Text("· daemon \(daemon)")
            }
            Spacer()
            if !model.permissions.allGranted {
                Button("Request permissions") { model.requestPermissions() }.controlSize(.mini)
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private func openEditor() {
        openWindow(id: EditorWindow.sceneID)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            WindowBringer.bringEditorFront()
        }
    }
}

extension AppModel {
    var abbreviatedConfigPath: String {
        let home = NSHomeDirectory()
        return configPath.hasPrefix(home) ? "~" + configPath.dropFirst(home.count) : configPath
    }

    /// One-line config status: the daemon's view when connected, otherwise the GUI's own compile.
    var configSummary: (text: String, isError: Bool, warnings: Int) {
        if connected, let cfg = status?.config {
            if let error = cfg.errors.first { return (error, true, cfg.warnings.count) }
            if cfg.loaded { return ("OK (\(cfg.layers.count) layer\(cfg.layers.count == 1 ? "" : "s"))", false, cfg.warnings.count) }
            return ("Not loaded by the daemon", true, cfg.warnings.count)
        }
        if let fileError { return (fileError, true, 0) }
        guard let result = compileResult else { return ("Not loaded", true, 0) }
        if let error = result.errors.first { return (error.description, true, result.warnings.count) }
        return ("OK (\(layerNames.count) layer\(layerNames.count == 1 ? "" : "s")) — daemon offline", false, result.warnings.count)
    }
}

/// Corner, opacity, click-through and position reset for the visualizer panel.
struct VisualizerOptions: View {
    @Bindable var settings: VisualizerSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Corner", selection: $settings.corner) {
                ForEach(VisualizerCorner.allCases) { Text($0.title).tag($0) }
            }
            HStack {
                Text("Opacity")
                Slider(value: $settings.opacity, in: VisualizerSettings.opacityRange)
                Text(settings.opacity, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit().foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
            }
            Toggle("Click-through (ignore mouse)", isOn: $settings.clickThrough)
            Button("Reset position") { settings.resetPosition() }
                .disabled(settings.customFrame == nil)
                .help("Snap the panel back to the chosen corner")
        }
        .font(.caption)
    }
}
