import Foundation
import os
import StrataCore
import StrataHID
import StrataIPC

/// The root LaunchDaemon role: seize keyboards → engine → virtual keyboard, plus config reload and GUI IPC.
/// All mutable state is confined to `queue`.
final class Daemon: @unchecked Sendable {
    struct Options {
        var configPath: String
        var user: String
        var uid: uid_t
        var devTimeout: TimeInterval?
        var allowAnyPath = false
    }

    private let opts: Options
    private let queue = DispatchQueue(label: "dev.farzadhayat.strata.engine", qos: .userInteractive)
    private let log = Logger(subsystem: "dev.farzadhayat.strata", category: "daemon")
    private let startDate = Date()

    private var engine: Engine
    private var input: HIDInput!
    private var vhid: VHIDClient!
    private var ipc: IPCServer!
    private var watcher: ConfigWatcher!
    private let caps = CapsLockController()
    private var engineTimer: DispatchSourceTimer?
    private var permissionTimer: DispatchSourceTimer?
    private var prefsTimer: DispatchSourceTimer?

    private var vhidStatus = VHIDClient.Status()
    private var devices: [HIDDeviceInfo] = []
    private var configStatus: IPC.ConfigStatus
    private var permissions = Permissions.check()
    private var guiPermissions: IPC.PermissionSnapshot?
    private var paused = false
    private var learning = false
    private var physicallyHeld = Set<HIDKey>()
    private var hadPermissionFailure = false
    private var permissionRetryTick = 0
    private var signalSources: [DispatchSourceSignal] = []

    init(options: Options) {
        opts = options
        engine = Engine(keymap: Keymap(source: [], layers: [Layer(name: "base", actions: [])]),
                        systemFunctionKeysStandard: SystemPrefs.functionKeysStandard(forUser: options.user) ?? false)
        configStatus = IPC.ConfigStatus(path: options.configPath, loaded: false, layers: [], errors: [], warnings: [], lastLoad: nil)
    }

    // MARK: - Lifecycle

