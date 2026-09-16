import Foundation
import StrataCore
import StrataIPC

/// `strata status [--json] [--watch]` — ask the running daemon for its status over the per-user IPC socket.
enum StatusCommand {
    static func run(args: [String]) -> Int32 {
        let json = args.contains("--json")
        let watch = args.contains("--watch")
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let client = IPCClient(onConnection: { connected in
            if !connected && !watch { box.set(nil) ; done.signal() }
        }, onEvent: { event in
            switch event {
            case .status(let s):
                if json, let data = try? JSONEncoder.pretty.encode(s) { print(String(decoding: data, as: UTF8.self)) }
                else { print(describe(s)) }
                if !watch { box.set(s); done.signal() }
            case .layer(let names): if watch { print("layer: \(names.joined(separator: " > "))") }
            case .learned(let key, _, _): if watch { print("learned: \(key)") }
            case .log(let s): if watch { print("log: \(s)") }
            }
        })
        client.start()
        if watch { dispatchMain() }
        if done.wait(timeout: .now() + 3) == .timedOut {
            FileHandle.standardError.write("no answer from the Strata daemon at \(IPC.socketPath(uid: getuid())) — is it running? (sudo launchctl print system/dev.farzadhayat.strata.daemon)\n".data(using: .utf8)!)
            return 1
        }
        return box.get() == nil ? 1 : 0
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

final class ResultBox: @unchecked Sendable {
    private var value: IPC.Status??
    private let lock = NSLock()
    func set(_ v: IPC.Status?) { lock.lock(); value = .some(v); lock.unlock() }
    func get() -> IPC.Status? { lock.lock(); defer { lock.unlock() }; return value ?? nil }
}

extension JSONEncoder {
    static let pretty: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e }()
}
