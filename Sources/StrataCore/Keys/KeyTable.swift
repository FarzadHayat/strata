/// Category of a key, used by the GUI for grouping and by the compiler for validation.
public enum KeyKind: String, Sendable, Codable {
    case letter, digit, symbol, modifier, navigation, editing, function, keypad, media, system, lock, international, other
}

/// One named key: canonical short name (kanata/kmonad style), accepted aliases, HID usage and a display label.
public struct KeyEntry: Sendable {
    public let name: String
    public let aliases: [String]
    public let key: HIDKey
    public let label: String
    public let kind: KeyKind

    init(_ name: String, _ key: HIDKey, label: String? = nil, kind: KeyKind) {
        self.init(name, [], key, label: label, kind: kind)
    }

    init(_ name: String, _ aliases: [String], _ key: HIDKey, label: String? = nil, kind: KeyKind) {
        self.name = name
        self.aliases = aliases
        self.key = key
        self.label = label ?? name
        self.kind = kind
    }
}

/// Registry of every key name understood by the config format.
/// Canonical names follow kanata/kmonad conventions so existing `.kbd` files read naturally;
/// Karabiner-Elements long names are accepted as aliases. Lookup is case-insensitive.
public enum KeyTable {
    public static let entries: [KeyEntry] = letters + digits + symbols + controls + modifiers
        + navigation + functionKeys + keypad + media + system + international

    public static func key(named raw: String) -> HIDKey? {
        byName[raw.lowercased()] ?? byName[raw]
    }

    public static func entry(named raw: String) -> KeyEntry? {
        guard let k = key(named: raw) else { return nil }
        return byKey[k]
    }

    public static func entry(for key: HIDKey) -> KeyEntry? { byKey[key] }

    public static func canonicalName(for key: HIDKey) -> String? { byKey[key]?.name }

    public static func label(for key: HIDKey) -> String { byKey[key]?.label ?? key.description }

    /// All names (canonical + aliases), for "did you mean" suggestions.
    public static var allNames: [String] { Array(byName.keys) }

    public static func suggestion(for raw: String) -> String? {
        let target = raw.lowercased()
        var best: (String, Int)? = nil
        for name in byName.keys where abs(name.count - target.count) <= 2 {
            let d = levenshtein(target, name)
            if d <= 2 && (best == nil || d < best!.1) { best = (name, d) }
        }
        return best?.0
    }

    // MARK: - Tables

    private static let byName: [String: HIDKey] = {
        var m: [String: HIDKey] = [:]
        for e in entries {
            m[e.name] = e.key
            for a in e.aliases where m[a.lowercased()] == nil { m[a.lowercased()] = e.key }
        }
        return m
    }()

    private static let byKey: [HIDKey: KeyEntry] = {
        var m: [HIDKey: KeyEntry] = [:]
        for e in entries where m[e.key] == nil { m[e.key] = e }
        return m
    }()

    static let letters: [KeyEntry] = "abcdefghijklmnopqrstuvwxyz".enumerated().map { i, c in
        KeyEntry(String(c), .kbd(UInt16(0x04 + i)), label: String(c).uppercased(), kind: .letter)
    }

    static let digits: [KeyEntry] = [
        KeyEntry("1", .kbd(0x1E), kind: .digit), KeyEntry("2", .kbd(0x1F), kind: .digit),
        KeyEntry("3", .kbd(0x20), kind: .digit), KeyEntry("4", .kbd(0x21), kind: .digit),
        KeyEntry("5", .kbd(0x22), kind: .digit), KeyEntry("6", .kbd(0x23), kind: .digit),
        KeyEntry("7", .kbd(0x24), kind: .digit), KeyEntry("8", .kbd(0x25), kind: .digit),
        KeyEntry("9", .kbd(0x26), kind: .digit), KeyEntry("0", .kbd(0x27), kind: .digit),
    ]

