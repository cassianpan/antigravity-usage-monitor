import AppKit
import SwiftUI
import UsageCore

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: opacity
        )
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: alpha
        )
    }
}

/// 1:1 aligned with claude-usage-monitor translucent dark glass + Antigravity Blue (#4F8CFF) accent.
enum Palette {
    static let accentHex: UInt32 = 0x4F8CFF
    static let accent = Color(hex: accentHex)

    static let controlSurface = Color.white.opacity(0.065)
    static let controlSelected = Color.white.opacity(0.14)
    static let previewBar = Color.black.opacity(0.35)

    static let text = Color.white.opacity(0.92)
    static let secondary = Color.white.opacity(0.58)
    static let tertiary = Color.white.opacity(0.38)
    static let quaternary = Color.white.opacity(0.20)

    static let track = Color.white.opacity(0.09)
    static let divider = Color.white.opacity(0.08)
    static let hover = Color.white.opacity(0.055)

    static let safeGreen = Color(hex: 0x5EC27B)
    static let warning = Color(hex: 0xE3A24B)
    static let critical = Color(hex: 0xE5584F)
    static let live = Color(hex: 0x6CC08B)

    // Low-saturation token breakdown palette
    static let cacheRead = accent
    static let input = Color.white.opacity(0.62)
    static let output = Color.white.opacity(0.36)

    static func levelHex(for fraction: Double, overPace: Bool = false) -> UInt32 {
        if overPace || fraction >= 0.90 { return 0xE5584F }
        if fraction >= 0.75 { return 0xE57A4B }
        if fraction >= 0.55 { return 0xE3A24B }
        if fraction >= 0.35 { return 0x9EC95A }
        return 0x5EC27B
    }

    static func levelColor(for fraction: Double, overPace: Bool = false) -> Color {
        Color(hex: levelHex(for: fraction, overPace: overPace))
    }
}

enum Metrics {
    static let popoverWidth: CGFloat = 356
    static let popoverCorner: CGFloat = 14
    static let shadowInset: CGFloat = 18
    static let padding: CGFloat = 16
}

// MARK: - Native macOS Frosted Glass (1:1 aligned with Surfaces.swift)

struct GlassEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> MaskedEffectView {
        let view = MaskedEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        view.cornerRadius = cornerRadius
        return view
    }

    func updateNSView(_ view: MaskedEffectView, context: Context) {
        if view.material != material {
            view.material = material
        }
        if view.cornerRadius != cornerRadius {
            view.cornerRadius = cornerRadius
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MaskedEffectView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

final class MaskedEffectView: NSVisualEffectView {
    var cornerRadius: CGFloat = 0 {
        didSet { if oldValue != cornerRadius { updateMask() } }
    }

    private func updateMask() {
        guard cornerRadius > 0 else {
            maskImage = nil
            return
        }
        let inset = ceil(cornerRadius * 1.6)
        let rect = CGRect(x: 0, y: 0, width: inset * 2 + 1, height: inset * 2 + 1)
        let path = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: rect).cgPath
        let image = NSImage(size: rect.size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.addPath(path)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            return true
        }
        image.capInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        image.resizingMode = .stretch
        maskImage = image
    }
}

/// Translucent dark glass panel background + subtle dim + 0.5pt border + soft drop shadow.
struct PanelBackground: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.popoverCorner, style: .continuous)
        ZStack {
            shape.fill(Color.black.opacity(0.32))
                .shadow(color: .black.opacity(0.32), radius: 14, x: 0, y: 8)
            GlassEffect(material: .popover, cornerRadius: Metrics.popoverCorner)
            shape.fill(Color.black.opacity(0.20))
            shape.strokeBorder(Color.white.opacity(0.11), lineWidth: 0.5)
        }
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Palette.divider)
            .frame(height: 0.5)
    }
}

/// Plan badge matching claude-usage-monitor's PlanTag (Pro outlined, Max tinted, Ultra solid).
struct PlanTagView: View {
    let rawTier: String

    private static let tracking: CGFloat = 0.2

