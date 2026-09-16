import AppKit
import Observation
import SwiftUI

/// Borderless, non-activating HUD panel. Never takes key/main status so typing is unaffected.
final class VisualizerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the visualizer panel: shows/hides it from `VisualizerSettings`, keeps it snapped to the chosen
/// corner (or the user's dragged position), and turns the daemon's key stream on and off with it.
@MainActor
final class VisualizerController: NSObject, NSWindowDelegate {
    static let margin: CGFloat = 16

    private let model: AppModel
    private let settings: VisualizerSettings
    private var panel: VisualizerPanel?
    private var screenObserver: NSObjectProtocol?
    /// Suppresses `windowDidMove` while we position the panel ourselves.
    private var isProgrammaticMove = false

    init(model: AppModel) {
        self.model = model
        self.settings = model.visualizerSettings
        super.init()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        observeSettings()
    }

    /// Applies the persisted `enabled` state; `forceShow` (the `--visualizer` launch flag) turns it on first.
    func applyLaunchState(forceShow: Bool) {
        if forceShow, !settings.enabled { settings.enabled = true }
        apply()
    }

    // MARK: - Settings → panel

    private func observeSettings() {
        withObservationTracking {
            _ = settings.enabled
            _ = settings.corner
            _ = settings.clickThrough
            _ = settings.opacity
            _ = settings.width
            _ = settings.customFrame
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.apply()
                self.observeSettings()
            }
        }
    }

    private func apply() {
        if settings.enabled { show() } else { hide() }
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        panel.alphaValue = settings.opacity
        panel.ignoresMouseEvents = settings.clickThrough
        layout()
        if !panel.isVisible { panel.orderFrontRegardless() }
        model.setKeyStream(true)
    }

    private func hide() {
        panel?.orderOut(nil)
        model.setKeyStream(false)
    }

    private func makePanel() -> VisualizerPanel {
        let size = VisualizerView.size(forWidth: settings.width)
        let panel = VisualizerPanel(contentRect: CGRect(origin: .zero, size: size),
                                    styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView, .resizable],
                                    backing: .buffered, defer: false)
        panel.title = "Keyboard Visualizer"
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.minSize = VisualizerView.size(forWidth: VisualizerSettings.widthRange.lowerBound)
        panel.maxSize = VisualizerView.size(forWidth: VisualizerSettings.widthRange.upperBound)
        let hosting = NSHostingView(rootView: VisualizerView(model: model))
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.delegate = self
        self.panel = panel
        return panel
    }

    // MARK: - Positioning

    /// Sizes the panel for `settings.width` and places it at the dragged origin if that is still on a
    /// screen, otherwise snapped to `settings.corner` of the main screen.
    private func layout() {
        guard let panel else { return }
        let size = VisualizerView.size(forWidth: settings.width)
        var origin = cornerOrigin(for: size)
        if let custom = settings.customFrame {
            let candidate = CGRect(origin: custom.origin, size: size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(candidate) }) { origin = custom.origin }
        }
        let frame = CGRect(origin: origin, size: size)
        guard panel.frame != frame else { return }
        isProgrammaticMove = true
        panel.setFrame(frame, display: true)
        isProgrammaticMove = false
    }

    private func cornerOrigin(for size: CGSize) -> CGPoint {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return .zero }
        let area = screen.visibleFrame
        let m = Self.margin
        let x = settings.corner.isLeft ? area.minX + m : area.maxX - m - size.width
        let y = settings.corner.isTop ? area.maxY - m - size.height : area.minY + m
        return CGPoint(x: x, y: y)
    }

    // MARK: - NSWindowDelegate

    /// Keep the keyboard's aspect ratio while the user drags an edge.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        VisualizerView.size(forWidth: VisualizerSettings.widthRange.clamping(frameSize.width))
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let panel else { return }
        settings.width = VisualizerSettings.widthRange.clamping(panel.frame.width)
        if settings.customFrame != nil { settings.customFrame = panel.frame }
    }

    /// A drag by the user: remember the position instead of the corner.
    func windowDidMove(_ notification: Notification) {
        guard let panel, !isProgrammaticMove, !panel.inLiveResize else { return }
        if settings.customFrame != panel.frame { settings.customFrame = panel.frame }
    }
}
