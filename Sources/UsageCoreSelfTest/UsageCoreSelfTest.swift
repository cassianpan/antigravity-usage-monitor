import Foundation
import UsageCore

@MainActor
private final class TestRunner {
    var passed = 0
    var failed = 0

    func check(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
        if condition() {
            passed += 1
        } else {
            failed += 1
            fputs("FAIL [\(file):\(line)] \(message)\n", stderr)
        }
    }

    func runCase(_ name: String, _ block: () throws -> Void) {
        do {
            try block()
            print("  ✓ \(name)")
        } catch {
            failed += 1
            fputs("  ✗ \(name) threw error: \(error)\n", stderr)
        }
    }
}

@MainActor
@main
struct UsageCoreSelfTest {
    static func main() {
        let runner = TestRunner()
        func check(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
            runner.check(condition(), message, file: file, line: line)
        }
        func runCase(_ name: String, _ block: () throws -> Void) {
            runner.runCase(name, block)
        }
        print("Running UsageCoreSelfTest (CommandLineTools-compatible test suite)...")

        runCase("S1: TranscriptParser parses valid lines and skips corrupted/non-token lines") {
            let jsonl = """
            {"step_index":0,"type":"USER_INPUT","created_at":"2026-11-23T06:35:24Z","content":"hi"}
            {broken json line
            {"step_index":1,"type":"PLANNER_RESPONSE","created_at":"2026-11-23T06:35:49Z","model":"gemini-2.5-pro","input_tokens":7677,"cache_read_tokens":22582,"output_tokens":587}
            {"step_index":2,"type":"PLANNER_RESPONSE","created_at":"2026-11-23T06:36:10.500Z","model":"gemini-4-neon-medium","input_tokens":5000,"cache_read_tokens":30000,"output_tokens":500}
            """
            let records = TranscriptParser().parseData(Data(jsonl.utf8), conversationId: "conv-1")
            check(records.count == 2, "Expected 2 valid records, got \(records.count)")
            check(records[0].totalInputTokens == 30259, "Expected totalInputTokens 30259")
            check(records[1].model == "gemini-4-neon-medium", "Expected second model gemini-4-neon-medium")
        }

        runCase("S1: TranscriptIndex incremental cursor reads appended lines without duplication") {
            let tempRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("usage-selftest-index-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: tempRoot) }

            let logsDir = tempRoot.appendingPathComponent("conv-a/.system_generated/logs", isDirectory: true)
            try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
            let fileURL = logsDir.appendingPathComponent("transcript.jsonl")

            let l1 = "{\"created_at\":\"2026-11-23T06:00:00Z\",\"model\":\"gemini-2.5-flash\",\"input_tokens\":1000,\"cache_read_tokens\":4000,\"output_tokens\":200}\n"
            try l1.write(to: fileURL, atomically: true, encoding: .utf8)

            let index = TranscriptIndex(brainDirectory: tempRoot)
            let p1 = index.refresh()
            check(p1.records.count == 1 && p1.conversationCount == 1, "Pass 1 count mismatch")

            let l2 = "{\"created_at\":\"2026-11-23T06:10:00Z\",\"type\":\"CHECKPOINT\",\"source\":\"SYSTEM\",\"input_tokens\":500,\"cache_read_tokens\":4500,\"output_tokens\":150}\n"
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(l2.utf8))
            try handle.close()

            let p2 = index.refresh()
            check(p2.records.count == 2 && p2.records[1].cacheReadTokens == 4500, "Pass 2 incremental append mismatch")
            check(p2.records[1].model == "gemini-2.5-flash", "CHECKPOINT without model should inherit conversation's lastKnownModel, got \(p2.records[1].model)")
        }

        runCase("S1: UsageAggregator computes cache hit rate, 14d trend, and flags unpriced models (D5)") {
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

            let report = UsageAggregator(pricing: .default, calendar: calendar)
                .aggregate(records: records, conversationCount: 2, now: now)

            check(report.today.uncachedInputTokens == 150_000, "Today uncached input mismatch")
            check(report.today.cacheReadTokens == 950_000, "Today cache read mismatch")
            check(abs(report.today.cacheHitRate - (950_000.0 / 1_100_000.0)) < 0.0001, "Cache hit rate mismatch")
            check(report.today.hasUnpricedModels == true, "Must flag unpriced model")
            check(report.today.unpricedModels == ["experimental-mystery-9b"], "Unpriced model list mismatch")
            check(report.dailyTrend.count == 14, "Expected 14-day trend")
            check(report.dailyTrend.last?.totalTokens == 1_115_000, "Last day total tokens mismatch")
        }

        runCase("S2: QuotaEvaluator computes Safe Line, staleness, and auto-resets after reset_time (D5)") {
            let now = ISO8601DateParser.parse("2026-11-23T12:00:00Z")!
            let capturedAt = now.addingTimeInterval(-45 * 60)
            let fiveHourReset = ISO8601DateParser.parse("2026-11-23T14:30:00Z")!
            let weeklyReset = ISO8601DateParser.parse("2026-11-28T12:00:00Z")!

            let snapshot = StatusLineSnapshot(
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
                planTier: "Pro",
                capturedAt: capturedAt
            )

            let report = QuotaEvaluator(staleThresholdSeconds: 30 * 60).evaluate(snapshot: snapshot, now: now)
            check(report.isStale == true, "45m snapshot should be stale")
            check(report.primaryFiveHour?.usedPercentageInt == 62, "5h used % should be 62")
            check(report.primaryFiveHour?.isOverPace == true, "5h should be over pace")
            check(report.primaryWeekly?.usedPercentageInt == 20, "Weekly used % should be 20")
            check(report.primaryWeekly?.isOverPace == false, "Weekly should be under pace")

            // Past reset_time -> auto zero
            let pastSnapshot = StatusLineSnapshot(
                quota: [
                    "gemini-5h": StatusLineQuotaBucket(
                        remainingFraction: 0.12,
                        resetTime: ISO8601DateFormatter().string(from: now.addingTimeInterval(-600)),
                        resetInSeconds: 0
                    ),
                ],
                capturedAt: now.addingTimeInterval(-3600)
            )
            let pastReport = QuotaEvaluator().evaluate(snapshot: pastSnapshot, now: now)
            check(pastReport.primaryFiveHour?.isResetElapsed == true, "Should mark reset elapsed")
            check(pastReport.primaryFiveHour?.usedPercentageInt == 0, "Should drop to 0% locally")

            // Inactive bucket with Unix epoch 1970-01-01 should NOT be marked as elapsed reset
            let inactiveSnapshot = StatusLineSnapshot(
                quota: [
                    "3p-5h": StatusLineQuotaBucket(
                        remainingFraction: 1.0,
                        resetTime: "1970-01-01T00:00:00Z",
                        resetInSeconds: 0
                    ),
                ],
                capturedAt: now
            )
            let inactiveReport = QuotaEvaluator().evaluate(snapshot: inactiveSnapshot, now: now)
            check(inactiveReport.primaryFiveHour?.resetTime == nil, "Epoch reset_time should normalize to nil")
            check(inactiveReport.primaryFiveHour?.isResetElapsed == false, "Unused bucket must not be marked reset elapsed")
            check(inactiveReport.primaryFiveHour?.remainingPercentageInt == 100, "Remaining % must equal 100 - used %")
        }

        runCase("S3: StatusLineBridgeInstaller direct install, script execution, and clean uninstall (D3)") {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agy-selftest-direct-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            let settingsURL = tempDir.appendingPathComponent("settings.json")
            try "{\"verbosity\": \"medium\"}\n".write(to: settingsURL, atomically: true, encoding: .utf8)

            let installer = StatusLineBridgeInstaller(cliConfigDirectory: tempDir)
            let installed = try installer.install()
            check(installed == .installedDirect, "Expected installedDirect")
            check(FileManager.default.fileExists(atPath: installer.backupSettingsURL.path), "Backup must exist")

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [installer.bridgeScriptURL.path]
            let inPipe = Pipe()
            process.standardInput = inPipe
            try process.run()
            inPipe.fileHandleForWriting.write(Data("{\"plan_tier\":\"Pro\",\"quota\":{\"gemini-weekly\":{\"remaining_fraction\":0.9}}}".utf8))
            try inPipe.fileHandleForWriting.close()
            process.waitUntilExit()
            check(process.terminationStatus == 0, "Bridge script exit 0")

            let loaded = QuotaEvaluator().loadSnapshot(from: installer.snapshotURL)
            check(loaded?.planTier == "Pro", "Snapshot planTier mismatch")

            try installer.uninstall()
            check(installer.status() == .notInstalled(existingCommand: nil), "Expected uninstalled")
            let restoredJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]
            check(restoredJSON?["verbosity"] as? String == "medium", "Unrelated setting preserved")
            check(restoredJSON?["statusLine"] == nil, "statusLine removed")
        }

