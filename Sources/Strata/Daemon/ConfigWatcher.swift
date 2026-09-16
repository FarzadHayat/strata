import Foundation
import CoreServices
import CryptoKit

/// Watches the config file's *directory* with FSEvents (robust against editors that save via rename),
/// debounces bursts, and only reports when the file content hash actually changed.
final class ConfigWatcher: @unchecked Sendable {
    private let path: String
    private let queue = DispatchQueue(label: "dev.farzadhayat.strata.configwatch")
    private var stream: FSEventStreamRef?
    private var debounce: DispatchWorkItem?
    private var lastHash: Data?
    private let onChange: @Sendable (String) -> Void

    init(path: String, onChange: @escaping @Sendable (String) -> Void) {
        self.path = path
        self.onChange = onChange
    }

    /// Reads the file now and starts watching. Returns the initial text (nil if unreadable).
    func start() -> String? {
        let dir = (path as NSString).deletingLastPathComponent
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            let me = Unmanaged<ConfigWatcher>.fromOpaque(info!).takeUnretainedValue()
            me.scheduleCheck()
        }
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &ctx, [dir] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags) else { return readIfChanged(force: true) }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
        return queue.sync { readIfChanged(force: true) }
    }

    func stop() {
        queue.sync {
            if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s); stream = nil }
        }
    }

    /// Force a re-read (e.g. GUI asked for reload).
    func reload() { queue.async { if let t = self.readIfChanged(force: true) { self.onChange(t) } } }

    /// Called after our own writes so the next event for identical content is ignored.
    func noteWritten(text: String) { queue.async { self.lastHash = Data(SHA256.hash(data: Data(text.utf8))) } }

    private func scheduleCheck() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if let t = self.readIfChanged(force: false) { self.onChange(t) }
        }
        debounce = work
        queue.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func readIfChanged(force: Bool) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let hash = Data(SHA256.hash(data: data))
        if !force && hash == lastHash { return nil }
        lastHash = hash
        return String(decoding: data, as: UTF8.self)
    }
}
