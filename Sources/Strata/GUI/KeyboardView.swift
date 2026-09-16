import StrataCore
import SwiftUI

/// The visual keyboard: blueprint keys positioned in a fixed-aspect canvas, plus any `defsrc` keys the
/// blueprint does not draw.
struct KeyboardView: View {
    var model: AppModel
    /// Gap between caps, in key units.
    private let gap = 0.08

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geo in
                let unit = geo.size.width / KeyboardBlueprint.totalWidth
                let positions = model.sourcePositions
                ZStack(alignment: .topLeading) {
                    ForEach(KeyboardBlueprint.ansiMacBookPro) { key in
                        let hid = KeyboardBlueprint.keysByName[key.name]
                        let position = hid.flatMap { positions[$0] }
                        Button {
                            if let position { model.selectedPosition = position }
                        } label: {
                            KeyCapView(physicalLabel: hid.map { KeyTable.label(for: $0) } ?? key.name,
                                       display: position.flatMap { model.display(position: $0) },
                                       selected: position != nil && position == model.selectedPosition,
                                       unit: unit)
                        }
                        .buttonStyle(.plain)
                        .disabled(position == nil)
                        .frame(width: (key.w - gap) * unit, height: (key.h - gap) * unit)
                        .offset(x: (key.x + gap / 2) * unit, y: (key.y + gap / 2) * unit)
                        .help(position == nil ? "\(key.name) is not in defsrc" : key.name)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
            .aspectRatio(KeyboardBlueprint.totalWidth / KeyboardBlueprint.totalHeight, contentMode: .fit)
            OtherKeysRow(model: model)
        }
    }
}

/// One keycap: physical label top-left, effective action centred.
struct KeyCapView: View {
    let physicalLabel: String
    /// `nil` when the key is not in `defsrc` (drawn disabled).
    let display: KeyDisplay?
    let selected: Bool
    let unit: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: unit * 0.12).fill(fill)
            RoundedRectangle(cornerRadius: unit * 0.12)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: selected ? 2 : 1)
            Text(physicalLabel)
                .font(.system(size: max(7, unit * 0.17)))
                .foregroundStyle(.secondary)
                .padding(unit * 0.08)
                .lineLimit(1)
            if let display {
                Text(display.text)
                    .font(.system(size: max(8, unit * 0.26), weight: .medium))
                    .foregroundStyle(textColor(display.style))
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .padding(.horizontal, unit * 0.06)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .offset(y: unit * 0.07)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: unit * 0.12))
        .opacity(display == nil ? 0.35 : 1)
    }

    private var fill: Color {
        switch display?.style {
        case .bound?: return Color.accentColor.opacity(0.18)
        case .blocked?: return Color.red.opacity(0.10)
        default: return Color(nsColor: .controlBackgroundColor)
        }
    }

    private func textColor(_ style: KeyDisplay.Style) -> Color {
        switch style {
        case .bound: return .primary
        case .inherited, .blocked: return .secondary
        case .hardware: return Color(nsColor: .tertiaryLabelColor)
        }
    }
}

/// `defsrc` keys that have no place on the blueprint (keypad, media keys, duplicates, unknown names).
struct OtherKeysRow: View {
    var model: AppModel
    private let unit: CGFloat = 40

    var body: some View {
        let extras = model.extraSourceKeys
        if !extras.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Other keys in defsrc").font(.caption).foregroundStyle(.secondary)
                FlowLayout(spacing: 4) {
                    ForEach(extras, id: \.position) { extra in
                        Button {
                            model.selectedPosition = extra.position
                        } label: {
                            KeyCapView(physicalLabel: extra.key.map { KeyTable.label(for: $0) } ?? extra.name,
                                       display: model.display(position: extra.position),
                                       selected: model.selectedPosition == extra.position,
                                       unit: unit)
                        }
                        .buttonStyle(.plain)
                        .frame(width: unit * 1.3, height: unit * 0.92)
                        .help(extra.key == nil ? "\(extra.name): unknown key name" : extra.name)
                    }
                }
            }
        }
    }
}

extension AppModel {
    /// What `position` shows on the selected layer.
    func display(position: Int) -> KeyDisplay? {
        guard let document, !layerNames.isEmpty else { return nil }
        let keys = sourceKeys
        return ActionPretty.effective(document: document, layerNames: layerNames, layerIndex: selectedLayerIndex,
                                      position: position, sourceKey: position < keys.count ? keys[position] : nil,
                                      functionRow: functionRowMode)
    }

    /// `defsrc` entries not reachable through the blueprint.
    var extraSourceKeys: [(position: Int, name: String, key: HIDKey?)] {
        guard let document else { return [] }
        let blueprint = Set(KeyboardBlueprint.keysByName.values)
        let positions = sourcePositions
        return document.sourceKeys.enumerated().compactMap { i, entry in
            let key = KeyNames.key(named: entry.name)
            if let key, blueprint.contains(key), positions[key] == i { return nil }
            return (i, entry.name, key)
        }
    }
}

/// Wraps subviews onto as many rows as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: width.isFinite ? width : maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > bounds.width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
