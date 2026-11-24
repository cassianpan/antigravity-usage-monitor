import Darwin
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

@main
struct UsageCoreSelfTest {
    static func main() {
        let cliArgs = Array(CommandLine.arguments.dropFirst())
        if let first = cliArgs.first {
            if first == AgySyncWrapper.flag {
                Darwin.exit(AgySyncWrapper.run(arguments: Array(cliArgs.dropFirst())))
            }
            if first == CLILoginSupervisor.flag {
                Darwin.exit(CLILoginSupervisor.run(arguments: Array(cliArgs.dropFirst())))
            }
        }

        MainActor.assumeIsolated {
            runAllTests()
        }
    }

    @MainActor
    private static func runAllTests() {
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

            // First 10% (30 min) of 5-hour window is settling -> 1% usage must NOT trigger over-pace warning
            let settlingSnapshot = StatusLineSnapshot(
                quota: [
                    "gemini-5h": StatusLineQuotaBucket(
                        remainingFraction: 0.985,
                        resetTime: ISO8601DateFormatter().string(from: now.addingTimeInterval(5 * 3600 - 60)),
                        resetInSeconds: 17940
                    ),
                ],
                capturedAt: now
            )
            let settlingReport = QuotaEvaluator().evaluate(snapshot: settlingSnapshot, now: now)
            check(settlingReport.primaryFiveHour?.usedPercentageInt == 1, "Expected 1% used")
            check(settlingReport.primaryFiveHour?.isPaceSettling == true, "First 30 min of 5h window should be settling")
            check(settlingReport.primaryFiveHour?.isOverPace == false, "Settling window must not trigger over-pace")
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

        runCase("S4: AppVersionComparator & UpdateChecker parse release assets and verify SHA-256") {
            check(AppVersionComparator.isNewer("v0.1.3", than: "0.1.2") == true, "0.1.3 > 0.1.2")
            check(AppVersionComparator.isNewer("v0.2.0", than: "0.1.9") == true, "0.2.0 > 0.1.9")
            check(AppVersionComparator.isNewer("1.0.0", than: "0.9.9") == true, "1.0.0 > 0.9.9")
            check(AppVersionComparator.isNewer("v0.1.3", than: "0.1.3") == false, "0.1.3 == 0.1.3")
            check(AppVersionComparator.isNewer("v0.1.2", than: "0.1.3") == false, "0.1.2 < 0.1.3")
            check(AppVersionComparator.isNewer("v0.1.3-beta.1", than: "0.1.2") == true, "Pre-release suffix stripped")

            let sampleJSON = """
            {
              "tag_name": "v0.1.4",
              "html_url": "https://github.com/cassianpan/antigravity-usage-monitor/releases/tag/v0.1.4",
              "body": "## What's New\\n- In-app updater",
              "assets": [
                {"name": "AntigravityUsageMonitor-0.1.4-macOS-arm64.dmg", "browser_download_url": "https://example.com/app.dmg"},
                {"name": "AntigravityUsageMonitor-0.1.4-macOS-arm64.zip", "browser_download_url": "https://example.com/app.zip"},
                {"name": "SHA256SUMS.txt", "browser_download_url": "https://example.com/SHA256SUMS.txt"}
              ]
            }
            """
            let res = try UpdateChecker.decodeGitHubRelease(Data(sampleJSON.utf8), currentVersion: "0.1.3")
            if case .updateAvailable(let info) = res {
                check(info.version == "0.1.4", "Expected 0.1.4")
                check(info.zipURL?.absoluteString == "https://example.com/app.zip", "Expected macOS zip asset URL")
                check(info.checksumsURL?.absoluteString == "https://example.com/SHA256SUMS.txt", "Expected SHA256SUMS.txt URL")
                check(info.releaseNotes.contains("In-app updater"), "Expected release notes body")
            } else {
                check(false, "Expected .updateAvailable")
            }

            let payload = Data("hello-antigravity".utf8)
            let expected = UpdateChecker.sha256Hex(of: payload)
            let sumsText = """
            aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  AntigravityUsageMonitor-0.1.4-macOS-arm64.dmg
            \(expected)  AntigravityUsageMonitor-0.1.4-macOS-arm64.zip
            """
            let parsed = UpdateChecker.parseSHA256(from: sumsText, matchingFileName: "AntigravityUsageMonitor-0.1.4-macOS-arm64.zip")
            check(parsed == expected, "SHA256SUMS parser must match exact zip filename")
            check(UpdateChecker.verifySHA256(data: payload, expectedHex: expected) == true, "SHA-256 verify must succeed")
            check(UpdateChecker.verifySHA256(data: Data("tampered".utf8), expectedHex: expected) == false, "SHA-256 verify must reject tampered data")
        }

        runner.runCase("ProcessControl: writeMergedSettings preserves user fields") {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("aum-test-merge-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: dir) }

            let userSettings = dir.appendingPathComponent("user-settings.json")
            try #"{"modelProvider":"custom","trustedWorkspaces":["/tmp"],"statusLine":{"command":"old"}}"#.write(
                to: userSettings, atomically: true, encoding: .utf8
            )
            let probeScript = dir.appendingPathComponent("probe.sh")
            let mergedURL = try CLIProbeSupport.writeMergedSettings(
                probeScriptURL: probeScript,
                into: dir,
                userSettingsURL: userSettings
            )
            let data = try Data(contentsOf: mergedURL)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            check(obj?["modelProvider"] as? String == "custom", "Merged settings must preserve user modelProvider")
            let sl = obj?["statusLine"] as? [String: Any]
            check(sl?["command"] as? String == probeScript.path, "Merged settings must override statusLine.command")
        }

        runner.runCase("ProcessControl: AgySyncWrapper kills SIGHUP/SIGTERM-ignoring child on pipe EOF") {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("aum-test-wrapper-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: dir) }

            let pidFile = dir.appendingPathComponent("child.pid")
            let mockAgy = dir.appendingPathComponent("mock-agy.sh")
            let script = """
            #!/bin/sh
            trap '' HUP TERM
            echo $$ > '\(pidFile.path)'
            sleep 60
            """
            try script.write(to: mockAgy, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockAgy.path)

            let settingsFile = dir.appendingPathComponent("settings.json")
            try "{}".write(to: settingsFile, atomically: true, encoding: .utf8)

            var masterFD: Int32 = -1
            var slaveFD: Int32 = -1
            check(openpty(&masterFD, &slaveFD, nil, nil, nil) == 0, "openpty must succeed")
            var wdPipe: [Int32] = [-1, -1]
            var pidPipe: [Int32] = [-1, -1]
            check(pipe(&wdPipe) == 0 && pipe(&pidPipe) == 0, "pipes must succeed")

            let selfExec = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
            let wrapperPID = try PosixSpawn.spawn(
                PosixSpawn.Options(
                    executable: selfExec,
                    arguments: [
                        AgySyncWrapper.flag,
                        "--agy", mockAgy.path,
                        "--settings", settingsFile.path,
                        "--cwd", dir.path,
                        "--timeout", "10",
                        "--watchdog-fd", "3",
                        "--pid-fd", "4",
                    ],
                    dup2Map: [
                        (slaveFD, STDIN_FILENO),
                        (slaveFD, STDOUT_FILENO),
                        (slaveFD, STDERR_FILENO),
                        (wdPipe[0], 3),
                        (pidPipe[1], 4),
                    ],
                    setProcessGroup: true,
                    closeOnExecDefault: true
                )
            )
            _ = close(slaveFD); _ = close(wdPipe[0]); _ = close(pidPipe[1])

            var buf = [UInt8](repeating: 0, count: 64)
            let n = read(pidPipe[0], &buf, buf.count)
            _ = close(pidPipe[0])
            let childPID = pid_t(String(decoding: buf[0..<max(0, n)], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
            check(childPID > 0, "Wrapper must report child PID")

            // Wait briefly for mock script to enter trap + sleep.
            let waitStart = Date()
            while !fm.fileExists(atPath: pidFile.path) && Date().timeIntervalSince(waitStart) < 2.0 {
                usleep(20_000)
            }
            check(kill(childPID, 0) == 0, "Mock agy child must be alive before parent EOF")

            // Simulate parent SIGKILL by closing watchdog write FD without writing "G".
            _ = close(wdPipe[1])

            var st: Int32 = 0
            let killDeadline = Date().addingTimeInterval(1.5)
            var wrapperExited = false
            while Date() < killDeadline {
                if waitpid(wrapperPID, &st, WNOHANG) == wrapperPID {
                    wrapperExited = true
                    break
                }
                usleep(20_000)
            }
            _ = close(masterFD)

            let childDead = (kill(childPID, 0) != 0 && errno == ESRCH)
            check(wrapperExited, "Wrapper must exit promptly after parent pipe EOF")
            check(childDead, "SIGHUP/SIGTERM-ignoring child must be killed within 1.5s of pipe EOF")
        }

        runner.runCase("ProcessControl: CLILoginSupervisor kills SIGHUP-ignoring child on Terminal close (POLLHUP)") {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("aum-test-login-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: dir) }

            let pidFile = dir.appendingPathComponent("login-child.pid")
            let mockAgy = dir.appendingPathComponent("mock-login-agy.sh")
            let script = """
            #!/bin/sh
            trap '' HUP TERM
            echo $$ > '\(pidFile.path)'
            sleep 60
            """
            try script.write(to: mockAgy, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockAgy.path)

            var masterFD: Int32 = -1
            var slaveFD: Int32 = -1
            check(openpty(&masterFD, &slaveFD, nil, nil, nil) == 0, "openpty must succeed")

            let selfExec = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
            let snapOut = dir.appendingPathComponent("snap.json")
            let helperPID = try PosixSpawn.spawn(
                PosixSpawn.Options(
                    executable: selfExec,
                    arguments: [
                        CLILoginSupervisor.flag,
                        "--snapshot", snapOut.path,
                        "--lang", "zh",
                        "--agy", mockAgy.path,
                    ],
                    dup2Map: [
                        (slaveFD, STDIN_FILENO),
                        (slaveFD, STDOUT_FILENO),
                        (slaveFD, STDERR_FILENO),
                    ],
                    setProcessGroup: true,
                    closeOnExecDefault: true
                )
            )
            _ = close(slaveFD)

            // Wait for mock agy child to start and write its PID.
            let waitStart = Date()
            var mockPID: pid_t = -1
            while Date().timeIntervalSince(waitStart) < 2.5 {
                if let raw = try? String(contentsOf: pidFile, encoding: .utf8),
                   let parsed = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                   parsed > 0 {
                    mockPID = parsed
                    break
                }
                usleep(30_000)
            }
            check(mockPID > 0 && kill(mockPID, 0) == 0, "Mock login agy must be running before Terminal close")

            // Simulate user clicking red X on Terminal window by closing masterFD.
            _ = close(masterFD)

            var st: Int32 = 0
            let deadline = Date().addingTimeInterval(1.5)
            var helperExited = false
            while Date() < deadline {
                if waitpid(helperPID, &st, WNOHANG) == helperPID {
                    helperExited = true
                    break
                }
                usleep(25_000)
            }
            if !helperExited {
                _ = kill(helperPID, SIGKILL)
                _ = waitpid(helperPID, &st, 0)
            }
            if mockPID > 0 && kill(mockPID, 0) == 0 {
                _ = kill(mockPID, SIGKILL)
                check(false, "Mock login agy survived Terminal close")
            } else {
                check(true, "Mock login agy killed immediately on Terminal close")
            }
            check(helperExited, "CLILoginSupervisor must exit promptly on Terminal close")
        }

        runner.runCase("Formatting: USD/CNY grouped formatting and FXRates parser") {
            check(DisplayCurrency.allCases == [.usd, .cny], "Expected USD and CNY display currencies")
            check(UsageFormatter.money(1234.56, currency: .usd, ratePerUSD: 1.0) == "$1,234.56", "USD grouped formatting")
            check(UsageFormatter.money(100, currency: .cny, ratePerUSD: 7.2) == "¥720.00", "CNY conversion formatting")
            check(UsageFormatter.money(2000, currency: .cny, ratePerUSD: 7.2) == "¥14,400", "Amounts >= 10,000 omit decimals")

            let fxJSON = Data(#"{"amount":1.0,"base":"USD","date":"2026-11-24","rates":{"CNY":7.21,"EUR":0.93}}"#.utf8)
            let rates = try FXRates.perUSD(fromFrankfurter: fxJSON)
            check(rates["USD"] == 1.0, "FXRates must include USD=1.0")
            check(rates["CNY"] == 7.21 && rates["EUR"] == 0.93, "FXRates must parse Frankfurter payload")

            let shares = UsageFormatter.apportionedShares([50.0, 30.0, 20.0])
            check(shares == ["50%", "30%", "20%"], "Clean integer shares omit decimal")
            let tenths = UsageFormatter.apportionLargestRemainder([1.0, 1.0, 1.0], total: 1000)
            check(tenths.reduce(0, +) == 1000, "Apportioned tenths must sum to 1000 (100.0%)")
            let splitMoney = UsageFormatter.apportionedMoney(totalUSD: 10.0, partsUSD: [3.333, 3.333, 3.334], currency: .usd, ratePerUSD: 1.0)
            check(splitMoney == ["$3.33", "$3.33", "$3.34"], "Apportioned money must sum exactly to displayed total")
        }

        print("Summary: \(runner.passed) assertions passed, \(runner.failed) failed.")
        if runner.failed > 0 {
            exit(1)
        }
    }
}
