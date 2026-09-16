import AppKit
import StrataHID
import SwiftUI

/// Shown as a sheet over the editor while permissions, the driver or the daemon are missing.
struct OnboardingView: View {
    var model: AppModel

    static let installCommand = "curl -fsSL https://raw.githubusercontent.com/FarzadHayat/strata/main/install.sh | bash"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Set up Strata", systemImage: "keyboard.badge.ellipsis").font(.title2.bold())
            Text("Strata needs its helper daemon, the Karabiner virtual keyboard driver and two privacy permissions before it can remap keys. Items below turn green as they are fixed.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            StatusChecklist(items: model.checklist)

            HStack {
                Button("Request permissions") { model.requestPermissions() }.buttonStyle(.borderedProminent)
                Button("Recheck") {
                    model.refreshPermissions()
                    model.requestStatus()
                }
            }

            Divider()
            Text("Steps").font(.headline)
            step(1) {
                Text("Run the installer in Terminal. It installs the daemon, the login item and the driver package:")
                HStack {
                    Text(Self.installCommand)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.installCommand, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("Copy command")
                }
            }
            step(2) {
                Text("Approve “Karabiner-DriverKit-VirtualHIDDevice” under System Settings › General › Login Items & Extensions › Driver Extensions.")
                Button("Open Driver Extensions") { NSWorkspace.shared.open(Permissions.driverExtensionsSettingsURL) }.controlSize(.small)
            }
            step(3) {
                Text("Enable Strata under System Settings › Privacy & Security › Input Monitoring and › Device Control and Data Access (Accessibility).")
                HStack {
                    Button("Input Monitoring") { NSWorkspace.shared.open(Permissions.inputMonitoringSettingsURL) }
                    Button("Device Control and Data Access") { NSWorkspace.shared.open(Permissions.accessibilitySettingsURL) }
                }
                .controlSize(.small)
            }

            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Continue anyway") { model.onboardingDismissed = true }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 580)
    }

    @ViewBuilder
    private func step<Content: View>(_ n: Int, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.callout.bold())
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))
            VStack(alignment: .leading, spacing: 6) { content() }
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