    static let symbols: [KeyEntry] = [
        KeyEntry("-", ["min", "minus", "hyphen"], .kbd(0x2D), kind: .symbol),
        KeyEntry("=", ["eql", "equal", "equal_sign"], .kbd(0x2E), kind: .symbol),
        KeyEntry("[", ["lbrc", "lbracket", "open_bracket"], .kbd(0x2F), kind: .symbol),
        KeyEntry("]", ["rbrc", "rbracket", "close_bracket"], .kbd(0x30), kind: .symbol),
        KeyEntry("\\", ["bksl", "bslash", "backslash"], .kbd(0x31), kind: .symbol),
        KeyEntry(";", ["scln", "semicolon"], .kbd(0x33), kind: .symbol),
        KeyEntry("'", ["apo", "apos", "quote", "apostrophe"], .kbd(0x34), kind: .symbol),
        KeyEntry("`", ["grv", "grave", "grave_accent_and_tilde"], .kbd(0x35), kind: .symbol),
        KeyEntry(",", ["comm", "comma"], .kbd(0x36), kind: .symbol),
        KeyEntry(".", ["dot", "period"], .kbd(0x37), kind: .symbol),
        KeyEntry("/", ["slash"], .kbd(0x38), kind: .symbol),
        KeyEntry("nuhs", ["non_us_pound", "nonuspound"], .kbd(0x32), label: "#", kind: .symbol),
        KeyEntry("102d", ["lsgt", "nubs", "non_us_backslash", "iso_section"], .kbd(0x64), label: "§", kind: .symbol),
    ]

    static let controls: [KeyEntry] = [
        KeyEntry("esc", ["escape"], .kbd(0x29), label: "esc", kind: .editing),
        KeyEntry("tab", .kbd(0x2B), label: "⇥", kind: .editing),
        KeyEntry("spc", ["space", "spacebar"], .kbd(0x2C), label: "space", kind: .editing),
        KeyEntry("ret", ["return", "ent", "enter", "return_or_enter"], .kbd(0x28), label: "↩", kind: .editing),
        KeyEntry("bspc", ["bks", "backspace", "delete_or_backspace"], .kbd(0x2A), label: "⌫", kind: .editing),
        KeyEntry("del", ["delete", "delete_forward", "fdel"], .kbd(0x4C), label: "⌦", kind: .editing),
        KeyEntry("ins", ["insert"], .kbd(0x49), kind: .editing),
        KeyEntry("caps", ["capslock", "caps_lock"], .kbd(0x39), label: "⇪", kind: .lock),
        KeyEntry("prnt", ["print", "prtsc", "print_screen", "sysrq"], .kbd(0x46), kind: .other),
        KeyEntry("slck", ["scrlck", "scroll_lock", "scrolllock"], .kbd(0x47), kind: .lock),
        KeyEntry("pause", ["brk", "pause_break"], .kbd(0x48), kind: .other),
        KeyEntry("menu", ["comp", "cmps", "cmp", "compose", "application", "app"], .kbd(0x65), label: "▤", kind: .other),
        KeyEntry("power", ["pwr"], .kbd(0x66), label: "⏻", kind: .system),
        KeyEntry("help", .kbd(0x75), kind: .other),
        KeyEntry("undo", .kbd(0x7A), kind: .editing),
        KeyEntry("cut_key", .kbd(0x7B), kind: .editing),
        KeyEntry("copy_key", .kbd(0x7C), kind: .editing),
        KeyEntry("paste_key", .kbd(0x7D), kind: .editing),
        KeyEntry("find_key", .kbd(0x7E), kind: .editing),
    ]

    static let modifiers: [KeyEntry] = [
        KeyEntry("lctl", ["lctrl", "ctl", "ctrl", "control", "left_control", "lcontrol"], .kbd(0xE0), label: "⌃", kind: .modifier),
        KeyEntry("lsft", ["lshift", "lshft", "shft", "sft", "shift", "left_shift"], .kbd(0xE1), label: "⇧", kind: .modifier),
        KeyEntry("lalt", ["alt", "lopt", "opt", "option", "left_option", "left_alt"], .kbd(0xE2), label: "⌥", kind: .modifier),
        KeyEntry("lmet", ["lmeta", "met", "meta", "lcmd", "cmd", "command", "left_command", "lgui"], .kbd(0xE3), label: "⌘", kind: .modifier),
        KeyEntry("rctl", ["rctrl", "right_control", "rcontrol"], .kbd(0xE4), label: "⌃", kind: .modifier),
        KeyEntry("rsft", ["rshift", "rshft", "right_shift"], .kbd(0xE5), label: "⇧", kind: .modifier),
        KeyEntry("ralt", ["ropt", "right_option", "right_alt"], .kbd(0xE6), label: "⌥", kind: .modifier),
        KeyEntry("rmet", ["rmeta", "rcmd", "right_command", "rgui"], .kbd(0xE7), label: "⌘", kind: .modifier),
        KeyEntry("fn", ["globe", "function", "keyboard_fn"], .topCase(0x03), label: "🌐", kind: .modifier),
    ]

