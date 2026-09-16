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

/// Menu bar icon plus the active layer name when it is not the base layer.
struct MenuBarLabel: View {
    var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "keyboard")
            if let layer = model.topLayer {
                Text(layer)
            }
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
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowBringer.bringEditorFront()
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
