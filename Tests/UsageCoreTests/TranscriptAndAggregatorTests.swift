import Foundation
import XCTest
@testable import UsageCore

final class TranscriptAndAggregatorTests: XCTestCase {
    func testParsesValidAndSkipsInvalidLines() {
        let jsonl = """
        {"step_index":0,"type":"USER_INPUT","created_at":"2026-11-23T06:35:24Z","content":"hi"}
        {broken json line
        {"step_index":1,"type":"PLANNER_RESPONSE","created_at":"2026-11-23T06:35:49Z","model":"gemini-2.5-pro","input_tokens":7677,"cache_read_tokens":22582,"output_tokens":587}
        {"step_index":2,"type":"PLANNER_RESPONSE","created_at":"2026-11-23T06:36:10.500Z","model":"gemini-4-neon-medium","input_tokens":5000,"cache_read_tokens":30000,"output_tokens":500}
        """
        let parser = TranscriptParser()
        let records = parser.parseData(Data(jsonl.utf8), conversationId: "conv-1")

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].model, "gemini-2.5-pro")
        XCTAssertEqual(records[0].inputTokens, 7677)
        XCTAssertEqual(records[0].cacheReadTokens, 22582)
        XCTAssertEqual(records[0].outputTokens, 587)
        XCTAssertEqual(records[0].totalInputTokens, 30259)
        XCTAssertEqual(records[1].model, "gemini-4-neon-medium")
    }

    func testIncrementalIndexTracksOffset() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-index-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let logsDir = tempRoot
            .appendingPathComponent("conv-a/.system_generated/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let fileURL = logsDir.appendingPathComponent("transcript.jsonl")

        let firstLine = "{\"created_at\":\"2026-11-23T06:00:00Z\",\"model\":\"gemini-2.5-flash\",\"input_tokens\":1000,\"cache_read_tokens\":4000,\"output_tokens\":200}\n"
        try firstLine.write(to: fileURL, atomically: true, encoding: .utf8)

        let index = TranscriptIndex(brainDirectory: tempRoot)
        let firstPass = index.refresh()
        XCTAssertEqual(firstPass.records.count, 1)
        XCTAssertEqual(firstPass.conversationCount, 1)

        // Append a second line
        let secondLine = "{\"created_at\":\"2026-11-23T06:10:00Z\",\"model\":\"gemini-2.5-flash\",\"input_tokens\":500,\"cache_read_tokens\":4500,\"output_tokens\":150}\n"
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(secondLine.utf8))
        try handle.close()

        let secondPass = index.refresh()
        XCTAssertEqual(secondPass.records.count, 2)
        XCTAssertEqual(secondPass.records[1].cacheReadTokens, 4500)
    }

    func testAggregatesWindowsAndFlagsUnpricedModels() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = ISO8601DateParser.parse("2026-11-23T12:00:00Z")!

        let records: [TranscriptRecord] = [
            TranscriptRecord(
                timestamp: ISO8601DateParser.parse("2026-11-23T10:00:00Z")!,
                model: "gemini-2.5-pro",
                inputTokens: 100_000,
                cacheReadTokens: 900_000,
                outputTokens: 10_000,
                conversationId: "c1"
            ),
            TranscriptRecord(
                timestamp: ISO8601DateParser.parse("2026-11-23T11:00:00Z")!,
                model: "experimental-mystery-9b",
                inputTokens: 50_000,
                cacheReadTokens: 50_000,
                outputTokens: 5_000,
                conversationId: "c1"
            ),
            TranscriptRecord(
                timestamp: ISO8601DateParser.parse("2026-11-21T10:00:00Z")!,
                model: "claude-sonnet-4",
                inputTokens: 200_000,
                cacheReadTokens: 800_000,
                outputTokens: 20_000,
                conversationId: "c2"
            ),
        ]

        let aggregator = UsageAggregator(pricing: .default, calendar: calendar)
        let report = aggregator.aggregate(records: records, conversationCount: 2, now: now)

        XCTAssertEqual(report.today.uncachedInputTokens, 150_000)
        XCTAssertEqual(report.today.cacheReadTokens, 950_000)
        XCTAssertEqual(report.today.outputTokens, 15_000)
        XCTAssertEqual(report.today.cacheHitRate, 950_000.0 / 1_100_000.0, accuracy: 0.0001)
        XCTAssertTrue(report.today.hasUnpricedModels)
        XCTAssertEqual(report.today.unpricedModels, ["experimental-mystery-9b"])
        XCTAssertGreaterThan(report.today.estimatedCostUSD, 0)
        XCTAssertGreaterThan(report.today.cacheSavingsUSD, 0)

        XCTAssertEqual(report.week.requestCount, 3)
        XCTAssertEqual(report.byModel.count, 3)
        XCTAssertEqual(report.dailyTrend.count, 14)
        XCTAssertEqual(report.dailyTrend.last?.dayKey, "2026-11-23")
        XCTAssertEqual(report.dailyTrend.last?.totalTokens, 1_115_000)
    }
}
