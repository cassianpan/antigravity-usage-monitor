import Darwin
import Foundation
import os

// MARK: - Signal Flag for CLILoginSupervisor (POSIX async-signal-safe)

private nonisolated(unsafe) var gLoginSupervisorStopSignal: sig_atomic_t = 0

private func loginSupervisorSignalHandler(_ sig: Int32) {
    gLoginSupervisorStopSignal = sig
}

// MARK: - PosixSpawn Wrapper (Swift 6 safe, zero Darwin.fork)

public enum PosixSpawnError: Error, LocalizedError, Sendable {
    case spawnFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .spawnFailed(let code):
            let message = String(cString: strerror(code))
            return "posix_spawn 失败 (\(code)): \(message)"
        }
    }
}

public enum PosixSpawn {
    public struct Options: Sendable {
        public var executable: String
        public var arguments: [String]
        public var environment: [String: String]
        public var dup2Map: [(sourceFD: Int32, targetFD: Int32)]
        public var inheritFDs: [Int32]
        public var setProcessGroup: Bool
        public var startSuspended: Bool
        public var closeOnExecDefault: Bool

        public init(
            executable: String,
            arguments: [String] = [],
            environment: [String: String] = ProcessInfo.processInfo.environment,
            dup2Map: [(sourceFD: Int32, targetFD: Int32)] = [],
            inheritFDs: [Int32] = [],
            setProcessGroup: Bool = true,
            startSuspended: Bool = false,
            closeOnExecDefault: Bool = true
        ) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
            self.dup2Map = dup2Map
            self.inheritFDs = inheritFDs
            self.setProcessGroup = setProcessGroup
            self.startSuspended = startSuspended
            self.closeOnExecDefault = closeOnExecDefault
        }
    }

    public static func spawn(_ options: Options) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        for fd in options.inheritFDs {
            posix_spawn_file_actions_addinherit_np(&fileActions, fd)
        }
        for mapping in options.dup2Map {
            if mapping.sourceFD == mapping.targetFD {
                posix_spawn_file_actions_addinherit_np(&fileActions, mapping.sourceFD)
            } else {
                posix_spawn_file_actions_adddup2(&fileActions, mapping.sourceFD, mapping.targetFD)
            }
        }

        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        defer { posix_spawnattr_destroy(&attrs) }

        var flags: Int32 = 0
        if options.setProcessGroup {
            flags |= POSIX_SPAWN_SETPGROUP
            posix_spawnattr_setpgroup(&attrs, 0)
        }
        if options.startSuspended {
            flags |= POSIX_SPAWN_START_SUSPENDED
        }
        if options.closeOnExecDefault {
            flags |= POSIX_SPAWN_CLOEXEC_DEFAULT
        }
        posix_spawnattr_setflags(&attrs, Int16(flags))

        let argvStrings = [options.executable] + options.arguments
        let envStrings = options.environment.map { "\($0.key)=\($0.value)" }

        var cArgv = argvStrings.map { strdup($0) }
        cArgv.append(nil)
        defer {
            for ptr in cArgv where ptr != nil {
                free(ptr)
            }
        }

        var cEnv = envStrings.map { strdup($0) }
        cEnv.append(nil)
        defer {
            for ptr in cEnv where ptr != nil {
                free(ptr)
            }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, options.executable, &fileActions, &attrs, &cArgv, &cEnv)
        guard rc == 0 else {
            throw PosixSpawnError.spawnFailed(rc)
        }
        return pid
    }
}

// MARK: - Synchronous Active Sync Process Registry (for applicationWillTerminate / signals)

public final class ActiveSyncProcessRegistry: Sendable {
    public static let shared = ActiveSyncProcessRegistry()

    private struct Entry: Sendable {
        var wrapperPID: Int32
        var agyPGID: Int32?
        var watchdogWriteFD: Int32?
    }

    private let state = OSAllocatedUnfairLock(initialState: [Int32: Entry]())

    private init() {}

