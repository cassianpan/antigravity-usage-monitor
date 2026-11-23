import Foundation

public enum DisplayCurrency: String, CaseIterable, Identifiable, Sendable {
    case usd = "USD"
    case cny = "CNY"

    public var id: String { rawValue }

    public var symbol: String {
        switch self {
        case .usd: return "$"
        case .cny: return "¥"
        }
    }
}

public enum UsageFormatter {
    public static func compactTokens(_ count: Int) -> String {
        let absCount = abs(count)
        let sign = count < 0 ? "-" : ""
        switch absCount {
        case 1_000_000_000...:
            return String(format: "%@%.2fB", sign, Double(absCount) / 1_000_000_000.0)
        case 1_000_000...:
            return String(format: "%@%.2fM", sign, Double(absCount) / 1_000_000.0)
        case 1_000...:
            return String(format: "%@%.1fK", sign, Double(absCount) / 1_000.0)
        default:
            return "\(count)"
        }
    }

    public static func currency(_ amount: Double) -> String {
        money(amount, currency: .usd, cnyRate: 7.25)
    }

    public static func money(_ usdAmount: Double, currency: DisplayCurrency, cnyRate: Double = 7.25) -> String {
        let converted = currency == .cny ? usdAmount * max(0.1, cnyRate) : usdAmount
        if converted < 0.01 && converted > 0 {
            return String(format: "%@%.4f", currency.symbol, converted)
        }
        return String(format: "%@%.2f", currency.symbol, converted)
    }

    public static func moneyCompact(_ usdAmount: Double, currency: DisplayCurrency, cnyRate: Double = 7.25) -> String {
        let converted = currency == .cny ? usdAmount * max(0.1, cnyRate) : usdAmount
        if converted >= 10000 {
            return String(format: "%@%.1fk", currency.symbol, converted / 1000.0)
        }
        if converted >= 100 {
            return String(format: "%@%.0f", currency.symbol, converted)
        }
        return money(usdAmount, currency: currency, cnyRate: cnyRate)
    }

    public static func percentage(_ fraction: Double) -> String {
        let clamped = max(0, min(1, fraction))
        return "\(Int(floor(clamped * 100.0 + 1e-9)))%"
    }

    public static func percentageOneDecimal(_ fraction: Double) -> String {
        let clamped = max(0, min(1, fraction))
        return String(format: "%.1f%%", clamped * 100.0)
    }

    public static func countdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60

        if days > 0 {
            return "\(days)天 \(hours)小时"
        }
        if hours > 0 {
            return "\(hours)小时 \(minutes)分"
        }
        if minutes > 0 {
            return "\(minutes)分钟"
        }
        return "即将重置"
    }

    public static func relativeAge(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 {
            return "刚刚"
        }
        let minutes = total / 60
        if minutes < 60 {
            return "\(minutes) 分钟前"
        }
        let hours = minutes / 60
        if hours < 24 {
            return "\(hours) 小时前"
        }
        let days = hours / 24
        return "\(days) 天前"
    }
}
