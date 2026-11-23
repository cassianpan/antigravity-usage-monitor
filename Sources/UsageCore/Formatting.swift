import Foundation

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
        if amount < 0.01 && amount > 0 {
            return String(format: "$%.4f", amount)
        }
        return String(format: "$%.2f", amount)
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