    var body: some View {
        let parsed = parseTier(rawTier)
        Text(parsed.label)
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(Self.tracking)
            .foregroundStyle(parsed.text)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Capsule().fill(parsed.fill))
            .overlay(Capsule().strokeBorder(parsed.stroke, lineWidth: 1))
            .fixedSize()
    }

    private func parseTier(_ raw: String) -> (label: String, fill: Color, stroke: Color, text: Color) {
        let lower = raw.lowercased()
        if lower.contains("ultra") {
            return ("Ultra", Palette.accent, .clear, Color(hex: 0x0A1930))
        }
        if lower.contains("max") {
            return ("Max", Palette.accent.opacity(0.22), .clear, Color(hex: 0x89B4FF))
        }
        if lower.contains("pro") {
            return ("Pro", .clear, Palette.accent.opacity(0.65), Color(hex: 0x89B4FF))
        }
        return (raw.capitalized, Color.white.opacity(0.08), .clear, Palette.secondary)
    }
}

/// Quiet icon-box hint row matching Claude Usage Monitor's login/empty notice blocks.
struct QuietNoticeRow: View {
    let systemImage: String
    let title: String
    let subtitle: String
    var actionTitle: String? = nil
    var actionIcon: String = "chevron.forward.square"
    var isActionHovered: Bool = false
    var onActionHover: ((Bool) -> Void)? = nil
    var onAction: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                Image(systemName: systemImage)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Palette.secondary)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.text)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let actionTitle, let onAction {
                    Button(action: onAction) {
                        HStack(spacing: 6) {
                            Image(systemName: actionIcon)
                                .font(.system(size: 11, weight: .medium))
                            Text(actionTitle)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(Palette.text)
                        .padding(.horizontal, 11)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(isActionHovered ? Color.white.opacity(0.15) : Color.white.opacity(0.08))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .onHover { inside in
                        withAnimation(.easeOut(duration: 0.14)) {
                            onActionHover?(inside)
                        }
                    }
                    .padding(.top, 5)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Localization

enum AppLanguage: String, CaseIterable, Identifiable {
    case system = "system"
    case zh = "zh"
    case en = "en"

    var id: String { rawValue }

    var isChinese: Bool {
        switch self {
        case .zh: return true
        case .en: return false
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "en"
            return preferred.lowercased().hasPrefix("zh")
        }
    }

    func label(isChinese uiZh: Bool) -> String {
        switch self {
        case .system: return uiZh ? "跟随系统" : "System"
        case .zh: return "简体中文"
        case .en: return "English"
        }
    }
}

struct L10n {
    let zh: Bool

    var appTitle: String { zh ? "Antigravity 用量" : "Antigravity usage" }
    var processes: String { zh ? "活跃进程" : "Processes" }
    var limits: String { zh ? "用量限额" : "Limits" }
    var context: String { zh ? "活跃上下文" : "Context window" }
    var spend: String { zh ? "本期消耗" : "Spend" }
    var thisMonth: String { zh ? "本月周期" : "This month" }
    var thisWeek: String { zh ? "本周期" : "This week" }
    var today: String { zh ? "每日" : "Today" }
    var tokens: String { zh ? "总 Tokens" : "Tokens" }
    var requests: String { zh ? "请求" : "Requests" }
    var todayShort: String { zh ? "今日" : "Today" }
    var input: String { zh ? "新增输入" : "Input" }
    var output: String { zh ? "输出" : "Output" }
    var cacheRead: String { zh ? "缓存命中" : "Cache read" }
    var cacheHitRate: String { zh ? "缓存命中率" : "Cache hit rate" }
    var savedPrefix: String { zh ? "省 " : "Saved " }
    var settings: String { zh ? "设置..." : "Settings..." }
    var refresh: String { zh ? "立即刷新" : "Refresh" }
    var quit: String { zh ? "退出" : "Quit" }
    var cliSyncTitle: String { zh ? "需要登录 agy CLI" : "agy CLI sign-in required" }
    var cliSyncSubtitle: String {
        zh
            ? "在终端完成一次登录后即可关闭终端，之后自动后台同步官方额度"
            : "Sign in once in Terminal, then close it — official limits sync automatically in the background"
    }
    var openTerminalConnect: String { zh ? "在终端中登录 agy CLI" : "Sign in with agy CLI in Terminal" }
    var unpricedBadge: String { zh ? "含未定价模型" : "Includes unpriced" }
    var unpricedLabel: String { zh ? "未定价" : "Unpriced" }
    var resetsIn: String { zh ? "重置倒计时 " : "Resets in " }
    var resetDone: String { zh ? "已重置" : "Reset" }
    var safeLine: String { zh ? "安全线 " : "Safe line " }
    var syncedSuffix: String { zh ? "同步" : "ago" }
    var contextIdleTitle: String { zh ? "当前没有活跃的 agy 会话" : "No active agy session" }
    var contextIdleSubtitle: String {
        zh
            ? "在 agy CLI 对话后，这里显示当前上下文窗口占比"
            : "Active context window usage appears here while using agy CLI"
    }
    var noActiveProcess: String { zh ? "当前无运行中的 agy / Antigravity 进程" : "No running agy / Antigravity processes" }
    var tabMenuBar: String { zh ? "菜单栏" : "Menu Bar" }
    var tabPanel: String { zh ? "面板" : "Panel" }
    var tabData: String { zh ? "数据" : "Data" }
    var tabGeneral: String { zh ? "通用" : "General" }
}

// MARK: - Gauges & Charts

struct ThinBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 4
    var safeLine: Double? = nil
    var exceeded: Bool = false
    var isPointed: Bool = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let clamped = max(0, min(1, fraction))
            let fillWidth = clamped > 0 ? max(height, width * clamped) : 0
            let markX = safeLine.map { width * max(0, min(1, $0)) }

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Palette.track)

                if isPointed, let markX {
                    Capsule()
                        .fill(Color.white.opacity(0.09))
                        .frame(width: max(height, markX))
                }

                if fillWidth > 0 {
                    Capsule()
                        .fill(color)
                        .frame(width: fillWidth)

                    if exceeded, let markX {
                        Capsule()
                            .fill(Palette.critical)
                            .frame(width: fillWidth)
                            .mask(alignment: .leading) {
                                HStack(spacing: 0) {
                                    Color.clear.frame(width: min(markX, fillWidth))
                                    Color.black
                                }
                            }
                    }
                }
            }
            .frame(width: width, height: height)
            .overlay(alignment: .leading) {
                if let markX {
                    Capsule()
                        .fill(Palette.text)
                        .frame(width: 1.5, height: height + (isPointed ? 8 : 5))
                        .offset(x: max(0, min(width - 1.5, markX - 0.75)))
                }
            }
        }
        .frame(height: height + 8)
    }
}

