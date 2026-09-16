import Foundation

/// The key-remapping engine: turns physical `KeyEvent`s into virtual-keyboard `OutputEvent`s
/// according to a compiled `Keymap`, tracking layers, tap-hold decisions and held outputs.
///
/// Not Sendable by design: the owner drives it from one serial queue.
public final class Engine {
    public private(set) var keymap: Keymap

    /// Mirrors the macOS setting "Use F1, F2, etc. keys as standard function keys" (com.apple.keyboard.fnState).
    public var systemFunctionKeysStandard: Bool

    // MARK: - State

    /// What a physical press did, so its release can undo exactly that.
    private indirect enum HeldBinding {
        /// Nothing to undo (block, layer switch, macro, transparent tap).
        case nothing
        /// One output key was pressed.
        case key(HIDKey)
        /// Modifiers then a key were pressed (released key first, then modifiers in reverse).
        case chord([HIDKey], HIDKey)
        /// A layer was pushed on the stack.
        case layer(LayerID)
        /// The binding is a tap-hold's *tap* action performed as a held action; its release counts as a tap
        /// for quick-tap purposes.
        case tap(HeldBinding)
    }

    /// A tap-hold key whose decision is still open.
    private struct Pending {
        let key: HIDKey
        let tap: Action
        let hold: Action
        let resolution: TapHoldResolution
        let pressTime: TimeInterval
        let deadline: TimeInterval
        /// Events that arrived while pending, replayed after the decision.
        var buffer: [KeyEvent] = []
        /// Keys whose *press* was buffered (their release decides `.permissive`).
        var pressedDuring: Set<HIDKey> = []
    }

    private var positionByKey: [HIDKey: Int]
    private var stack: [LayerID] = [0]
    private var held: [HIDKey: HeldBinding] = [:]
    /// Reference counts of pressed output keys: the ground truth of the virtual keyboard state.
    private var outputCounts: [HIDKey: Int] = [:]
    private var pending: Pending?
    private var fnHeld = false
    /// Most recent physical press (for `priorIdleMs`).
    private var lastPress: (key: HIDKey, time: TimeInterval)?
    /// When each tap-hold key last completed a tap (for quick-tap).
    private var lastTap: [HIDKey: TimeInterval] = [:]
    /// Output accumulator for the call in progress.
    private var out: [OutputEvent] = []

    // MARK: - Public API

    public init(keymap: Keymap, systemFunctionKeysStandard: Bool = false) {
        self.keymap = keymap
        self.positionByKey = keymap.positionByKey
        self.systemFunctionKeysStandard = systemFunctionKeysStandard
    }

    /// Replace the keymap (hot reload). Keys currently held keep the outputs they were pressed with until
    /// they are released. Layer stack resets to the new base; pending tap-holds are resolved as taps first.
    public func load(_ keymap: Keymap) -> [OutputEvent] {
        out.removeAll(keepingCapacity: true)
        // Resolve pending tap-holds (and anything their buffers contain) against the old keymap.
        while pending != nil { resolveTap(at: nil) }
        self.keymap = keymap
        positionByKey = keymap.positionByKey
        if stack != [0] {
            stack = [0]
            emitLayerChanged()
        }
        return take()
    }

    /// Process one physical event. Returns outputs in order. May also return outputs for buffered events
    /// that a tap-hold decision just released.
    public func handle(_ event: KeyEvent) -> [OutputEvent] {
        out.removeAll(keepingCapacity: true)
        dispatch(event)
        return take()
    }

    /// Fire any timers that are due at `now`.
    public func tick(now: TimeInterval) -> [OutputEvent] {
        out.removeAll(keepingCapacity: true)
        while let p = pending, now >= p.deadline { resolveHold() }
        return take()
    }

    /// Earliest time `tick` needs to be called, or nil.
    public var nextDeadline: TimeInterval? { pending?.deadline }

