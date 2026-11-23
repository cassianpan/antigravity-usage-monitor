import Foundation

public struct QuotaEvaluator: Sendable {
    public let staleThresholdSeconds: TimeInterval

    public init(staleThresholdSeconds: TimeInterval = 30 * 60) {
        self.staleThresholdSeconds = staleThresholdSeconds
    }

    public func loadSnapshot(from url: URL) -> StatusLineSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let timestamp = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: timestamp)
            }
            if let string = try? container.decode(String.self), let date = ISO8601DateParser.parse(string) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date format")
        }

        guard let parsed = try? decoder.decode(StatusLineSnapshot.self, from: data) else {
            return nil
        }

        if parsed.capturedAt != nil {
            return parsed
        }

        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        return StatusLineSnapshot(
            conversationId: parsed.conversationId,
            conversationTitle: parsed.conversationTitle,
            model: parsed.model,
            version: parsed.version,
            contextWindow: parsed.contextWindow,
            quota: parsed.quota,
            agentState: parsed.agentState,
            planTier: parsed.planTier,
            email: parsed.email,
            cost: parsed.cost,
            capturedAt: mtime
        )
    }

    public func evaluate(snapshot: StatusLineSnapshot?, now: Date = Date()) -> OfficialQuotaReport {
        guard let snapshot else {
            return OfficialQuotaReport()
        }

        let capturedAt = snapshot.capturedAt ?? now
        let age = max(0, now.timeIntervalSince(capturedAt))
        let isStale = age > staleThresholdSeconds

        var evaluatedBuckets: [QuotaBucketEvaluation] = []
        if let quotaMap = snapshot.quota {
            for (bucketId, rawBucket) in quotaMap {
                let kind = Self.classifyWindow(bucketId: bucketId, resetInSeconds: rawBucket.resetInSeconds)
                let resetDate = Self.resolveResetDate(rawBucket: rawBucket, capturedAt: capturedAt)
                let remainingSeconds: TimeInterval?
                let isResetElapsed: Bool

                if let resetDate {
                    let delta = resetDate.timeIntervalSince(now)
                    isResetElapsed = delta <= 0
                    remainingSeconds = max(0, delta)
                } else {
                    isResetElapsed = false
                    remainingSeconds = nil
                }

                // Decision D5: When reset time elapses, drop used fraction to 0 locally.
                let rawRemaining = Self.clamp01(rawBucket.remainingFraction ?? 1.0)
                let effectiveRemaining = isResetElapsed ? 1.0 : rawRemaining
                let effectiveUsed = isResetElapsed ? 0.0 : Self.clamp01(1.0 - rawRemaining)

                let safeLine = Self.computeSafeLine(
                    windowKind: kind,
                    resetDate: resetDate,
                    now: now,
                    isResetElapsed: isResetElapsed
                )

                evaluatedBuckets.append(
                    QuotaBucketEvaluation(
                        bucketId: bucketId,
                        displayName: Self.displayName(for: bucketId, kind: kind),
                        windowKind: kind,
                        usedFraction: effectiveUsed,
                        remainingFraction: effectiveRemaining,
                        safeLineFraction: safeLine,
                        resetTime: resetDate,
                        remainingSecondsUntilReset: remainingSeconds,
                        isResetElapsed: isResetElapsed,
                        isDisabled: rawBucket.disabled ?? false
                    )
                )
            }
        }

        evaluatedBuckets.sort { lhs, rhs in
            let order: (QuotaWindowKind) -> Int = { kind in
                switch kind {
                case .fiveHour: return 0
                case .weekly: return 1
                case .other: return 2
                }
            }
            if order(lhs.windowKind) != order(rhs.windowKind) {
                return order(lhs.windowKind) < order(rhs.windowKind)
            }
            return lhs.bucketId < rhs.bucketId
        }

        let primaryFiveHour = evaluatedBuckets.first(where: { $0.windowKind == .fiveHour && !$0.isDisabled })
            ?? evaluatedBuckets.first(where: { $0.windowKind == .fiveHour })
        let primaryWeekly = evaluatedBuckets.first(where: { $0.windowKind == .weekly && !$0.isDisabled })
            ?? evaluatedBuckets.first(where: { $0.windowKind == .weekly })

        return OfficialQuotaReport(
            buckets: evaluatedBuckets,
            primaryFiveHour: primaryFiveHour,
            primaryWeekly: primaryWeekly,
            snapshotCapturedAt: capturedAt,
            isStale: isStale,
            staleAgeSeconds: age,
            activeModelName: snapshot.model?.displayName ?? snapshot.model?.id,
            contextWindow: snapshot.contextWindow,
            conversationTitle: snapshot.conversationTitle,
            agentState: snapshot.agentState,
            planTier: snapshot.planTier,
            email: snapshot.email,
            sessionCostUSD: snapshot.cost?.totalUSD
        )
    }

    public static func classifyWindow(bucketId: String, resetInSeconds: Int?) -> QuotaWindowKind {
        let lower = bucketId.lowercased()
        if lower.contains("5h") || lower.contains("5-hour") || lower.contains("five_hour") || lower.contains("five-hour") || lower.contains("session") || lower.contains("rolling") {
            return .fiveHour
        }
        if lower.contains("week") || lower.contains("7d") || lower.contains("7-day") {
            return .weekly
        }
        if let seconds = resetInSeconds {
            if seconds > 0 && seconds <= 6 * 3600 {
                return .fiveHour
            }
            if seconds > 24 * 3600 && seconds <= 8 * 24 * 3600 {
                return .weekly
            }
        }
        return .other
    }

    public static func computeSafeLine(
        windowKind: QuotaWindowKind,
        resetDate: Date?,
        now: Date,
        isResetElapsed: Bool
    ) -> Double? {
        guard !isResetElapsed, let resetDate, let duration = windowKind.durationSeconds else {
            return nil
        }

        let windowStart = resetDate.addingTimeInterval(-duration)
        let elapsed = now.timeIntervalSince(windowStart)
        guard elapsed >= 0 else { return 0 }

        switch windowKind {
        case .fiveHour:
            return clamp01(elapsed / duration)
        case .weekly:
            // Mirrors claude-usage-monitor: weekly safe line advances 1/7 per elapsed day.
            let dayIndex = min(7.0, floor(elapsed / (24 * 3600)) + 1.0)
            return clamp01(dayIndex / 7.0)
        case .other:
            return nil
        }
    }

    private static func resolveResetDate(rawBucket: StatusLineQuotaBucket, capturedAt: Date) -> Date? {
        if let resetTime = rawBucket.resetTime, let parsed = ISO8601DateParser.parse(resetTime) {
            return parsed
        }
        if let seconds = rawBucket.resetInSeconds {
            return capturedAt.addingTimeInterval(TimeInterval(seconds))
        }
        return nil
    }

    private static func displayName(for bucketId: String, kind: QuotaWindowKind) -> String {
        let lower = bucketId.lowercased()
        let group: String
        if lower.contains("gemini") {
            group = "Gemini"
        } else if lower.contains("claude") {
            group = "Claude"
        } else if lower.contains("gpt") {
            group = "GPT"
        } else {
            group = bucketId
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }

        switch kind {
        case .fiveHour:
            return "\(group) · 5 小时"
        case .weekly:
            return "\(group) · 周限额"
        case .other:
            return group
        }
    }

    private static func clamp01(_ value: Double) -> Double {
        max(0.0, min(1.0, value))
    }
}
