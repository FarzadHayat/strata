import Carbon.HIToolbox
import Foundation

/// Maps macOS virtual key codes (`NSEvent.keyCode`, the Carbon `kVK_*` constants) to canonical Strata
/// key names. Used by the editor's "press a key" feature when the daemon is not available and the only
/// source of key presses is a local `NSEvent` monitor.
///
/// Built from `Carbon/HIToolbox/Events.h`: the `kVK_ANSI_*` codes are positional (US layout) so
/// they map one-to-one onto the ANSI blueprint regardless of the user's input source; the layout-
/// independent codes (`kVK_Return`, `kVK_Shift`, arrows, F-keys …) are listed by their Carbon names.
enum KeyCodeTable {
    static func name(forKeyCode code: UInt16) -> String? { names[Int(code)] }

    private static let names: [Int: String] = [
        // Letters (positional, US ANSI layout).
        kVK_ANSI_A: "a", kVK_ANSI_B: "b", kVK_ANSI_C: "c", kVK_ANSI_D: "d", kVK_ANSI_E: "e", kVK_ANSI_F: "f",
        kVK_ANSI_G: "g", kVK_ANSI_H: "h", kVK_ANSI_I: "i", kVK_ANSI_J: "j", kVK_ANSI_K: "k", kVK_ANSI_L: "l",
        kVK_ANSI_M: "m", kVK_ANSI_N: "n", kVK_ANSI_O: "o", kVK_ANSI_P: "p", kVK_ANSI_Q: "q", kVK_ANSI_R: "r",
        kVK_ANSI_S: "s", kVK_ANSI_T: "t", kVK_ANSI_U: "u", kVK_ANSI_V: "v", kVK_ANSI_W: "w", kVK_ANSI_X: "x",
        kVK_ANSI_Y: "y", kVK_ANSI_Z: "z",
        // Digits and symbols.
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Grave: "`",
        kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ISO_Section: "102d",
        // Whitespace, editing, escape.
        kVK_Space: "spc", kVK_Return: "ret", kVK_Tab: "tab", kVK_Delete: "bspc", kVK_ForwardDelete: "del",
        kVK_Escape: "esc", kVK_Help: "help",
        // Modifiers and locks.
        kVK_CapsLock: "caps", kVK_Shift: "lsft", kVK_RightShift: "rsft", kVK_Control: "lctl", kVK_RightControl: "rctl",
        kVK_Option: "lalt", kVK_RightOption: "ralt", kVK_Command: "lmet", kVK_RightCommand: "rmet", kVK_Function: "fn",
        // Navigation.
        kVK_LeftArrow: "left", kVK_RightArrow: "right", kVK_UpArrow: "up", kVK_DownArrow: "down",
        kVK_Home: "home", kVK_End: "end", kVK_PageUp: "pgup", kVK_PageDown: "pgdn",
        // Function keys.
        kVK_F1: "f1", kVK_F2: "f2", kVK_F3: "f3", kVK_F4: "f4", kVK_F5: "f5", kVK_F6: "f6", kVK_F7: "f7",
        kVK_F8: "f8", kVK_F9: "f9", kVK_F10: "f10", kVK_F11: "f11", kVK_F12: "f12", kVK_F13: "f13",
        kVK_F14: "f14", kVK_F15: "f15", kVK_F16: "f16", kVK_F17: "f17", kVK_F18: "f18", kVK_F19: "f19", kVK_F20: "f20",
        // Keypad (external keyboards).
        kVK_ANSI_Keypad0: "kp0", kVK_ANSI_Keypad1: "kp1", kVK_ANSI_Keypad2: "kp2", kVK_ANSI_Keypad3: "kp3",
        kVK_ANSI_Keypad4: "kp4", kVK_ANSI_Keypad5: "kp5", kVK_ANSI_Keypad6: "kp6", kVK_ANSI_Keypad7: "kp7",
        kVK_ANSI_Keypad8: "kp8", kVK_ANSI_Keypad9: "kp9", kVK_ANSI_KeypadDecimal: "kp.", kVK_ANSI_KeypadMultiply: "kp*",
        kVK_ANSI_KeypadPlus: "kp+", kVK_ANSI_KeypadMinus: "kp-", kVK_ANSI_KeypadDivide: "kp/", kVK_ANSI_KeypadEnter: "kprt",
        kVK_ANSI_KeypadEquals: "kp=", kVK_ANSI_KeypadClear: "nlck",
        // Media keys that reach the app as key events on some keyboards.
        kVK_VolumeUp: "volu", kVK_VolumeDown: "vold", kVK_Mute: "mute",
    ]
}
