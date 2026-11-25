import Foundation
import XCTest
@testable import UsageCore

final class UpgradeRegressionTests: XCTestCase {
    func testPricingCatalogDateEffectiveChildModelsAndLongContext() {
        let catalog = PricingCatalog.default
        let iso = ISO8601DateFormatter()
        let nov2026 = iso.date(from: "2026-11-25T00:00:00Z")!
        let dec2026 = iso.date(from: "2026-12-01T00:00:00Z")!
        let jan2027 = iso.date(from: "2027-01-01T00:00:00Z")!

        XCTAssertEqual(catalog.price(for: "claude-opus-4-6", at: nov2026)?.inputPerMillion, 5.0)
        XCTAssertEqual(catalog.price(for: "claude-opus-4-1", at: nov2026)?.inputPerMillion, 15.0)
        XCTAssertEqual(catalog.price(for: "claude-opus-4-20250514", at: nov2026)?.inputPerMillion, 15.0)
        XCTAssertEqual(catalog.price(for: "claude-opus-4-0", at: nov2026)?.inputPerMillion, 15.0)
        XCTAssertEqual(catalog.price(for: "claude-opus-5-5", at: nov2026)?.inputPerMillion, 4.0)

        XCTAssertEqual(catalog.price(for: "gpt-4.1-mini", at: nov2026)?.inputPerMillion, 0.40)
        XCTAssertEqual(catalog.price(for: "gpt-4.1-nano", at: nov2026)?.inputPerMillion, 0.10)
        XCTAssertEqual(catalog.price(for: "gpt-5-nano", at: nov2026)?.inputPerMillion, 0.05)
        XCTAssertEqual(catalog.price(for: "o3-mini", at: nov2026)?.inputPerMillion, 1.10)
        XCTAssertEqual(catalog.price(for: "models/gemini-2.5-pro", at: nov2026)?.inputPerMillion, 1.25)

        XCTAssertEqual(catalog.price(for: "gemini-4-carbon-medium", at: nov2026)?.inputPerMillion, 2.0)
        XCTAssertEqual(catalog.price(for: "gemini-4-carbon-medium", at: dec2026)?.inputPerMillion, 4.0)
        XCTAssertEqual(catalog.price(for: "gemini-3.8-flash", at: nov2026)?.inputPerMillion, 0.75)
        XCTAssertEqual(catalog.price(for: "gemini-3.8-flash", at: jan2027)?.inputPerMillion, 1.50)

        XCTAssertEqual(catalog.price(for: "Orchestrator (Neon-n)", at: nov2026)?.inputPerMillion, 3.0)
        XCTAssertTrue(PricingCatalog.isGeminiQuotaFamily("Orchestrator (Neon-n)"))
        XCTAssertFalse(PricingCatalog.isGeminiQuotaFamily("claude-opus-4-6"))

        let gpt54 = catalog.price(for: "gpt-5-4", at: nov2026)!
        XCTAssertEqual(gpt54.costUSD(uncachedInput: 100_000, cacheRead: 0, output: 0), 0.25, accuracy: 1e-6)
        XCTAssertEqual(gpt54.costUSD(uncachedInput: 300_000, cacheRead: 0, output: 0), 1.50, accuracy: 1e-6)
        XCTAssertEqual(gpt54.cacheSavingsUSD(cacheRead: 200_000, uncachedInput: 100_000), 0.90, accuracy: 1e-6)
    }

    func testUsageLedgerPersistenceFlushSchemaGuardAndBackfill() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("xctest-ledger-\(UUID().uuidString)", isDirectory: true)
        let brainDir = tmp.appendingPathComponent("brain", isDirectory: true)
        let convDir = brainDir.appendingPathComponent("conv-1/.system_generated/logs", isDirectory: true)
        let ledgerURL = tmp.appendingPathComponent("ledger.json")
        try fm.createDirectory(at: convDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let transcriptURL = convDir.appendingPathComponent("transcript.jsonl")
        let line1 = #"{"step_index":1,"type":"PLANNER_RESPONSE","created_at":"2026-11-25T06:00:00Z","model":"unknown","input_tokens":10000,"cache_read_tokens":50000,"output_tokens":1000}"# + "\n"
        try line1.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let index = TranscriptIndex(brainDirectory: brainDir, ledgerURL: ledgerURL)
        let first = index.refresh()
        XCTAssertEqual(first.records.count, 1)

        let line2 = #"{"step_index":2,"type":"PLANNER_RESPONSE","created_at":"2026-11-25T06:00:10Z","model":"gemini-4-neon-medium","input_tokens":2000,"cache_read_tokens":0,"output_tokens":200}"# + "\n"
        let fh = try FileHandle(forWritingTo: transcriptURL)
        try fh.seekToEnd()
        try fh.write(contentsOf: Data(line2.utf8))
        try fh.close()

        let second = index.refresh()
        XCTAssertEqual(second.records.count, 2)
        XCTAssertTrue(second.records.allSatisfy { $0.model == "gemini-4-neon-medium" })
        index.flushLedger()

        try fm.removeItem(at: brainDir.appendingPathComponent("conv-1"))
        let reloaded = TranscriptIndex(brainDirectory: brainDir, ledgerURL: ledgerURL).refresh()
        XCTAssertEqual(reloaded.records.count, 2)

        // Future version must stay untouched
        let futureURL = tmp.appendingPathComponent("future.json")
        let futurePayload = #"{"version":99,"conversations":{}}"#
        try futurePayload.write(to: futureURL, atomically: true, encoding: .utf8)
        let futureLedger = UsageLedger(fileURL: futureURL)
        _ = futureLedger.mergeAndPersist(liveByConversation: ["c": reloaded.records], now: Date())
        futureLedger.flush()
        XCTAssertEqual(try String(contentsOf: futureURL, encoding: .utf8), futurePayload)
    }

