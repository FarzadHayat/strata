import Foundation
import StrataCore

/// Daemon side: accepts GUI connections on the per-user socket and broadcasts events.
public final class IPCServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.farzadhayat.strata.ipc.server")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [Int32: LineConnection] = [:]
    private let path: String
    private let owner: uid_t
    private let onRequest: @Sendable (IPC.Request) -> Void

    public init(uid: uid_t, onRequest: @escaping @Sendable (IPC.Request) -> Void) {
        self.path = IPC.socketPath(uid: uid)
        self.owner = uid
        self.onRequest = onRequest
    }

    public func start() throws {
        try FileManager.default.createDirectory(atPath: IPC.socketDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.system("socket", errno) }
        var addr = UnixSocket.address(for: path)
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { close(fd); throw IPCError.system("bind", errno) }
        chmod(path, 0o600)
        chown(path, owner, 0)
        guard listen(fd, 8) == 0 else { close(fd); throw IPCError.system("listen", errno) }
        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptClient() }
        src.resume()
        acceptSource = src
    }

    public func stop() {
        queue.sync {
            acceptSource?.cancel(); acceptSource = nil
            if listenFD >= 0 { close(listenFD); listenFD = -1 }
            for c in clients.values { c.closeConnection() }
            clients.removeAll()
            unlink(path)
        }
    }

    public var clientCount: Int { queue.sync { clients.count } }

    public func broadcast(_ event: IPC.Event) {
        guard let data = try? IPC.encode(event) else { return }
        queue.async { for c in self.clients.values { c.send(data) } }
    }

    private func acceptClient() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        let conn = LineConnection(fd: fd, queue: queue)
        conn.onLine = { [weak self] line in
            guard let self, let req = try? IPC.decode(IPC.Request.self, from: line) else { return }
            self.onRequest(req)
        }
        conn.onClose = { [weak self] in self?.clients.removeValue(forKey: fd) }
        clients[fd] = conn
        conn.start()
        onRequest(.status)   // greet every new client with a status
    }
}

public enum IPCError: Error, CustomStringConvertible {
    case system(String, Int32)
    case notConnected
    public var description: String {
        switch self {
        case .system(let call, let err): return "\(call)(): \(String(cString: strerror(err)))"
        case .notConnected: return "not connected to the Strata daemon"
        }
    }
}
