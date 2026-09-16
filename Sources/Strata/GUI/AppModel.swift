import AppKit
import Foundation
import Observation
import StrataCore
import StrataHID
import StrataIPC

/// Single source of truth for the GUI: daemon connection and status, permission state, the config
/// document being edited, and editor selection. Everything lives on the main actor.
@MainActor @Observable
final class AppModel {
    // MARK: Daemon

    private(set) var connected = false
    private(set) var status: IPC.Status?
    private(set) var activeLayers: [String] = []

    // MARK: Permissions / driver (checked locally by the GUI process)

    private(set) var permissions: PermissionState
    private(set) var driverActivated: Bool

    // MARK: Config

    let configPath: String
    private(set) var document: ConfigDocument?
    private(set) var compileResult: CompileResult?
    /// Why the config could not be read (`nil` when `document` is set).
    private(set) var fileError: String?
    /// Last structural edit failure (`EditError` or I/O), shown in a banner.
    var editError: String?
    /// Diagnostics returned by the last `deleteLayer` (dangling references).
    var layerDiagnostics: [Diagnostic] = []

    // MARK: Editor selection / UI state

    var selectedLayer: String?
    var selectedPosition: Int?
    var showLayoutSettings = false
    var onboardingDismissed = false
    private(set) var isLearning = false

