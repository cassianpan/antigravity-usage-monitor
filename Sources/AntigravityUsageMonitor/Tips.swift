import SwiftUI

// MARK: - 1:1 Ported Tip System from claude-usage-monitor (Zero @State macro)

struct Tip: Equatable {
    var title: String?
    var rows: [Row] = []
    var note: String?

    struct Row: Equatable {
        var label: String
        var value: String
        var color: Color?
        var dot: Color?
        var separated = false

        init(_ label: String, _ value: String, color: Color? = nil, dot: Color? = nil, separated: Bool = false) {
            self.label = label
            self.value = value
            self.color = color
            self.dot = dot
            self.separated = separated
        }
    }

    init(title: String? = nil, rows: [Row] = [], note: String? = nil) {
        self.title = title
        self.rows = rows
        self.note = note
    }

    init(_ note: String) {
        self.note = note
    }

    var isEmpty: Bool {
        title == nil && rows.isEmpty && (note?.isEmpty ?? true)
    }
}

@MainActor
@Observable
final class TipCenter {
    private(set) var shown: String?
    @ObservationIgnored private var hovered: String?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var hiddenAt = Date.distantPast
    @ObservationIgnored private var active = false

    private static let delay = Duration.milliseconds(180)
    private static let warm: TimeInterval = 0.6

    func setActive(_ active: Bool) {
        self.active = active
        reset()
    }

    func enter(_ id: String) {
        guard active else { return }
        hovered = id
        pending?.cancel()
        pending = nil
        guard shown != id else { return }
        if shown != nil || Date().timeIntervalSince(hiddenAt) < Self.warm {
            show(id)
            return
        }
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled else { return }
            self?.show(id)
        }
    }

    func exit(_ id: String) {
        guard hovered == id else { return }
        hovered = nil
        pending?.cancel()
        pending = nil
        if shown == id {
            hide()
        }
    }

    private func reset() {
        hovered = nil
        pending?.cancel()
        pending = nil
        if shown != nil { shown = nil }
        hiddenAt = .distantPast
    }

    private func show(_ id: String) {
        guard active, hovered == id else { return }
        withAnimation(.easeOut(duration: 0.12)) {
            shown = id
        }
    }

    private func hide() {
        withAnimation(.easeOut(duration: 0.10)) {
            shown = nil
        }
        hiddenAt = Date()
    }
}

enum TipHorizontalAlignment {
    case leading
    case center
    case trailing
}

struct TipPlacement {
    let id: String
    let tip: Tip
    let anchor: Anchor<CGRect>
    let alignment: TipHorizontalAlignment
}

struct TipAnchorKey: PreferenceKey {
    static let defaultValue: TipPlacement? = nil
    static func reduce(value: inout TipPlacement?, nextValue: () -> TipPlacement?) {
        if let next = nextValue() {
            value = next
        }
    }
}

private struct TipTargetModifier: ViewModifier {
    let id: String
    let center: TipCenter
    let alignment: TipHorizontalAlignment
    let make: () -> Tip?

    func body(content: Content) -> some View {
        let isShown = center.shown == id
        content
            .onHover { inside in
                if inside {
                    center.enter(id)
                } else {
                    center.exit(id)
                }
            }
            .anchorPreference(key: TipAnchorKey.self, value: .bounds) { anchor in
                guard isShown, let tip = make(), !tip.isEmpty else { return nil }
                return TipPlacement(id: id, tip: tip, anchor: anchor, alignment: alignment)
            }
    }
}

extension View {
    func panelTip(
        _ id: String,
        center: TipCenter,
        alignment: TipHorizontalAlignment = .center,
        _ make: @escaping () -> Tip?
    ) -> some View {
        modifier(TipTargetModifier(id: id, center: center, alignment: alignment, make: make))
    }

