/// How a tap-hold key decides between its tap and hold actions.
public enum TapHoldResolution: String, Sendable, Codable, CaseIterable {
    /// Hold if another key is pressed *and released* while this key is held (QMK "permissive hold",
    /// kanata `tap-hold-release`, kmonad `tap-hold-next-release`), or when the hold timeout elapses.
    case permissive
    /// Hold as soon as any other key is pressed while this key is held (kanata `tap-hold-press`).
    case holdOnPress = "hold-on-press"
    /// Hold only when the hold timeout elapses (QMK default, kanata `tap-hold`).
    case timeout
}

/// What the function row does when no explicit mapping applies.
public enum FunctionRowMode: String, Sendable, Codable, CaseIterable {
    /// Follow the system setting "Use F1, F2, etc. keys as standard function keys".
    case system
    /// F-keys always send media/system functions unless `fn` is held.
    case media
    /// F-keys always send plain F1–F12 unless `fn` is held.
    case function
}

/// Global tuning knobs from `(defcfg …)`.
public struct Settings: Sendable, Equatable, Codable {
    public var tapTimeoutMs: Int = 200
    public var holdTimeoutMs: Int = 200
    /// Force a tap if the previous key press happened less than this many ms before the tap-hold press.
    public var priorIdleMs: Int = 120
    public var resolution: TapHoldResolution = .permissive
    public var functionRow: FunctionRowMode = .system
    /// Product-name substrings of keyboards to leave alone (case-insensitive).
    public var excludeDevices: [String] = []

    public init() {}
}

/// Identifier of a layer inside a compiled keymap.
public typealias LayerID = Int

/// A fully resolved action bound to a physical key position on some layer.
public indirect enum Action: Sendable, Equatable, Hashable {
    /// `_` — fall through to the layer below (ultimately the hardware default).
    case transparent
    /// `XX` — swallow the key.
    case block
    /// Send a single key (any usage page).
    case key(HIDKey)
    /// Send modifiers + a key together, e.g. `M-c`.
    case chord(modifiers: [HIDKey], key: HIDKey)
    /// Activate a layer while held (kanata `layer-while-held`, kmonad `layer-toggle`).
    case layerWhileHeld(LayerID)
    /// Permanently switch the base layer.
    case layerSwitch(LayerID)
    /// Tap for one action, hold for another.
    case tapHold(TapHold)
    /// Send a sequence of actions (each pressed and released in turn).
    case macro([Action])

    public struct TapHold: Sendable, Equatable, Hashable {
        public var tap: Action
        public var hold: Action
        public var tapTimeoutMs: Int?
        public var holdTimeoutMs: Int?
        public var resolution: TapHoldResolution?

        public init(tap: Action, hold: Action, tapTimeoutMs: Int? = nil, holdTimeoutMs: Int? = nil,
                    resolution: TapHoldResolution? = nil) {
            self.tap = tap
            self.hold = hold
            self.tapTimeoutMs = tapTimeoutMs
            self.holdTimeoutMs = holdTimeoutMs
            self.resolution = resolution
        }
    }

    /// Whether this action, when pressed, keeps something "held" until physical release.
    public var isMomentary: Bool {
        switch self {
        case .key, .chord, .layerWhileHeld, .tapHold: return true
        case .transparent, .block, .layerSwitch, .macro: return false
        }
    }
}

/// One layer: an action per `defsrc` position (`nil` = not specified = transparent).
public struct Layer: Sendable, Equatable {
    public var name: String
    public var actions: [Action?]

    public init(name: String, actions: [Action?]) {
        self.name = name
        self.actions = actions
    }
}

/// The compiled, immutable form of a config file that the engine executes.
public struct Keymap: Sendable, Equatable {
    public var settings: Settings
    /// Physical keys in `defsrc` order. Position index is the key identity used by layers.
    public var source: [HIDKey]
    /// Layers; index 0 is the base layer.
    public var layers: [Layer]

    public init(settings: Settings = Settings(), source: [HIDKey], layers: [Layer]) {
        self.settings = settings
        self.source = source
        self.layers = layers
    }

    public var positionByKey: [HIDKey: Int] {
        var m: [HIDKey: Int] = [:]
        for (i, k) in source.enumerated() where m[k] == nil { m[k] = i }
        return m
    }

    public func layerID(named name: String) -> LayerID? {
        layers.firstIndex { $0.name == name }
    }

    /// The action for `position` on `layer`, looking through transparent entries down to `base`.
    /// Returns `nil` when every layer in the stack is transparent (→ hardware default).
    public func resolve(position: Int, stack: [LayerID]) -> Action? {
        for id in stack.reversed() {
            guard layers.indices.contains(id), layers[id].actions.indices.contains(position) else { continue }
            if let a = layers[id].actions[position], a != .transparent { return a }
        }
        return nil
    }
}
