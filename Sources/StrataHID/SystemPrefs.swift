import Foundation

/// Reads user-level macOS preferences the daemon (running as root) needs.
public enum SystemPrefs {
    /// The user currently logged in at the console (owner of /dev/console), or nil.
    public static func consoleUser() -> String? {
        var st = stat()
        guard stat("/dev/console", &st) == 0, let pw = getpwuid(st.st_uid) else { return nil }
        return String(cString: pw.pointee.pw_name)
    }

    public static func homeDirectory(forUser user: String) -> String? {
        guard let pw = getpwnam(user) else { return nil }
        return String(cString: pw.pointee.pw_dir)
    }

    /// `com.apple.keyboard.fnState` — true when "Use F1, F2, etc. keys as standard function keys" is on.
    public static func functionKeysStandard(forUser user: String?) -> Bool? {
        guard let user, let home = homeDirectory(forUser: user) else { return nil }
        let path = home + "/Library/Preferences/.GlobalPreferences.plist"
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        if let b = plist["com.apple.keyboard.fnState"] as? Bool { return b }
        if let n = plist["com.apple.keyboard.fnState"] as? Int { return n != 0 }
        return false
    }
}
