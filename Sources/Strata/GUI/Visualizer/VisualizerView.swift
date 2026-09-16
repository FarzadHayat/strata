import StrataCore
import SwiftUI

/// Content of the floating visualizer panel: layer badge, the live keyboard, and a strip of recent keys.
struct VisualizerView: View {
    var model: AppModel

    static let padding: CGFloat = 10
    static let headerHeight: CGFloat = 20
    static let stripHeight: CGFloat = 14
    static let spacing: CGFloat = 6
    static let cornerRadius: CGFloat = 14

    /// Panel size for a given width (the keyboard keeps the blueprint's aspect ratio).
    static func size(forWidth width: CGFloat) -> CGSize {
        let keyboardWidth = width - padding * 2
        let keyboardHeight = keyboardWidth * KeyboardBlueprint.totalHeight / KeyboardBlueprint.totalWidth
        return CGSize(width: width, height: padding * 2 + headerHeight + spacing * 2 + keyboardHeight + stripHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            header.frame(height: Self.headerHeight)
            VisualizerKeyboard(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            RecentKeysStrip(keys: model.recentKeys).frame(height: Self.stripHeight)
        }
        .padding(Self.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack {
            LayerBadge(text: badgeText, offline: !model.connected)
            Spacer()
        }
    }

    private var badgeText: String {
        guard model.connected else { return "daemon offline" }
        return model.topLayer ?? model.baseLayer ?? "base"
    }
}

/// Layer name pill that pulses briefly whenever the name changes.
struct LayerBadge: View {
    let text: String
    let offline: Bool
    @State private var pulse = false

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(offline ? Color.secondary : Color.primary)
            .background(Capsule().fill(offline ? Color.primary.opacity(0.08) : Color.accentColor.opacity(pulse ? 0.5 : 0.25)))
            .scaleEffect(pulse ? 1.1 : 1, anchor: .leading)
            .onChange(of: text) {
                withAnimation(.easeOut(duration: 0.15)) { pulse = true }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(220))
                    withAnimation(.easeInOut(duration: 0.3)) { pulse = false }
                }
            }
    }
}

/// The blueprint keyboard showing the effective binding for the active layer stack, with held keys lit.
struct VisualizerKeyboard: View {
    var model: AppModel
    private let gap = 0.08

    var body: some View {
        GeometryReader { geo in
            let unit = geo.size.width / KeyboardBlueprint.totalWidth
            let positions = model.sourcePositions
            let pressed = model.pressedPositions
            ZStack(alignment: .topLeading) {
                ForEach(KeyboardBlueprint.ansiMacBookPro) { key in
                    let hid = KeyboardBlueprint.keysByName[key.name]
                    let position = hid.flatMap { positions[$0] }
                    VisualizerKeyCap(display: position.flatMap { model.activeDisplay(position: $0) },
                                     fallback: hid.map { KeyTable.label(for: $0) } ?? key.name,
                                     pressed: position.map { pressed.contains($0) } ?? false,
                                     unit: unit)
                        .frame(width: (key.w - gap) * unit, height: (key.h - gap) * unit)
                        .offset(x: (key.x + gap / 2) * unit, y: (key.y + gap / 2) * unit)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .aspectRatio(KeyboardBlueprint.totalWidth / KeyboardBlueprint.totalHeight, contentMode: .fit)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keyboard visualizer")
    }
}

/// Compact keycap: one centred label, lit while pressed.
struct VisualizerKeyCap: View {
    /// `nil` when the key is not in `defsrc`.
    let display: KeyDisplay?
    let fallback: String
    let pressed: Bool
    let unit: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: unit * 0.14, style: .continuous)
        ZStack {
            shape.fill(fill)
            shape.strokeBorder(pressed ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: pressed ? 1.5 : 0.5)
            Text(display?.text ?? fallback)
                .font(.system(size: max(6, unit * 0.34), weight: pressed ? .semibold : .medium))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .padding(.horizontal, unit * 0.06)
        }
        .opacity(display == nil ? 0.3 : 1)
        .scaleEffect(pressed ? 1.1 : 1)
        .animation(.easeOut(duration: 0.08), value: pressed)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(display?.text ?? fallback))
        .accessibilityAddTraits(pressed ? .isSelected : [])
    }

    private var fill: Color {
        if pressed { return Color.accentColor.opacity(0.85) }
        switch display?.style {
        case .bound?: return Color.accentColor.opacity(0.28)
        case .blocked?: return Color.red.opacity(0.12)
        default: return Color.primary.opacity(0.07)
        }
    }

    private var textColor: Color {
        if pressed { return .white }
        switch display?.style {
        case .bound?: return .primary
        case .inherited?, .blocked?, nil: return .secondary
        case .hardware?: return Color(nsColor: .tertiaryLabelColor)
        }
    }
}

/// The last few pressed keys, newest on the right, older ones fading.
struct RecentKeysStrip: View {
    let keys: [RecentKey]

    var body: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            ForEach(Array(keys.enumerated()), id: \.element.id) { index, key in
                Text(key.label)
                    .font(.caption2.monospaced())
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .opacity(0.3 + 0.7 * Double(index + 1) / Double(max(keys.count, 1)))
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: keys.map(\.id))
        .accessibilityHidden(true)
    }
}
