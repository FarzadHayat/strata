import AppKit
import StrataCore
import SwiftUI

/// The menu bar app. Started from `StrataMain` via `GUIApp.main()`.
struct GUIApp: App {
    @NSApplicationDelegateAdaptor(GUIAppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        let model = AppModel()
        model.start()
        _model = State(initialValue: model)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Strata Editor", id: EditorWindow.sceneID) {
            EditorWindow(model: model)
        }
        .defaultSize(width: 980, height: 620)
        .windowResizability(.contentMinSize)
    }
}

extension Notification.Name {
    /// Posted to open the editor window from outside SwiftUI (launch flag `--editor`, or `open -a Strata` reopen).
    static let strataOpenEditor = Notification.Name("dev.farzadhayat.strata.openEditor")
}

/// Menu bar icon plus the active layer name when it is not the base layer.
/// Also the always-alive view that owns the `openWindow` action for external "open editor" requests.
struct MenuBarLabel: View {
    var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "keyboard")
            if let layer = model.topLayer {
                Text(layer)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .strataOpenEditor)) { _ in
            openWindow(id: EditorWindow.sceneID)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { WindowBringer.bringEditorFront() }
        }
    }
}

@MainActor
final class GUIAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock icon, no app menu, whether launched as Strata.app (LSUIElement) or bare.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let problems = KeyboardBlueprint.validate()
        if !problems.isEmpty {
            FileHandle.standardError.write(Data(("strata: keyboard blueprint problems:\n  " + problems.joined(separator: "\n  ") + "\n").utf8))
            assertionFailure("invalid keyboard blueprint")
        }
        if CommandLine.arguments.contains("--editor") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NotificationCenter.default.post(name: .strataOpenEditor, object: nil)
            }
        }
    }

    /// `open -a Strata` (or clicking the app in Finder) while running: show the editor.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: .strataOpenEditor, object: nil)
        return false
    }
}

/// Activates the app and raises the editor window (the `Window` scene must already have been opened).
enum WindowBringer {
    @MainActor
    static func bringEditorFront() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.identifier?.rawValue.hasPrefix(EditorWindow.sceneID) == true {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
