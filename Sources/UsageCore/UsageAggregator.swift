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
        officialWeeklyResetTime: Date? = nil,
        billingDay: Int? = nil
    ) -> LocalUsageReport {
        let startOfToday = calendar.startOfDay(for: now)
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)

        let weekStart: Date
        let weekEnd: Date
        if let reset = officialWeeklyResetTime, reset > now {
            weekStart = reset.addingTimeInterval(-7 * 24 * 3600)
            weekEnd = reset.addingTimeInterval(-1)
        } else {
            weekStart = now.addingTimeInterval(-7 * 24 * 3600)
            weekEnd = now
        }
        let weekPeriod = makePeriodInfo(start: weekStart, end: weekEnd, now: now, fallbackTotalDays: 7)

        let monthBounds = resolveBillingMonthBounds(
            now: now,
            billingDay: billingDay,
            clockReference: officialWeeklyResetTime
        )
        let monthPeriod = monthBounds.map {
            makePeriodInfo(start: $0.start, end: $0.end, now: now, fallbackTotalDays: 30)
        }

        let todayRecords = records.filter { $0.timestamp >= startOfToday && $0.timestamp <= now }
        let fiveHourRecords = records.filter { $0.timestamp >= fiveHoursAgo && $0.timestamp <= now }
        let weekRecords = records.filter { $0.timestamp >= weekStart && $0.timestamp <= now }
        let monthStartForRecords = monthBounds?.start ?? now.addingTimeInterval(-30 * 24 * 3600)
        let monthRecords = records.filter { $0.timestamp >= monthStartForRecords && $0.timestamp <= now }

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
            weekPeriod: weekPeriod,
            monthPeriod: monthPeriod,
            byModel: byModel,
            dailyTrend: dailyTrend,
            conversationCount: conversationCount,
            updatedAt: now
        )
    }

    private func resolveBillingMonthBounds(now: Date, billingDay: Int?, clockReference: Date?) -> (start: Date, end: Date)? {
        guard let rawDay = billingDay, (1...31).contains(rawDay) else {
            return nil
        }

        let comps = calendar.dateComponents([.year, .month, .day], from: now)
        let year = comps.year ?? 2026
        let month = comps.month ?? 1

        // Align billing clock with official weekly reset clock (matching claude-usage-monitor).
        let clock = clockReference.map { calendar.dateComponents([.hour, .minute, .second], from: $0) }
        let hour = clock?.hour ?? 0
        let minute = clock?.minute ?? 0
        let second = clock?.second ?? 0

        func clampedAnchor(year: Int, month: Int, day: Int) -> Date {
            let firstOfMonth = calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? now
            let range = calendar.range(of: .day, in: .month, for: firstOfMonth) ?? 1..<29
            let clampedDay = min(day, range.count)
            return calendar.date(from: DateComponents(
                year: year,
                month: month,
                day: clampedDay,
                hour: hour,
                minute: minute,
                second: second
            )) ?? firstOfMonth
        }

        let thisMonthAnchor = clampedAnchor(year: year, month: month, day: rawDay)
        if now >= thisMonthAnchor {
            let nextMonthDate = calendar.date(byAdding: .month, value: 1, to: DateComponents(calendar: calendar, year: year, month: month, day: 1).date ?? now) ?? now
            let nextComps = calendar.dateComponents([.year, .month], from: nextMonthDate)
            let nextAnchor = clampedAnchor(year: nextComps.year ?? year, month: nextComps.month ?? month, day: rawDay)
            return (thisMonthAnchor, nextAnchor.addingTimeInterval(-1))
        } else {
            let prevMonthDate = calendar.date(byAdding: .month, value: -1, to: DateComponents(calendar: calendar, year: year, month: month, day: 1).date ?? now) ?? now
            let prevComps = calendar.dateComponents([.year, .month], from: prevMonthDate)
            let prevAnchor = clampedAnchor(year: prevComps.year ?? year, month: prevComps.month ?? month, day: rawDay)
            return (prevAnchor, thisMonthAnchor.addingTimeInterval(-1))
        }
    }

    private func makePeriodInfo(start: Date, end: Date, now: Date, fallbackTotalDays: Int) -> BillingPeriodInfo {
        let totalSecs = max(86400, end.timeIntervalSince(start) + 1)
        let totalDays = max(1, Int(round(totalSecs / 86400.0)))
        let elapsedSecs = max(0, now.timeIntervalSince(start))
        let currentDay = min(totalDays, max(1, Int(floor(elapsedSecs / 86400.0)) + 1))
        let remainingSecs = max(0, end.timeIntervalSince(now))
        let remainingDays = max(0, Int(ceil(remainingSecs / 86400.0)))
        return BillingPeriodInfo(
            start: start,
            end: end,
            currentDay: currentDay,
            totalDays: totalDays > 0 ? totalDays : fallbackTotalDays,
            remainingDays: remainingDays
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
