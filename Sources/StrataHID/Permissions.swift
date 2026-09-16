import Foundation
import IOKit
import IOKit.hid
import ApplicationServices

/// TCC state relevant to seizing keyboards. Both the GUI (to prompt) and the daemon (to decide) use this.
public struct PermissionState: Sendable, Equatable, Codable {
    public enum Access: String, Sendable, Codable { case granted, denied, unknown }
    public var inputMonitoring: Access
    public var accessibility: Bool

    public var allGranted: Bool { inputMonitoring == .granted && accessibility }
}

public enum Permissions {
    public static func check() -> PermissionState {
        let im: PermissionState.Access
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: im = .granted
        case kIOHIDAccessTypeDenied: im = .denied
        default: im = .unknown
        }
        return PermissionState(inputMonitoring: im, accessibility: AXIsProcessTrusted())
    }

    /// Show the system prompts (only works from a process with a GUI session).
    /// Input Monitoring is requested first: requesting Accessibility first suppresses the other prompt.
    @discardableResult
    public static func request() -> PermissionState {
        let before = check()
        if before.inputMonitoring != .granted { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
        if !before.accessibility {
            let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        return check()
    }

    public static let inputMonitoringSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
    public static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    public static let driverExtensionsSettingsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!

    /// Is the Karabiner DriverKit virtual HID driver loaded?
    public static func virtualHIDDriverActivated() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("org_pqrs_Karabiner_DriverKit_VirtualHIDDeviceRoot"))
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
    }
}