    /// Emergency: release every held output, drop pending state, reset layers to base.
    public func releaseAll() -> [OutputEvent] {
        out.removeAll(keepingCapacity: true)
        pending = nil
        held.removeAll()
        lastTap.removeAll()
        lastPress = nil
        fnHeld = false
        // Deterministic order: non-modifiers first, then modifiers, each by usage.
        let keys = outputCounts.keys.sorted { a, b in
            if a.isModifier != b.isModifier { return !a.isModifier }
            if a.page != b.page { return a.page < b.page }
            return a.usage < b.usage
        }
        outputCounts.removeAll()
        for k in keys { out.append(.release(k)) }
        if stack != [0] {
            stack = [0]
            emitLayerChanged()
        }
        return take()
    }

    /// Active layer ids, base first.
    public var activeLayers: [LayerID] { stack }

    /// Currently pressed virtual keys (for resync after reconnect).
    public var heldOutputs: Set<HIDKey> { Set(outputCounts.keys) }

    // MARK: - Event routing

    private func take() -> [OutputEvent] {
        let result = out
        out.removeAll(keepingCapacity: true)
        return result
    }

    /// Route an event through the pending tap-hold (if any) or straight to `process`.
    private func dispatch(_ e: KeyEvent) {
        // An event stamped after the deadline means the timer should already have fired.
        if let p = pending, e.time >= p.deadline { resolveHold() }
        guard let p = pending else {
            process(e)
            return
        }
        if e.key == p.key {
            if e.isDown { return } // duplicate press (hardware repeat); ignore
            resolveTap(at: e.time)
            return
        }
        if e.isDown {
            if p.resolution == .holdOnPress {
                resolveHold()
                dispatch(e)
            } else {
                pending!.buffer.append(e)
                pending!.pressedDuring.insert(e.key)
            }
        } else if p.pressedDuring.contains(e.key) {
            if p.resolution == .permissive {
                resolveHold()
                dispatch(e)
            } else {
                pending!.buffer.append(e)
            }
        } else {
            // Release of a key that was already down before the tap-hold press: it cannot influence
            // the decision, so pass it through now.
            process(e)
        }
    }

    /// The normal (non-buffered) path: resolve on press, undo on release.
    private func process(_ e: KeyEvent) {
        if e.key == Keys.fn { fnHeld = e.isDown }
        if e.isDown {
            processPress(e)
        } else if let binding = held.removeValue(forKey: e.key) {
            release(binding, key: e.key, at: e.time)
        }
        // Releases of keys we never saw pressed are dropped: their output is not held.
    }

    private func processPress(_ e: KeyEvent) {
        defer { lastPress = (e.key, e.time) }
        guard held[e.key] == nil else { return } // duplicate press; ignore

        let action: Action?
        if let pos = positionByKey[e.key] {
            action = keymap.resolve(position: pos, stack: stack)
        } else {
            action = nil
        }

        guard case .tapHold(let th)? = action else {
            held[e.key] = press(action, key: e.key)
            return
        }

        let settings = keymap.settings
        let resolution = th.resolution ?? settings.resolution
        let tapTimeout = seconds(th.tapTimeoutMs ?? settings.tapTimeoutMs)
        let holdTimeout = seconds(th.holdTimeoutMs ?? settings.holdTimeoutMs)

        // Prior idle: a different key pressed very recently means we are typing, so this is a tap.
        if settings.priorIdleMs > 0, let lp = lastPress, lp.key != e.key,
           e.time - lp.time < seconds(settings.priorIdleMs) {
            held[e.key] = .tap(press(th.tap, key: e.key))
            return
        }
        // Quick tap: pressing again right after a tap repeats the tap (held), e.g. `esc esc` or auto-repeat.
        if let t = lastTap[e.key], e.time - t < tapTimeout {
            held[e.key] = .tap(press(th.tap, key: e.key))
            return
        }
        pending = Pending(key: e.key, tap: th.tap, hold: th.hold, resolution: resolution,
                          pressTime: e.time, deadline: e.time + holdTimeout)
    }

