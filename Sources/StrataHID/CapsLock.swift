import Foundation
import IOKit
import IOKit.hidsystem

/// Toggles the system caps-lock state through IOHIDSystem so both the modifier state and the physical
/// keyboard LED update (the virtual keyboard has no LED, so sending usage 0x39 would leave it dark).
public final class CapsLockController: @unchecked Sendable {
    private var connect: io_connect_t = 0
    private let lock = NSLock()

    public init() {}

    private func connection() -> io_connect_t? {
        lock.lock(); defer { lock.unlock() }
        if connect != 0 { return connect }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var c: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &c) == kIOReturnSuccess else { return nil }
        connect = c
        return c
    }

    public var isOn: Bool? {
        guard let c = connection() else { return nil }
        var state: Bool = false
        guard IOHIDGetModifierLockState(c, Int32(kIOHIDCapsLockState), &state) == kIOReturnSuccess else { return nil }
        return state
    }

    @discardableResult
    public func set(on: Bool) -> Bool {
        guard let c = connection() else { return false }
        return IOHIDSetModifierLockState(c, Int32(kIOHIDCapsLockState), on) == kIOReturnSuccess
    }

    @discardableResult
    public func toggle() -> Bool? {
        guard let current = isOn else { return nil }
        return set(on: !current) ? !current : nil
    }
}
