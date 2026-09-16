import Foundation
import IOKit
import IOKit.hid
import StrataCore

/// Description of a keyboard we found (seized or skipped).
public struct HIDDeviceInfo: Sendable, Equatable, Identifiable {
    public var id: UInt64
    public var product: String
    public var manufacturer: String
    public var vendorID: Int
    public var productID: Int
    public var transport: String
    public var usagePage: Int
    public var usage: Int
    public var seized: Bool
    public var error: String?
}

/// Seizes physical keyboards with IOKit and reports raw HID transitions.
///
/// Runs its own thread with a CFRunLoop (required for IOKit notifications). Devices are matched with
/// `IOServiceAddMatchingNotification` so hot-plug and wake re-enumeration are handled; each device is
/// opened with `kIOHIDOptionsTypeSeizeDevice` so macOS no longer sees its events directly.
public final class HIDInput: @unchecked Sendable {
    public struct Options: Sendable {
        /// Additional (usagePage, usage) pairs to match besides the keyboard {1,6}.
        public var extraUsagePairs: [(Int, Int)] = []
        /// Product-name substrings to skip (case-insensitive).
        public var excludeProducts: [String] = []
        /// When false, devices are opened without seizing (observe only) — used by the probe.
        public var seize = true
        /// Probe only: also open (never seize) Karabiner's virtual keyboard to watch what macOS receives.
        public var includeVirtual = false
        public init() {}
    }

    public typealias EventHandler = @Sendable (KeyEvent, HIDDeviceInfo) -> Void
    public typealias DeviceHandler = @Sendable ([HIDDeviceInfo]) -> Void

    private let options: Options
    private let onEvent: EventHandler
    private let onDevices: DeviceHandler
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var notifyPort: IONotificationPortRef?
    private var matchedIterator: io_iterator_t = 0
    private var terminatedIterator: io_iterator_t = 0
    private var devices: [UInt64: IOHIDDevice] = [:]
    private var infos: [UInt64: HIDDeviceInfo] = [:]
    private let lock = NSLock()
    private let startTime = ProcessInfo.processInfo.systemUptime

    public init(options: Options = Options(), onDevices: @escaping DeviceHandler, onEvent: @escaping EventHandler) {
        self.options = options
        self.onEvent = onEvent
        self.onDevices = onDevices
    }

    /// (usagePage, usage, isInput) of every element a device exposes — used by `strata probe --elements`.
    public func elements(ofDevice id: UInt64) -> [(Int, Int, String)] {
        lock.lock(); let device = devices[id]; lock.unlock()
        guard let device, let list = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else { return [] }
        var out: [(Int, Int, String)] = []
        for e in list {
            let type: String
            switch IOHIDElementGetType(e) {
            case kIOHIDElementTypeInput_Button: type = "in-button"
            case kIOHIDElementTypeInput_Misc: type = "in-misc"
            case kIOHIDElementTypeInput_Axis: type = "in-axis"
            case kIOHIDElementTypeOutput: type = "out"
            case kIOHIDElementTypeFeature: type = "feature"
            case kIOHIDElementTypeCollection: type = "collection"
            default: type = "other"
            }
            out.append((Int(IOHIDElementGetUsagePage(e)), Int(IOHIDElementGetUsage(e)), type))
        }
        return out
    }

    public var deviceList: [HIDDeviceInfo] { lock.lock(); defer { lock.unlock() }; return Array(infos.values).sorted { $0.id < $1.id } }

    public func start() {
        let t = Thread { [weak self] in self?.threadMain() }
        t.name = "dev.farzadhayat.strata.hid"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    /// Release every device (keys go back to macOS) and stop the run loop.
    public func stop() {
        guard let rl = runLoop else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue) { [self] in
            self.closeAll()
            CFRunLoopStop(rl)
        }
        CFRunLoopWakeUp(rl)
    }

