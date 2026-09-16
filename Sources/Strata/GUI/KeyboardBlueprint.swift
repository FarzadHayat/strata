import Foundation
import StrataCore

/// One keycap of the visual keyboard. Coordinates and sizes are in key units (1 = one standard key).
/// `name` is the canonical key name used in `defsrc`.
struct KeyBlueprint: Identifiable, Hashable, Sendable {
    let name: String
    let x: Double
    let y: Double
    let w: Double
    let h: Double

    var id: String { name }
    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

/// Data-driven layouts of the physical keyboard drawn by the editor.
enum KeyboardBlueprint {
    /// Height of the (shorter) function row, in key units.
    static let functionRowHeight = 0.7
    /// Overall size of the ANSI MacBook Pro blueprint, in key units.
    static let totalWidth = 14.5
    static let totalHeight = functionRowHeight + 5.0

    /// MacBook Pro (ANSI, 2021+) keyboard. Touch ID is omitted. Order matches the recommended `defsrc` order.
    static let ansiMacBookPro: [KeyBlueprint] = {
        var keys: [KeyBlueprint] = []
        let fnH = functionRowHeight
        keys += row(y: 0, h: fnH, [("esc", 1.5)] + (1...12).map { ("f\($0)", 1.0) })
        var y = fnH
        keys += row(y: y, h: 1, [("`", 1)] + ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "="].map { ($0, 1.0) } + [("bspc", 1.5)])
        y += 1
        keys += row(y: y, h: 1, [("tab", 1.5)] + ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p", "[", "]"].map { ($0, 1.0) } + [("\\", 1)])
        y += 1
        keys += row(y: y, h: 1, [("caps", 1.75)] + ["a", "s", "d", "f", "g", "h", "j", "k", "l", ";", "'"].map { ($0, 1.0) } + [("ret", 1.75)])
        y += 1
        keys += row(y: y, h: 1, [("lsft", 2.25)] + ["z", "x", "c", "v", "b", "n", "m", ",", ".", "/"].map { ($0, 1.0) } + [("rsft", 2.25)])
        // `up` sits half-height above `down`, on the shift row's line.
        y += 1
        keys.append(KeyBlueprint(name: "up", x: 12.5, y: y, w: 1, h: 0.5))
        keys += row(y: y, h: 1, [("fn", 1), ("lctl", 1), ("lalt", 1), ("lmet", 1.25), ("spc", 5), ("rmet", 1.25), ("ralt", 1)])
        keys.append(KeyBlueprint(name: "left", x: 11.5, y: y + 0.5, w: 1, h: 0.5))
        keys.append(KeyBlueprint(name: "down", x: 12.5, y: y + 0.5, w: 1, h: 0.5))
        keys.append(KeyBlueprint(name: "right", x: 13.5, y: y + 0.5, w: 1, h: 0.5))
        return keys
    }()

    /// Key names of the blueprint in `defsrc` order (used to seed a starter config).
    static var defaultSourceKeys: [String] {
        ansiMacBookPro.map { $0.name == "`" ? "grv" : $0.name }
    }

    /// HID key for each blueprint entry (names are validated by `validate()`).
    static let keysByName: [String: HIDKey] = {
        var m: [String: HIDKey] = [:]
        for k in ansiMacBookPro { if let hid = KeyTable.key(named: k.name) { m[k.name] = hid } }
        return m
    }()

    private static func row(y: Double, h: Double, _ keys: [(String, Double)]) -> [KeyBlueprint] {
        var x = 0.0
        var out: [KeyBlueprint] = []
        for (name, w) in keys {
            out.append(KeyBlueprint(name: name, x: x, y: y, w: w, h: h))
            x += w
        }
        return out
    }

    /// Sanity checks for the blueprint: every name is a known key, no duplicates, no overlapping caps,
    /// everything inside the declared bounds. Returns human-readable problems (empty = valid).
    static func validate() -> [String] {
        var problems: [String] = []
        let keys = ansiMacBookPro
        var seen: [HIDKey: String] = [:]
        for k in keys {
            guard let hid = KeyTable.key(named: k.name) else {
                problems.append("blueprint key '\(k.name)' is not a known key name")
                continue
            }
            if let first = seen[hid], first != k.name {
                problems.append("blueprint keys '\(first)' and '\(k.name)' are the same physical key")
            }
            seen[hid] = k.name
            if k.w <= 0 || k.h <= 0 { problems.append("blueprint key '\(k.name)' has a non-positive size") }
            if k.x < 0 || k.y < 0 || k.x + k.w > totalWidth + 1e-9 || k.y + k.h > totalHeight + 1e-9 {
                problems.append("blueprint key '\(k.name)' lies outside the \(totalWidth)×\(totalHeight) bounds")
            }
        }
        for i in keys.indices {
            for j in keys.indices where j > i {
                let overlap = keys[i].rect.intersection(keys[j].rect)
                if !overlap.isNull, overlap.width > 1e-6, overlap.height > 1e-6 {
                    problems.append("blueprint keys '\(keys[i].name)' and '\(keys[j].name)' overlap")
                }
            }
        }
        return problems
    }
}
