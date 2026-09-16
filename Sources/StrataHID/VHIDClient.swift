import Foundation
import StrataCore

/// Client for the Karabiner-DriverKit-VirtualHIDDevice daemon (package v8.x, client protocol 7).
///
/// Transport: a Unix stream socket at
/// `/Library/Application Support/org.pqrs/tmp/rootonly/karabiner_virtual_hid_device_service.sock`
/// (only root can traverse the directory). Framing (pqrs::unix_domain_stream):
/// `u32 BE body_size | u8 type | [u64 BE request_id] | payload`. Payload structs are little-endian.
/// The daemon pushes status changes as *request* frames that must be answered with an empty response.
///
/// Thread model: all state lives on `queue`; public methods hop onto it.
public final class VHIDClient: @unchecked Sendable {
    public static let socketPath = "/Library/Application Support/org.pqrs/tmp/rootonly/karabiner_virtual_hid_device_service.sock"
    static let clientProtocolVersion: UInt16 = 7
    static let heartbeatInterval: TimeInterval = 3
    static let idleTimeout: TimeInterval = 30
    static let reconnectInterval: TimeInterval = 1

    public struct Status: Sendable, Equatable {
        public var connected = false
        public var driverActivated = false
        public var driverConnected = false
        public var driverVersionMismatched = false
        public var keyboardReady = false
        public var lastError: String?
        public init() {}
        init(connected: Bool = false, lastError: String? = nil) { self.connected = connected; self.lastError = lastError }
    }

    enum FrameType: UInt8 { case heartbeat = 0, userData = 1, healthCheck = 2, healthCheckResponse = 3, request = 4, response = 5 }
    enum Request: UInt8 {
        case keyboardInitialize = 0, keyboardTerminate = 1, keyboardReset = 2
        case pointingInitialize = 3, pointingTerminate = 4, pointingReset = 5
        case postKeyboardInput = 6, postConsumerInput = 7, postAppleVendorKeyboardInput = 8
        case postAppleVendorTopCaseInput = 9, postGenericDesktopInput = 10, postPointingInput = 11
    }

    private let queue = DispatchQueue(label: "dev.farzadhayat.strata.vhid")
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var heartbeatTimer: DispatchSourceTimer?
    private var reconnectTimer: DispatchSourceTimer?
    private var lastActivity = Date()
    private var inbox = [UInt8]()
    private var nextRequestID: UInt64 = 0
    private var stopped = false
    private let countryCode: UInt64
    private(set) var status = Status()
    private let onStatus: @Sendable (Status) -> Void
    private var reports = VirtualReports()

    /// - Parameters:
    ///   - countryCode: HID country code for the virtual keyboard (33 = US).
    ///   - onStatus: called (on an internal queue) whenever the status changes.
    public init(countryCode: UInt64 = 33, onStatus: @escaping @Sendable (Status) -> Void) {
        self.countryCode = countryCode
        self.onStatus = onStatus
    }

    public func start() { queue.async { self.connect() } }

    public func stop() {
        queue.sync {
            stopped = true
            reconnectTimer?.cancel(); reconnectTimer = nil
            if fd >= 0 { sendReport(.keyboardTerminate, payload: []) }
            teardown(error: nil)
        }
    }

    /// True when reports can be posted right now.
    public var isReady: Bool { queue.sync { status.connected && status.keyboardReady } }

    // MARK: - Key output

    /// Press or release a key on the virtual keyboard. Safe to call from any thread.
    public func set(_ key: HIDKey, down: Bool) {
        queue.async {
            guard let (request, bytes) = self.reports.update(key: key, down: down) else { return }
            guard self.status.keyboardReady else { return }
            self.sendReport(request, payload: bytes)
        }
    }

    /// Re-post every report (after reconnect) or clear everything.
    public func resync(held: Set<HIDKey>) {
        queue.async {
            self.reports = VirtualReports()
            for k in held { _ = self.reports.update(key: k, down: true) }
            self.postAllReports()
        }
    }

    public func releaseAll() {
        queue.async {
            self.reports = VirtualReports()
            self.postAllReports()
        }
    }

    private func postAllReports() {
        guard status.keyboardReady else { return }
        for (request, bytes) in reports.all() { sendReport(request, payload: bytes) }
    }

    // MARK: - Connection