    // MARK: - Tap-hold decisions

    /// Decide the pending tap-hold as a hold, then replay what was buffered.
    private func resolveHold() {
        guard let p = pending else { return }
        pending = nil
        held[p.key] = press(p.hold, key: p.key)
        for e in p.buffer { dispatch(e) }
    }

    /// Decide the pending tap-hold as a tap (press + release of the tap action), then replay what was
    /// buffered. `time` is the physical release time, or nil when forced (e.g. by `load`).
    private func resolveTap(at time: TimeInterval?) {
        guard let p = pending else { return }
        pending = nil
        let binding = press(p.tap, key: p.key)
        release(binding, key: p.key, at: nil)
        if let time { lastTap[p.key] = time }
        for e in p.buffer { dispatch(e) }
    }

    // MARK: - Performing actions

    /// Perform the press half of `action` for physical `key` (nil / transparent = hardware default)
    /// and return what must be undone on release.
    private func press(_ action: Action?, key: HIDKey) -> HeldBinding {
        guard let action else { return .key(pressOutput(hardwareDefault(for: key))) }
        switch action {
        case .transparent:
            return .key(pressOutput(hardwareDefault(for: key)))
        case .block:
            return .nothing
        case .key(let k):
            return .key(pressOutput(k))
        case .chord(let mods, let k):
            for m in mods { pressOutput(m) }
            pressOutput(k)
            return .chord(mods, k)
        case .layerWhileHeld(let id):
            stack.append(id)
            emitLayerChanged()
            return .layer(id)
        case .layerSwitch(let id):
            if stack[0] != id {
                stack[0] = id
                emitLayerChanged()
            }
            return .nothing
        case .tapHold(let th):
            // Reached only when nested inside another action; behave as its tap.
            return press(th.tap, key: key)
        case .macro(let actions):
            for a in actions {
                let b = press(a, key: key)
                release(b, key: key, at: nil)
            }
            return .nothing
        }
    }

    /// Undo `binding`. `time` is the physical release time when known (for quick-tap tracking).
    private func release(_ binding: HeldBinding, key: HIDKey, at time: TimeInterval?) {
        switch binding {
        case .nothing:
            break
        case .key(let k):
            releaseOutput(k)
        case .chord(let mods, let k):
            releaseOutput(k)
            for m in mods.reversed() { releaseOutput(m) }
        case .layer(let id):
            // Remove the most recent matching instance, never the base.
            if let i = stack.lastIndex(of: id), i > 0 {
                stack.remove(at: i)
                emitLayerChanged()
            }
        case .tap(let inner):
            release(inner, key: key, at: time)
            if let time { lastTap[key] = time }
        }
    }

    /// What an unmapped key sends: media/system function for F1–F12 depending on mode and `fn`,
    /// the key itself otherwise.
    private func hardwareDefault(for key: HIDKey) -> HIDKey {
        guard let media = Keys.mediaFunctionRow[key] else { return key }
        var mediaMode: Bool
        switch keymap.settings.functionRow {
        case .media: mediaMode = true
        case .function: mediaMode = false
        case .system: mediaMode = !systemFunctionKeysStandard
        }
        if fnHeld { mediaMode.toggle() }
        return mediaMode ? media : key
    }

    // MARK: - Output bookkeeping

    @discardableResult
    private func pressOutput(_ k: HIDKey) -> HIDKey {
        let count = outputCounts[k, default: 0]
        outputCounts[k] = count + 1
        if count == 0 { out.append(.press(k)) }
        return k
    }

    private func releaseOutput(_ k: HIDKey) {
        guard let count = outputCounts[k] else { return }
        if count <= 1 {
            outputCounts.removeValue(forKey: k)
            out.append(.release(k))
        } else {
            outputCounts[k] = count - 1
        }
    }

    private func emitLayerChanged() {
        out.append(.layerChanged(stack))
    }

    private func seconds(_ ms: Int) -> TimeInterval { TimeInterval(ms) / 1000 }
}