    static let navigation: [KeyEntry] = [
        KeyEntry("left", ["lft", "left_arrow"], .kbd(0x50), label: "←", kind: .navigation),
        KeyEntry("right", ["rght", "rgt", "right_arrow"], .kbd(0x4F), label: "→", kind: .navigation),
        KeyEntry("up", ["up_arrow"], .kbd(0x52), label: "↑", kind: .navigation),
        KeyEntry("down", ["down_arrow"], .kbd(0x51), label: "↓", kind: .navigation),
        KeyEntry("home", .kbd(0x4A), label: "↖", kind: .navigation),
        KeyEntry("end", .kbd(0x4D), label: "↘", kind: .navigation),
        KeyEntry("pgup", ["pageup", "page_up"], .kbd(0x4B), label: "⇞", kind: .navigation),
        KeyEntry("pgdn", ["pagedown", "page_down", "pgdown"], .kbd(0x4E), label: "⇟", kind: .navigation),
    ]

    static let functionKeys: [KeyEntry] = (1...24).map { n in
        KeyEntry("f\(n)", [], Keys.functionKey(n), label: "F\(n)", kind: .function)
    }

    static let keypad: [KeyEntry] = [
        KeyEntry("nlck", ["numlock", "num_lock", "clear", "keypad_num_lock"], .kbd(0x53), kind: .lock),
        KeyEntry("kp/", ["kpslash", "keypad_slash"], .kbd(0x54), label: "/", kind: .keypad),
        KeyEntry("kp*", ["kpasterisk", "kpast", "keypad_asterisk"], .kbd(0x55), label: "*", kind: .keypad),
        KeyEntry("kp-", ["kpminus", "keypad_hyphen"], .kbd(0x56), label: "-", kind: .keypad),
        KeyEntry("kp+", ["kpplus", "keypad_plus"], .kbd(0x57), label: "+", kind: .keypad),
        KeyEntry("kprt", ["kpenter", "kpret", "keypad_enter"], .kbd(0x58), label: "⌤", kind: .keypad),
        KeyEntry("kp1", ["keypad_1"], .kbd(0x59), label: "1", kind: .keypad),
        KeyEntry("kp2", ["keypad_2"], .kbd(0x5A), label: "2", kind: .keypad),
        KeyEntry("kp3", ["keypad_3"], .kbd(0x5B), label: "3", kind: .keypad),
        KeyEntry("kp4", ["keypad_4"], .kbd(0x5C), label: "4", kind: .keypad),
        KeyEntry("kp5", ["keypad_5"], .kbd(0x5D), label: "5", kind: .keypad),
        KeyEntry("kp6", ["keypad_6"], .kbd(0x5E), label: "6", kind: .keypad),
        KeyEntry("kp7", ["keypad_7"], .kbd(0x5F), label: "7", kind: .keypad),
        KeyEntry("kp8", ["keypad_8"], .kbd(0x60), label: "8", kind: .keypad),
        KeyEntry("kp9", ["keypad_9"], .kbd(0x61), label: "9", kind: .keypad),
        KeyEntry("kp0", ["keypad_0"], .kbd(0x62), label: "0", kind: .keypad),
        KeyEntry("kp.", ["kpdot", "keypad_period"], .kbd(0x63), label: ".", kind: .keypad),
        KeyEntry("kp=", ["kpeql", "keypad_equal_sign"], .kbd(0x67), label: "=", kind: .keypad),
        KeyEntry("kp,", ["kpcomma", "keypad_comma"], .kbd(0x85), label: ",", kind: .keypad),
    ]