    private func connect() {
        guard !stopped else { return }
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { scheduleReconnect(error: "socket(): \(errnoString())"); return }
        var on: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Self.socketPath.utf8CString
        guard path.count <= MemoryLayout.size(ofValue: addr.sun_path) else { fatalError("socket path too long") }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: path.count) { dst in
                for (i, c) in path.enumerated() { dst[i] = c }
            }
        }
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else {
            let err = errnoString()
            close(sock)
            scheduleReconnect(error: "connect(): \(err) (is Karabiner-VirtualHIDDevice-Daemon running? are we root?)")
            return
        }
        fd = sock
        inbox.removeAll()
        lastActivity = Date()
        status = Status(connected: true)
        publish()

        let src = DispatchSource.makeReadSource(fileDescriptor: sock, queue: queue)
        src.setEventHandler { [weak self] in self?.readAvailable() }
        src.resume()
        readSource = src

        let hb = DispatchSource.makeTimerSource(queue: queue)
        hb.schedule(deadline: .now() + Self.heartbeatInterval, repeating: Self.heartbeatInterval)
        hb.setEventHandler { [weak self] in self?.heartbeat() }
        hb.resume()
        heartbeatTimer = hb

        // Give the daemon its 100 ms "ready" grace, then initialise the keyboard.
        queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.fd == sock else { return }
            self.sendKeyboardInitialize()
        }
    }

    private func scheduleReconnect(error: String?) {
        if let error { status.lastError = error; publish() }
        guard !stopped else { return }
        reconnectTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.reconnectInterval)
        t.setEventHandler { [weak self] in self?.connect() }
        t.resume()
        reconnectTimer = t
    }

    private func teardown(error: String?) {
        readSource?.cancel(); readSource = nil
        heartbeatTimer?.cancel(); heartbeatTimer = nil
        if fd >= 0 { close(fd); fd = -1 }
        let wasConnected = status.connected
        status = Status(lastError: error ?? status.lastError)
        if wasConnected || error != nil { publish() }
    }

    private func heartbeat() {
        guard fd >= 0 else { return }
        if Date().timeIntervalSince(lastActivity) > Self.idleTimeout {
            teardown(error: "daemon silent for \(Int(Self.idleTimeout))s")
            scheduleReconnect(error: nil)
            return
        }
        write(frame: [FrameType.heartbeat.rawValue])
    }

    // MARK: - Framing

    private func write(frame body: [UInt8]) {
        guard fd >= 0 else { return }
        var out = [UInt8]()
        out.reserveCapacity(4 + body.count)
        let n = UInt32(body.count)
        out.append(UInt8(n >> 24 & 0xFF)); out.append(UInt8(n >> 16 & 0xFF)); out.append(UInt8(n >> 8 & 0xFF)); out.append(UInt8(n & 0xFF))
        out.append(contentsOf: body)
        var offset = 0
        while offset < out.count {
            let w = out.withUnsafeBytes { Darwin.send(fd, $0.baseAddress! + offset, out.count - offset, 0) }
            if w < 0 {
                if errno == EINTR { continue }
                teardown(error: "send(): \(errnoString())")
                scheduleReconnect(error: nil)
                return
            }
            offset += w
        }
    }

    private func sendRequest(_ payload: [UInt8]) {
        nextRequestID &+= 1
        var body = [FrameType.request.rawValue]
        body.append(contentsOf: Self.be64(nextRequestID))
        body.append(contentsOf: payload)
        write(frame: body)
    }

    private func sendEmptyResponse(id: UInt64) {
        var body = [FrameType.response.rawValue]
        body.append(contentsOf: Self.be64(id))
        write(frame: body)
    }

    private func sendReport(_ request: Request, payload: [UInt8]) {
        var p = [UInt8(Self.clientProtocolVersion & 0xFF), UInt8(Self.clientProtocolVersion >> 8), request.rawValue]
        p.append(contentsOf: payload)
        sendRequest(p)
    }

    private func sendKeyboardInitialize() {
        var p = [UInt8]()
        p.append(contentsOf: Self.le64(0x16C0))       // vendor id
        p.append(contentsOf: Self.le64(0x27DB))       // product id
        p.append(contentsOf: Self.le64(countryCode))  // country code
        sendReport(.keyboardInitialize, payload: p)
    }

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = buf.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress!, 4096, 0) }
        if n == 0 {
            teardown(error: "daemon closed the connection")
            scheduleReconnect(error: nil)
            return
        }
        if n < 0 {
            if errno == EAGAIN || errno == EINTR { return }
            teardown(error: "recv(): \(errnoString())")
            scheduleReconnect(error: nil)
            return
        }
        lastActivity = Date()
        inbox.append(contentsOf: buf[0..<n])
        while inbox.count >= 4 {
            let size = Int(inbox[0]) << 24 | Int(inbox[1]) << 16 | Int(inbox[2]) << 8 | Int(inbox[3])
            guard size >= 1, size <= 1024 + 9 else {
                teardown(error: "bad frame size \(size)"); scheduleReconnect(error: nil); return
            }
            guard inbox.count >= 4 + size else { break }
            let body = Array(inbox[4..<(4 + size)])
            inbox.removeFirst(4 + size)
            handle(body: body)
        }
    }

    private func handle(body: [UInt8]) {
        guard let type = FrameType(rawValue: body[0]) else { return }
        switch type {
        case .heartbeat, .userData, .healthCheck, .healthCheckResponse:
            return
        case .request:
            guard body.count >= 9 else { return }
            let id = Self.readBE64(body, at: 1)
            applyStatus(Array(body[9...]))
            sendEmptyResponse(id: id)
        case .response:
            guard body.count >= 9 else { return }
            let payload = Array(body[9...])
            if payload.count >= 10 { applyStatus(payload) }
        }
    }

    private func applyStatus(_ payload: [UInt8]) {
        guard payload.count % 2 == 0 else { return }
        var s = status
        var i = 0
        while i + 1 < payload.count {
            let flag = payload[i + 1] != 0
            switch payload[i] {
            case 1: s.driverActivated = flag
            case 2: s.driverConnected = flag
            case 3: s.driverVersionMismatched = flag
            case 4: s.keyboardReady = flag
            default: break
            }
            i += 2
        }
        if s != status {
            let becameReady = s.keyboardReady && !status.keyboardReady
            status = s
            publish()
            if becameReady { postAllReports() }
        }
    }

    private func publish() { onStatus(status) }

    // MARK: - Byte helpers

    static func be64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * (7 - UInt64($0)))) & 0xFF) } }
    static func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xFF) } }
    static func readBE64(_ b: [UInt8], at o: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v = v << 8 | UInt64(b[o + i]) }
        return v
    }
    private func errnoString() -> String { String(cString: strerror(errno)) }
}

