/// A HID usage: the (usage page, usage) pair that identifies a key on the wire.
/// Physical input from seized keyboards and output to the virtual keyboard both use this type.
public struct HIDKey: Hashable, Sendable, Codable, CustomStringConvertible {
    public let page: UInt16
    public let usage: UInt16

    public init(page: UInt16, usage: UInt16) {
        self.page = page
        self.usage = usage
    }

    /// Keyboard/Keypad page (0x07).
    public static func kbd(_ usage: UInt16) -> HIDKey { HIDKey(page: Page.keyboard, usage: usage) }
    /// Consumer page (0x0C).
    public static func consumer(_ usage: UInt16) -> HIDKey { HIDKey(page: Page.consumer, usage: usage) }
    /// Apple vendor top-case page (0x00FF): fn, brightness, keyboard illumination.
    public static func topCase(_ usage: UInt16) -> HIDKey { HIDKey(page: Page.appleTopCase, usage: usage) }
    /// Apple vendor keyboard page (0xFF01): spotlight, launchpad, mission control.
    public static func appleKeyboard(_ usage: UInt16) -> HIDKey { HIDKey(page: Page.appleKeyboard, usage: usage) }
    /// Generic desktop page (0x01): do not disturb (0x9B).
    public static func genericDesktop(_ usage: UInt16) -> HIDKey { HIDKey(page: Page.genericDesktop, usage: usage) }

    public enum Page {
        public static let genericDesktop: UInt16 = 0x01
        public static let keyboard: UInt16 = 0x07
        public static let consumer: UInt16 = 0x0C
        public static let appleTopCase: UInt16 = 0x00FF
        public static let appleKeyboard: UInt16 = 0xFF01
    }

    private func hex2(_ v: UInt16) -> String {
        let h = String(v, radix: 16, uppercase: true)
        return h.count < 2 ? "0" + h : h
    }

    public var isModifier: Bool { page == Page.keyboard && (0xE0...0xE7).contains(usage) }

    public var description: String {
        if let name = KeyTable.canonicalName(for: self) { return name }
        return "0x" + hex2(page) + ":0x" + hex2(usage)
    }
}

/// Well-known keys used by the engine itself.
public enum Keys {
    public static let capsLock = HIDKey.kbd(0x39)
    public static let escape = HIDKey.kbd(0x29)
    public static let fn = HIDKey.topCase(0x03)
    public static let leftControl = HIDKey.kbd(0xE0)
    public static let leftShift = HIDKey.kbd(0xE1)
    public static let leftOption = HIDKey.kbd(0xE2)
    public static let leftCommand = HIDKey.kbd(0xE3)
    public static let rightControl = HIDKey.kbd(0xE4)
    public static let rightShift = HIDKey.kbd(0xE5)
    public static let rightOption = HIDKey.kbd(0xE6)
    public static let rightCommand = HIDKey.kbd(0xE7)
    public static let f1 = HIDKey.kbd(0x3A)
    public static let f12 = HIDKey.kbd(0x45)

    public static func functionKey(_ n: Int) -> HIDKey {
        precondition((1...24).contains(n))
        return n <= 12 ? .kbd(UInt16(0x3A + n - 1)) : .kbd(UInt16(0x68 + n - 13))
    }

    /// Default MacBook Pro (2021+) function-row behaviour when `fn` is not held
    /// and "Use F1, F2, etc. keys as standard function keys" is off.
    public static let mediaFunctionRow: [HIDKey: HIDKey] = [
        functionKey(1): .topCase(0x05),          // brightness down
        functionKey(2): .topCase(0x04),          // brightness up
        functionKey(3): .appleKeyboard(0x10),    // mission control
        functionKey(4): .appleKeyboard(0x01),    // spotlight
        functionKey(5): .consumer(0xCF),         // dictation
        functionKey(6): .genericDesktop(0x9B),   // do not disturb / focus
        functionKey(7): .consumer(0xB6),         // previous track
        functionKey(8): .consumer(0xCD),         // play / pause
        functionKey(9): .consumer(0xB5),         // next track
        functionKey(10): .consumer(0xE2),        // mute
        functionKey(11): .consumer(0xEA),        // volume down
        functionKey(12): .consumer(0xE9),        // volume up
    ]
}