    public func register(wrapperPID: Int32, agyPGID: Int32? = nil, watchdogWriteFD: Int32? = nil) {
        state.withLock { map in
            map[wrapperPID] = Entry(
                wrapperPID: wrapperPID,
                agyPGID: agyPGID,
                watchdogWriteFD: watchdogWriteFD
            )
        }
    }

    public func updateAgyPGID(wrapperPID: Int32, agyPGID: Int32) {
        state.withLock { map in
            if var entry = map[wrapperPID] {
                entry.agyPGID = agyPGID
                map[wrapperPID] = entry
            }
        }
    }

    public func unregister(wrapperPID: Int32) {
        _ = state.withLock { map in
            map.removeValue(forKey: wrapperPID)
        }
    }

    /// Synchronously kills all registered sync subprocess groups and wrappers.
    /// Safe to invoke from `applicationWillTerminate` without awaiting actors.
    public func terminateAllImmediately() {
        let entries = state.withLock { map -> [Entry] in
            let all = Array(map.values)
            map.removeAll()
            return all
        }

        for entry in entries {
            if let fd = entry.watchdogWriteFD, fd >= 0 {
                _ = close(fd)
            }
            if let pgid = entry.agyPGID, pgid > 0 {
                _ = kill(-pgid, SIGKILL)
            }
            if entry.wrapperPID > 0 {
                _ = kill(entry.wrapperPID, SIGKILL)
            }
        }
    }
}

// MARK: - Shared Probe Helpers