struct MiniBarsView: View {
    let points: [DailyUsagePoint]
    let highlightIndex: Int
    let interaction: PanelInteractionState
    let tipCenter: TipCenter
    let isChinese: Bool
    let formatMoney: (Double) -> String

    var body: some View {
        let maxVal = max(1, points.map(\.totalTokens).max() ?? 1)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(points.enumerated()), id: \.offset) { idx, point in
                let ratio = Double(point.totalTokens) / Double(maxVal)
                let isToday = idx == highlightIndex
                let isHovered = interaction.hoveredBarIndex == idx
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(
                        isToday
                            ? Palette.accent.opacity(isHovered ? 1.0 : 0.92)
                            : (isHovered
                                ? Color.white.opacity(0.65)
                                : (point.totalTokens > 0 ? Color.white.opacity(0.28) : Color.white.opacity(0.08)))
                    )
                    .frame(width: 5, height: point.totalTokens > 0 ? max(3, CGFloat(ratio) * 30) : 2)
                    .frame(height: 32, alignment: .bottom)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        withAnimation(.easeOut(duration: 0.12)) {
                            if inside {
                                if interaction.hoveredBarIndex != idx {
                                    interaction.hoveredBarIndex = idx
                                }
                            } else if interaction.hoveredBarIndex == idx {
                                interaction.hoveredBarIndex = nil
                            }
                        }
                    }
                    .panelTip("bar.\(idx)", center: tipCenter) {
                        Tip(
                            title: point.dayKey,
                            rows: [
                                Tip.Row("Tokens", UsageFormatter.compactTokens(point.totalTokens)),
                                Tip.Row(isChinese ? "估算花费" : "Est. spend", formatMoney(point.estimatedCostUSD)),
                            ]
                        )
                    }
            }
        }
        .frame(height: 32, alignment: .bottom)
    }
}

