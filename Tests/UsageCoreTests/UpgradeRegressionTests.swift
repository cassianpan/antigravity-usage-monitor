import Foundation
import SQLite3
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

    func testSilentCLISyncerAuthFailureClassification() {
        let networkEOFFail = """
        I1127 16:39:24.641 keyring.go:64] keyringAuth: loaded token, expiry=2026-11-27 16:42:25 +0800 CST expired=false
        W1127 16:39:29.648 browser.go:256] token refresh failed due to network error: Post "https://oauth2.googleapis.com/token": EOF
        """
        if case .failed = SilentCLISyncer.classifyAuthProbeFailure(logText: networkEOFFail, sawAuthenticatingTimeout: true) {
            // expected
        } else {
            XCTFail("Transient network error during OAuth refresh must not return .authRequired")
        }

        let wakeTimeout = "I1126 19:03:28.164 keyring.go:64] keyringAuth: loaded token, expired=false"
        if case .failed = SilentCLISyncer.classifyAuthProbeFailure(logText: wakeTimeout, sawAuthenticatingTimeout: true) {
            // expected
        } else {
            XCTFail("Loaded keyring token timeout must not return .authRequired")
        }

        let revoked = #"E1128 browser.go:260] {"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#
        XCTAssertEqual(SilentCLISyncer.classifyAuthProbeFailure(logText: revoked, sawAuthenticatingTimeout: false), .authRequired)
        XCTAssertEqual(SilentCLISyncer.classifyAuthProbeFailure(logText: "", sawAuthenticatingTimeout: true), .authRequired)
    }

    func testRunningAgentDetectorTopLevelAndSubagentAggregation() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("xctest-agents-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let dbURL = tmp.appendingPathComponent("conversation_summaries.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        if let db {
            defer { sqlite3_close(db) }
            let sql = """
            CREATE TABLE conversation_summaries (
                conversation_id TEXT PRIMARY KEY,
                title TEXT NOT NULL DEFAULT '',
                status TEXT NOT NULL DEFAULT '',
                nesting_depth INTEGER NOT NULL DEFAULT 0,
                parent_conversation_id TEXT NOT NULL DEFAULT '',
                killed NUMERIC NOT NULL DEFAULT 0,
                last_modified_time DATETIME NOT NULL
            );
            INSERT INTO conversation_summaries VALUES ('top-1', 'Main Task A', 'CASCADE_RUN_STATUS_RUNNING', 0, '', 0, '2026-11-28 07:34:08.83818+00:00');
            INSERT INTO conversation_summaries VALUES ('sub-1', 'Subagent 1', 'CASCADE_RUN_STATUS_RUNNING', 1, 'top-1', 0, '2026-11-28 07:34:10.123456+00:00');
            INSERT INTO conversation_summaries VALUES ('sub-2', 'Nested Subagent', 'CASCADE_RUN_STATUS_RUNNING', 2, 'sub-1', 0, '2026-11-28 07:34:11.000+00:00');
            INSERT INTO conversation_summaries VALUES ('top-2', 'Main Task B', 'CASCADE_RUN_STATUS_RUNNING', 0, '', 0, '2026-11-28 07:30:00+00:00');
            INSERT INTO conversation_summaries VALUES ('killed-1', 'Killed Task', 'CASCADE_RUN_STATUS_RUNNING', 0, '', 1, '2026-11-28 07:34:00+00:00');
            INSERT INTO conversation_summaries VALUES ('stale-1', 'Crash Leftover', 'CASCADE_RUN_STATUS_RUNNING', 0, '', 0, '2026-11-27 00:00:00+00:00');
            """
            XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        }

        let now = try XCTUnwrap(RunningAgentDetector.parseSQLiteTimestamp("2026-11-28 07:35:00.000+00:00"))
        let detector = RunningAgentDetector(
            desktopDatabaseURL: dbURL,
            cliDatabaseURL: tmp.appendingPathComponent("missing-cli.db")
        )
        let live = detector.detect(desktopProcessAlive: true, cliProcessAlive: true, now: now)
        XCTAssertEqual(live.totalCount, 2)
        XCTAssertEqual(live.desktopAgents.first(where: { $0.id == "top-1" })?.subagentCount, 2)
        XCTAssertEqual(live.desktopAgents.first(where: { $0.id == "top-2" })?.subagentCount, 0)
        XCTAssertEqual(detector.detect(desktopProcessAlive: false, cliProcessAlive: false, now: now).totalCount, 0)
    }
}