    static let media: [KeyEntry] = [
        KeyEntry("volu", ["volup", "volumeup", "volume_up", "volume_increment"], .consumer(0xE9), label: "🔊", kind: .media),
        KeyEntry("vold", ["voldwn", "voldown", "volumedown", "volume_down", "volume_decrement"], .consumer(0xEA), label: "🔉", kind: .media),
        KeyEntry("mute", ["volmute", "volume_mute"], .consumer(0xE2), label: "🔇", kind: .media),
        KeyEntry("pp", ["playpause", "play_pause", "play_or_pause"], .consumer(0xCD), label: "⏯", kind: .media),
        KeyEntry("play", .consumer(0xB0), label: "▶", kind: .media),
        KeyEntry("pause_media", .consumer(0xB1), label: "⏸", kind: .media),
        KeyEntry("stop", ["stopcd"], .consumer(0xB7), label: "⏹", kind: .media),
        KeyEntry("next", ["nextsong", "nexttrack", "scan_next_track"], .consumer(0xB5), label: "⏭", kind: .media),
        KeyEntry("prev", ["previoussong", "previoustrack", "scan_previous_track"], .consumer(0xB6), label: "⏮", kind: .media),
        KeyEntry("ffwd", ["fastforward", "fast_forward", "forward_media"], .consumer(0xB3), label: "⏩", kind: .media),
        KeyEntry("rewind", .consumer(0xB4), label: "⏪", kind: .media),
        KeyEntry("eject", ["ejectcd"], .consumer(0xB8), label: "⏏", kind: .media),
        KeyEntry("brup", ["bru", "brightnessup", "brightness_up", "display_brightness_increment"], .topCase(0x04), label: "☀︎+", kind: .media),
        KeyEntry("brdn", ["brdown", "brdwn", "brightnessdown", "brightness_down", "display_brightness_decrement"], .topCase(0x05), label: "☀︎-", kind: .media),
        KeyEntry("blup", ["kbdillumup", "illumination_up"], .topCase(0x08), label: "⌨︎+", kind: .media),
        KeyEntry("bldn", ["kbdillumdown", "illumination_down"], .topCase(0x09), label: "⌨︎-", kind: .media),
        KeyEntry("bltog", ["kbdillumtoggle", "illumination_toggle"], .topCase(0x07), label: "⌨︎", kind: .media),
    ]

    static let system: [KeyEntry] = [
        KeyEntry("mctl", ["missionctrl", "mission_control", "missioncontrol"], .appleKeyboard(0x10), label: "⌗", kind: .system),
        KeyEntry("spot", ["spotlight", "search"], .appleKeyboard(0x01), label: "🔍", kind: .system),
        KeyEntry("lp", ["launchpad"], .appleKeyboard(0x04), label: "⊞", kind: .system),
        KeyEntry("desktop", ["expose_desktop", "showdesktop"], .appleKeyboard(0x11), kind: .system),
        KeyEntry("dict", ["dictation"], .consumer(0xCF), label: "🎤", kind: .system),
        KeyEntry("dnd", ["do_not_disturb", "focus"], .genericDesktop(0x9B), label: "☾", kind: .system),
        KeyEntry("sleep", ["zzz"], .consumer(0x32), kind: .system),
        KeyEntry("www", ["browser", "internetbrowser"], .consumer(0x196), kind: .system),
        KeyEntry("mail", ["email", "emailreader"], .consumer(0x18A), kind: .system),
        KeyEntry("calc", ["calculator"], .consumer(0x192), kind: .system),
        KeyEntry("back", ["ac_back"], .consumer(0x224), kind: .system),
        KeyEntry("forward", ["fwd", "ac_forward"], .consumer(0x225), kind: .system),
        KeyEntry("refresh", ["ac_refresh"], .consumer(0x227), kind: .system),
        KeyEntry("prog1", [], .consumer(0x1A6), kind: .system),
        KeyEntry("prog2", [], .consumer(0x1A7), kind: .system),
    ]

    static let international: [KeyEntry] = [
        KeyEntry("ro", ["int1", "international1"], .kbd(0x87), kind: .international),
        KeyEntry("kana", ["int2", "katakanahiragana", "international2"], .kbd(0x88), kind: .international),
        KeyEntry("yen", ["int3", "international3"], .kbd(0x89), kind: .international),
        KeyEntry("henkan", ["int4", "international4"], .kbd(0x8A), kind: .international),
        KeyEntry("muhenkan", ["int5", "international5"], .kbd(0x8B), kind: .international),
        KeyEntry("lang1", ["hangeul", "japanese_kana", "kana_toggle"], .kbd(0x90), kind: .international),
        KeyEntry("lang2", ["hanja", "japanese_eisuu", "eisu"], .kbd(0x91), kind: .international),
    ]

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}
