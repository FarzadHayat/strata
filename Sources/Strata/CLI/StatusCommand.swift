import Foundation
import StrataCore
import StrataIPC

/// `strata status [--json] [--watch]` — ask the running daemon for its status over the per-user IPC socket.
enum StatusCommand {
    static func run(args: [String]) -> Int32 {
        let json = args.contains("--json")
        let watch = args.contains("--watch")
        // Deliver on a private queue: with dispatchMain() the main thread is gone, so the main queue must not be used.
        let client = IPCClient(deliveryQueue: DispatchQueue(label: "strata.status"), onConnection: { _ in }, onEvent: { event in
            switch event {
            case .status(let s):
                if json, let data = try? JSONEncoder.pretty.encode(s) { print(String(decoding: data, as: UTF8.self)) }
                else { print(describe(s)) }
                if !watch { exit(0) }
            case .layer(let names): if watch { print("layer: \(names.joined(separator: " > "))") }
            case .learned(let key, _, _): if watch { print("learned: \(key)") }
            case .log(let s): if watch { print("log: \(s)") }
            }
        })
        client.start()
        if !watch {
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                FileHandle.standardError.write("no answer from the Strata daemon at \(IPC.socketPath(uid: getuid())) — is it running? (sudo launchctl print system/dev.farzadhayat.strata.daemon)\n".data(using: .utf8)!)
                exit(1)
            }
        }
        dispatchMain()
    }

    static func describe(_ s: IPC.Status) -> String {
        var out: [String] = []
        out.append("strata daemon \(s.version) pid \(s.daemonPID), up \(Int(s.uptime))s\(s.paused ? "  [PAUSED]" : "")")
        out.append("permissions : input monitoring=\(s.permissions.inputMonitoring), accessibility=\(s.permissions.accessibility)")
        out.append("driver      : \(s.driverActivated ? "activated" : "NOT activated")")
        out.append("virtual kbd : \(s.vhidReady ? "ready" : s.vhidConnected ? "connected, not ready" : "not connected")\(s.vhidError.map { " (\($0))" } ?? "")")
        for d in s.devices { out.append("device      : \(d.name) — \(d.seized ? "seized" : (d.note ?? "not seized"))") }
        out.append("config      : \(s.config.path) — \(s.config.loaded ? "loaded (\(s.config.layers.joined(separator: ", ")))" : "NOT loaded")")
        for e in s.config.errors { out.append("  error: \(e)") }
        for w in s.config.warnings { out.append("  warning: \(w)") }
        out.append("active layer: \(s.activeLayers.joined(separator: " > "))")
        return out.joined(separator: "\n")
    }
}

extension JSONEncoder {
    static let pretty: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e }()
}