    /// Close and re-open every known device (e.g. after wake).
    public func reseize() {
        guard let rl = runLoop else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue) { [self] in
            let ids = Array(self.devices.keys)
            for id in ids { self.close(id: id) }
            self.drain(iterator: self.matchedIterator, matched: true)
        }
        CFRunLoopWakeUp(rl)
    }

    // MARK: - Run loop thread

    private func threadMain() {
        runLoop = CFRunLoopGetCurrent()
        let port = IONotificationPortCreate(kIOMainPortDefault)!
        notifyPort = port
        let source = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(runLoop, source, .defaultMode)

        var pairs: [[String: Int]] = [[kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 6]]
        for (p, u) in options.extraUsagePairs { pairs.append([kIOHIDDeviceUsagePageKey: p, kIOHIDDeviceUsageKey: u]) }
        let matching = IOServiceMatching(kIOHIDDeviceKey)! as NSMutableDictionary
        matching[kIOHIDDeviceUsagePairsKey] = pairs

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let matchedCB: IOServiceMatchingCallback = { refcon, iterator in
            let me = Unmanaged<HIDInput>.fromOpaque(refcon!).takeUnretainedValue()
            me.drain(iterator: iterator, matched: true)
        }
        let terminatedCB: IOServiceMatchingCallback = { refcon, iterator in
            let me = Unmanaged<HIDInput>.fromOpaque(refcon!).takeUnretainedValue()
            me.drain(iterator: iterator, matched: false)
        }
        // IOServiceAddMatchingNotification consumes one reference to the matching dictionary per call.
        IOServiceAddMatchingNotification(port, kIOMatchedNotification, matching.copy() as! CFDictionary, matchedCB, selfPtr, &matchedIterator)
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, matching.copy() as! CFDictionary, terminatedCB, selfPtr, &terminatedIterator)
        drain(iterator: matchedIterator, matched: true)
        drain(iterator: terminatedIterator, matched: false)

        CFRunLoopRun()
        IONotificationPortDestroy(port)
    }

    private func drain(iterator: io_iterator_t, matched: Bool) {
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &entryID)
            if matched { open(service: service, id: entryID) } else { close(id: entryID) }
            IOObjectRelease(service)
        }
        onDevices(deviceList)
    }

    private func open(service: io_service_t, id: UInt64) {
        guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, service) else { return }
        func str(_ key: String) -> String {
            (IOHIDDeviceGetProperty(device, key as CFString) as? String)?.split(separator: "\0").first.map(String.init) ?? ""
        }
        func int(_ key: String) -> Int { (IOHIDDeviceGetProperty(device, key as CFString) as? Int) ?? 0 }
        var info = HIDDeviceInfo(id: id, product: str(kIOHIDProductKey), manufacturer: str(kIOHIDManufacturerKey),
                                 vendorID: int(kIOHIDVendorIDKey), productID: int(kIOHIDProductIDKey),
                                 transport: str(kIOHIDTransportKey), usagePage: int(kIOHIDPrimaryUsagePageKey),
                                 usage: int(kIOHIDPrimaryUsageKey), seized: false, error: nil)
        let lowerProduct = info.product.lowercased()
        let isVirtual = info.manufacturer == "pqrs.org" && info.product.hasPrefix("Karabiner DriverKit VirtualHID")
        if isVirtual && !options.includeVirtual {
            info.error = "skipped: own virtual device"
        } else if lowerProduct.contains("sidecar") {
            info.error = "skipped: sidecar virtual keyboard"
        } else if options.excludeProducts.contains(where: { lowerProduct.contains($0.lowercased()) }) {
            info.error = "skipped: excluded by config"
        } else if info.usagePage == 1 && info.usage == 2 {
            info.error = "skipped: pointing device"
        }
        if info.error != nil {
            lock.lock(); infos[id] = info; lock.unlock()
            return
        }

        let opts = (options.seize && !isVirtual) ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice) : IOOptionBits(kIOHIDOptionsTypeNone)
        let kr = IOHIDDeviceOpen(device, opts)
        guard kr == kIOReturnSuccess else {
            info.error = Self.describe(kr)
            lock.lock(); infos[id] = info; lock.unlock()
            return
        }
        info.seized = options.seize && !isVirtual
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputValueCallback(device, { refcon, _, _, value in
            let me = Unmanaged<HIDInput>.fromOpaque(refcon!).takeUnretainedValue()
            me.handle(value: value)
        }, ctx)
        IOHIDDeviceScheduleWithRunLoop(device, runLoop!, CFRunLoopMode.defaultMode.rawValue)
        lock.lock()
        devices[id] = device
        infos[id] = info
        lock.unlock()
    }

    private func close(id: UInt64) {
        lock.lock()
        let device = devices.removeValue(forKey: id)
        infos.removeValue(forKey: id)
        lock.unlock()
        guard let device else { return }
        IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(device, runLoop!, CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
    }

    private func closeAll() {
        for id in Array(devices.keys) { close(id: id) }
        onDevices(deviceList)
    }

    private func handle(value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        // Keyboard page: 0x00–0x03 are "no event"/rollover/POST fail; ignore reserved range.
        if page == 0x07 && (usage <= 0x03 || usage >= 0xFFFF) { return }
        if page == 0x0C && usage == 0 { return }
        if IOHIDValueGetLength(value) > 8 { return }
        let pressed = IOHIDValueGetIntegerValue(value) != 0
        let key = HIDKey(page: UInt16(truncatingIfNeeded: page), usage: UInt16(truncatingIfNeeded: usage))
        let device = IOHIDElementGetDevice(element)
        var devID: UInt64 = 0
        lock.lock()
        if let (id, _) = devices.first(where: { $0.value == device }) { devID = id }
        let info = infos[devID]
        lock.unlock()
        let now = ProcessInfo.processInfo.systemUptime
        let event = KeyEvent(key: key, isDown: pressed, time: now, device: devID)
        onEvent(event, info ?? HIDDeviceInfo(id: devID, product: "?", manufacturer: "", vendorID: 0, productID: 0, transport: "", usagePage: 0, usage: 0, seized: true, error: nil))
    }

    public static func describe(_ kr: IOReturn) -> String {
        switch UInt32(bitPattern: kr) {
        case 0xE00002C5: return "exclusive access: another program (kmonad/Karabiner?) has seized this keyboard"
        case 0xE00002E2: return "not permitted: grant Input Monitoring and Accessibility (Device Control) to Strata"
        case 0xE00002C7: return "unsupported"
        default: return "IOHIDDeviceOpen failed: 0x" + String(UInt32(bitPattern: kr), radix: 16)
        }
    }
}
