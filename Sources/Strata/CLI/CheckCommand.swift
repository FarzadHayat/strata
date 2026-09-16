import Foundation
import StrataCore
import StrataHID

enum CheckCommand {
    static func run() -> Int32 {
        let p = Permissions.check()
        print("input monitoring : \(p.inputMonitoring.rawValue)")
        print("accessibility    : \(p.accessibility ? "granted" : "not granted")")
        print("vhid driver      : \(Permissions.virtualHIDDriverActivated() ? "activated" : "NOT activated")")
        print("vhid daemon sock : \(FileManager.default.fileExists(atPath: VHIDClient.socketPath) ? "present" : (getuid() == 0 ? "MISSING" : "unknown (not root)"))")
        print("console user     : \(SystemPrefs.consoleUser() ?? "-")")
        return 0
    }
}
