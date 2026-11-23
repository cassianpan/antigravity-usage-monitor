import AppKit
import SwiftUI

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

/// 1:1 aligned with claude-usage-monitor dark charcoal surfaces + Antigravity Blue (#4F8CFF) accent.
enum Palette {
    static let accentHex: UInt32 = 0x4F8CFF
    static let accent = Color(hex: accentHex)

    static let panelBackground = Color(hex: 0x2B2B2A)
    static let settingsBackground = Color(hex: 0x232322)
    static let controlSurface = Color.white.opacity(0.065)
    static let controlSelected = Color.white.opacity(0.14)
    static let previewBar = Color(hex: 0x1D1D1C)

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

    // Low-saturation token breakdown palette (single brand hue + neutral grays)
    static let cacheRead = accent
    static let input = Color.white.opacity(0.62)
    static let output = Color.white.opacity(0.36)
    static let cacheSavings = Color(hex: 0x6CC08B)

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
    static let padding: CGFloat = 16
}

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
    var limits: String { zh ? "额度" : "Limits" }
    var context: String { zh ? "活跃上下文" : "Context window" }
    var spend: String { zh ? "花费与缓存" : "Spend" }
    var thisMonth: String { zh ? "本月" : "This month" }
    var thisWeek: String { zh ? "本周" : "This week" }
    var today: String { zh ? "今日" : "Today" }
    var tokens: String { "Tokens" }
    var requests: String { zh ? "请求" : "Requests" }
    var input: String { zh ? "新增输入" : "Input" }
    var output: String { zh ? "输出" : "Output" }
    var cacheRead: String { zh ? "缓存命中" : "Cache read" }
    var cacheHitRate: String { zh ? "缓存命中率" : "Cache hit rate" }
    var savedPrefix: String { zh ? "省 " : "Saved " }
    var settings: String { zh ? "设置..." : "Settings..." }
    var refresh: String { zh ? "刷新" : "Refresh" }
    var quit: String { zh ? "退出" : "Quit" }
    var openTerminalConnect: String { zh ? "在终端打开 agy 登录并同步" : "Open Terminal to sign in & sync agy" }
    var noSnapshotHint: String {
        zh
            ? "打开终端运行 agy 登录并执行一次 /usage，官方 5 小时与每周额度会自动同步到这里。"
            : "Sign in via agy CLI in Terminal and run /usage once to sync official 5-hour & weekly limits."
    }
    var unpricedBadge: String { zh ? "含未定价模型" : "Includes unpriced" }
    var unpricedLabel: String { zh ? "未定价" : "Unpriced" }
    var resetsIn: String { zh ? "重置倒计时 " : "Resets in " }
    var resetDone: String { zh ? "已重置" : "Reset" }
    var safeLine: String { zh ? "安全线 " : "Safe line " }
    var syncedPrefix: String { zh ? "同步于 " : "Synced " }
    var noActiveContext: String { zh ? "暂无活跃 agy CLI 会话" : "No active agy CLI session" }
    var noActiveProcess: String { zh ? "当前无运行中的 agy / Antigravity 进程" : "No running agy / Antigravity processes" }
    var tabMenuBar: String { zh ? "菜单栏" : "Menu Bar" }
    var tabPanel: String { zh ? "面板" : "Panel" }
    var tabData: String { zh ? "CLI 与数据" : "Data" }
    var tabGeneral: String { zh ? "通用" : "General" }
}

// MARK: - Reference-aligned Components (Zero @State macro for CLT compatibility)

/// Thin progress bar with Safe Line mark. Portion past safe line turns critical red.
struct ThinBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 4
    var safeLine: Double? = nil
    var exceeded: Bool = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let clamped = max(0, min(1, fraction))
            let fillWidth = clamped > 0 ? max(height, width * clamped) : 0
            let markX = safeLine.map { width * max(0, min(1, $0)) }

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Palette.track)

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
                        .frame(width: 1.5, height: height + 5)
                        .offset(x: max(0, min(width - 1.5, markX - 0.75)))
                }
            }
        }
        .frame(height: height + 5)
    }
}

/// Minimalist 14-day bar chart matching claude-usage-monitor Spend section.
struct MiniBarsView: View {
    let values: [Double]
    let labels: [String]
    let highlightIndex: Int

    var body: some View {
        let maxVal = max(1e-9, values.max() ?? 1)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(values.enumerated()), id: \.offset) { idx, val in
                let ratio = val / maxVal
                let isToday = idx == highlightIndex
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(
                        isToday
                            ? Palette.accent
                            : (val > 0 ? Color.white.opacity(0.28) : Color.white.opacity(0.08))
                    )
                    .frame(width: 5, height: val > 0 ? max(3, CGFloat(ratio) * 32) : 2)
                    .help(idx < labels.count ? labels[idx] : "")
            }
        }
        .frame(height: 34, alignment: .bottom)
    }
}

/// Antigravity geometric brand mark (clean vector, tinted with brand accent).
struct BrandMarkView: View {
    var size: CGFloat = 14
    var color: Color = Palette.accent

    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(color)
    }
}
