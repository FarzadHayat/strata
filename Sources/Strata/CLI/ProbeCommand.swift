import Foundation
import StrataCore
import StrataHID

/// `strata probe` — the empirical spike tool. Runs as root. Seizes keyboards, passes every key through the
/// virtual keyboard unchanged, and logs what it sees so we can learn what the hardware/driver really do.
///
/// Options:
///   --observe          open devices without seizing (keys still reach macOS; we only log)
///   --top-case         additionally match the Apple vendor top-case node (usage page 0xFF00, usage 11)
///   --no-output        do not connect to the virtual keyboard (log only)
///   --send P:U         after startup, press+release usage page P usage U (hex) on the virtual keyboard, e.g. --send 0xFF:0x05
///   --timeout N        exit after N seconds (default 60; deadman so a broken run can't hold the keyboard)
///   --caps-toggle      toggle caps lock via IOHIDSystem once and report state
enum ProbeCommand {
    static func run(args: [String]) -> Int32 {
        var observe = false, topCase = false, noOutput = false, capsToggle = false, dumpElements = false, includeVirtual = false
        var timeout: TimeInterval = 60
        var sends: [HIDKey] = []
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--observe": observe = true
            case "--top-case": topCase = true
            case "--no-output": noOutput = true
            case "--caps-toggle": capsToggle = true
            case "--elements": dumpElements = true
            case "--include-virtual": includeVirtual = true
            case "--timeout": i += 1; timeout = TimeInterval(args[i]) ?? 60
            case "--send":
                i += 1
                let parts = args[i].split(separator: ":")
                if parts.count == 2, let p = UInt16(parts[0].replacingOccurrences(of: "0x", with: ""), radix: 16),
                   let u = UInt16(parts[1].replacingOccurrences(of: "0x", with: ""), radix: 16) {
                    sends.append(HIDKey(page: p, usage: u))
                } else if let k = KeyTable.key(named: args[i]) {
                    sends.append(k)
                } else { log("bad --send value \(args[i])"); return 2 }
            default: log("unknown option \(args[i])"); return 2
            }
            i += 1
        }

        log("strata probe — uid=\(getuid()) pid=\(getpid())")
        let perms = Permissions.check()
        log("permissions: inputMonitoring=\(perms.inputMonitoring.rawValue) accessibility=\(perms.accessibility)")
        log("virtual HID driver activated: \(Permissions.virtualHIDDriverActivated())")
        log("system fnState (F-keys standard): \(SystemPrefs.functionKeysStandard(forUser: SystemPrefs.consoleUser()) ?? false)")

        if capsToggle {
            let caps = CapsLockController()
            log("caps lock before: \(String(describing: caps.isOn))")
            log("toggle → \(String(describing: caps.toggle()))")
            Thread.sleep(forTimeInterval: 1)
            log("caps lock after: \(String(describing: caps.isOn)); toggling back → \(String(describing: caps.toggle()))")
        }

        let vhid: VHIDClient? = noOutput ? nil : VHIDClient { status in
            log("vhid status: connected=\(status.connected) activated=\(status.driverActivated) driverConnected=\(status.driverConnected) mismatch=\(status.driverVersionMismatched) keyboardReady=\(status.keyboardReady) err=\(status.lastError ?? "-")")
        }
        vhid?.start()

        var opts = HIDInput.Options()
        opts.seize = !observe
        if topCase { opts.extraUsagePairs = [(0xFF00, 11)] }
        opts.includeVirtual = includeVirtual
        let held = HeldSet()
        let passthrough = !observe
        let observeMode = observe
        let input = HIDInput(options: opts, onDevices: { devices in
            for d in devices {
                log("device \(d.id): '\(d.product)' by '\(d.manufacturer)' vid=\(d.vendorID) pid=\(d.productID) transport=\(d.transport) usage=\(d.usagePage):\(d.usage) seized=\(d.seized) \(d.error ?? "")")
            }
        }, onEvent: { event, dev in
            let name = KeyTable.canonicalName(for: event.key) ?? "?"
            log(String(format: "%@ page=0x%02X usage=0x%02X (%@) dev=%llu", event.isDown ? "DOWN" : "UP  ", event.key.page, event.key.usage, name, dev.id))
            if passthrough {
                if event.isDown { held.insert(event.key) } else { held.remove(event.key) }
                vhid?.set(event.key, down: event.isDown)
            }
        })
        input.start()

        if dumpElements {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                for d in input.deviceList where d.seized || observeMode {
                    var summary: [String: Int] = [:]
                    var interesting: [String] = []
                    for (page, usage, type) in input.elements(ofDevice: d.id) where type != "collection" {
                        summary["page 0x\(String(page, radix: 16)) \(type)", default: 0] += 1
                        if page != 0x07 || usage >= 0xE8 { interesting.append("0x\(String(page, radix: 16)):0x\(String(usage, radix: 16)) \(type)") }
                    }
                    log("elements of \(d.id) '\(d.product)' usage=\(d.usagePage):\(d.usage): \(summary.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))")
                    if !interesting.isEmpty { log("  non-keyboard-page elements: \(interesting.joined(separator: " "))") }
                }
            }
        }

        if !sends.isEmpty, let vhid {
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.5) {
                for k in sends {
                    log("sending \(k) (\(KeyTable.canonicalName(for: k) ?? "?")) down/up")
                    vhid.set(k, down: true)
                    Thread.sleep(forTimeInterval: 0.08)
                    vhid.set(k, down: false)
                    Thread.sleep(forTimeInterval: 0.4)
                }
            }
        }

        let stopper = DispatchWorkItem {
            log("timeout reached; releasing devices")
            input.stop()
            vhid?.releaseAll()
            vhid?.stop()
            exit(0)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stopper)
        signal(SIGINT) { _ in exit(0) }
        signal(SIGTERM) { _ in exit(0) }
        log("running for \(Int(timeout))s — press keys; Ctrl-C to stop")
        dispatchMain()
    }

    static func log(_ s: String) {
        let ts = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime, .withFractionalSeconds])
        FileHandle.standardError.write(("[\(ts)] " + s + "\n").data(using: .utf8)!)
    }
}

final class HeldSet: @unchecked Sendable {
    private var set = Set<HIDKey>()
    private let lock = NSLock()
    func insert(_ k: HIDKey) { lock.lock(); set.insert(k); lock.unlock() }
    func remove(_ k: HIDKey) { lock.lock(); set.remove(k); lock.unlock() }
    var all: Set<HIDKey> { lock.lock(); defer { lock.unlock() }; return set }
}
