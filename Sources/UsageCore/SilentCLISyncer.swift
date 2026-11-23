import Darwin
import Foundation

public enum SilentSyncResult: Sendable, Equatable {
    case synced(StatusLineSnapshot)
    case authRequired
    case cliNotFound
    case failed(String)
}

/// Runs `agy --settings '{"statusLine":...}'` silently inside a short-lived PTY
/// to collect fresh official quota without requiring a permanently open Terminal
/// or mutating the user's `settings.json`.
public actor SilentCLISyncer {
    private let snapshotURL: URL
    private let evaluator: QuotaEvaluator
    private var isRunning = false
    private var activeChildPID: Int32?

    public init(
        snapshotURL: URL = StatusLineBridgeInstaller.defaultCLIConfigDirectory
            .appendingPathComponent("usage-monitor-snapshot.json"),
        evaluator: QuotaEvaluator = QuotaEvaluator()
    ) {
        self.snapshotURL = snapshotURL
        self.evaluator = evaluator
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

    public func sync(timeoutSeconds: TimeInterval = 12.0) async -> SilentSyncResult {
        guard !isRunning else {
            return .failed("Sync already in progress")
        }
        guard let agyURL = Self.locateAgyBinary() else {
            return .cliNotFound
        }

        isRunning = true
        defer {
            isRunning = false
            activeChildPID = nil
        }

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("agy-silent-sync-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            return .failed("无法创建临时目录：\(error.localizedDescription)")
        }
        defer { try? fm.removeItem(at: tempDir) }

        let tempSnapshotURL = tempDir.appendingPathComponent("probe.json")
        let tempScriptURL = tempDir.appendingPathComponent("probe.sh")
        let escapedTempSnap = "'" + tempSnapshotURL.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        let scriptContent = """
        #!/bin/sh
        set -eu
        OUT=\(escapedTempSnap)
        TMP="${OUT}.tmp.$$"
        cat > "$TMP"
        mv -f "$TMP" "$OUT"
        exit 0
        """
        do {
            try scriptContent.write(to: tempScriptURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempScriptURL.path)
        } catch {
            return .failed("无法写入临时探测脚本：\(error.localizedDescription)")
        }

        let settingsDict: [String: Any] = [
            "statusLine": [
                "type": "command",
                "command": tempScriptURL.path,
                "enabled": true,
            ]
        ]
        guard let settingsData = try? JSONSerialization.data(withJSONObject: settingsDict),
              let settingsJSON = String(data: settingsData, encoding: .utf8) else {
            return .failed("序列化临时配置失败")
        }

        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        var winSize = winsize(ws_row: 30, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&masterFD, &slaveFD, nil, nil, &winSize) == 0 else {
            return .failed("无法分配后台伪终端 (openpty)")
        }

        // Prevent master FD from blocking if child writes terminal output.
        let flags = fcntl(masterFD, F_GETFL)
        if flags >= 0 {
            _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)
        }

        let slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
        let process = Process()
        process.executableURL = agyURL
        process.arguments = ["--settings", settingsJSON]
        process.currentDirectoryURL = tempDir
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        var env = ProcessInfo.processInfo.environment
        let home = fm.homeDirectoryForCurrentUser.path
        let extraPaths = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let existingPath = env["PATH"], !existingPath.isEmpty {
            env["PATH"] = "\(extraPaths):\(existingPath)"
        } else {
            env["PATH"] = extraPaths
        }
        env["TERM"] = "xterm-256color"
        env["HOME"] = home
        process.environment = env

        do {
            try process.run()
        } catch {
            close(slaveFD)
            close(masterFD)
            return .failed("启动 agy 失败：\(error.localizedDescription)")
        }

        // Parent closes slave side immediately.
        close(slaveFD)
        activeChildPID = process.processIdentifier

        defer {
            if process.isRunning {
                process.terminate()
                let killDeadline = Date().addingTimeInterval(1.5)
                while process.isRunning && Date() < killDeadline {
                    usleep(50_000)
                }
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
            close(masterFD)
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var firstQuotaAt: Date?
        var latestSnapshot: StatusLineSnapshot?
        var sawAuthRequired = false
        var drainBuffer = [UInt8](repeating: 0, count: 4096)

        while Date() < deadline {
            // Drain PTY output so child never blocks on full tty buffer.
            while read(masterFD, &drainBuffer, drainBuffer.count) > 0 {}

            if fm.fileExists(atPath: tempSnapshotURL.path),
               let parsed = evaluator.loadSnapshot(from: tempSnapshotURL) {
                latestSnapshot = parsed
                if parsed.agentState == "authenticating" {
                    sawAuthRequired = true
                    break
                }
                if let quota = parsed.quota, !quota.isEmpty {
                    if parsed.planTier?.isEmpty == false {
                        break
                    }
                    if firstQuotaAt == nil {
                        firstQuotaAt = Date()
                    } else if Date().timeIntervalSince(firstQuotaAt!) >= 0.8 {
                        break
                    }
                }
            }

            if !process.isRunning {
                break
            }
            try? await Task.sleep(for: .milliseconds(200))
        }

        if sawAuthRequired {
            return .authRequired
        }

        guard let captured = latestSnapshot, let quota = captured.quota, !quota.isEmpty else {
            return .failed("超时未获取到官方额度，请确认 agy CLI 已登录")
        }

        // Persist atomically to snapshotURL, preserving previous planTier if new payload omitted it.
        let previous = evaluator.loadSnapshot(from: snapshotURL)
        let merged = StatusLineSnapshot(
            conversationId: captured.conversationId ?? previous?.conversationId,
            conversationTitle: captured.conversationTitle ?? previous?.conversationTitle,
            model: captured.model ?? previous?.model,
            version: captured.version ?? previous?.version,
            contextWindow: captured.contextWindow ?? previous?.contextWindow,
            quota: quota,
            agentState: captured.agentState,
            planTier: (captured.planTier?.isEmpty == false) ? captured.planTier : previous?.planTier,
            email: (captured.email?.isEmpty == false) ? captured.email : previous?.email,
            cost: captured.cost ?? previous?.cost,
            capturedAt: Date()
        )

        do {
            try fm.createDirectory(at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(merged)
            try data.write(to: snapshotURL, options: .atomic)
        } catch {
            return .failed("保存官方快照失败：\(error.localizedDescription)")
        }

        return .synced(merged)
    }
}
