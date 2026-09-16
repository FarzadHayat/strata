import AppKit
import Foundation
import Observation

/// Screen corner the visualizer panel snaps to.
enum VisualizerCorner: String, CaseIterable, Identifiable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }

    var isTop: Bool { self == .topLeft || self == .topRight }
    var isLeft: Bool { self == .topLeft || self == .bottomLeft }
}

/// User settings of the on-screen keyboard visualizer, mirrored to `UserDefaults.standard` on every change.
@MainActor @Observable
final class VisualizerSettings {
    enum Key {
        static let enabled = "visualizer.enabled"
        static let corner = "visualizer.corner"
        static let clickThrough = "visualizer.clickThrough"
        static let opacity = "visualizer.opacity"
        static let width = "visualizer.width"
        static let frame = "visualizer.frame"
    }

    static let widthRange: ClosedRange<Double> = 260...720
    static let opacityRange: ClosedRange<Double> = 0.4...1.0
    static let defaultWidth = 380.0
    static let defaultOpacity = 0.9

    @ObservationIgnored private let defaults: UserDefaults

    var enabled: Bool { didSet { defaults.set(enabled, forKey: Key.enabled) } }
    var corner: VisualizerCorner { didSet { defaults.set(corner.rawValue, forKey: Key.corner) } }
    var clickThrough: Bool { didSet { defaults.set(clickThrough, forKey: Key.clickThrough) } }
    /// Panel alpha, `opacityRange`.
    var opacity: Double { didSet { defaults.set(opacity, forKey: Key.opacity) } }
    /// Panel width in points, `widthRange`; the height follows from the keyboard's aspect ratio.
    var width: Double { didSet { defaults.set(width, forKey: Key.width) } }
    /// Where the user last dragged the panel. `nil` = snapped to `corner`.
    var customFrame: CGRect? {
        didSet {
            if let customFrame { defaults.set(NSStringFromRect(customFrame), forKey: Key.frame) } else { defaults.removeObject(forKey: Key.frame) }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: Key.enabled)
        corner = defaults.string(forKey: Key.corner).flatMap(VisualizerCorner.init(rawValue:)) ?? .bottomRight
        clickThrough = defaults.bool(forKey: Key.clickThrough)
        let storedOpacity = defaults.object(forKey: Key.opacity) as? Double ?? Self.defaultOpacity
        opacity = Self.opacityRange.clamping(storedOpacity)
        let storedWidth = defaults.object(forKey: Key.width) as? Double ?? Self.defaultWidth
        width = Self.widthRange.clamping(storedWidth)
        if let text = defaults.string(forKey: Key.frame) {
            let rect = NSRectFromString(text)
            customFrame = rect.isEmpty ? nil : rect
        } else {
            customFrame = nil
        }
    }

    /// Forget the dragged position and snap back to `corner`.
    func resetPosition() { customFrame = nil }
}

extension ClosedRange where Bound == Double {
    func clamping(_ value: Double) -> Double {
        value.isFinite ? Swift.min(Swift.max(value, lowerBound), upperBound) : lowerBound
    }
}