struct SparklineView: View {
    let samples: [OutputSpeedSample]
    let hoveredIndex: Int?
    let onHoverIndex: (Int?) -> Void
    let onTap: () -> Void

    var body: some View {
        let recent = Array(samples.suffix(18))
        let values = recent.map(\.tokensPerSec)
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let minV = (values.min() ?? 0) * 0.85
            let maxV = max(minV + 1, (values.max() ?? 1) * 1.05)

            ZStack {
                if values.count >= 2 {
                    Path { path in
                        for (idx, val) in values.enumerated() {
                            let x = w * CGFloat(idx) / CGFloat(values.count - 1)
                            let norm = (val - minV) / (maxV - minV)
                            let y = h - CGFloat(norm) * (h - 6) - 3
                            if idx == 0 {
                                path.move(to: CGPoint(x: x, y: y))
                            } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                    }
                    .stroke(Color.white.opacity(hoveredIndex != nil ? 0.65 : 0.45), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

                    let activeIdx = hoveredIndex ?? (values.count - 1)
                    if activeIdx >= 0 && activeIdx < values.count {
                        let x = w * CGFloat(activeIdx) / CGFloat(values.count - 1)
                        let norm = (values[activeIdx] - minV) / (maxV - minV)
                        let y = h - CGFloat(norm) * (h - 6) - 3
                        if hoveredIndex != nil {
                            Path { p in
                                p.move(to: CGPoint(x: x, y: 0))
                                p.addLine(to: CGPoint(x: x, y: h))
                            }
                            .stroke(Color.white.opacity(0.16), lineWidth: 1)
                        }
                        Circle()
                            .fill(Palette.accent)
                            .frame(width: hoveredIndex != nil ? 6 : 4.5, height: hoveredIndex != nil ? 6 : 4.5)
                            .position(x: x, y: y)
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let loc):
                    guard values.count >= 2 else { return }
                    let ratio = max(0, min(1, loc.x / max(1, w)))
                    let idx = Int(round(ratio * Double(values.count - 1)))
                    if idx != hoveredIndex {
                        onHoverIndex(idx)
                    }
                case .ended:
                    if hoveredIndex != nil {
                        onHoverIndex(nil)
                    }
                }
            }
            .onTapGesture {
                onTap()
            }
        }
        .frame(width: 104, height: 30)
    }
}

/// 1-hour reply dot/heat scatter plot (matching claude-usage-monitor SpeedChart).
/// Tap anywhere to toggle back to the compact sparkline.
struct SpeedDotChartView: View {
    let samples: [OutputSpeedSample]
    let now: Date
    let hoveredSampleId: Int?
    let onHoverSample: (Int?) -> Void
    let onTap: () -> Void

