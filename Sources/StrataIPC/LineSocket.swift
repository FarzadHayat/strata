import Foundation

/// Minimal newline-delimited framing over a Unix stream socket, shared by server and client.
/// All callbacks run on `queue`.
final class LineConnection: @unchecked Sendable {
    let fd: Int32
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    private var buffer = Data()
    var onLine: ((Data) -> Void)?
    var onClose: (() -> Void)?

    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    func start() {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.readAvailable() }
        src.setCancelHandler { [fd] in close(fd) }
        src.resume()
        source = src
    }

    func send(_ data: Data) {
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress! + offset, data.count - offset, 0) }
            if n < 0 {
                if errno == EINTR { continue }
                closeConnection()
                return
            }
            offset += n
        }
    }

    func closeConnection() {
        guard let src = source else { return }
        source = nil
        src.cancel()
        onClose?()
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 8192)
        let n = chunk.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress!, 8192, 0) }
        if n <= 0 {
            if n < 0 && (errno == EAGAIN || errno == EINTR) { return }
            closeConnection()
            return
        }
        buffer.append(contentsOf: chunk[0..<n])
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if !line.isEmpty { onLine?(line) }
        }
        if buffer.count > 1_000_000 { closeConnection() }   // garbage guard
    }
}

enum UnixSocket {
    static func address(for path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        precondition(bytes.count <= MemoryLayout.size(ofValue: addr.sun_path), "socket path too long")
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: bytes.count) { dst in
                for (i, c) in bytes.enumerated() { dst[i] = c }
            }
        }
        return addr
    }
}