    @ObservationIgnored private var client: IPCClient?
    @ObservationIgnored private var learnHandler: ((String) -> Void)?
    @ObservationIgnored private var localMonitor: Any?
    @ObservationIgnored private var lastDaemonLoad: Date?
    @ObservationIgnored private var lastSentSnapshot: IPC.PermissionSnapshot?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored var directoryWatcher: DispatchSourceFileSystemObject?
    @ObservationIgnored var fileWatcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    static var defaultConfigPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".config/strata/keymap.kbd")
    }

    init(configPath: String = AppModel.defaultConfigPath) {
        self.configPath = configPath
        self.permissions = Permissions.check()
        self.driverActivated = Permissions.virtualHIDDriverActivated()
    }

    /// Loads the config, connects to the daemon and starts watching for changes. Call once.
    func start() {
        loadConfig()
        startWatchingConfig()
        startClient()
        startPermissionPolling()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.loadConfig()
                self?.refreshPermissions()
            }
        }
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "requestedPermissions"), !permissions.allGranted {
            defaults.set(true, forKey: "requestedPermissions")
            requestPermissions()
        }
    }

    // MARK: - Derived state

    var layerNames: [String] { document?.layerNames ?? [] }

    var baseLayer: String? { status?.config.layers.first ?? layerNames.first }

    /// The top of the daemon's layer stack, or `nil` when only the base layer is active.
    var topLayer: String? {
        guard let top = activeLayers.last, top != baseLayer else { return nil }
        return top
    }

    var selectedLayerIndex: Int {
        guard let selectedLayer, let i = layerNames.firstIndex(of: selectedLayer) else { return 0 }
        return i
    }

    /// The physical keys of `defsrc` (`nil` for names the key table does not know).
    var sourceKeys: [HIDKey?] { document?.sourceKeys.map { KeyNames.key(named: $0.name) } ?? [] }

    /// `defsrc` position of each physical key (first occurrence wins).
    var sourcePositions: [HIDKey: Int] {
        var m: [HIDKey: Int] = [:]
        for (i, key) in sourceKeys.enumerated() { if let key, m[key] == nil { m[key] = i } }
        return m
    }

    var functionRowMode: FunctionRowMode {
        compileResult?.keymap?.settings.functionRow
            ?? document?.settings.first { $0.key.lowercased() == "fn-row" }.flatMap { FunctionRowMode(rawValue: $0.text.lowercased()) }
            ?? .system
    }

    /// Effective `Settings` (from the last successful compile, else defaults).
    var settings: Settings { compileResult?.keymap?.settings ?? Settings() }

    var daemonRunning: Bool { connected && status != nil }

    /// Anything the onboarding checklist would flag.
    var needsOnboarding: Bool {
        !permissions.allGranted || !driverActivated || !connected || (status.map { !$0.vhidReady } ?? false)
    }

    // MARK: - Permissions

    func refreshPermissions() {
        permissions = Permissions.check()
        driverActivated = Permissions.virtualHIDDriverActivated()
        sendPermissionSnapshot()
    }

    /// Shows the system prompts (Input Monitoring first, then Accessibility) and reports the result to the daemon.
    func requestPermissions() {
        permissions = Permissions.request()
        driverActivated = Permissions.virtualHIDDriverActivated()
        lastSentSnapshot = nil
        sendPermissionSnapshot()
    }

    private func sendPermissionSnapshot() {
        let snapshot = IPC.PermissionSnapshot(inputMonitoring: permissions.inputMonitoring.rawValue,
                                              accessibility: permissions.accessibility)
        guard connected, snapshot != lastSentSnapshot else { return }
        lastSentSnapshot = snapshot
        client?.send(.permissions(snapshot))
    }

    private func startPermissionPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                if !self.permissions.allGranted || !self.driverActivated { self.refreshPermissions() }
            }
        }
    }

    // MARK: - Daemon connection

    private func startClient() {
        let client = IPCClient(
            onConnection: { [weak self] up in MainActor.assumeIsolated { self?.connectionChanged(up) } },
            onEvent: { [weak self] event in MainActor.assumeIsolated { self?.handle(event) } })
        self.client = client
        client.start()
    }

    private func connectionChanged(_ up: Bool) {
        connected = up
        if up {
            client?.send(.status)
            lastSentSnapshot = nil
            sendPermissionSnapshot()
        } else {
            status = nil
            activeLayers = []
            if isLearning { installLocalMonitor() }
        }
    }

    private func handle(_ event: IPC.Event) {
        switch event {
        case .status(let s):
            status = s
            activeLayers = s.activeLayers
            if s.config.lastLoad != lastDaemonLoad {
                lastDaemonLoad = s.config.lastLoad
                loadConfig()
            }
        case .layer(let active):
            activeLayers = active
        case .learned(let key, _, _):
            finishLearn(key)
        case .log:
            break
        }
    }

    func reloadDaemon() { client?.send(.reload) }

    func requestStatus() { client?.send(.status) }

    // MARK: - Learn ("press a key")

    /// Reports the next physical key press to `handler` (canonical name). Uses the daemon when connected,
    /// otherwise a local event monitor (which only sees keys while the editor window is focused, and sees
    /// them *after* remapping when the daemon is running elsewhere).
    func beginLearn(_ handler: @escaping (String) -> Void) {
        cancelLearn()
        learnHandler = handler
        isLearning = true
        if connected { client?.send(.learn) } else { installLocalMonitor() }
    }

    func cancelLearn() {
        if isLearning, connected { client?.send(.cancelLearn) }
        removeLocalMonitor()
        learnHandler = nil
        isLearning = false
    }

    private func finishLearn(_ name: String) {
        let handler = learnHandler
        removeLocalMonitor()
        learnHandler = nil
        isLearning = false
        handler?(name)
    }

    private func installLocalMonitor() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let keyCode = event.keyCode
            let isRepeat = event.type == .keyDown && event.isARepeat
            // AppKit delivers these on the main thread; decide inside the actor, return the (non-Sendable) event outside.
            let consumed: Bool = MainActor.assumeIsolated {
                guard let self, self.isLearning else { return false }
                if isRepeat { return true }
                guard let name = KeyCodeTable.name(forKeyCode: keyCode) else { return false }
                self.finishLearn(name)
                return true
            }
            return consumed ? nil : event
        }
    }

    private func removeLocalMonitor() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
    }

    // MARK: - Config document (state changes; file I/O lives in AppModel+Config.swift)

    /// Replaces the document, recompiles and keeps the selection valid.
    func setDocument(_ doc: ConfigDocument?, error: String? = nil) {
        document = doc
        fileError = doc == nil ? (error ?? "No config file") : nil
        compileResult = doc?.compile()
        let names = layerNames
        if let selectedLayer, names.contains(selectedLayer) {
            // keep
        } else {
            selectedLayer = names.first
        }
        if let p = selectedPosition, p >= (doc?.sourceKeys.count ?? 0) { selectedPosition = nil }
    }

    /// Debounced re-read used by the file watchers.
    func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.loadConfig()
            self.rewatchFile()
        }
    }
}