    func panelTipOverlay(center: TipCenter) -> some View {
        overlayPreferenceValue(TipAnchorKey.self) { placement in
            GeometryReader { proxy in
                if let placement {
                    let targetRect = proxy[placement.anchor]
                    TipBubbleLayout(target: targetRect, alignment: placement.alignment) {
                        TipBubble(tip: placement.tip)
                            .allowsHitTesting(false)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

private struct TipBubbleLayout: Layout {
    let target: CGRect
    let alignment: TipHorizontalAlignment
    private static let gap: CGFloat = 7
    private static let margin: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let bubble = subviews.first else { return }
        let maxW = max(120, bounds.width - Self.margin * 2)
        let idealSize = bubble.sizeThatFits(.unspecified)
        let width = min(idealSize.width, maxW)
        let size = idealSize.width > maxW
            ? bubble.sizeThatFits(ProposedViewSize(width: maxW, height: nil))
            : idealSize
        let height = size.height

        // Prefer placing above target; flip below if insufficient space.
        let aboveY = bounds.minY + target.minY - Self.gap - height
        let y = aboveY >= bounds.minY + Self.margin
            ? aboveY
            : min(bounds.maxY - Self.margin - height, bounds.minY + target.maxY + Self.gap)

        let idealX: CGFloat
        switch alignment {
        case .leading:
            idealX = bounds.minX + target.minX
        case .center:
            idealX = bounds.minX + target.midX - width / 2.0
        case .trailing:
            idealX = bounds.minX + target.maxX - width
        }
        let x = max(bounds.minX + Self.margin, min(bounds.maxX - Self.margin - width, idealX))

        bubble.place(
            at: CGPoint(x: x.rounded(), y: y.rounded()),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: width, height: height)
        )
    }
}

private struct TipBubble: View {
    let tip: Tip

    var body: some View {
        let lone = tip.title == nil && tip.rows.isEmpty
        VStack(alignment: .leading, spacing: 5) {
            if let title = tip.title {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !tip.rows.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(tip.rows.indices, id: \.self) { i in
                        rowView(tip.rows[i])
                            .padding(.top, i > 0 && tip.rows[i].separated ? 4 : 0)
                    }
                }
            }
            if let note = tip.note, !note.isEmpty {
                Text(note)
                    .font(.system(size: lone ? 11 : 10.5))
                    .foregroundStyle(lone ? Palette.text : Palette.secondary)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .monospacedDigit()
        .padding(.horizontal, 10)
        .padding(.vertical, 6.5)
        .background {
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            shape
                .fill(Color(white: 0.11).opacity(0.97))
                .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 3)
            shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        }
    }

    private func rowView(_ row: Tip.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            HStack(spacing: 5) {
                if let dot = row.dot {
                    Circle()
                        .fill(dot)
                        .frame(width: 5, height: 5)
                }
                Text(row.label)
            }
            .foregroundStyle(Palette.secondary)
            .lineLimit(1)
            .fixedSize()
            Spacer(minLength: 14)
            Text(row.value)
                .foregroundStyle(row.color ?? Palette.text)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
    }
}

// MARK: - Interactive Controls (Zero @State macro)

@MainActor
@Observable
final class PanelInteractionState {
    var hoveredFooterId: String? = nil
    var hoveredBucketId: String? = nil
    var hoveredBarIndex: Int? = nil
    var hoveredTab: SpendWindowTab? = nil
    var isLoginButtonHovered: Bool = false
    var showSpeedDotChart: Bool = false
    var hoveredSparkSampleIndex: Int? = nil
    var hoveredDotSampleId: Int? = nil
    var refreshSpinDegrees: Double = 0

    func triggerRefreshSpin() {
        withAnimation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.55)) {
            refreshSpinDegrees += 360
        }
    }

    func resetHovers() {
        hoveredFooterId = nil
        hoveredBucketId = nil
        hoveredBarIndex = nil
        hoveredTab = nil
        isLoginButtonHovered = false
        hoveredSparkSampleIndex = nil
        hoveredDotSampleId = nil
    }
}

struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

struct FooterActionButton: View {
    let id: String
    let systemImage: String
    let title: String
    let shortcut: String
    var extraTipRows: [Tip.Row] = []
    var tipAlignment: TipHorizontalAlignment = .center
    var rotation: Double = 0
    let interaction: PanelInteractionState
    let tipCenter: TipCenter
    let isChinese: Bool
    let action: () -> Void

    var body: some View {
        let hovering = interaction.hoveredFooterId == id
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11.5, weight: .regular))
                    .rotationEffect(.degrees(rotation))
                Text(title)
                    .font(.system(size: 11.5, weight: .regular))
            }
            .foregroundStyle(hovering ? Palette.text : Palette.secondary)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Palette.hover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.14)) {
                if inside {
                    interaction.hoveredFooterId = id
                } else if interaction.hoveredFooterId == id {
                    interaction.hoveredFooterId = nil
                }
            }
        }
        .panelTip("footer.\(id)", center: tipCenter, alignment: tipAlignment) {
            var rows = extraTipRows
            rows.append(Tip.Row(isChinese ? "快捷键" : "Shortcut", shortcut))
            return Tip(rows: rows)
        }
    }
}
