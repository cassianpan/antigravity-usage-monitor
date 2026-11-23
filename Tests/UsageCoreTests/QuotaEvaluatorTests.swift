import Foundation
import XCTest
@testable import UsageCore

final class QuotaEvaluatorTests: XCTestCase {
    func testEvaluatesSafeLineAndStaleness() {
        let now = ISO8601DateParser.parse("2026-11-23T12:00:00Z")!
        let capturedAt = now.addingTimeInterval(-45 * 60) // 45m ago -> stale (> 30m)

        // 5h window resets in 2.5h -> 50% elapsed -> safe line = 0.50; used = 62% -> over pace
        let fiveHourReset = ISO8601DateParser.parse("2026-11-23T14:30:00Z")!
        // Weekly window resets in 5 days -> elapsed 2 days -> dayIndex = 3 -> safe line = 3/7 (~42.8%); used = 20% -> safe
        let weeklyReset = ISO8601DateParser.parse("2026-11-28T12:00:00Z")!

        let snapshot = StatusLineSnapshot(
            conversationId: "conv-1",
            conversationTitle: "Test",
            model: StatusLineModelInfo(id: "gemini-2.5-pro", displayName: "Gemini 2.5 Pro"),
            contextWindow: StatusLineContextWindow(
                totalInputTokens: 80_000,
                totalOutputTokens: 10_000,
                contextWindowSize: 1_000_000,
                usedPercentage: 9.0,
                remainingPercentage: 91.0
            ),
            quota: [
                "gemini-5h": StatusLineQuotaBucket(
                    remainingFraction: 0.38,
                    resetTime: ISO8601DateFormatter().string(from: fiveHourReset),
                    resetInSeconds: 9000
                ),
                "gemini-weekly": StatusLineQuotaBucket(
                    remainingFraction: 0.80,
                    resetTime: ISO8601DateFormatter().string(from: weeklyReset),
                    resetInSeconds: 5 * 86400
                ),
            ],
            agentState: "idle",
            planTier: "Pro",
            email: "dev@example.com",
            cost: StatusLineCostInfo(totalUSD: 0.42),
            capturedAt: capturedAt
        )

        let evaluator = QuotaEvaluator(staleThresholdSeconds: 30 * 60)
        let report = evaluator.evaluate(snapshot: snapshot, now: now)

        XCTAssertTrue(report.hasSnapshot)
        XCTAssertTrue(report.isStale)
        XCTAssertEqual(report.primaryFiveHour?.usedPercentageInt, 62)
        XCTAssertEqual(report.primaryFiveHour?.isOverPace, true)
        XCTAssertEqual(report.primaryFiveHour?.safeLineFraction ?? 0, 0.5, accuracy: 0.01)

        XCTAssertEqual(report.primaryWeekly?.usedPercentageInt, 20)
        XCTAssertEqual(report.primaryWeekly?.isOverPace, false)
        XCTAssertEqual(report.primaryWeekly?.safeLineFraction ?? 0, 3.0 / 7.0, accuracy: 0.01)
    }

    func testResetsLocallyAfterResetTime() {
        let now = ISO8601DateParser.parse("2026-11-23T15:00:00Z")!
        let pastReset = ISO8601DateParser.parse("2026-11-23T14:30:00Z")!

        let snapshot = StatusLineSnapshot(
            quota: [
                "gemini-5h": StatusLineQuotaBucket(
                    remainingFraction: 0.12,
                    resetTime: ISO8601DateFormatter().string(from: pastReset),
                    resetInSeconds: 0
                ),
            ],
            capturedAt: now.addingTimeInterval(-3600)
        )

        let report = QuotaEvaluator().evaluate(snapshot: snapshot, now: now)
        XCTAssertEqual(report.primaryFiveHour?.isResetElapsed, true)
        XCTAssertEqual(report.primaryFiveHour?.usedPercentageInt, 0)
        XCTAssertEqual(report.primaryFiveHour?.remainingFraction, 1.0)
        XCTAssertEqual(report.primaryFiveHour?.isOverPace, false)
    }
}
