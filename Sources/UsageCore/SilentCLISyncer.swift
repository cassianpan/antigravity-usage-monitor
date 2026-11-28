import Darwin
import Foundation

public enum SilentSyncResult: Sendable, Equatable {
    case synced(StatusLineSnapshot)
    case authRequired
    case cliNotFound
    case failed(String)
}

/// Runs `agy --settings <mergedTempSettings.json>` silently inside a short-lived PTY
/// guarded by a kqueue Pipe-EOF wrapper (or POSIX `/bin/sh` pipe-EOF fallback in tests),
/// guaranteeing zero orphan `agy` processes even if the parent app receives `SIGKILL`.
public actor SilentCLISyncer {
    private let snapshotURL: URL
    private let evaluator: QuotaEvaluator
    private let wrapperExecutableURL: URL?
    private var isRunning = false
    private var activeChildPID: Int32?

    public init(
        snapshotURL: URL = StatusLineBridgeInstaller.defaultCLIConfigDirectory
            .appendingPathComponent("usage-monitor-snapshot.json"),
        evaluator: QuotaEvaluator = QuotaEvaluator(),
        wrapperExecutableURL: URL? = SilentCLISyncer.resolveAppExecutableURL()
    ) {
        self.snapshotURL = snapshotURL
        self.evaluator = evaluator
        self.wrapperExecutableURL = wrapperExecutableURL
    }

    public nonisolated static func resolveAppExecutableURL() -> URL? {
        if let url = Bundle.main.executableURL,
           url.lastPathComponent == "AntigravityUsageMonitor",
           FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        if let arg0 = CommandLine.arguments.first {
            let url = URL(fileURLWithPath: arg0).standardizedFileURL
            if url.lastPathComponent == "AntigravityUsageMonitor",
               FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    public nonisolated static func locateAgyBinary() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/agy",
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
            "/Applications/Antigravity.app/Contents/Resources/app/bin/agy",
            "\(home)/.npm-global/bin/agy",
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            for dir in envPath.split(separator: ":") {
                let candidate = "\(dir)/agy"
                if fm.isExecutableFile(atPath: candidate) {
                    return URL(fileURLWithPath: candidate)
                }
            }
        }
        return nil
    }

    public func currentChildPID() -> Int32? {
        activeChildPID
    }

    public func sync(
        timeoutSeconds: TimeInterval = 12.0,
        agyBinaryOverride: URL? = nil
    ) async -> SilentSyncResult {
        guard !isRunning else {
            return .failed("Sync already in progress")
        }
        guard let agyURL = agyBinaryOverride ?? Self.locateAgyBinary() else {
            return .cliNotFound
        }

        isRunning = true
        defer {
            isRunning = false
            activeChildPID = nil
        }

        let fm = FileManager.default
        let ownerPID = getpid()
        let tempDir = fm.temporaryDirectory.appendingPathComponent(
            "agy-silent-sync-\(ownerPID)-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            return .failed("无法创建临时目录：\(error.localizedDescription)")
        }
        defer { try? fm.removeItem(at: tempDir) }

        let tempSnapshotURL = tempDir.appendingPathComponent("probe.json")
        let tempLogURL = tempDir.appendingPathComponent("probe.log")
        let settingsURL: URL
        do {
            let probeScriptURL = try CLIProbeSupport.writeProbeScript(outputURL: tempSnapshotURL, into: tempDir)
            settingsURL = try CLIProbeSupport.writeMergedSettings(probeScriptURL: probeScriptURL, into: tempDir)
        } catch {
            return .failed("无法准备临时探测配置：\(error.localizedDescription)")
        }

        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        var winSize = winsize(ws_row: 30, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&masterFD, &slaveFD, nil, nil, &winSize) == 0 else {
            return .failed("无法分配后台伪终端 (openpty)")
        }

        let masterFlags = fcntl(masterFD, F_GETFL)
        if masterFlags >= 0 {
            _ = fcntl(masterFD, F_SETFL, masterFlags | O_NONBLOCK)
        }

        var wdPipe: [Int32] = [-1, -1]
        guard pipe(&wdPipe) == 0 else {
            _ = close(slaveFD)
            _ = close(masterFD)
            return .failed("无法创建看门狗管道")
        }
        let wdReadFD = wdPipe[0]
        var wdWriteFD = wdPipe[1]

        var wrapperPID: pid_t = -1
        var agyPID: pid_t = -1
        let usingNativeWrapper: Bool

        if let wrapperURL = wrapperExecutableURL, fm.isExecutableFile(atPath: wrapperURL.path) {
            usingNativeWrapper = true
            var pidPipe: [Int32] = [-1, -1]
            guard pipe(&pidPipe) == 0 else {
                _ = close(wdReadFD); _ = close(wdWriteFD)
                _ = close(slaveFD); _ = close(masterFD)
                return .failed("无法创建 PID 通道")
            }
            let pidReadFD = pidPipe[0]
            let pidWriteFD = pidPipe[1]

            do {
                wrapperPID = try PosixSpawn.spawn(
                    PosixSpawn.Options(
                        executable: wrapperURL.path,
                        arguments: [
                            AgySyncWrapper.flag,
                            "--agy", agyURL.path,
                            "--settings", settingsURL.path,
                            "--log-file", tempLogURL.path,
                            "--cwd", tempDir.path,
                            "--timeout", String(format: "%.1f", timeoutSeconds),
                            "--watchdog-fd", "3",
                            "--pid-fd", "4",
                        ],
                        environment: CLIProbeSupport.defaultEnvironment(),
                        dup2Map: [
                            (slaveFD, STDIN_FILENO),
                            (slaveFD, STDOUT_FILENO),
                            (slaveFD, STDERR_FILENO),
                            (wdReadFD, 3),
                            (pidWriteFD, 4),
                        ],
                        setProcessGroup: true,
                        startSuspended: false,
                        closeOnExecDefault: true
                    )
                )
            } catch {
                _ = close(pidReadFD); _ = close(pidWriteFD)
                _ = close(wdReadFD); _ = close(wdWriteFD)
                _ = close(slaveFD); _ = close(masterFD)
                return .failed("启动同步监督器失败：\(error.localizedDescription)")
            }

            _ = close(slaveFD)
            _ = close(wdReadFD)
            _ = close(pidWriteFD)

            ActiveSyncProcessRegistry.shared.register(
                wrapperPID: wrapperPID,
                agyPGID: nil,
                watchdogWriteFD: wdWriteFD
            )

            // Read child agy PID from pidReadFD (bounded wait).
            if let reportedPID = Self.readPIDLine(from: pidReadFD, timeoutMs: 2000) {
                agyPID = reportedPID
                ActiveSyncProcessRegistry.shared.updateAgyPGID(wrapperPID: wrapperPID, agyPGID: agyPID)
            }
            _ = close(pidReadFD)
        } else {
            // Library / unit-test fallback: `/bin/sh` blocks on watchdog pipe EOF and kills -agyPGID.
            usingNativeWrapper = false
            do {
                wrapperPID = try PosixSpawn.spawn(
                    PosixSpawn.Options(
                        executable: "/bin/sh",
                        arguments: [
                            "-c",
                            "IFS= read -r pgid || exit 0; IFS= read -r _ || true; /bin/kill -KILL -\"$pgid\" 2>/dev/null || true",
                        ],
                        environment: CLIProbeSupport.defaultEnvironment(),
                        dup2Map: [(wdReadFD, STDIN_FILENO)],
                        setProcessGroup: true,
                        startSuspended: false,
                        closeOnExecDefault: true
                    )
                )

                var env = CLIProbeSupport.defaultEnvironment()
                env["TERM"] = "xterm-256color"
                agyPID = try PosixSpawn.spawn(
                    PosixSpawn.Options(
                        executable: agyURL.path,
                        arguments: ["--settings", settingsURL.path, "--log-file", tempLogURL.path],
                        environment: env,
                        dup2Map: [
                            (slaveFD, STDIN_FILENO),
                            (slaveFD, STDOUT_FILENO),
                            (slaveFD, STDERR_FILENO),
                        ],
                        setProcessGroup: true,
                        startSuspended: false,
                        closeOnExecDefault: true
                    )
                )
            } catch {
                if wrapperPID > 0 { _ = kill(wrapperPID, SIGKILL) }
                _ = close(wdReadFD); _ = close(wdWriteFD)
                _ = close(slaveFD); _ = close(masterFD)
                return .failed("启动 agy 失败：\(error.localizedDescription)")
            }

            _ = close(slaveFD)
            _ = close(wdReadFD)

            let line = "\(agyPID)\n"
            line.withCString { cstr in
                _ = write(wdWriteFD, cstr, strlen(cstr))
            }

            ActiveSyncProcessRegistry.shared.register(
                wrapperPID: wrapperPID,
                agyPGID: agyPID,
                watchdogWriteFD: wdWriteFD
            )
        }

        activeChildPID = agyPID > 0 ? agyPID : wrapperPID

        var didCleanupChild = false
        func stopChildIfNeeded() {
            guard !didCleanupChild else { return }
            didCleanupChild = true
            if usingNativeWrapper {
                // Signal graceful stop ("G") then close pipe.
                if wdWriteFD >= 0 {
                    var marker: UInt8 = UInt8(ascii: "G")
                    _ = write(wdWriteFD, &marker, 1)
                    _ = close(wdWriteFD)
                    wdWriteFD = -1
                }
                let reapDeadline = Date().addingTimeInterval(0.35)
                var st: Int32 = 0
                var exited = false
                while Date() < reapDeadline {
                    if waitpid(wrapperPID, &st, WNOHANG) == wrapperPID {
                        exited = true
                        break
                    }
                    usleep(20_000)
                }
                if !exited {
                    if agyPID > 0 { _ = kill(-agyPID, SIGKILL) }
                    _ = kill(wrapperPID, SIGKILL)
                    _ = waitpid(wrapperPID, &st, 0)
                } else if agyPID > 0 {
                    _ = kill(-agyPID, SIGKILL)
                }
            } else {
                if wdWriteFD >= 0 {
                    _ = close(wdWriteFD)
                    wdWriteFD = -1
                }
                if agyPID > 0 {
                    _ = kill(agyPID, SIGTERM)
                    let killDeadline = Date().addingTimeInterval(0.15)
                    var st: Int32 = 0
                    while Date() < killDeadline {
                        if waitpid(agyPID, &st, WNOHANG) == agyPID { break }
                        usleep(20_000)
                    }
                    _ = kill(-agyPID, SIGKILL)
                    _ = waitpid(agyPID, &st, WNOHANG)
                }
                if wrapperPID > 0 {
                    var st: Int32 = 0
                    if waitpid(wrapperPID, &st, WNOHANG) != wrapperPID {
                        _ = kill(wrapperPID, SIGKILL)
                        _ = waitpid(wrapperPID, &st, 0)
                    }
                }
            }

            ActiveSyncProcessRegistry.shared.unregister(wrapperPID: wrapperPID)
            activeChildPID = nil
            _ = close(masterFD)
        }
        defer { stopChildIfNeeded() }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var firstQuotaAt: Date?
        var firstAuthAt: Date?
        var latestSnapshot: StatusLineSnapshot?
        var sawAuthRequired = false
        var drainBuffer = [UInt8](repeating: 0, count: 4096)

        while Date() < deadline {
            while read(masterFD, &drainBuffer, drainBuffer.count) > 0 {}

            if fm.fileExists(atPath: tempSnapshotURL.path),
               let parsed = evaluator.loadSnapshot(from: tempSnapshotURL) {
                latestSnapshot = parsed
                if let quota = parsed.quota, !quota.isEmpty {
                    firstAuthAt = nil
                    if parsed.planTier?.isEmpty == false {
                        break
                    }
                    if firstQuotaAt == nil {
                        firstQuotaAt = Date()
                    } else if Date().timeIntervalSince(firstQuotaAt!) >= 0.8 {
                        break
                    }
                } else if parsed.agentState == "authenticating" && (parsed.email?.isEmpty ?? true) {
                    if firstAuthAt == nil {
                        firstAuthAt = Date()
                    } else if Date().timeIntervalSince(firstAuthAt!) >= 7.5 {
                        sawAuthRequired = true
                        break
                    }
                } else {
                    firstAuthAt = nil
                }
            }

            // Check if child exited early.
            var status: Int32 = 0
            let monitoredPID = usingNativeWrapper ? wrapperPID : agyPID
            if monitoredPID > 0, waitpid(monitoredPID, &status, WNOHANG) == monitoredPID {
                break
            }

            try? await Task.sleep(for: .milliseconds(200))
        }

        // Stop child cleanly before inspecting probe.log so agy flushes its final log lines.
        stopChildIfNeeded()

        if let captured = latestSnapshot, let quota = captured.quota, !quota.isEmpty {
            do {
                let merged = try CLIProbeSupport.persistSnapshot(captured, to: snapshotURL, evaluator: evaluator)
                return .synced(merged)
            } catch {
                return .failed("保存官方快照失败：\(error.localizedDescription)")
            }
        }

        let probeLogText = (try? String(contentsOf: tempLogURL, encoding: .utf8)) ?? ""
        return Self.classifyAuthProbeFailure(
            logText: probeLogText,
            sawAuthenticatingTimeout: sawAuthRequired
        )
    }

    /// Distinguishes genuine sign-out/revocation from transient network/proxy errors during OAuth refresh.
    public nonisolated static func classifyAuthProbeFailure(
        logText: String,
        sawAuthenticatingTimeout: Bool
    ) -> SilentSyncResult {
        let lower = logText.lowercased()

        // 1. Definitive server/keyring auth revocation -> genuinely needs sign-in.
        let hasDefinitiveRevocation = lower.contains("invalid_grant")
            || lower.contains("token has been expired or revoked")
            || lower.contains("refresh token revoked")
            || lower.contains("keyringauth: no token")
            || lower.contains("secret not found in keyring")
        if hasDefinitiveRevocation && !lower.contains("oauth: authenticated successfully") {
            return .authRequired
        }

        // 2. Network / proxy hiccup during OAuth token validation or refresh -> transient failure, NOT sign-out.
        let hasNetworkError = lower.contains("token refresh failed due to network error")
            || lower.contains("token validation failed due to network error")
            || lower.contains("oauth2.googleapis.com/token") && (
                lower.contains("eof")
                || lower.contains("timeout")
                || lower.contains("connection refused")
                || lower.contains("no such host")
                || lower.contains("network is unreachable")
                || lower.contains("tls")
                || lower.contains("connection reset")
            )
        if hasNetworkError {
            return .failed("网络或代理波动导致 OAuth 校验暂时失败，稍后将自动重试")
        }

        // 3. Keychain already holds a token (or OAuth succeeded) and wasn't revoked -> never falsely claim logged out.
        if lower.contains("oauth: authenticated successfully") {
            return .failed("已通过登录校验，但拉取官方额度超时，稍后将自动重试")
        }
        if lower.contains("keyringauth: loaded token") {
            return .failed("后台登录态校验超时（本地凭证仍在），稍后将自动重试")
        }

        // 4. Persisted in authenticating state with no keyring token and no network error -> genuinely needs login.
        if sawAuthenticatingTimeout {
            return .authRequired
        }

        return .failed("超时未获取到官方额度，稍后将自动重试")
    }

    // MARK: - Startup Orphan Probe Sweeper

    /// Sweeps leftover `agy` processes spawned by previous crashed/killed `SilentCLISyncer` runs
    /// (strictly identified by `agy-silent-sync-` in argv and dead owner PID or `ppid == 1`).
    /// Never touches normal user `agy` sessions.
    public nonisolated static func sweepOrphanedProbes(excludingCurrentPID currentPID: Int32 = getpid()) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,ppid=,ucomm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        if let output = String(data: data, encoding: .utf8) {
            for line in output.split(whereSeparator: \.isNewline) {
                let parts = line.trimmingCharacters(in: .whitespaces).split(maxSplits: 2, whereSeparator: \.isWhitespace)
                guard parts.count >= 3,
                      let pid = Int32(parts[0]),
                      let ppid = Int32(parts[1]) else { continue }
                let comm = String(parts[2]).lowercased()
                guard comm == "agy" else { continue }
                guard let args = readProcessArgs(pid: pid) else { continue }
                let joined = args.joined(separator: " ")
                guard joined.contains("agy-silent-sync-") else { continue }

                var shouldKill = (ppid == 1)
                if !shouldKill, let ownerPID = extractOwnerPID(from: joined) {
                    if ownerPID != currentPID && kill(ownerPID, 0) != 0 && errno == ESRCH {
                        shouldKill = true
                    }
                }
                if shouldKill {
                    _ = kill(pid, SIGKILL)
                }
            }
        }

        // Clean stale temporary probe directories older than 1 hour.
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory
        if let items = try? fm.contentsOfDirectory(
            at: tempRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            let cutoff = Date().addingTimeInterval(-3600)
            for item in items where item.lastPathComponent.hasPrefix("agy-silent-sync-") {
                if let attrs = try? item.resourceValues(forKeys: [.contentModificationDateKey]),
                   let mtime = attrs.contentModificationDate,
                   mtime < cutoff {
                    try? fm.removeItem(at: item)
                }
            }
        }
    }

    private nonisolated static func extractOwnerPID(from commandLine: String) -> Int32? {
        guard let range = commandLine.range(of: "agy-silent-sync-") else { return nil }
        let suffix = commandLine[range.upperBound...]
        let digits = suffix.prefix(while: { $0.isNumber })
        guard !digits.isEmpty else { return nil }
        return Int32(digits)
    }

    private nonisolated static func readPIDLine(from fd: Int32, timeoutMs: Int32) -> pid_t? {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let pr = poll(&pfd, 1, timeoutMs)
        guard pr > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: 64)
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { return nil }
        let str = String(decoding: buf[0..<n], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return pid_t(str)
    }

    private nonisolated static func readProcessArgs(pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        var argc: Int32 = 0
        _ = withUnsafeMutableBytes(of: &argc) { dst in
            buffer.withUnsafeBytes { src in
                memcpy(dst.baseAddress!, src.baseAddress!, MemoryLayout<Int32>.size)
            }
        }
        guard argc > 0 else { return nil }

        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var args: [String] = []
        while args.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return args
    }
}
