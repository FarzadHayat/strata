import Foundation
import StrataCore

/// File I/O and structural edits. Every edit goes: `ConfigDocument` mutation → atomic write → recompile.
/// The daemon watches the file itself and hot-reloads.
extension AppModel {
    // MARK: - Reading

    /// Re-reads the file if its content differs from the current document.
    func loadConfig() {
        guard let data = FileManager.default.contents(atPath: configPath) else {
            if document != nil || fileError == nil {
                setDocument(nil, error: FileManager.default.fileExists(atPath: configPath)
                    ? "Cannot read \(configPath)" : "No config file at \(configPath)")
            }
            return
        }
        let text = String(decoding: data, as: UTF8.self)
        if text == document?.text { return }
        setDocument(ConfigDocument(text: text))
    }

    /// Writes a starter config (QWERTY + extend) when there is none yet.
    func createStarterConfig() {
        let dir = (configPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let text = Formatter.defaultConfig(sourceKeys: KeyboardBlueprint.defaultSourceKeys)
            try Data(text.utf8).write(to: URL(fileURLWithPath: configPath), options: .atomic)
            setDocument(ConfigDocument(text: text))
            startWatchingConfig()
        } catch {
            editError = "Could not create \(configPath): \(error.localizedDescription)"
        }
    }

    // MARK: - Watching

    /// Watches the config directory (catches atomic saves/renames) and the file itself (in-place writes).
    func startWatchingConfig() {
        directoryWatcher?.cancel()
        directoryWatcher = nil
        let dir = (configPath as NSString).deletingLastPathComponent
        directoryWatcher = makeWatcher(path: dir, mask: [.write, .rename, .delete])
        rewatchFile()
    }

    func rewatchFile() {
        fileWatcher?.cancel()
        fileWatcher = makeWatcher(path: configPath, mask: [.write, .extend, .attrib, .delete, .rename])
    }

    private func makeWatcher(path: String, mask: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    // MARK: - Writing

    /// Applies a structural edit, saves atomically and recompiles. Errors are surfaced in `editError`.
    func apply(_ edit: (ConfigDocument) throws -> ConfigDocument) {
        guard let document else {
            editError = fileError ?? "No config loaded"
            return
        }
        do {
            let updated = try edit(document)
            try Data(updated.text.utf8).write(to: URL(fileURLWithPath: configPath), options: .atomic)
            setDocument(updated)
            editError = nil
        } catch let error as EditError {
            editError = Self.describe(error)
        } catch {
            editError = "Could not save \(configPath): \(error.localizedDescription)"
        }
    }

    static func describe(_ error: EditError) -> String {
        switch error {
        case .unknownLayer(let name): return "Layer '\(name)' does not exist"
        case .layerAlreadyExists(let name): return "A layer named '\(name)' already exists"
        case .positionOutOfRange(let p): return "Key position \(p) is outside this layer"
        case .missingDefsrc: return "The config has no (defsrc …) form"
        case .unknownAlias(let name): return "Alias '@\(name)' does not exist"
        }
    }

    // MARK: - Edits

    /// The raw action token for the selection (`nil` if the layer has no token at that position).
    var selectedActionText: String? {
        guard let selectedLayer, let selectedPosition else { return nil }
        return document?.action(layer: selectedLayer, position: selectedPosition)?.text
    }

    func setSelectedAction(_ text: String) {
        guard let selectedLayer, let selectedPosition else { return }
        setAction(layer: selectedLayer, position: selectedPosition, to: text)
    }

    func setAction(layer: String, position: Int, to text: String) {
        apply { try $0.setAction(layer: layer, position: position, to: text) }
    }

    func setSetting(_ key: String, to text: String) {
        apply { $0.setSetting(key: key, to: text) }
    }

    func setAlias(_ name: String, to text: String) {
        apply { $0.setAlias(name: name, to: text) }
    }

    func removeAlias(_ name: String) {
        apply { try $0.removeAlias(name: name) }
    }

    func addLayer(_ name: String, copyFrom: String?) {
        apply { try $0.addLayer(name: name, copyFrom: copyFrom) }
        if editError == nil { selectedLayer = name }
    }

    func renameLayer(_ name: String, to newName: String) {
        apply { try $0.renameLayer(name, to: newName) }
        if editError == nil, selectedLayer == name { selectedLayer = newName }
    }

    func deleteLayer(_ name: String) {
        var diagnostics: [Diagnostic] = []
        apply {
            let result = try $0.deleteLayer(name)
            diagnostics = result.diagnostics
            return result.document
        }
        if editError == nil {
            layerDiagnostics = diagnostics
            if selectedLayer == name { selectedLayer = layerNames.first }
        }
    }

    /// Compile diagnostics that touch the selected action token.
    var selectedActionDiagnostics: [Diagnostic] {
        guard let selectedLayer, let selectedPosition, let document,
              let action = document.action(layer: selectedLayer, position: selectedPosition),
              let result = compileResult else { return [] }
        return result.diagnostics.filter { $0.range.overlaps(action.range) || $0.range.lowerBound == action.range.lowerBound }
    }
}
