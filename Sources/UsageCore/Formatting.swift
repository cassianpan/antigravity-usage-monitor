import Foundation

public enum DisplayCurrency: String, CaseIterable, Identifiable, Sendable, Codable {
    case usd = "USD"
    case cny = "CNY"

    public var id: String { rawValue }

    public var code: String { rawValue }

    public var symbol: String {
        switch self {
        case .usd: return "$"
        case .cny: return "¥"
        }
    }

    public func title(zh: Bool) -> String {
        if zh {
            switch self {
            case .usd: return "美元"
            case .cny: return "人民币"
            }
        }
        return rawValue
    }

    public var fractionDigits: Int { 2 }

    /// Approximate fallback rate per 1 USD before live FX rates arrive.
    public var fallbackPerUSD: Double {
        switch self {
        case .usd: return 1.0
        case .cny: return 7.20
        }
    }
}

/// ECB exchange rates via Frankfurter public endpoint (`GET https://api.frankfurter.app/latest?from=USD`).
public enum FXRates {
    public static func perUSD(fromFrankfurter data: Data) throws -> [String: Double] {
        struct Raw: Decodable {
            let base: String
            let rates: [String: Double]
        }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        guard raw.base == "USD" else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "expected USD base"))
        }
        var rates = raw.rates
        rates["USD"] = 1.0
        return rates
    }
}

public enum UsageFormatter {
    private static let groupedLock = NSLock()
    private static let groupedFormatters: [NumberFormatter] = (0...2).map { digits in
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        f.usesGroupingSeparator = true
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        return f
    }

    private static func formatDecimal(_ value: Double, digits: Int) -> String {
        let idx = min(max(digits, 0), 2)
        groupedLock.lock()
        defer { groupedLock.unlock() }
        return groupedFormatters[idx].string(from: NSNumber(value: value))
            ?? String(format: "%.\(idx)f", value)
    }

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
        money(amount, currency: .usd, ratePerUSD: 1.0)
    }

    /// Formats a USD amount in `currency` using `ratePerUSD` (units of `currency` per 1 USD).
    /// Matches claude-usage-monitor: grouped thousands, 0 decimals for JPY/KRW or values >= 10,000.
    public static func money(_ usdAmount: Double, currency: DisplayCurrency, ratePerUSD: Double) -> String {
        let effectiveRate = currency == .usd ? 1.0 : max(0.0001, ratePerUSD)
        let converted = usdAmount * effectiveRate
        if currency.fractionDigits == 0 {
            return currency.symbol + formatDecimal(converted.rounded(), digits: 0)
        }
        if abs(converted) < 0.01 && abs(converted) > 0 {
            return String(format: "%@%.4f", currency.symbol, converted)
        }
        let digits = abs(converted) >= 10_000 ? 0 : 2
        return currency.symbol + formatDecimal(converted, digits: digits)
    }

    /// Backward-compatible overload kept for existing callers/tests.
    public static func money(_ usdAmount: Double, currency: DisplayCurrency, cnyRate: Double = 7.25) -> String {
        let rate: Double = (currency == .cny) ? cnyRate : 1.0
        return money(usdAmount, currency: currency, ratePerUSD: rate)
    }

    /// Whole / compact amount for projections and cache savings (mirrors claude-usage-monitor).
    public static func moneyCompact(_ usdAmount: Double, currency: DisplayCurrency, ratePerUSD: Double) -> String {
        let effectiveRate = currency == .usd ? 1.0 : max(0.0001, ratePerUSD)
        let converted = usdAmount * effectiveRate
        if abs(converted) >= 1_000_000 {
            return String(format: "%@%.2fM", currency.symbol, converted / 1_000_000.0)
        }
        if abs(converted) >= 10_000 {
            return String(format: "%@%.1fk", currency.symbol, converted / 1_000.0)
        }
        if abs(converted) >= 100 {
            return currency.symbol + formatDecimal(converted.rounded(), digits: 0)
        }
        return money(usdAmount, currency: currency, ratePerUSD: effectiveRate)
    }

    /// Backward-compatible overload kept for existing callers/tests.
    public static func moneyCompact(_ usdAmount: Double, currency: DisplayCurrency, cnyRate: Double = 7.25) -> String {
        let rate: Double = (currency == .cny) ? cnyRate : 1.0
        return moneyCompact(usdAmount, currency: currency, ratePerUSD: rate)
    }

    public static func percentage(_ fraction: Double) -> String {
        let clamped = max(0, min(1, fraction))
        return "\(Int(floor(clamped * 100.0 + 1e-9)))%"
    }

    public static func percentageOneDecimal(_ fraction: Double) -> String {
        let clamped = max(0, min(1, fraction))
        return String(format: "%.1f%%", clamped * 100.0)
    }

    /// Apportions integer units to `weights` using Hamilton's largest-remainder method so parts sum exactly to `total`.
    public static func apportionLargestRemainder(_ weights: [Double], total: Int) -> [Int] {
        guard !weights.isEmpty else { return [] }
        let safe = weights.map { ($0.isFinite && $0 > 0) ? $0 : 0.0 }
        let sum = safe.reduce(0, +)
        guard sum > 0, total > 0 else { return Array(repeating: 0, count: weights.count) }

        let exact = safe.map { $0 / sum * Double(total) }
        var floors = exact.map { Int(floor($0)) }
        var remainder = total - floors.reduce(0, +)
        if remainder > 0 {
            let order = exact.indices.sorted { i, j in
                let ri = exact[i] - Double(floors[i])
                let rj = exact[j] - Double(floors[j])
                if abs(ri - rj) > 1e-12 { return ri > rj }
                return i < j
            }
            for idx in order.prefix(remainder) {
                floors[idx] += 1
            }
            remainder = 0
        }
        return floors
    }

    /// Formats shares that always sum to exactly 100% (whole integers if all clean, else 1 decimal place).
    public static func apportionedShares(_ weights: [Double]) -> [String] {
        let tenths = apportionLargestRemainder(weights, total: 1000)
        if tenths.allSatisfy({ $0 % 10 == 0 }) {
            return tenths.map { "\($0 / 10)%" }
        }
        return tenths.map { "\($0 / 10).\($0 % 10)%" }
    }

    /// Formats per-row amounts using the total's decimal precision so the rows add up exactly to `money(totalUSD)`.
    public static func apportionedMoney(
        totalUSD: Double,
        partsUSD: [Double],
        currency: DisplayCurrency,
        ratePerUSD: Double
    ) -> [String] {
        let effectiveRate = currency == .usd ? 1.0 : max(0.0001, ratePerUSD)
        let convertedTotal = totalUSD * effectiveRate
        let digits = abs(convertedTotal) >= 10_000 ? 0 : 2
        let scale = pow(10.0, Double(digits))
        let totalUnits = Int((convertedTotal * scale).rounded())
        let units = apportionLargestRemainder(partsUSD.map { $0 * effectiveRate }, total: totalUnits)
        return units.map { currency.symbol + formatDecimal(Double($0) / scale, digits: digits) }
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
