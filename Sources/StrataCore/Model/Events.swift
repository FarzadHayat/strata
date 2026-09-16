import Foundation

/// One physical key transition as delivered by the HID layer.
public struct KeyEvent: Sendable, Equatable {
    public var key: HIDKey
    public var isDown: Bool
    /// Monotonic seconds (e.g. `ProcessInfo.systemUptime`). Only differences matter.
    public var time: TimeInterval
    /// Opaque device id (0 = unknown).
    public var device: UInt64

    public init(key: HIDKey, isDown: Bool, time: TimeInterval, device: UInt64 = 0) {
        self.key = key
        self.isDown = isDown
        self.time = time
        self.device = device
    }
}

/// What the engine wants the virtual keyboard (or the GUI) to do.
public enum OutputEvent: Sendable, Equatable {
    case press(HIDKey)
    case release(HIDKey)
    /// Emitted whenever the active layer stack changes (for the GUI). Layer ids, base first.
    case layerChanged([LayerID])
}