        runCase("S3: StatusLineBridgeInstaller chains existing custom script and restores exact config (D3)") {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agy-selftest-chain-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            let customScript = tempDir.appendingPathComponent("my-custom.sh")
            try "#!/bin/sh\ncat >/dev/null\necho 'CUSTOM_STATUS_OK'\n".write(to: customScript, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: customScript.path)

            let settingsURL = tempDir.appendingPathComponent("settings.json")
            let initial: [String: Any] = [
                "statusLine": [
                    "type": "command",
                    "command": customScript.path,
                    "padding": 1,
                    "stack_with_default": false,
                ]
            ]
            try JSONSerialization.data(withJSONObject: initial, options: [.prettyPrinted]).write(to: settingsURL)

            let installer = StatusLineBridgeInstaller(cliConfigDirectory: tempDir)
            let installed = try installer.install()
            check(installed == .installedChained(originalCommand: customScript.path), "Expected chained install")

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [installer.bridgeScriptURL.path]
            let inPipe = Pipe()
            let outPipe = Pipe()
            process.standardInput = inPipe
            process.standardOutput = outPipe
            try process.run()
            inPipe.fileHandleForWriting.write(Data("{\"email\":\"test@example.com\"}".utf8))
            try inPipe.fileHandleForWriting.close()
            process.waitUntilExit()

            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            check(process.terminationStatus == 0 && out == "CUSTOM_STATUS_OK", "Chained stdout must be forwarded")
            check(QuotaEvaluator().loadSnapshot(from: installer.snapshotURL)?.email == "test@example.com", "Chained snapshot saved")

            try installer.uninstall()
            let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]
            let sl = restored?["statusLine"] as? [String: Any]
            check(sl?["command"] as? String == customScript.path && sl?["padding"] as? Int == 1, "Exact original statusLine restored")
        }

        runCase("S4: AppVersionComparator compares semantic versions accurately") {
            check(AppVersionComparator.isNewer("v0.1.3", than: "0.1.2") == true, "0.1.3 > 0.1.2")
            check(AppVersionComparator.isNewer("v0.2.0", than: "0.1.9") == true, "0.2.0 > 0.1.9")
            check(AppVersionComparator.isNewer("1.0.0", than: "0.9.9") == true, "1.0.0 > 0.9.9")
            check(AppVersionComparator.isNewer("v0.1.3", than: "0.1.3") == false, "0.1.3 == 0.1.3")
            check(AppVersionComparator.isNewer("v0.1.2", than: "0.1.3") == false, "0.1.2 < 0.1.3")
            check(AppVersionComparator.isNewer("v0.1.3-beta.1", than: "0.1.2") == true, "Pre-release suffix stripped")
        }

        print("Summary: \(runner.passed) assertions passed, \(runner.failed) failed.")
        if runner.failed > 0 {
            exit(1)
        }
    }
}
