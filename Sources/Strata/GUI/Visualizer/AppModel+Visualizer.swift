import Foundation
import StrataCore
import StrataIPC

/// One entry of the visualizer's "recently pressed" strip.
struct RecentKey: Identifiable, Equatable {
    let id: UUID
    /// What the key did on the layer stack at press time (falls back to the physical label).
    let label: String
    let at: Date
}

/// Live key stream for the visualizer: subscription, pressed-key tracking and the active-stack display.
extension AppModel {
    /// A key still "down" this long is assumed to have lost its up-event and is cleared.
    static let stuckKeyTimeout: TimeInterval = 10
    static let recentKeyLifetime: TimeInterval = 4
    static let recentKeyLimit = 6

    /// Asks the daemon to stream key transitions (re-sent automatically on every reconnect while on).
    func setKeyStream(_ on: Bool) {
        guard keyStreamEnabled != on else { return }
        keyStreamEnabled = on
        if connected { client?.send(.subscribeKeys(on)) }
        if on {
            startKeySweep()
        } else {
            keySweepTask?.cancel()
            keySweepTask = nil
            clearPressedKeys()
        }
    }

    /// Handles an `IPC.Event.key`.
    func keyEvent(name: String, down: Bool, position: Int?) {
        if down {
            let label = position.flatMap { activeDisplay(position: $0)?.text } ?? ActionPretty.keyLabel(name)
            recentKeys.append(RecentKey(id: UUID(), label: label, at: .now))
            if recentKeys.count > Self.recentKeyLimit { recentKeys.removeFirst(recentKeys.count - Self.recentKeyLimit) }
        }
        guard let position else { return }
        if down {
            pressedPositions.insert(position)
            pressedAt[position] = .now
        } else {
            pressedPositions.remove(position)
            pressedAt[position] = nil
        }
    }

    func clearPressedKeys() {
        if !pressedPositions.isEmpty { pressedPositions = [] }
        pressedAt = [:]
        if !recentKeys.isEmpty { recentKeys = [] }
    }

    private func startKeySweep() {
        keySweepTask?.cancel()
        keySweepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                self.sweepKeys()
            }
        }
    }

    /// Drops stuck keys and faded-out recent entries.
    private func sweepKeys() {
        let now = Date.now
        for (position, at) in pressedAt where now.timeIntervalSince(at) > Self.stuckKeyTimeout {
            pressedAt[position] = nil
            pressedPositions.remove(position)
        }
        if recentKeys.contains(where: { now.timeIntervalSince($0.at) > Self.recentKeyLifetime }) {
            recentKeys.removeAll { now.timeIntervalSince($0.at) > Self.recentKeyLifetime }
        }
    }

    // MARK: - Active-stack display

    /// The layer stack to render: the daemon's (top = last), or just the base layer when it is unknown.
    var displayStack: [String] {
        if !activeLayers.isEmpty { return activeLayers }
        return baseLayer.map { [$0] } ?? []
    }

    /// What `position` does right now, resolved like the daemon does: top of the active stack first, through
    /// transparent entries down to the base layer, then the hardware default.
    func activeDisplay(position: Int) -> KeyDisplay? {
        guard let document, !layerNames.isEmpty else { return nil }
        let stack = displayStack
        for (index, layer) in stack.enumerated().reversed() {
            let tokens = document.actionTexts(layer: layer) ?? []
            let token = position < tokens.count ? tokens[position] : "_"
            guard !ActionPretty.isTransparent(token, document: document) else { continue }
            let text = ActionPretty.pretty(text: token, document: document)
            let style: KeyDisplay.Style = text == ActionPretty.blockedGlyph ? .blocked : (index == stack.count - 1 ? .bound : .inherited)
            return KeyDisplay(text: text, style: style)
        }
        let keys = sourceKeys
        guard position < keys.count, let sourceKey = keys[position] else { return KeyDisplay(text: "?", style: .hardware) }
        return KeyDisplay(text: ActionPretty.hardwareLabel(sourceKey: sourceKey, functionRow: functionRowMode), style: .hardware)
    }
}
