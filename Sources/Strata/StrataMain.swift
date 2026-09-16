import Foundation
import StrataCore

/// Entry point. One executable, several roles:
///   strata                 GUI (menu bar app) — default when launched as an .app
///   strata --daemon …      root LaunchDaemon: seize keyboards, run the engine, drive the virtual keyboard
///   strata probe …         empirical hardware/driver probe (root)
///   strata check           print permission/driver status
///   strata version
@main
struct StrataMain {
    static func main() {
        var args = Array(CommandLine.arguments.dropFirst())
        // Launch Services passes "-psn_…" to bundled apps; ignore it.
        args.removeAll { $0.hasPrefix("-psn_") }
        let role = args.first ?? ""
        let rest = Array(args.dropFirst())
        switch role {
        case "probe":
            exit(ProbeCommand.run(args: rest))
        case "version", "--version":
            print("strata \(StrataCore.version)")
        case "compile":
            exit(CompileCommand.run(args: rest))
        case "status":
            exit(StatusCommand.run(args: rest))
        case "check":
            exit(CheckCommand.run())
        case "--daemon":
            exit(DaemonCommand.run(args: rest))
        default:
            GUIApp.main()
        }
    }
}