    func run() -> Never {
        info("strata daemon \(StrataCore.version) starting (pid \(getpid()), uid \(getuid()), user \(opts.user), config \(opts.configPath))")
        if getuid() != 0 { warn("not running as root — the virtual keyboard socket is root-only; expect connection failures") }

        installSignalHandlers()

        // IPC first so the GUI can see status while we come up.
        ipc = IPCServer(uid: opts.uid) { [weak self] req in self?.queue.async { self?.handle(request: req) } }
        do { try ipc.start() } catch { warn("IPC server failed: \(error)") }

        // Config.
        watcher = ConfigWatcher(path: opts.configPath) { [weak self] text in self?.queue.async { self?.apply(configText: text, reason: "file changed") } }
        if let text = watcher.start() { apply(configText: text, reason: "startup") } else {
            configStatus.errors = ["cannot read \(opts.configPath)"]
            warn("cannot read config at \(opts.configPath); waiting for it to appear")
        }

        // Output.
        vhid = VHIDClient { [weak self] status in self?.queue.async { self?.vhidStatusChanged(status) } }
        vhid.start()

        // Input.
        var hidOptions = HIDInput.Options()
        hidOptions.excludeProducts = engine.keymap.settings.excludeDevices
        input = HIDInput(options: hidOptions, onDevices: { [weak self] list in
            self?.queue.async { self?.devicesChanged(list) }
        }, onEvent: { [weak self] event, _ in
            self?.queue.async { self?.process(event) }
        })
        input.start()

        startPermissionPolling()
        startPrefsPolling()

        if let t = opts.devTimeout {
            warn("dev timeout: exiting in \(Int(t))s")
            queue.asyncAfter(deadline: .now() + t) { [weak self] in self?.shutdown(reason: "dev timeout") }
        }
        dispatchMain()
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            src.setEventHandler { [weak self] in
                if sig == SIGHUP { self?.watcher.reload() } else { self?.shutdown(reason: "signal \(sig)") }
            }
            src.resume()
            signalSources.append(src)
        }
    }

    private func shutdown(reason: String) -> Never {
        info("shutting down: \(reason)")
        _ = engine.releaseAll()
        vhid.releaseAll()
        input.stop()
        usleep(150_000)
        vhid.stop()
        ipc.stop()
        exit(0)
    }

    // MARK: - Config

    private func apply(configText: String, reason: String) {
        if !opts.allowAnyPath, !Self.isAllowedConfigPath(opts.configPath, user: opts.user) {
            configStatus.errors = ["config path must be inside ~\(opts.user)/.config/strata (got \(opts.configPath))"]
            warn(configStatus.errors[0])
            broadcastStatus()
            return
        }
        let result = ConfigCompiler.compile(text: configText)
        let file = (opts.configPath as NSString).lastPathComponent
        configStatus.warnings = result.warnings.map { $0.description(filename: file) }
        if let keymap = result.keymap, !result.hasErrors {
            let outputs = engine.load(keymap)
            emit(outputs)
            configStatus.loaded = true
            configStatus.errors = []
            configStatus.layers = keymap.layers.map(\.name)
            configStatus.lastLoad = Date()
            info("config loaded (\(reason)): \(keymap.layers.count) layers, \(keymap.source.count) keys, \(result.warnings.count) warnings")
            for w in configStatus.warnings { warn(w) }
        } else {
            configStatus.errors = result.errors.map { $0.description(filename: file) }
            warn("config rejected (\(reason)); keeping the previous keymap")
            for e in configStatus.errors { warn(e) }
        }
        broadcastStatus()
    }

    static func isAllowedConfigPath(_ path: String, user: String) -> Bool {
        guard let home = SystemPrefs.homeDirectory(forUser: user) else { return false }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let allowed = URL(fileURLWithPath: home + "/.config/strata").resolvingSymlinksInPath().path
        return resolved.hasPrefix(allowed + "/")
    }

    // MARK: - Engine loop

    private func process(_ event: KeyEvent) {
        if event.isDown { physicallyHeld.insert(event.key) } else { physicallyHeld.remove(event.key) }

        if learning && event.isDown {
            learning = false
            ipc.broadcast(.learned(key: KeyTable.canonicalName(for: event.key) ?? event.key.description, page: event.key.page, usage: event.key.usage))
        }

        if Self.panicChord.isSubset(of: physicallyHeld) {
            paused.toggle()
            warn(paused ? "panic chord: paused (keys pass through unchanged)" : "panic chord: resumed")
            emit(engine.releaseAll())
            vhid.releaseAll()
            broadcastStatus()
            return
        }

        if paused {
            vhid.set(event.key, down: event.isDown)
            return
        }
        emit(engine.handle(event))
        rescheduleTimer()
    }

    static let panicChord: Set<HIDKey> = [Keys.leftControl, Keys.leftOption, Keys.leftCommand, Keys.escape]

    private func emit(_ outputs: [OutputEvent]) {
        for o in outputs {
            switch o {
            case .press(let k):
                if k == Keys.capsLock { caps.toggle() } else { vhid.set(k, down: true) }
            case .release(let k):
                if k != Keys.capsLock { vhid.set(k, down: false) }
            case .layerChanged(let ids):
                ipc.broadcast(.layer(active: ids.map { engine.keymap.layers.indices.contains($0) ? engine.keymap.layers[$0].name : "?" }))
            }
        }
    }

    private func rescheduleTimer() {
        engineTimer?.cancel()
        engineTimer = nil
        guard let deadline = engine.nextDeadline else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + max(0, deadline - now))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.emit(self.engine.tick(now: ProcessInfo.processInfo.systemUptime))
            self.rescheduleTimer()
        }
        t.resume()
        engineTimer = t
    }

    // MARK: - Component callbacks

    private func vhidStatusChanged(_ s: VHIDClient.Status) {
        let becameReady = s.keyboardReady && !vhidStatus.keyboardReady
        if let e = s.lastError, e != vhidStatus.lastError { warn("vhid: \(e)") }
        vhidStatus = s
        if becameReady {
            info("virtual keyboard ready")
            vhid.resync(held: engine.heldOutputs)
        }
        broadcastStatus()
    }

    private func devicesChanged(_ list: [HIDDeviceInfo]) {
        let previous = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        devices = list
        for d in list where previous[d.id] != d {
            if d.seized { info("seized '\(d.product)' (\(d.transport)) id \(d.id)") }
            else if let e = d.error, !e.hasPrefix("skipped") { warn("'\(d.product)': \(e)") }
        }
        for old in previous.values where !list.contains(where: { $0.id == old.id }) {
            info("released '\(old.product)' id \(old.id)")
        }
        hadPermissionFailure = list.contains { ($0.error ?? "").hasPrefix("not permitted") }
        broadcastStatus()
    }

    private func startPermissionPolling() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let p = Permissions.check()
            let changed = p != self.permissions
            self.permissions = p
            if changed { self.info("permissions: inputMonitoring=\(p.inputMonitoring.rawValue) accessibility=\(p.accessibility)") }
            // On macOS 26+ Accessibility alone may be enough for IOHIDDeviceOpen even while IOHIDCheckAccess still
            // reports Input Monitoring as denied, so retry the seize on *any* change (and periodically while failing).
            if self.hadPermissionFailure && (changed || self.permissionRetryTick % 5 == 0) {
                self.info("retrying keyboard seize (permissions: inputMonitoring=\(p.inputMonitoring.rawValue) accessibility=\(p.accessibility))")
                self.input.reseize()
            }
            self.permissionRetryTick += 1
            if changed { self.broadcastStatus() }
        }
        t.resume()
        permissionTimer = t
    }

    private func startPrefsPolling() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in
            guard let self, let v = SystemPrefs.functionKeysStandard(forUser: self.opts.user) else { return }
            if v != self.engine.systemFunctionKeysStandard {
                self.engine.systemFunctionKeysStandard = v
                self.info("fnState changed: standard function keys = \(v)")
            }
        }
        t.resume()
        prefsTimer = t
    }

    // MARK: - IPC

    private func handle(request: IPC.Request) {
        switch request {
        case .status: broadcastStatus()
        case .reload: watcher.reload()
        case .learn: learning = true
        case .cancelLearn: learning = false
        case .permissions(let snap): guiPermissions = snap; broadcastStatus()
        }
    }

    private func broadcastStatus() {
        let names = engine.activeLayers.map { engine.keymap.layers.indices.contains($0) ? engine.keymap.layers[$0].name : "?" }
        let status = IPC.Status(
            version: StrataCore.version, daemonPID: getpid(), uptime: Date().timeIntervalSince(startDate),
            permissions: IPC.PermissionSnapshot(inputMonitoring: permissions.inputMonitoring.rawValue, accessibility: permissions.accessibility),
            guiPermissions: guiPermissions, driverActivated: Permissions.virtualHIDDriverActivated(),
            vhidConnected: vhidStatus.connected, vhidReady: vhidStatus.keyboardReady, vhidError: vhidStatus.lastError,
            devices: devices.map { IPC.DeviceStatus(id: $0.id, name: $0.product, seized: $0.seized, note: $0.error) },
            config: configStatus, activeLayers: names, paused: paused)
        ipc.broadcast(.status(status))
    }

    // MARK: - Logging

    private func info(_ s: String) { log.info("\(s, privacy: .public)"); Self.stderr("[info] " + s) }
    private func warn(_ s: String) { log.warning("\(s, privacy: .public)"); Self.stderr("[warn] " + s) }
    private static func stderr(_ s: String) {
        let ts = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
        FileHandle.standardError.write(("\(ts) \(s)\n").data(using: .utf8)!)
    }
}