public enum CLIProbeSupport {
    public static func defaultEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extraPaths = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let existingPath = env["PATH"], !existingPath.isEmpty {
            env["PATH"] = "\(extraPaths):\(existingPath)"
        } else {
            env["PATH"] = extraPaths
        }
        env["TERM"] = env["TERM"] ?? "xterm-256color"
        env["HOME"] = home
        return env
    }

    public static func writeProbeScript(outputURL: URL, into directory: URL) throws -> URL {
        let scriptURL = directory.appendingPathComponent("probe.sh")
        let escapedOut = "'" + outputURL.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        let scriptContent = """
        #!/bin/sh
        umask 077
        OUT=\(escapedOut)
        TMP=$(/usr/bin/mktemp "${OUT}.tmp.XXXXXX" 2>/dev/null) || TMP=""
        if [ -n "$TMP" ] && cat > "$TMP" 2>/dev/null; then
            mv -f "$TMP" "$OUT" 2>/dev/null || rm -f "$TMP" 2>/dev/null || true
        elif [ -n "$TMP" ]; then
            rm -f "$TMP" 2>/dev/null || true
        fi
        exit 0
        """
        try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    /// Reads the user's existing `settings.json` (if present and valid) and writes a merged
    /// temporary `settings.json` overriding only `statusLine`, without mutating disk `settings.json`.
    public static func writeMergedSettings(
        probeScriptURL: URL,
        into directory: URL,
        userSettingsURL: URL = StatusLineBridgeInstaller.defaultCLIConfigDirectory
            .appendingPathComponent("settings.json")
    ) throws -> URL {
        var merged: [String: Any] = [:]
        if let data = try? Data(contentsOf: userSettingsURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            merged = existing
        }
        merged["statusLine"] = [
            "type": "command",
            "command": probeScriptURL.path,
            "enabled": true,
        ]
        let outURL = directory.appendingPathComponent("settings.json")
        let data = try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
        try data.write(to: outURL, options: .atomic)
        return outURL
    }

    /// Atomically persists a captured snapshot to `snapshotURL`, preserving previous `planTier`/`email` if omitted.
    @discardableResult
    public static func persistSnapshot(
        _ captured: StatusLineSnapshot,
        to snapshotURL: URL,
        evaluator: QuotaEvaluator = QuotaEvaluator()
    ) throws -> StatusLineSnapshot {
        let previous = evaluator.loadSnapshot(from: snapshotURL)
        let merged = StatusLineSnapshot(
            conversationId: captured.conversationId ?? previous?.conversationId,
            conversationTitle: captured.conversationTitle ?? previous?.conversationTitle,
            model: captured.model ?? previous?.model,
            version: captured.version ?? previous?.version,
            contextWindow: captured.contextWindow ?? previous?.contextWindow,
            quota: captured.quota,
            agentState: captured.agentState,
            planTier: (captured.planTier?.isEmpty == false) ? captured.planTier : previous?.planTier,
            email: (captured.email?.isEmpty == false) ? captured.email : previous?.email,
            cost: captured.cost ?? previous?.cost,
            capturedAt: Date()
        )
        let fm = FileManager.default
        let parentDir = snapshotURL.deletingLastPathComponent()
        try fm.createDirectory(
            at: parentDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var st = stat()
        if lstat(snapshotURL.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK {
            throw POSIXError(.ELOOP)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(merged)
        try data.write(to: snapshotURL, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshotURL.path)
        return merged
    }
}

// MARK: - B-Class: Headless kqueue Pipe-EOF Wrapper (--agy-sync-wrapper)

public enum AgySyncWrapper {
    public static let flag = "--agy-sync-wrapper"

    public static func run(arguments: [String]) -> Int32 {
        var agyPath: String?
        var settingsPath: String?
        var logFilePath: String?
        var cwdPath: String?
        var timeoutSeconds: Double = 12.0
        var watchdogFD: Int32 = 3
        var pidFD: Int32 = 4

        var i = 0
        while i < arguments.count {
            let arg = arguments[i]
            let next = (i + 1 < arguments.count) ? arguments[i + 1] : nil
            switch arg {
            case "--agy":
                agyPath = next; i += 2
            case "--settings":
                settingsPath = next; i += 2
            case "--log-file":
                logFilePath = next; i += 2
            case "--cwd":
                cwdPath = next; i += 2
            case "--timeout":
                if let next, let val = Double(next) { timeoutSeconds = val }
                i += 2
            case "--watchdog-fd":
                if let next, let val = Int32(next) { watchdogFD = val }
                i += 2
            case "--pid-fd":
                if let next, let val = Int32(next) { pidFD = val }
                i += 2
            default:
                i += 1
            }
        }

        guard let agyPath, let settingsPath else {
            return 2
        }

        if let cwdPath, !cwdPath.isEmpty {
            _ = chdir(cwdPath)
        }

        // Ignore signals so kqueue EVFILT_SIGNAL delivers them synchronously for clean child teardown.
        signal(SIGTERM, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)

        let childPID: pid_t
        do {
            var env = CLIProbeSupport.defaultEnvironment()
            env["TERM"] = "xterm-256color"
            var agyArgs = ["--settings", settingsPath]
            if let logFilePath, !logFilePath.isEmpty {
                agyArgs.append(contentsOf: ["--log-file", logFilePath])
            }
            childPID = try PosixSpawn.spawn(
                PosixSpawn.Options(
                    executable: agyPath,
                    arguments: agyArgs,
                    environment: env,
                    inheritFDs: [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO],
                    setProcessGroup: true,
                    startSuspended: false,
                    closeOnExecDefault: true
                )
            )
        } catch {
            _ = close(pidFD)
            _ = close(watchdogFD)
            return 3
        }

        // Report child PGID (= childPID) back to parent and immediately close pidFD.
        let pidLine = "\(childPID)\n"
        pidLine.withCString { cstr in
            _ = write(pidFD, cstr, strlen(cstr))
        }
        _ = close(pidFD)

        // Set watchdogFD non-blocking for reading graceful marker bytes.
        let wdFlags = fcntl(watchdogFD, F_GETFL)
        if wdFlags >= 0 {
            _ = fcntl(watchdogFD, F_SETFL, wdFlags | O_NONBLOCK)
        }

        let kq = kqueue()
        if kq < 0 {
            _ = kill(-childPID, SIGKILL)
            var st: Int32 = 0
            _ = waitpid(childPID, &st, 0)
            _ = close(watchdogFD)
            return 4
        }
        defer {
            _ = close(kq)
            _ = close(watchdogFD)
        }

        let hardTimeoutMs = max(2000, Int((timeoutSeconds + 4.0) * 1000.0))
        var changes: [kevent] = [
            kevent(
                ident: UInt(watchdogFD),
                filter: Int16(EVFILT_READ),
                flags: UInt16(EV_ADD | EV_ENABLE),
                fflags: 0,
                data: 0,
                udata: nil
            ),
            kevent(
                ident: UInt(childPID),
                filter: Int16(EVFILT_PROC),
                flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
                fflags: UInt32(NOTE_EXIT),
                data: 0,
                udata: nil
            ),
            kevent(
                ident: UInt(SIGTERM),
                filter: Int16(EVFILT_SIGNAL),
                flags: UInt16(EV_ADD | EV_ENABLE),
                fflags: 0,
                data: 0,
                udata: nil
            ),
            kevent(
                ident: UInt(SIGHUP),
                filter: Int16(EVFILT_SIGNAL),
                flags: UInt16(EV_ADD | EV_ENABLE),
                fflags: 0,
                data: 0,
                udata: nil
            ),
            kevent(
                ident: UInt(SIGINT),
                filter: Int16(EVFILT_SIGNAL),
                flags: UInt16(EV_ADD | EV_ENABLE),
                fflags: 0,
                data: 0,
                udata: nil
            ),
            kevent(
                ident: 1,
                filter: Int16(EVFILT_TIMER),
                flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
                fflags: 0,
                data: hardTimeoutMs,
                udata: nil
            ),
        ]

        _ = kevent(kq, &changes, Int32(changes.count), nil, 0, nil)

        func reapChild(graceful: Bool) {
            var st: Int32 = 0
            if waitpid(childPID, &st, WNOHANG) == childPID {
                _ = kill(-childPID, SIGKILL)
                return
            }
            if graceful {
                _ = kill(childPID, SIGTERM)
                let deadline = Date().addingTimeInterval(0.10)
                while Date() < deadline {
                    if waitpid(childPID, &st, WNOHANG) == childPID {
                        _ = kill(-childPID, SIGKILL)
                        return
                    }
                    usleep(15_000)
                }
            }
            _ = kill(-childPID, SIGKILL)
            _ = waitpid(childPID, &st, 0)
        }

        var event = kevent()
        while true {
            let n = kevent(kq, nil, 0, &event, 1, nil)
            if n < 0 {
                if errno == EINTR { continue }
                reapChild(graceful: false)
                return 0
            }
            if n == 0 { continue }

            switch event.filter {
            case Int16(EVFILT_PROC):
                var st: Int32 = 0
                _ = waitpid(childPID, &st, WNOHANG)
                _ = kill(-childPID, SIGKILL)
                return 0

            case Int16(EVFILT_READ):
                var buf = [UInt8](repeating: 0, count: 16)
                let bytesRead = read(watchdogFD, &buf, buf.count)
                let sawGraceful = bytesRead > 0 && buf.prefix(bytesRead).contains(UInt8(ascii: "G"))
                let isEOF = (event.flags & UInt16(EV_EOF)) != 0 || bytesRead <= 0
                if sawGraceful {
                    reapChild(graceful: true)
                    return 0
                }
                if isEOF {
                    // Parent died (e.g. SIGKILL / crash) -> instant SIGKILL to entire child process group.
                    reapChild(graceful: false)
                    return 0
                }

            case Int16(EVFILT_SIGNAL), Int16(EVFILT_TIMER):
                reapChild(graceful: false)
                return 0

            default:
                break
            }
        }
    }
}

// MARK: - A-Class: Terminal Login Supervisor (--cli-login-helper)

public enum CLILoginSupervisor {
    public static let flag = "--cli-login-helper"

    public static func run(arguments: [String]) -> Int32 {
        var snapshotPath = StatusLineBridgeInstaller.defaultCLIConfigDirectory
            .appendingPathComponent("usage-monitor-snapshot.json").path
        var isChinese = true
        var customAgyPath: String?
        var doneFilePath: String?

        var i = 0
        while i < arguments.count {
            let arg = arguments[i]
            let next = (i + 1 < arguments.count) ? arguments[i + 1] : nil
            switch arg {
            case "--snapshot":
                if let next { snapshotPath = next }
                i += 2
            case "--lang":
                if let next { isChinese = (next != "en") }
                i += 2
            case "--agy":
                customAgyPath = next
                i += 2
            case "--done-file":
                doneFilePath = next
                i += 2
            default:
                i += 1
            }
        }

        var markedDone = false
        func writeDoneStatus(_ status: String) {
            guard !markedDone, let doneFilePath, !doneFilePath.isEmpty else { return }
            markedDone = true
            try? status.write(toFile: doneFilePath, atomically: true, encoding: .utf8)
        }
        defer {
            writeDoneStatus("cancelled")
        }

        let agyURL: URL
        if let customAgyPath, FileManager.default.isExecutableFile(atPath: customAgyPath) {
            agyURL = URL(fileURLWithPath: customAgyPath)
        } else if let located = SilentCLISyncer.locateAgyBinary() {
            agyURL = located
        } else {
            let msg = isChinese
                ? "未找到 agy CLI 可执行文件，请先安装 Antigravity CLI。\n"
                : "agy CLI binary not found. Please install Antigravity CLI first.\n"
            fputs(msg, stderr)
            return 127
        }

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(
            "agy-login-helper-\(getpid())-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            fputs("Failed to create temp directory: \(error.localizedDescription)\n", stderr)
            return 1
        }
        defer { try? fm.removeItem(at: tempDir) }

        let probeSnapshotURL = tempDir.appendingPathComponent("probe.json")
        let settingsURL: URL
        do {
            let probeScriptURL = try CLIProbeSupport.writeProbeScript(outputURL: probeSnapshotURL, into: tempDir)
            settingsURL = try CLIProbeSupport.writeMergedSettings(probeScriptURL: probeScriptURL, into: tempDir)
        } catch {
            fputs("Failed to prepare login probe: \(error.localizedDescription)\n", stderr)
            return 1
        }

        let banner = isChinese
            ? "Antigravity Usage Monitor — 请在下方完成 agy CLI 登录（登录成功将自动同步并退出；直接关闭窗口也不会残留后台进程）\n\n"
            : "Antigravity Usage Monitor — Sign in to agy CLI below (auto-syncs and exits once signed in; closing this window cleanly terminates agy)\n\n"
        fputs(banner, stdout)
        fflush(stdout)

        let hasTTY = isatty(STDIN_FILENO) != 0
        var origTermios = termios()
        let savedTermios = hasTTY && (tcgetattr(STDIN_FILENO, &origTermios) == 0)

        // Install SIGHUP / SIGTERM handlers without SA_RESTART so poll() wakes promptly.
        gLoginSupervisorStopSignal = 0
        var sa = sigaction()
        sa.__sigaction_u.__sa_handler = loginSupervisorSignalHandler
        sigemptyset(&sa.sa_mask)
        sa.sa_flags = 0
        _ = sigaction(SIGHUP, &sa, nil)
        _ = sigaction(SIGTERM, &sa, nil)
        // Ignore SIGINT in supervisor so Ctrl+C goes straight to foreground agy process group.
        signal(SIGINT, SIG_IGN)
        signal(SIGPIPE, SIG_IGN)

        let childPID: pid_t
        do {
            let env = CLIProbeSupport.defaultEnvironment()
            childPID = try PosixSpawn.spawn(
                PosixSpawn.Options(
                    executable: agyURL.path,
                    arguments: ["--settings", settingsURL.path],
                    environment: env,
                    inheritFDs: [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO],
                    setProcessGroup: true,
                    startSuspended: true,
                    closeOnExecDefault: true
                )
            )
        } catch {
            fputs("Failed to launch agy: \(error.localizedDescription)\n", stderr)
            return 1
        }

        // Hand foreground terminal control to child process group before waking it (zero race).
        if hasTTY {
            let prevTTOU = signal(SIGTTOU, SIG_IGN)
            _ = tcsetpgrp(STDIN_FILENO, childPID)
            _ = signal(SIGTTOU, prevTTOU)
        }
        _ = kill(childPID, SIGCONT)

        func restoreTTYIfNeeded() {
            guard hasTTY else { return }
            let prevTTOU = signal(SIGTTOU, SIG_IGN)
            _ = tcsetpgrp(STDIN_FILENO, getpgrp())
            if savedTermios {
                var restored = origTermios
                _ = tcsetattr(STDIN_FILENO, TCSANOW, &restored)
            }
            _ = signal(SIGTTOU, prevTTOU)
            // Leave alt-screen, clear inline TUI residue, move cursor home, show cursor, reset SGR.
            let resetSeq = "\u{1B}[?1049l\u{1B}[2J\u{1B}[H\u{1B}[?25h\u{1B}[0m"
            fputs(resetSeq, stdout)
            fflush(stdout)
        }

        func killChildGroupAndReap() {
            _ = kill(-childPID, SIGKILL)
            var st: Int32 = 0
            _ = waitpid(childPID, &st, 0)
        }

        let evaluator = QuotaEvaluator()
        let targetSnapshotURL = URL(fileURLWithPath: snapshotPath)

        while true {
            // Monitor ONLY hangup/error on STDIN — never POLLIN — so we never steal input from agy.
            var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLERR | POLLHUP), revents: 0)
            let pr = poll(&pfd, 1, 150)

            let ttyHungUp = (pr > 0 && (pfd.revents & Int16(POLLHUP | POLLERR | POLLNVAL)) != 0)
                || (hasTTY && isatty(STDIN_FILENO) == 0)

            if gLoginSupervisorStopSignal != 0 || ttyHungUp {
                killChildGroupAndReap()
                return 0
            }

            // Check if agy exited on its own (e.g. user pressed Ctrl+C/Ctrl+D twice or /exit).
            var status: Int32 = 0
            if waitpid(childPID, &status, WNOHANG) == childPID {
                _ = kill(-childPID, SIGKILL)
                restoreTTYIfNeeded()
                if let snap = evaluator.loadSnapshot(from: probeSnapshotURL),
                   let quota = snap.quota, !quota.isEmpty {
                    _ = try? CLIProbeSupport.persistSnapshot(snap, to: targetSnapshotURL, evaluator: evaluator)
                }
                return 0
            }

            // Check whether login succeeded and official quota has been fetched.
            if fm.fileExists(atPath: probeSnapshotURL.path),
               let snap = evaluator.loadSnapshot(from: probeSnapshotURL),
               let quota = snap.quota, !quota.isEmpty,
               let email = snap.email, !email.isEmpty,
               snap.agentState != "authenticating" {
                _ = try? CLIProbeSupport.persistSnapshot(snap, to: targetSnapshotURL, evaluator: evaluator)
                // Brief grace period so agy flushes any local auth state before SIGKILL.
                usleep(600_000)
                killChildGroupAndReap()
                restoreTTYIfNeeded()
                let doneMsg = isChinese
                    ? "\u{1B}[32m✓ agy CLI 登录成功并已同步官方额度，窗口即将自动关闭…\u{1B}[0m\n"
                    : "\u{1B}[32m✓ agy CLI signed in and official quota synced. Closing Terminal window…\u{1B}[0m\n"
                fputs(doneMsg, stdout)
                fflush(stdout)
                writeDoneStatus("ok")
                return 0
            }
        }
    }
}