    func testQuotaEstimatorCalibrationSafetyAndRegimeShift() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("xctest-cal-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let calURL = tmp.appendingPathComponent("calibration.json")

        let thinned = QuotaEstimator.thinSamples([
            QuotaEstimator.Sample(u: 0.01, costUSD: 1, tokens: 100, requests: 1),
            QuotaEstimator.Sample(u: 0.02, costUSD: 2, tokens: 200, requests: 2),
            QuotaEstimator.Sample(u: 0.03, costUSD: 3, tokens: 300, requests: 3),
        ], limit: 2)
        XCTAssertEqual(thinned.count, 2)
        XCTAssertNil(QuotaEstimator.computeTheilSenSlope(samples: [
            QuotaEstimator.Sample(u: 0.05, costUSD: 10, tokens: 1000, requests: 1),
            QuotaEstimator.Sample(u: 0.05, costUSD: 20, tokens: 2000, requests: 2),
            QuotaEstimator.Sample(u: 0.05, costUSD: 30, tokens: 3000, requests: 3),
        ], livePoint: nil, minSpan: 0, minPairDu: 0, value: \.costUSD))

        let estimator = QuotaEstimator(fileURL: calURL)
        let reset1 = Date(timeIntervalSince1970: 1_800_000_000)
        _ = estimator.observeAndEstimateWeekly(accountKey: "a@test.com", resetTime: reset1, usedFraction: 0.01, spentCostUSD: 106, spentTokens: 1_000_000, requestCount: 3)
        _ = estimator.observeAndEstimateWeekly(accountKey: "a@test.com", resetTime: reset1, usedFraction: 0.03, spentCostUSD: 118, spentTokens: 3_000_000, requestCount: 6)
        let est1 = estimator.observeAndEstimateWeekly(accountKey: "a@test.com", resetTime: reset1, usedFraction: 0.05, spentCostUSD: 130, spentTokens: 5_000_000, requestCount: 12)
        XCTAssertEqual(est1?.fullCostUSD ?? 0, 600.0, accuracy: 1.0)

        _ = estimator.observeAndEstimateWeekly(accountKey: "a@test.com", resetTime: reset1, usedFraction: 0.10, spentCostUSD: 160, spentTokens: 10_000_000, requestCount: 20)
        let reloaded = QuotaEstimator(fileURL: calURL)
        let reset2 = reset1.addingTimeInterval(7 * 86_400)
        let warm = reloaded.observeAndEstimateWeekly(accountKey: "a@test.com", resetTime: reset2, usedFraction: 0.005, spentCostUSD: 3, spentTokens: 500_000, requestCount: 2)
        XCTAssertEqual(warm?.usedPriorOnly, true)
        XCTAssertEqual(warm?.fullCostUSD ?? 0, 600.0, accuracy: 5.0)

        let crossDevice = reloaded.observeAndEstimateWeekly(accountKey: "a@test.com", resetTime: reset2, usedFraction: 0.21, spentCostUSD: 6, spentTokens: 600_000, requestCount: 8)
        XCTAssertEqual(crossDevice?.isBlendedWithPrior, true)

        let reset3 = reset2.addingTimeInterval(7 * 86_400)
        _ = reloaded.observeAndEstimateWeekly(accountKey: "a@test.com", resetTime: reset3, usedFraction: 0.02, spentCostUSD: 30, spentTokens: 2_000_000, requestCount: 4)
        _ = reloaded.observeAndEstimateWeekly(accountKey: "a@test.com", resetTime: reset3, usedFraction: 0.04, spentCostUSD: 60, spentTokens: 4_000_000, requestCount: 8)
        let shifted = reloaded.observeAndEstimateWeekly(accountKey: "a@test.com", resetTime: reset3, usedFraction: 0.06, spentCostUSD: 90, spentTokens: 6_000_000, requestCount: 12)
        XCTAssertEqual(shifted?.isBlendedWithPrior, false)
        XCTAssertEqual(shifted?.fullCostUSD ?? 0, 1500.0, accuracy: 1.0)
    }

    func testMADOutlierQuarantineDropsSpikes() {
        let agg = UsageAggregator()
        let now = Date()
        var recs: [TranscriptRecord] = []
        for i in 0..<6 {
            recs.append(TranscriptRecord(
                timestamp: now.addingTimeInterval(Double(-200 + i * 10)),
                model: "gemini-4-neon-medium",
                inputTokens: 1000,
                cacheReadTokens: 0,
                outputTokens: 400,
                conversationId: "c1"
            ))
        }
        recs.append(TranscriptRecord(
            timestamp: now.addingTimeInterval(-148),
            model: "gemini-4-neon-medium",
            inputTokens: 1000,
            cacheReadTokens: 0,
            outputTokens: 780,
            conversationId: "c1"
        ))
        let report = agg.aggregate(records: recs, conversationCount: 1, now: now)
        let avg = report.outputSpeed.recent5mTokPerSec ?? 0
        XCTAssertGreaterThanOrEqual(avg, 35.0)
        XCTAssertLessThanOrEqual(avg, 45.0)
    }
}
