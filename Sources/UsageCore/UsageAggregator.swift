import Foundation

public struct UsageAggregator: Sendable {
    private let pricing: PricingCatalog
    private let calendar: Calendar

    public init(pricing: PricingCatalog = .default, calendar: Calendar = .current) {
        self.pricing = pricing
        self.calendar = calendar
    }

    public func aggregate(
        records: [TranscriptRecord],
        conversationCount: Int,
        now: Date = Date(),
        officialWeeklyResetTime: Date? = nil
    ) -> LocalUsageReport {
        let startOfToday = calendar.startOfDay(for: now)
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        let monthComponents = calendar.dateComponents([.year, .month], from: now)
        let startOfMonth = calendar.date(from: monthComponents) ?? now.addingTimeInterval(-30 * 24 * 3600)

        let weekStart: Date
        if let reset = officialWeeklyResetTime, reset > now {
            weekStart = reset.addingTimeInterval(-7 * 24 * 3600)
        } else {
            weekStart = now.addingTimeInterval(-7 * 24 * 3600)
        }

        let todayRecords = records.filter { $0.timestamp >= startOfToday && $0.timestamp <= now }
        let fiveHourRecords = records.filter { $0.timestamp >= fiveHoursAgo && $0.timestamp <= now }
        let weekRecords = records.filter { $0.timestamp >= weekStart && $0.timestamp <= now }
        let monthRecords = records.filter { $0.timestamp >= startOfMonth && $0.timestamp <= now }

        let todaySummary = summarize(todayRecords)
        let fiveHourSummary = summarize(fiveHourRecords)
        let weekSummary = summarize(weekRecords)
        let monthSummary = summarize(monthRecords)
        let byModel = summarizeByModel(weekRecords)
        let dailyTrend = buildDailyTrend(records: records, now: now, days: 14)

        return LocalUsageReport(
            today: todaySummary,
            fiveHour: fiveHourSummary,
            week: weekSummary,
            month: monthSummary,
            byModel: byModel,
            dailyTrend: dailyTrend,
            conversationCount: conversationCount,
            updatedAt: now
        )
    }

    private func summarize(_ records: [TranscriptRecord]) -> UsageWindowSummary {
        var uncached = 0
        var cacheRead = 0
        var output = 0
        var costUSD = 0.0
        var savingsUSD = 0.0
        var unpriced = Set<String>()

        for record in records {
            uncached += record.inputTokens
            cacheRead += record.cacheReadTokens
            output += record.outputTokens

            if let price = pricing.price(for: record.model) {
                costUSD += price.costUSD(
                    uncachedInput: record.inputTokens,
                    cacheRead: record.cacheReadTokens,
                    output: record.outputTokens
                )
                savingsUSD += price.cacheSavingsUSD(cacheRead: record.cacheReadTokens)
            } else {
                unpriced.insert(record.model)
            }
        }

        return UsageWindowSummary(
            uncachedInputTokens: uncached,
            cacheReadTokens: cacheRead,
            outputTokens: output,
            requestCount: records.count,
            estimatedCostUSD: costUSD,
            cacheSavingsUSD: savingsUSD,
            unpricedModels: unpriced.sorted()
        )
    }

    private func summarizeByModel(_ records: [TranscriptRecord]) -> [ModelUsageSummary] {
        struct Accumulator {
            var uncached = 0
            var cacheRead = 0
            var output = 0
            var count = 0
        }

        var grouped: [String: Accumulator] = [:]
        for record in records {
            var acc = grouped[record.model] ?? Accumulator()
            acc.uncached += record.inputTokens
            acc.cacheRead += record.cacheReadTokens
            acc.output += record.outputTokens
            acc.count += 1
            grouped[record.model] = acc
        }

        return grouped.map { model, acc in
            let price = pricing.price(for: model)
            let cost = price?.costUSD(uncachedInput: acc.uncached, cacheRead: acc.cacheRead, output: acc.output)
            let savings = price?.cacheSavingsUSD(cacheRead: acc.cacheRead)
            return ModelUsageSummary(
                model: model,
                displayName: PricingCatalog.displayName(for: model),
                uncachedInputTokens: acc.uncached,
                cacheReadTokens: acc.cacheRead,
                outputTokens: acc.output,
                requestCount: acc.count,
                estimatedCostUSD: cost,
                cacheSavingsUSD: savings
            )
        }
        .sorted { lhs, rhs in
            if lhs.totalTokens != rhs.totalTokens {
                return lhs.totalTokens > rhs.totalTokens
            }
            return lhs.model < rhs.model
        }
    }

    private func buildDailyTrend(records: [TranscriptRecord], now: Date, days: Int) -> [DailyUsagePoint] {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        let todayStart = calendar.startOfDay(for: now)
        var dayStarts: [Date] = []
        for offset in stride(from: -(days - 1), through: 0, by: 1) {
            if let day = calendar.date(byAdding: .day, value: offset, to: todayStart) {
                dayStarts.append(day)
            }
        }

        guard let earliestDay = dayStarts.first else { return [] }

        struct Bucket {
            var uncached = 0
            var cacheRead = 0
            var output = 0
            var cost = 0.0
        }

        var byDayKey: [String: Bucket] = [:]
        for record in records where record.timestamp >= earliestDay && record.timestamp <= now {
            let key = formatter.string(from: record.timestamp)
            var bucket = byDayKey[key] ?? Bucket()
            bucket.uncached += record.inputTokens
            bucket.cacheRead += record.cacheReadTokens
            bucket.output += record.outputTokens
            if let price = pricing.price(for: record.model) {
                bucket.cost += price.costUSD(
                    uncachedInput: record.inputTokens,
                    cacheRead: record.cacheReadTokens,
                    output: record.outputTokens
                )
            }
            byDayKey[key] = bucket
        }

        return dayStarts.map { day in
            let key = formatter.string(from: day)
            let bucket = byDayKey[key] ?? Bucket()
            return DailyUsagePoint(
                dayKey: key,
                date: day,
                uncachedInputTokens: bucket.uncached,
                cacheReadTokens: bucket.cacheRead,
                outputTokens: bucket.output,
                estimatedCostUSD: bucket.cost
            )
        }
    }
}
