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

        runner.runCase("PricingCatalog: 2026/2027 date-effective pricing, Opus 4.6/5.5, child models, aliases, and long-context step-up") {
            let catalog = PricingCatalog.default
            let iso = ISO8601DateFormatter()
            let nov2026 = iso.date(from: "2026-11-25T00:00:00Z")!
            let dec2026 = iso.date(from: "2026-12-01T00:00:00Z")!
            let jan2027 = iso.date(from: "2027-01-01T00:00:00Z")!

            let opus46 = catalog.price(for: "claude-opus-4-6", at: nov2026)
            check(opus46?.inputPerMillion == 5.0 && opus46?.outputPerMillion == 25.0, "Claude Opus 4.6 must be $5/$25")
            let opus41 = catalog.price(for: "claude-opus-4-1", at: nov2026)
            check(opus41?.inputPerMillion == 15.0 && opus41?.outputPerMillion == 75.0, "Legacy Claude Opus 4.1 must remain $15/$75")
            let opus4Dated = catalog.price(for: "claude-opus-4-20250514", at: nov2026)
            check(opus4Dated?.inputPerMillion == 15.0 && opus4Dated?.outputPerMillion == 75.0, "Dated Claude Opus 4 must remain $15/$75")
            let opus40 = catalog.price(for: "claude-opus-4-0", at: nov2026)
            check(opus40?.inputPerMillion == 15.0 && opus40?.outputPerMillion == 75.0, "Claude Opus 4.0 must remain $15/$75")
            let opus55 = catalog.price(for: "claude-opus-5-5", at: nov2026)
            check(opus55?.inputPerMillion == 4.0 && opus55?.outputPerMillion == 20.0, "Claude Opus 5.5 must be $4/$20")

            check(catalog.price(for: "gpt-4.1-mini", at: nov2026)?.inputPerMillion == 0.40, "gpt-4.1-mini must not match gpt-4.1 parent price")
            check(catalog.price(for: "gpt-4.1-nano", at: nov2026)?.inputPerMillion == 0.10, "gpt-4.1-nano must be $0.10/1M")
            check(catalog.price(for: "gpt-5-nano", at: nov2026)?.inputPerMillion == 0.05, "gpt-5-nano must be $0.05/1M")
            check(catalog.price(for: "o3-mini", at: nov2026)?.inputPerMillion == 1.10, "o3-mini must be $1.10/1M")
            check(catalog.price(for: "models/gemini-2.5-pro", at: nov2026)?.inputPerMillion == 1.25, "models/ prefix must strip cleanly")

            let carbonNov = catalog.price(for: "gemini-4-carbon-medium", at: nov2026)
            let carbonDec = catalog.price(for: "gemini-4-carbon-medium", at: dec2026)
            check(carbonNov?.inputPerMillion == 2.0 && carbonNov?.outputPerMillion == 10.0, "Gemini 4 Carbon intro price before Dec 1")
            check(carbonDec?.inputPerMillion == 4.0 && carbonDec?.outputPerMillion == 20.0, "Gemini 4 Carbon price steps up on Dec 1")

            let flashNov = catalog.price(for: "gemini-3.8-flash", at: nov2026)
            let flashJan = catalog.price(for: "gemini-3.8-flash", at: jan2027)
            check(flashNov?.inputPerMillion == 0.75 && flashNov?.outputPerMillion == 3.75, "Gemini 3.8 Flash intro price before Jan 1, 2027")
            check(flashJan?.inputPerMillion == 1.50 && flashJan?.outputPerMillion == 7.50, "Gemini 3.8 Flash price steps up on Jan 1, 2027")

            let orchNeon = catalog.price(for: "Orchestrator (Neon)", at: nov2026)
            let orchNeonN = catalog.price(for: "Orchestrator (Neon-n)", at: nov2026)
            check(orchNeon?.inputPerMillion == 3.0 && orchNeon?.outputPerMillion == 15.0, "Orchestrator (Neon) must resolve to Gemini 4 Neon")
            check(orchNeonN?.inputPerMillion == 3.0 && orchNeonN?.outputPerMillion == 15.0, "Orchestrator (Neon-n) must resolve to Gemini 4 Neon")
            check(PricingCatalog.isGeminiQuotaFamily("Orchestrator (Neon-n)"), "Orchestrator (Neon-n) belongs to Gemini quota family")
            check(!PricingCatalog.isGeminiQuotaFamily("claude-opus-4-6"), "Claude Opus does not belong to Gemini quota family")

            let gpt54 = catalog.price(for: "gpt-5-4", at: nov2026)!
            let shortCost = gpt54.costUSD(uncachedInput: 100_000, cacheRead: 0, output: 0)
            let longCost = gpt54.costUSD(uncachedInput: 300_000, cacheRead: 0, output: 0)
            let longSavings = gpt54.cacheSavingsUSD(cacheRead: 200_000, uncachedInput: 100_000)
            check(abs(shortCost - 0.25) < 1e-6, "GPT 5.4 <=272K input must bill at $2.50/1M")
            check(abs(longCost - 1.50) < 1e-6, "GPT 5.4 >272K input must step up to $5.00/1M")
            check(abs(longSavings - 0.90) < 1e-6, "GPT 5.4 >272K cache savings must use stepped-up input rate ($5.00 - $0.50 = $4.50/1M)")
        }

        runner.runCase("UsageLedger & TranscriptIndex: deletion survival, throttle flush, schema guard, corrupt backup, backfill, symlink skip") {
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory.appendingPathComponent("aum-test-ledger-\(UUID().uuidString)", isDirectory: true)
            let brainDir = tmp.appendingPathComponent("brain", isDirectory: true)
            let convDir = brainDir.appendingPathComponent("conv-deleted-test/.system_generated/logs", isDirectory: true)
            let ledgerURL = tmp.appendingPathComponent("ledger.json")
            try fm.createDirectory(at: convDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }

            let transcriptURL = convDir.appendingPathComponent("transcript.jsonl")
            let line1 = #"{"step_index":1,"type":"PLANNER_RESPONSE","created_at":"2026-11-25T06:00:00Z","model":"unknown","input_tokens":10000,"cache_read_tokens":50000,"output_tokens":1000}"# + "\n"
            try line1.write(to: transcriptURL, atomically: true, encoding: .utf8)

            // Also place a symlinked transcript that must be ignored by TranscriptIndex.
            let secretFile = tmp.appendingPathComponent("secret.jsonl")
            let secretLine = #"{"step_index":1,"type":"PLANNER_RESPONSE","created_at":"2026-11-25T06:00:00Z","model":"gemini-4-neon-medium","input_tokens":999999,"cache_read_tokens":0,"output_tokens":1}"# + "\n"
            try secretLine.write(to: secretFile, atomically: true, encoding: .utf8)
            let symlinkConvDir = brainDir.appendingPathComponent("conv-symlink/.system_generated/logs", isDirectory: true)
            try fm.createDirectory(at: symlinkConvDir, withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: symlinkConvDir.appendingPathComponent("transcript.jsonl"), withDestinationURL: secretFile)

            let index = TranscriptIndex(brainDirectory: brainDir, ledgerURL: ledgerURL)
            let first = index.refresh()
            check(first.records.count == 1 && first.conversationCount == 1, "Initial scan must load 1 record and skip symlink")
            check(fm.fileExists(atPath: ledgerURL.path), "Ledger file must be flushed to disk")

            let attrs = try fm.attributesOfItem(atPath: ledgerURL.path)
            let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
            check((perms & 0o777) == 0o600, "Ledger file must have 0600 permissions (got \(String(perms & 0o777, radix: 8)))")

            // Append second line within < 2s throttle window with real model -> must backfill unknown AND flush cleanly on flushLedger().
            let line2 = #"{"step_index":2,"type":"PLANNER_RESPONSE","created_at":"2026-11-25T06:00:10Z","model":"gemini-4-neon-medium","input_tokens":2000,"cache_read_tokens":0,"output_tokens":200}"# + "\n"
            let fh = try FileHandle(forWritingTo: transcriptURL)
            try fh.seekToEnd()
            try fh.write(contentsOf: Data(line2.utf8))
            try fh.close()

            let second = index.refresh()
            check(second.records.count == 2, "Incremental refresh must read appended record")
            check(second.records.allSatisfy { $0.model == "gemini-4-neon-medium" }, "Incremental refresh must backfill leading unknown model")
            index.flushLedger()

            // Delete the conversation directory and reload from a brand new TranscriptIndex instance.
            try fm.removeItem(at: brainDir.appendingPathComponent("conv-deleted-test"))
            let reloaded = TranscriptIndex(brainDirectory: brainDir, ledgerURL: ledgerURL)
            let afterDelete = reloaded.refresh()
            check(afterDelete.records.count == 2 && afterDelete.conversationCount == 1, "Throttled update flushed before delete must survive reload")
            check(afterDelete.records.first?.inputTokens == 10000, "Preserved ledger record must retain exact token counts")

            // Future schema version protection: version 99 must not be overwritten.
            let futureURL = tmp.appendingPathComponent("future-ledger.json")
            let futurePayload = #"{"version":99,"conversations":{}}"#
            try futurePayload.write(to: futureURL, atomically: true, encoding: .utf8)
            let futureLedger = UsageLedger(fileURL: futureURL)
            _ = futureLedger.mergeAndPersist(liveByConversation: ["c1": afterDelete.records], now: Date())
            futureLedger.flush()
            let futureAfter = try String(contentsOf: futureURL, encoding: .utf8)
            check(futureAfter == futurePayload, "Future ledger schema version must remain read-only on disk")

            // Corrupt JSON backup protection.
            let corruptURL = tmp.appendingPathComponent("corrupt-ledger.json")
            try "{not valid json".write(to: corruptURL, atomically: true, encoding: .utf8)
            let corruptLedger = UsageLedger(fileURL: corruptURL)
            _ = corruptLedger.mergeAndPersist(liveByConversation: ["c1": afterDelete.records], now: Date())
            let dirEntries = (try? fm.contentsOfDirectory(atPath: tmp.path)) ?? []
            check(dirEntries.contains(where: { $0.hasPrefix("corrupt-ledger.json.corrupt-") && $0.hasSuffix(".bak") }), "Corrupt ledger must be backed up before rebuild")
        }

        runner.runCase("QuotaEstimator: Theil-Sen slope, persistence, thinning, stale-reset guard, and multi-point regime-shift") {
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory.appendingPathComponent("aum-test-cal-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }
            let calURL = tmp.appendingPathComponent("calibration.json")

            // Edge cases: thinSamples(limit: 2) and minPairDu <= 0 must never crash or yield inf.
            let tinySamples = [
                QuotaEstimator.Sample(u: 0.01, costUSD: 1, tokens: 100, requests: 1),
                QuotaEstimator.Sample(u: 0.02, costUSD: 2, tokens: 200, requests: 2),
                QuotaEstimator.Sample(u: 0.03, costUSD: 3, tokens: 300, requests: 3),
            ]
            let thinned2 = QuotaEstimator.thinSamples(tinySamples, limit: 2)
            check(thinned2.count == 2 && thinned2.first?.u == 0.01 && thinned2.last?.u == 0.03, "thinSamples(limit: 2) must safely preserve endpoints")
            let zeroDuSamples = [
                QuotaEstimator.Sample(u: 0.05, costUSD: 10, tokens: 1000, requests: 1),
                QuotaEstimator.Sample(u: 0.05, costUSD: 20, tokens: 2000, requests: 2),
                QuotaEstimator.Sample(u: 0.05, costUSD: 30, tokens: 3000, requests: 3),
            ]
            check(QuotaEstimator.computeTheilSenSlope(samples: zeroDuSamples, livePoint: nil, minSpan: 0, minPairDu: 0, value: \.costUSD) == nil, "Zero du pairs must never produce +inf")

            let estimator = QuotaEstimator(fileURL: calURL)
            let reset1 = Date(timeIntervalSince1970: 1_800_000_000)

            // Cross-device offset = +$100, true local slope = $600 per 100% quota.
            _ = estimator.observeAndEstimateWeekly(accountKey: "a@test.com", resetTime: reset1, usedFraction: 0.01, spentCostUSD: 106, spentTokens: 1_000_000, requestCount: 3)
            _ = estimator.observeAndEstimateWeekly(accountKey: "a@test.com", resetTime: reset1, usedFraction: 0.03, spentCostUSD: 118, spentTokens: 3_000_000, requestCount: 6)
            let est1 = estimator.observeAndEstimateWeekly(accountKey: "a@test.com", resetTime: reset1, usedFraction: 0.05, spentCostUSD: 130, spentTokens: 5_000_000, requestCount: 12)
            check(est1 != nil, "Should produce estimate once >= 3 samples spanning >= 2%")
            check(abs((est1?.fullCostUSD ?? 0) - 600.0) < 1.0, "Theil-Sen slope must recover $600 full capacity despite $100 offset")

            // Advance to >= 8% then roll into next weekly cycle to populate prior & verify disk persistence + 0600 perms.
            _ = estimator.observeAndEstimateWeekly(accountKey: "a@test.com", resetTime: reset1, usedFraction: 0.10, spentCostUSD: 160, spentTokens: 10_000_000, requestCount: 20)
            let calAttrs = try fm.attributesOfItem(atPath: calURL.path)
            let calPerms = (calAttrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
            check((calPerms & 0o777) == 0o600, "Calibration file must have 0600 permissions")

            let reloadedEstimator = QuotaEstimator(fileURL: calURL)
            let reset2 = reset1.addingTimeInterval(7 * 86_400)
            let warmStart = reloadedEstimator.observeAndEstimateWeekly(accountKey: "a@test.com", resetTime: reset2, usedFraction: 0.005, spentCostUSD: 3, spentTokens: 500_000, requestCount: 2)
            check(warmStart?.usedPriorOnly == true && abs((warmStart?.fullCostUSD ?? 0) - 600.0) < 5.0, "Reloaded estimator must preserve prior ~$600 across restarts")

            // Stale out-of-order older resetEpoch must be ignored (no backward cycle roll).
            let staleCall = reloadedEstimator.observeAndEstimateWeekly(accountKey: "a@test.com", resetTime: reset1, usedFraction: 0.50, spentCostUSD: 300, spentTokens: 30_000_000, requestCount: 50)
            check(staleCall == nil || abs((staleCall?.fullCostUSD ?? 0) - 600.0) < 5.0, "Out-of-order older resetEpoch must not corrupt current cycle")

            // Single-point cross-device offset in reset2 (u = 0.21, local cost = $6) must NOT falsely trigger regime shift.
            let crossDeviceSingle = reloadedEstimator.observeAndEstimateWeekly(accountKey: "a@test.com", resetTime: reset2, usedFraction: 0.21, spentCostUSD: 6, spentTokens: 600_000, requestCount: 8)
            check(crossDeviceSingle?.isBlendedWithPrior == true && (crossDeviceSingle?.fullCostUSD ?? 0) > 200.0, "Single-point cross-device offset must stay anchored to prior, not collapse to $28")

            // Genuine multi-point regime shift in reset3: official quota doubles to $1,500 full capacity (ratio 2.5x > 1.45x).
            let reset3 = reset2.addingTimeInterval(7 * 86_400)
            _ = reloadedEstimator.observeAndEstimateWeekly(accountKey: "a@test.com", resetTime: reset3, usedFraction: 0.02, spentCostUSD: 30, spentTokens: 2_000_000, requestCount: 4)
            _ = reloadedEstimator.observeAndEstimateWeekly(accountKey: "a@test.com", resetTime: reset3, usedFraction: 0.04, spentCostUSD: 60, spentTokens: 4_000_000, requestCount: 8)
            let shifted = reloadedEstimator.observeAndEstimateWeekly(accountKey: "a@test.com", resetTime: reset3, usedFraction: 0.06, spentCostUSD: 90, spentTokens: 6_000_000, requestCount: 12)
            check(shifted?.isBlendedWithPrior == false && abs((shifted?.fullCostUSD ?? 0) - 1500.0) < 1.0, "Multi-point regime shift >1.45x must bypass stale prior")
        }

        runner.runCase("StatusLineBridgeInstaller: hardened script exits 0 even if chained command fails and sets 0600 snapshot") {
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory.appendingPathComponent("aum-test-bridge-fail-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }

            let failingCustom = tmp.appendingPathComponent("failing.sh")
            try "#!/bin/sh\ncat >/dev/null\necho 'PARTIAL_OUT'\nexit 42\n".write(to: failingCustom, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: failingCustom.path)

            let settings: [String: Any] = ["statusLine": ["type": "command", "command": failingCustom.path]]
            let settingsData = try JSONSerialization.data(withJSONObject: settings)
            try settingsData.write(to: tmp.appendingPathComponent("settings.json"))

            let installer = StatusLineBridgeInstaller(cliConfigDirectory: tmp)
            _ = try installer.install()

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = [installer.bridgeScriptURL.path]
            let inPipe = Pipe()
            let outPipe = Pipe()
            proc.standardInput = inPipe
            proc.standardOutput = outPipe
            try proc.run()
            inPipe.fileHandleForWriting.write(Data(#"{"email":"safe@test.com"}"#.utf8))
            try inPipe.fileHandleForWriting.close()
            proc.waitUntilExit()

            let outText = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            check(proc.terminationStatus == 0, "Bridge script must always exit 0 even when chained command fails")
            check(outText == "PARTIAL_OUT", "Chained command must still receive stdin and produce stdout")
            check(QuotaEvaluator().loadSnapshot(from: installer.snapshotURL)?.email == "safe@test.com", "Snapshot must be atomically written")
            let snapAttrs = try fm.attributesOfItem(atPath: installer.snapshotURL.path)
            let snapPerms = (snapAttrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
            check((snapPerms & 0o777) == 0o600, "Snapshot created by bridge script must have 0600 permissions")
        }

        runner.runCase("UsageAggregator: MAD outlier quarantine drops bursty TPS spikes") {
            let agg = UsageAggregator()
            let now = Date()
            var recs: [TranscriptRecord] = []
            // 6 normal turns: 400 output tokens / 10s = 40 tok/s
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
            // 1 absurd outlier turn: 780 output tokens / 2s = 390 tok/s (> 8 * 40 = 320)
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
            check(avg >= 35.0 && avg <= 45.0, "MAD quarantine must exclude 390 tok/s spike and keep ~40 tok/s average (got \(avg))")
        }

        print("Summary: \(runner.passed) assertions passed, \(runner.failed) failed.")
        if runner.failed > 0 {
            exit(1)
        }
    }
}