/// The five input reports of the virtual keyboard, kept persistent so each change re-posts the whole report.
struct VirtualReports {
    /// 32-slot array of u16 usages (HID array field; slot order irrelevant).
    struct Slots {
        var usages = [UInt16](repeating: 0, count: 32)
        mutating func insert(_ u: UInt16) -> Bool {
            if usages.contains(u) { return false }
            guard let i = usages.firstIndex(of: 0) else { return false }
            usages[i] = u
            return true
        }
        mutating func erase(_ u: UInt16) -> Bool {
            var changed = false
            for i in usages.indices where usages[i] == u { usages[i] = 0; changed = true }
            return changed
        }
        var bytes: [UInt8] {
            var b = [UInt8](); b.reserveCapacity(64)
            for u in usages { b.append(UInt8(u & 0xFF)); b.append(UInt8(u >> 8)) }
            return b
        }
    }

    var keyboard = Slots(), consumer = Slots(), topCase = Slots(), appleKeyboard = Slots(), genericDesktop = Slots()

    /// Applies the change; returns the request + report bytes to post, or nil if nothing changed / unsupported page.
    mutating func update(key: HIDKey, down: Bool) -> (VHIDClient.Request, [UInt8])? {
        func apply(_ slots: inout Slots) -> Bool { down ? slots.insert(key.usage) : slots.erase(key.usage) }
        switch key.page {
        case HIDKey.Page.keyboard:
            guard apply(&keyboard) else { return nil }
            return (.postKeyboardInput, Self.keyboardReport(keyboard))
        case HIDKey.Page.consumer:
            guard key.usage <= 0x300, apply(&consumer) else { return nil }
            return (.postConsumerInput, [2] + consumer.bytes)
        case HIDKey.Page.appleTopCase:
            guard apply(&topCase) else { return nil }
            return (.postAppleVendorTopCaseInput, [3] + topCase.bytes)
        case HIDKey.Page.appleKeyboard:
            guard apply(&appleKeyboard) else { return nil }
            return (.postAppleVendorKeyboardInput, [4] + appleKeyboard.bytes)
        case HIDKey.Page.genericDesktop:
            guard apply(&genericDesktop) else { return nil }
            return (.postGenericDesktopInput, [7] + genericDesktop.bytes)
        default:
            return nil
        }
    }

    func all() -> [(VHIDClient.Request, [UInt8])] {
        [(.postKeyboardInput, Self.keyboardReport(keyboard)),
         (.postConsumerInput, [2] + consumer.bytes),
         (.postAppleVendorTopCaseInput, [3] + topCase.bytes),
         (.postAppleVendorKeyboardInput, [4] + appleKeyboard.bytes),
         (.postGenericDesktopInput, [7] + genericDesktop.bytes)]
    }

    /// report id 1, modifier bitmask (unused: modifiers travel in the key array), reserved, 32 × u16.
    static func keyboardReport(_ s: Slots) -> [UInt8] { [1, 0, 0] + s.bytes }
}
