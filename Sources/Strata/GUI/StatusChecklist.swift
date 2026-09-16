import AppKit
import StrataHID
import SwiftUI

/// One line of the readiness checklist shared by the menu bar panel and the onboarding sheet.
struct ChecklistItem: Identifiable {
    enum State { case ok, bad, unknown }
    struct Fix {
        let title: String
        let action: @MainActor () -> Void
    }

    let id: String
    let title: String
    let state: State
    var detail: String? = nil
    var help: String? = nil
    var fix: Fix? = nil
}

struct ChecklistRow: View {
    let item: ChecklistItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                if let detail = item.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            if let fix = item.fix, item.state != .ok {
                Button(fix.title) { fix.action() }.controlSize(.small)
            }
        }
        .help(item.help ?? item.title)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch item.state {
        case .ok: return .green
        case .bad: return .red
        case .unknown: return .gray
        }
    }
}

struct StatusChecklist: View {
    let items: [ChecklistItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { ChecklistRow(item: $0) }
        }
    }
}

extension AppModel {
    /// The readiness checklist in display order.
    var checklist: [ChecklistItem] {
        var items: [ChecklistItem] = []

        let im: ChecklistItem.State
        switch permissions.inputMonitoring {
        case .granted: im = .ok
        case .denied: im = .bad
        case .unknown: im = .unknown
        }
        items.append(ChecklistItem(
            id: "input-monitoring", title: "Input Monitoring", state: im,
            detail: im == .ok ? nil : "Needed to read the keyboards Strata takes over.",
            help: "System Settings › Privacy & Security › Input Monitoring",
            fix: .init(title: "Open Settings") { NSWorkspace.shared.open(Permissions.inputMonitoringSettingsURL) }))

        items.append(ChecklistItem(
            id: "accessibility", title: "Accessibility", state: permissions.accessibility ? .ok : .bad,
            detail: permissions.accessibility ? nil : "Needed to post keys through the virtual keyboard.",
            help: "On macOS 27 this pane is called “Device Control and Data Access” (System Settings › Privacy & Security). Enable Strata there.",
            fix: .init(title: "Open Settings") { NSWorkspace.shared.open(Permissions.accessibilitySettingsURL) }))

        let driver = driverActivated || status?.driverActivated == true
        items.append(ChecklistItem(
            id: "driver", title: "Virtual HID driver", state: driver ? .ok : .bad,
            detail: driver ? nil : "Install the Karabiner-DriverKit-VirtualHIDDevice pkg (the installer does this), then approve it under Login Items & Extensions › Driver Extensions.",
            help: "System Settings › General › Login Items & Extensions › Driver Extensions",
            fix: .init(title: "Driver Extensions") { NSWorkspace.shared.open(Permissions.driverExtensionsSettingsURL) }))

        items.append(ChecklistItem(
            id: "daemon", title: "Daemon connected", state: connected ? .ok : .bad,
            detail: connected
                ? status.map { "PID \($0.daemonPID), version \($0.version)" }
                : "The Strata daemon is not running. Run the installer to set up the LaunchDaemon.",
            help: "The root daemon does the remapping; the GUI only talks to it."))

        let vhid: ChecklistItem.State = status.map { $0.vhidReady ? .ok : .bad } ?? .unknown
        items.append(ChecklistItem(
            id: "vhid", title: "Virtual keyboard ready", state: vhid,
            detail: status?.vhidError ?? (connected ? nil : "Unknown until the daemon connects."),
            help: "Connection from the daemon to the Karabiner virtual keyboard."))

        let devices = status?.devices ?? []
        let seized = devices.filter(\.seized)
        let seizedState: ChecklistItem.State = !connected ? .unknown : (seized.isEmpty ? (devices.isEmpty ? .unknown : .bad) : .ok)
        let names = seized.isEmpty ? devices : seized
        items.append(ChecklistItem(
            id: "devices", title: seized.isEmpty ? "Keyboards seized" : "Keyboards seized (\(seized.count))", state: seizedState,
            detail: names.isEmpty ? (connected ? "No keyboards found." : nil)
                : names.map { $0.name + ($0.seized ? "" : " (not seized" + ($0.note.map { ": " + $0 } ?? "") + ")") }.joined(separator: ", "),
            help: "Physical keyboards the daemon has taken exclusive control of."))
        return items
    }
}
