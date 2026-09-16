import Foundation
import StrataHID

/// `strata --daemon [--config PATH] [--user NAME] [--dev-timeout SECONDS] [--allow-any-path]`
enum DaemonCommand {
    static func run(args: [String]) -> Int32 {
        var configPath: String?
        var user = SystemPrefs.consoleUser() ?? ProcessInfo.processInfo.environment["SUDO_USER"] ?? NSUserName()
        var devTimeout: TimeInterval?
        var allowAny = false
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--config": i += 1; configPath = args[i]
            case "--user": i += 1; user = args[i]
            case "--dev-timeout": i += 1; devTimeout = TimeInterval(args[i])
            case "--allow-any-path": allowAny = true
            default:
                FileHandle.standardError.write("unknown daemon option \(args[i])\n".data(using: .utf8)!)
                return 2
            }
            i += 1
        }
        guard let pw = getpwnam(user) else {
            FileHandle.standardError.write("unknown user \(user)\n".data(using: .utf8)!)
            return 2
        }
        let home = String(cString: pw.pointee.pw_dir)
        let path = configPath ?? home + "/.config/strata/keymap.kbd"
        let daemon = Daemon(options: .init(configPath: path, user: user, uid: pw.pointee.pw_uid, devTimeout: devTimeout, allowAnyPath: allowAny))
        daemon.run()
    }
}