    var body: some View {
        let minSpeed = max(0, (samples.map(\.tokensPerSec).min() ?? 0) * 0.8)
        let maxSpeed = max(minSpeed + 10, (samples.map(\.tokensPerSec).max() ?? 60) * 1.1)
        let maxOut = max(1, samples.map(\.outputTokens).max() ?? 1)

        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let span: TimeInterval = 3600

            ZStack {
                // Subtle horizontal baseline guides
                VStack {
                    Hairline().opacity(0.45)
                    Spacer()
                    Hairline().opacity(0.45)
                    Spacer()
                    Hairline().opacity(0.45)
                }

                ForEach(samples) { sample in
                    let age = max(0, min(span, now.timeIntervalSince(sample.timestamp)))
                    let x = w * CGFloat(1.0 - age / span)
                    let normY = (sample.tokensPerSec - minSpeed) / (maxSpeed - minSpeed)
                    let y = h - CGFloat(normY) * (h - 14) - 7
                    let sizeRatio = sqrt(Double(sample.outputTokens) / Double(maxOut))
                    let baseSize = CGFloat(4.5 + sizeRatio * 5.0)
                    let isHovered = hoveredSampleId == sample.id
                    let isLatest = sample.id == samples.last?.id

                    Circle()
                        .fill(
                            isHovered || isLatest
                                ? Palette.accent
                                : Color.white.opacity(0.25 + 0.45 * (1.0 - age / span))
                        )
                        .frame(width: isHovered ? baseSize + 3 : baseSize, height: isHovered ? baseSize + 3 : baseSize)
                        .shadow(color: (isHovered || isLatest) ? Palette.accent.opacity(0.55) : .clear, radius: 4)
                        .position(x: max(6, min(w - 6, x)), y: y)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let loc):
                    var bestId: Int?
                    var bestDist: CGFloat = 24
                    for sample in samples {
                        let age = max(0, min(span, now.timeIntervalSince(sample.timestamp)))
                        let sx = max(6, min(w - 6, w * CGFloat(1.0 - age / span)))
                        let normY = (sample.tokensPerSec - minSpeed) / (maxSpeed - minSpeed)
                        let sy = h - CGFloat(normY) * (h - 14) - 7
                        let d = hypot(loc.x - sx, loc.y - sy)
                        if d < bestDist {
                            bestDist = d
                            bestId = sample.id
                        }
                    }
                    if bestId != hoveredSampleId {
                        onHoverSample(bestId)
                    }
                case .ended:
                    if hoveredSampleId != nil {
                        onHoverSample(nil)
                    }
                }
            }
            .onTapGesture {
                onTap()
            }
        }
        .frame(height: 62)
        .padding(.horizontal, 4)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

@MainActor
enum CachedFormatters {
    static let hhmm: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static let zhPeriodDateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm:ss"
        return f
    }()

    static let enPeriodDateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, HH:mm:ss"
        return f
    }()

    static let zhDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f
    }()

    static let enDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        return f
    }()
}

/// Unified zero-lag segmented switch with full-area hit targets and smooth transitions.
struct SegmentSwitch<Option: Hashable & Identifiable>: View {
    let options: [Option]
    let selection: Option
    let label: (Option) -> String
    var fullWidth: Bool = false
    let onSelect: (Option) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let active = selection == option
                Button {
                    guard selection != option else { return }
                    withAnimation(.easeOut(duration: 0.14)) {
                        onSelect(option)
                    }
                } label: {
                    Text(label(option))
                        .font(.system(size: fullWidth ? 11.5 : 11, weight: active ? .medium : .regular))
                        .foregroundStyle(active ? Palette.text : Palette.secondary)
                        .frame(maxWidth: fullWidth ? .infinity : nil)
                        .padding(.horizontal, fullWidth ? 6 : 10)
                        .padding(.vertical, fullWidth ? 5 : 4)
                        .background(
                            RoundedRectangle(cornerRadius: fullWidth ? 6 : 5, style: .continuous)
                                .fill(active ? Palette.controlSelected : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Palette.controlSurface, in: RoundedRectangle(cornerRadius: fullWidth ? 8 : 7, style: .continuous))
    }
}

struct FourPointStarShape: Shape {
    func path(in rect: CGRect) -> Path {
        let cx = rect.midX
        let cy = rect.midY
        let r = min(rect.width, rect.height) / 2.0
        var path = Path()
        path.move(to: CGPoint(x: cx, y: cy - r))
        path.addQuadCurve(to: CGPoint(x: cx + r, y: cy), control: CGPoint(x: cx + r * 0.14, y: cy - r * 0.14))
        path.addQuadCurve(to: CGPoint(x: cx, y: cy + r), control: CGPoint(x: cx + r * 0.14, y: cy + r * 0.14))
        path.addQuadCurve(to: CGPoint(x: cx - r, y: cy), control: CGPoint(x: cx - r * 0.14, y: cy + r * 0.14))
        path.addQuadCurve(to: CGPoint(x: cx, y: cy - r), control: CGPoint(x: cx - r * 0.14, y: cy - r * 0.14))
        path.closeSubpath()
        return path
    }
}

struct BrandMarkView: View {
    var size: CGFloat = 15
    var color: Color = Palette.accent

    var body: some View {
        FourPointStarShape()
            .fill(
                LinearGradient(
                    colors: [Color(hex: 0x7AB8FF), color, Color(hex: 0x7361FA)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .rotationEffect(.degrees(30))
            .frame(width: size, height: size)
    }
}
