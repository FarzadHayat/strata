import Foundation
import StrataCore

/// GUI side: connects to the daemon's per-user socket, auto-reconnects, delivers events on the main queue.
public final class IPCClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.farzadhayat.strata.ipc.client")
    private var connection: LineConnection?
    private var reconnect: DispatchSourceTimer?
    private let path: String
    private let onEvent: @Sendable (IPC.Event) -> Void
    private let onConnection: @Sendable (Bool) -> Void
    private var stopped = false

    public init(uid: uid_t = getuid(), onConnection: @escaping @Sendable (Bool) -> Void,
                onEvent: @escaping @Sendable (IPC.Event) -> Void) {
        self.path = IPC.socketPath(uid: uid)
        self.onEvent = onEvent
        self.onConnection = onConnection
    }

    public func start() { queue.async { self.connect() } }

    public func stop() {
        queue.sync {
            stopped = true
            reconnect?.cancel(); reconnect = nil
            connection?.closeConnection(); connection = nil
        }
    }

    public var isConnected: Bool { queue.sync { connection != nil } }

    public func send(_ request: IPC.Request) {
        guard let data = try? IPC.encode(request) else { return }
        queue.async { self.connection?.send(data) }
    }

    private func connect() {
        guard !stopped else { return }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { scheduleReconnect(); return }
        var addr = UnixSocket.address(for: path)
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { close(fd); scheduleReconnect(); return }
        let conn = LineConnection(fd: fd, queue: queue)
        conn.onLine = { [weak self] line in
            guard let self, let ev = try? IPC.decode(IPC.Event.self, from: line) else { return }
            DispatchQueue.main.async { self.onEvent(ev) }
        }
        conn.onClose = { [weak self] in
            guard let self else { return }
            self.connection = nil
            DispatchQueue.main.async { self.onConnection(false) }
            self.scheduleReconnect()
        }
        connection = conn
        conn.start()
        DispatchQueue.main.async { self.onConnection(true) }
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        reconnect?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1.0)
        t.setEventHandler { [weak self] in self?.connect() }
        t.resume()
        reconnect = t
    }
}
