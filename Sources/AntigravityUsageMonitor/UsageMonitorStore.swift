import AppKit
import Darwin
import Foundation
import UsageCore

struct RunningProcessInfo: Identifiable, Sendable, Equatable {
    let id: Int32
    let memberPIDs: [Int32]
    let name: String
    let detail: String?
    let kind: String
    let tty: String?
    let isDetached: Bool
    let memoryBytes: Int64

    init(
        id: Int32,
        memberPIDs: [Int32] = [],
        name: String,
        detail: String? = nil,
        kind: String,
        tty: String? = nil,
        isDetached: Bool = false,
        memoryBytes: Int64 = 0
    ) {
        self.id = id
        self.memberPIDs = memberPIDs.isEmpty ? [id] : memberPIDs
        self.name = name
        self.detail = detail
        self.kind = kind
        self.tty = tty
        self.isDetached = isDetached
        self.memoryBytes = memoryBytes
    }
}

struct MenuBarColumnItem: Identifiable, Equatable {
    var id: String { topLabel }
    let topLabel: String
    let value: String
    let valueHex: UInt32
}

enum UpdateInstallPhase: Equatable {
    case idle
    case checking
    case upToDate
    case available(AppUpdateInfo)
    case downloading(version: String, progress: Double)
    case installing(version: String)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .installing:
            return true
        default:
            return false
        }
    }
}

private struct RefreshPayload: Sendable {
    let bridgeStatus: BridgeStatus
    let cliBinaryPath: String?
    let officialReport: OfficialQuotaReport
    let localReport: LocalUsageReport
    let runningProcesses: [RunningProcessInfo]
}

@MainActor
@Observable
final class UsageMonitorStore {
    private let transcriptIndex: TranscriptIndex
    private let aggregator: UsageAggregator
    private let quotaEvaluator: QuotaEvaluator
    private let silentSyncer: SilentCLISyncer
    private let updateChecker: UpdateChecker
    let bridgeInstaller: StatusLineBridgeInstaller
    let preferences: AppPreferences

    var localReport: LocalUsageReport = LocalUsageReport()
    var officialReport: OfficialQuotaReport = OfficialQuotaReport()
    var bridgeStatus: BridgeStatus = .notInstalled(existingCommand: nil)
    var runningProcesses: [RunningProcessInfo] = []
    var terminatingProcessIds: Set<Int32> = []
    var bridgeFeedback: String?
    var isRefreshing: Bool = false
    var isSyncingOfficial: Bool = false
    var officialAuthRequired: Bool = false
    var cliBinaryPath: String? = SilentCLISyncer.locateAgyBinary()?.path

    let currentAppVersion: String = {
        let raw = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        return AppVersionComparator.normalize(raw)
    }()
    var availableUpdate: AppUpdateInfo? = nil
    var updatePhase: UpdateInstallPhase = .idle
    var isCheckingUpdates: Bool = false
    var updateStatusText: String? = nil
    var updateNotesVisible: Bool = false
    var isUpdateStatusHovered: Bool = false
    var isUpdateBrowserLinkHovered: Bool = false
    var copiedBrewUpgrade: Bool = false

    var visibleAvailableUpdate: AppUpdateInfo? {
        guard let info = availableUpdate else { return nil }
        if preferences.dismissedUpdateVersion == info.version {
            return nil
        }
        return info
    }

    var isUpdateDismissed: Bool {
        guard let info = availableUpdate else { return false }
        return preferences.dismissedUpdateVersion == info.version
    }

    var showsSettingsUpdateBadge: Bool {
        switch updatePhase {
        case .downloading, .installing:
            return true
        case .available:
            return visibleAvailableUpdate != nil
        default:
            return visibleAvailableUpdate != nil
        }
    }

    var updateDownloadFraction: Double? {
        if case .downloading(_, let progress) = updatePhase {
            return progress
        }
        return nil
    }

    var canInstallUpdateInPlace: Bool {
        guard let info = availableUpdate, info.zipURL != nil else { return false }
        return !updatePhase.isBusy
    }

    var onMenuBarUpdate: (() -> Void)?
    var onSyncStateChanged: ((Bool) -> Void)?

    private var timer: Timer?
    private var loginTerminalWatchTask: Task<Void, Never>?
    private var directoryWatcher: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1
    private var watcherDebounceTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var lastAutoSyncAttempt: Date = .distantPast
    private var lastUpdateCheckAt: Date = .distantPast
    private var lastSeenTotalTokens: Int = 0

    init(
        preferences: AppPreferences,
        brainDirectory: URL = TranscriptIndex.defaultBrainDirectory,
        cliConfigDirectory: URL = StatusLineBridgeInstaller.defaultCLIConfigDirectory
    ) {
        self.preferences = preferences
        self.transcriptIndex = TranscriptIndex(brainDirectory: brainDirectory)
        self.aggregator = UsageAggregator()
        self.quotaEvaluator = QuotaEvaluator()
        self.bridgeInstaller = StatusLineBridgeInstaller(cliConfigDirectory: cliConfigDirectory)
        self.silentSyncer = SilentCLISyncer(snapshotURL: bridgeInstaller.snapshotURL, evaluator: quotaEvaluator)
        self.updateChecker = UpdateChecker()

        refreshNow()
        startTimer()
        startSnapshotWatcher()

        Task { [weak self] in
            await self?.syncOfficialInBackground(force: true)
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.checkForUpdatesIfNeeded()
        }
    }

    func checkForUpdatesIfNeeded() async {
        guard preferences.autoCheckUpdates else { return }
        guard Date().timeIntervalSince(lastUpdateCheckAt) >= 4 * 3600 else { return }
        await checkForUpdates(manual: false)
    }

    func toggleUpdateNotes() {
        updateNotesVisible.toggle()
        if updateNotesVisible && availableUpdate == nil && !updatePhase.isBusy {
            Task { [weak self] in
                await self?.checkForUpdates(manual: true)
            }
        }
    }

    func showUpdateNotes() {
        updateNotesVisible = true
    }

    func checkForUpdates(manual: Bool) async {
        guard !updatePhase.isBusy else { return }
        isCheckingUpdates = true
        if manual || updatePhase == .idle {
            updatePhase = .checking
        }
        lastUpdateCheckAt = Date()
        let zh = preferences.language.isChinese
        if manual {
            updateStatusText = zh ? "正在检查更新…" : "Checking for updates…"
        }

        let result = await updateChecker.checkLatestRelease(currentVersion: currentAppVersion)
        isCheckingUpdates = false

        switch result {
        case .updateAvailable(let info):
            availableUpdate = info
            updatePhase = .available(info)
            if manual {
                preferences.dismissedUpdateVersion = ""
            }
            updateStatusText = isUpdateDismissed
                ? (zh ? "已忽略 v\(info.version)，仍可随时更新" : "Skipped v\(info.version). Still available.")
                : (zh ? "发现新版本 v\(info.version)" : "Version v\(info.version) is available")
            if !isUpdateDismissed {
                NotificationManager.shared.postUpdateAvailableIfNew(version: info.version, zh: zh)
            }
        case .upToDate(let current):
            availableUpdate = nil
            updatePhase = .upToDate
            if manual {
                updateStatusText = zh ? "已是最新版本 (v\(current))" : "Up to date (v\(current))"
            }
        case .failed(let reason):
            if manual {
                updatePhase = .failed(reason)
                updateStatusText = zh ? "检查失败：\(reason)" : "Check failed: \(reason)"
            } else if availableUpdate == nil {
                updatePhase = .idle
            }
        }
    }

    func installAvailableUpdate() async {
        guard let info = availableUpdate, let zipURL = info.zipURL else {
            openUpdateReleasePage()
            return
        }
        guard !updatePhase.isBusy else { return }

        let zh = preferences.language.isChinese
        let targetAppURL = Bundle.main.bundleURL
        guard targetAppURL.pathExtension == "app" else {
            let msg = zh ? "当前为开发运行态，请前往 GitHub 下载或在终端升级" : "Running outside .app bundle. Download from GitHub or use Homebrew."
            updatePhase = .failed(msg)
            updateStatusText = msg
            return
        }

        updatePhase = .downloading(version: info.version, progress: 0)
        updateStatusText = zh ? "正在下载 v\(info.version)…" : "Downloading v\(info.version)…"

        do {
            let zipData = try await updateChecker.downloadData(from: zipURL) { [weak self] fraction in
                guard let self else { return }
                self.updatePhase = .downloading(version: info.version, progress: fraction)
                let pct = Int(round(fraction * 100))
                self.updateStatusText = zh ? "正在下载 v\(info.version) (\(pct)%)" : "Downloading v\(info.version) (\(pct)%)"
            }

            if let checksumsURL = info.checksumsURL, let zipName = info.zipFileName {
                if let expectedHash = try await updateChecker.fetchExpectedSHA256(from: checksumsURL, matchingFileName: zipName) {
                    guard UpdateChecker.verifySHA256(data: zipData, expectedHex: expectedHash) else {
                        let msg = zh ? "安装包 SHA-256 校验失败，已中止更新" : "SHA-256 verification failed. Update aborted."
                        updatePhase = .failed(msg)
                        updateStatusText = msg
                        return
                    }
                }
            }

            updatePhase = .installing(version: info.version)
            updateStatusText = zh ? "正在安装 v\(info.version)，即将重启…" : "Installing v\(info.version), restarting…"

            let extractedAppURL = try await Task.detached(priority: .userInitiated) {
                try Self.unpackUpdateZip(zipData)
            }.value

            try Self.launchRelaunchScript(replacing: targetAppURL, with: extractedAppURL)
        } catch {
            let msg = zh ? "更新失败：\(error.localizedDescription)" : "Update failed: \(error.localizedDescription)"
            updatePhase = .failed(msg)
            updateStatusText = msg
        }
    }

    private nonisolated static func unpackUpdateZip(_ zipData: Data) throws -> URL {
        let fm = FileManager.default
        let stagingDir = fm.temporaryDirectory
            .appendingPathComponent("aum-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let zipFile = stagingDir.appendingPathComponent("update.zip")
        try zipData.write(to: zipFile, options: .atomic)

        let unpackDir = stagingDir.appendingPathComponent("unpacked", isDirectory: true)
        try fm.createDirectory(at: unpackDir, withIntermediateDirectories: true)

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zipFile.path, unpackDir.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            throw NSError(domain: "UpdateInstaller", code: Int(ditto.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "解压安装包失败",
            ])
        }

        let contents = try fm.contentsOfDirectory(at: unpackDir, includingPropertiesForKeys: nil)
        guard let appBundle = contents.first(where: { $0.pathExtension == "app" }) else {
            throw NSError(domain: "UpdateInstaller", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "安装包内未找到 .app 文件",
            ])
        }
        return appBundle
    }

    private static func launchRelaunchScript(replacing target: URL, with source: URL) throws {
        func shellQuote(_ path: String) -> String {
            "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let stagingRoot = source.deletingLastPathComponent().deletingLastPathComponent()
        let script = """
        #!/bin/zsh
        while /bin/kill -0 \(pid) 2>/dev/null; do
          sleep 0.2
        done
        /bin/rm -rf \(shellQuote(target.path))
        /usr/bin/ditto \(shellQuote(source.path)) \(shellQuote(target.path))
        /usr/bin/xattr -dr com.apple.quarantine \(shellQuote(target.path)) 2>/dev/null || true
        /usr/bin/open \(shellQuote(target.path))
        /bin/rm -rf \(shellQuote(stagingRoot.path))
        """
        let scriptFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("aum-relaunch-\(UUID().uuidString).zsh")
        try Data(script.utf8).write(to: scriptFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptFile.path)

        let runner = Process()
        runner.executableURL = URL(fileURLWithPath: "/bin/zsh")
        runner.arguments = ["-c", "nohup /bin/zsh \(shellQuote(scriptFile.path)) >/dev/null 2>&1 &"]
        try runner.run()
        runner.waitUntilExit()

        NSApp.terminate(nil)
    }

    func openUpdateReleasePage() {
        let url = availableUpdate?.releaseURL
            ?? URL(string: "https://github.com/cassianpan/antigravity-usage-monitor/releases/latest")!
        NSWorkspace.shared.open(url)
    }

    func copyBrewUpgradeCommand() {
        let cmd = "brew update && brew upgrade --cask antigravity-usage-monitor"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
        copiedBrewUpgrade = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.copiedBrewUpgrade = false
        }
    }

    func dismissAvailableUpdate() {
        if let version = availableUpdate?.version {
            preferences.dismissedUpdateVersion = version
            let zh = preferences.language.isChinese
            updateStatusText = zh ? "已忽略 v\(version)，仍可随时更新" : "Skipped v\(version). Still available."
        }
    }

    /// Non-blocking refresh: all disk I/O, JSONL parsing, aggregation, and pgrep run off the main thread.
    func refreshNow() {
        refreshTask?.cancel()
        isRefreshing = true

        let index = transcriptIndex
        let agg = aggregator
        let evaluator = quotaEvaluator
        let installer = bridgeInstaller
        let billingDay = preferences.billingDay > 0 ? preferences.billingDay : nil
        let selfPid = Int32(ProcessInfo.processInfo.processIdentifier)

        refreshTask = Task { [weak self] in
            let payload: RefreshPayload = await Task.detached(priority: .utility) {
                let now = Date()
                let status = installer.status()
                let cliPath = SilentCLISyncer.locateAgyBinary()?.path
                let snapshot = evaluator.loadSnapshot(from: installer.snapshotURL)
                let official = evaluator.evaluate(snapshot: snapshot, now: now)
                let scan = index.refresh()
                let local = agg.aggregate(
                    records: scan.records,
                    conversationCount: scan.conversationCount,
                    now: now,
                    officialWeeklyResetTime: official.primaryWeekly?.resetTime,
                    billingDay: billingDay
                )
                let procs = Self.detectRunningProcesses(excluding: selfPid)
                return RefreshPayload(
                    bridgeStatus: status,
                    cliBinaryPath: cliPath,
                    officialReport: official,
                    localReport: local,
                    runningProcesses: procs
                )
            }.value

            guard !Task.isCancelled, let self else { return }

            let now = Date()
            self.bridgeStatus = payload.bridgeStatus
            self.cliBinaryPath = payload.cliBinaryPath
            self.officialReport = payload.officialReport
            self.localReport = payload.localReport
            self.runningProcesses = payload.runningProcesses

            if payload.officialReport.hasSnapshot,
               (payload.officialReport.primaryFiveHour != nil || payload.officialReport.primaryWeekly != nil),
               let age = payload.officialReport.staleAgeSeconds, age < 120 {
                if self.officialAuthRequired {
                    self.officialAuthRequired = false
                    self.bridgeFeedback = nil
                }
            }

            if let weekly = payload.officialReport.primaryWeekly,
               !weekly.isResetElapsed,
               weekly.usedFraction >= 0.10,
               payload.localReport.week.estimatedCostUSD > 0 {
                self.preferences.savedFullWeekCostUSD = payload.localReport.week.estimatedCostUSD / weekly.usedFraction
                self.preferences.savedFullWeekTokens = Int(Double(payload.localReport.week.totalTokens) / weekly.usedFraction)
            }

            let currentTokens = payload.localReport.week.totalTokens
            let tokensIncreased = currentTokens > self.lastSeenTotalTokens
            self.lastSeenTotalTokens = currentTokens

            self.isRefreshing = false
            self.onMenuBarUpdate?()
            NotificationManager.shared.evaluateAlerts(
                official: payload.officialReport,
                local: payload.localReport,
                preferences: self.preferences
            )

            let age = payload.officialReport.staleAgeSeconds ?? .infinity
            let sinceLastAttempt = now.timeIntervalSince(self.lastAutoSyncAttempt)
            if !self.isSyncingOfficial && sinceLastAttempt >= 90 {
                if !payload.officialReport.hasSnapshot || age >= 300 || (tokensIncreased && age >= 120) {
                    Task { [weak self] in
                        await self?.syncOfficialInBackground(force: false)
                    }
                }
            }
        }
    }

    func restartTimer() {
        timer?.invalidate()
        startTimer()
    }

    func syncOfficialInBackground(force: Bool) async {
        guard !isSyncingOfficial else { return }
        if !force, Date().timeIntervalSince(lastAutoSyncAttempt) < 90 {
            return
        }
        isSyncingOfficial = true
        onSyncStateChanged?(true)
        lastAutoSyncAttempt = Date()

        let result = await silentSyncer.sync(timeoutSeconds: 12.0)
        isSyncingOfficial = false
        onSyncStateChanged?(false)

        switch result {
        case .synced:
            officialAuthRequired = false
            bridgeFeedback = nil
            refreshNow()
        case .authRequired:
            officialAuthRequired = true
            bridgeFeedback = preferences.language.isChinese
                ? "agy CLI 需要重新登录，点击下方按钮在终端完成登录后即可关闭终端。"
                : "agy CLI requires sign-in. Complete login in Terminal once, then you can close Terminal."
        case .cliNotFound:
            bridgeFeedback = preferences.language.isChinese
                ? "未找到 agy CLI，请先安装 Antigravity CLI。"
                : "agy CLI not found. Please install Antigravity CLI first."
        case .failed(let msg):
            if force {
                bridgeFeedback = msg
            }
        }
    }

    func openTerminalToConnectCLI() {
        let isChinese = preferences.language.isChinese
        let snapshotPath = bridgeInstaller.snapshotURL.path
        let doneFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agy-login-done-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: doneFileURL)

        func shQuote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        }

        let usingSupervisor: Bool
        let terminalCommand: String
        if let appExec = SilentCLISyncer.resolveAppExecutableURL() {
            usingSupervisor = true
            let langFlag = isChinese ? "zh" : "en"
            terminalCommand = "clear; exec \(shQuote(appExec.path)) \(CLILoginSupervisor.flag) --snapshot \(shQuote(snapshotPath)) --lang \(langFlag) --done-file \(shQuote(doneFileURL.path))"
        } else {
            usingSupervisor = false
            terminalCommand = """
            export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"; \
            clear; agy
            """
        }

        let escaped = terminalCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let appleScript = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
            return id of front window
        end tell
        """

        bridgeFeedback = isChinese
            ? "正在打开终端启动 agy 登录监督器…"
            : "Opening Terminal with agy sign-in supervisor…"

        loginTerminalWatchTask?.cancel()
        loginTerminalWatchTask = Task { [weak self] in
            let launchResult: (windowId: Int?, errorMessage: String?) = await Task.detached(priority: .userInitiated) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", appleScript]
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                do {
                    try process.run()
                    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    if process.terminationStatus != 0 {
                        let stderrText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let msg = isChinese
                            ? "无法自动打开终端（请检查「系统设置 → 隐私与安全性 → 自动化」中是否允许控制 Terminal）：\(stderrText)"
                            : "Failed to open Terminal (check System Settings → Privacy & Security → Automation): \(stderrText)"
                        return (nil, msg)
                    }
                    let outText = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return (Int(outText), nil)
                } catch {
                    let msg = isChinese
                        ? "启动 osascript 失败：\(error.localizedDescription)"
                        : "Failed to run osascript: \(error.localizedDescription)"
                    return (nil, msg)
                }
            }.value

            guard !Task.isCancelled, let self else { return }
            if let errorMessage = launchResult.errorMessage {
                self.bridgeFeedback = errorMessage
                return
            }

            self.bridgeFeedback = isChinese
                ? "已打开终端。完成登录后将自动同步并关闭窗口；中途关窗也不会残留后台进程。"
                : "Opened Terminal. Sign-in auto-syncs and closes the window; closing early leaves no orphan process."

            guard usingSupervisor, let windowId = launchResult.windowId else { return }

            // Poll doneFile for up to 10 minutes; auto-close ONLY this exact Terminal window on success.
            let deadline = Date().addingTimeInterval(600)
            while !Task.isCancelled && Date() < deadline {
                if let status = try? String(contentsOf: doneFileURL, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines) {
                    try? FileManager.default.removeItem(at: doneFileURL)
                    if status == "ok" {
                        // Brief pause so user sees the green checkmark and helper process fully exits before closing window.
                        try? await Task.sleep(for: .milliseconds(800))
                        guard !Task.isCancelled else { return }
                        await Task.detached(priority: .utility) {
                            let closeScript = """
                            tell application "Terminal"
                                repeat with w in windows
                                    if id of w is \(windowId) then
                                        if (count of tabs of w) is 1 then
                                            close w saving no
                                        end if
                                        exit repeat
                                    end if
                                end repeat
                            end tell
                            """
                            let proc = Process()
                            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                            proc.arguments = ["-e", closeScript]
                            proc.standardOutput = FileHandle.nullDevice
                            proc.standardError = FileHandle.nullDevice
                            try? proc.run()
                            proc.waitUntilExit()
                        }.value

                        self.officialAuthRequired = false
                        self.bridgeFeedback = nil
                        self.refreshNow()
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            try? FileManager.default.removeItem(at: doneFileURL)
        }
    }

    func terminateProcess(_ proc: RunningProcessInfo) {
        guard !terminatingProcessIds.contains(proc.id) else { return }
        terminatingProcessIds.insert(proc.id)
        let isDesktopApp = proc.kind == "App"
        let rootPID = proc.id
        let knownMembers = proc.memberPIDs

        Task.detached(priority: .userInitiated) { [weak self] in
            // 1) Re-sample live subtree so we don't miss freshly spawned helpers or kill stale PIDs.
            let liveSubtree = Self.collectLiveSubtreePIDs(rootPID: rootPID, seedMembers: knownMembers)
            let stampedTargets: [(pid: Int32, startSec: UInt64, startUsec: UInt64)] = liveSubtree.compactMap { pid in
                guard let stamp = Self.processStartStamp(pid) else { return nil }
                return (pid: pid, startSec: stamp.sec, startUsec: stamp.usec)
            }

            // 2) Graceful terminate first (NSRunningApplication for desktop app, SIGTERM for CLI).
            if isDesktopApp {
                _ = await MainActor.run {
                    NSRunningApplication(processIdentifier: rootPID)?.terminate()
                }
            } else {
                _ = kill(rootPID, SIGTERM)
            }

            let waitBudget: TimeInterval = isDesktopApp ? 1.2 : 0.3
            let deadline = Date().addingTimeInterval(waitBudget)
            while Date() < deadline {
                let anyAlive = stampedTargets.contains { target in
                    Self.isSameProcessAlive(pid: target.pid, startSec: target.startSec, startUsec: target.startUsec)
                }
                if !anyAlive { break }
                try? await Task.sleep(for: .milliseconds(50))
            }

            // 3) Force-kill remaining subtree members only if start timestamp still matches (PID-reuse safe).
            for target in stampedTargets {
                if Self.isSameProcessAlive(pid: target.pid, startSec: target.startSec, startUsec: target.startUsec) {
                    _ = kill(target.pid, SIGKILL)
                }
            }

            try? await Task.sleep(for: .milliseconds(120))
            await MainActor.run {
                guard let self else { return }
                self.terminatingProcessIds.remove(rootPID)
                self.refreshNow()
            }
        }
    }

    func uninstallBridge() {
        do {
            try bridgeInstaller.uninstall()
            bridgeStatus = bridgeInstaller.status()
            bridgeFeedback = preferences.language.isChinese
                ? "已移除桥接脚本并还原 settings.json。"
                : "Removed statusLine bridge and restored settings.json."
            refreshNow()
        } catch {
            bridgeFeedback = preferences.language.isChinese
                ? "卸载失败：\(error.localizedDescription)"
                : "Uninstall failed: \(error.localizedDescription)"
        }
    }

    func menuBarColumns() -> [MenuBarColumnItem] {
        var columns: [MenuBarColumnItem] = []

        if preferences.showFiveHourInMenuBar {
            if let fiveHour = officialReport.primaryFiveHour {
                let hex = Palette.levelHex(for: fiveHour.usedFraction, overPace: fiveHour.isOverPace)
                columns.append(MenuBarColumnItem(
                    topLabel: "5H",
                    value: "\(fiveHour.usedPercentageInt)%",
                    valueHex: hex
                ))
            } else {
                columns.append(MenuBarColumnItem(topLabel: "5H", value: "--", valueHex: 0x9A9A9A))
            }
        }

        if preferences.showWeeklyInMenuBar {
            if let weekly = officialReport.primaryWeekly {
                let hex = Palette.levelHex(for: weekly.usedFraction, overPace: weekly.isOverPace)
                columns.append(MenuBarColumnItem(
                    topLabel: "WEEK",
                    value: "\(weekly.usedPercentageInt)%",
                    valueHex: hex
                ))
            } else {
                columns.append(MenuBarColumnItem(topLabel: "WEEK", value: "--", valueHex: 0x9A9A9A))
            }
        }

        if preferences.showCacheRateInMenuBar {
            let value = localReport.today.totalInputTokens > 0
                ? UsageFormatter.percentage(localReport.today.cacheHitRate)
                : "--"
            columns.append(MenuBarColumnItem(
                topLabel: "CACHE",
                value: value,
                valueHex: localReport.today.totalInputTokens > 0 ? Palette.accentHex : 0x9A9A9A
            ))
        }

        if preferences.showTodayCostInMenuBar {
            let formatted = preferences.formatMoneyCompact(localReport.today.estimatedCostUSD)
            columns.append(MenuBarColumnItem(
                topLabel: "TODAY",
                value: formatted,
                valueHex: 0xECECEC
            ))
        }

        if preferences.showContextInMenuBar {
            if let used = officialReport.contextWindow?.usedPercentage {
                let frac = max(0, min(1, used / 100.0))
                columns.append(MenuBarColumnItem(
                    topLabel: "CTX",
                    value: "\(Int(used))%",
                    valueHex: Palette.levelHex(for: frac)
                ))
            } else {
                columns.append(MenuBarColumnItem(topLabel: "CTX", value: "--", valueHex: 0x9A9A9A))
            }
        }

        return columns
    }

    private enum ProcessKind: Equatable {
        case desktop(main: Bool)
        case cli
    }

    private struct RawProcess {
        let pid: Int32
        let ppid: Int32
        let kind: ProcessKind
        let tty: String?
        let bytes: Int64
    }

    /// Groups Antigravity desktop app + helpers into 1 row (with summed memory),
    /// and lists each real user `agy` CLI session with its working directory, detached state, and memory,
    /// excluding our own monitor app, XPC services, and background `agy-silent-sync-` probes.
    private nonisolated static func detectRunningProcesses(excluding selfPid: Int32) -> [RunningProcessInfo] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-axo", "pid=,ppid=,rss=,tty=,ucomm="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var raw: [RawProcess] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard parts.count == 5,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]),
                  let rssKB = Int64(parts[2]),
                  pid != selfPid else { continue }
            let rawTTY = String(parts[3]).trimmingCharacters(in: .whitespaces)
            let tty: String? = (rawTTY == "??" || rawTTY == "-" || rawTTY.isEmpty) ? nil : rawTTY
            let ucomm = String(parts[4]).trimmingCharacters(in: .whitespaces)
            guard let kind = classifyProcess(pid: pid, ucomm: ucomm) else { continue }
            raw.append(RawProcess(pid: pid, ppid: ppid, kind: kind, tty: tty, bytes: rssKB * 1024))
        }

        let ids = Set(raw.map(\.pid))
        var children: [Int32: [RawProcess]] = [:]
        var roots: [RawProcess] = []
        for item in raw {
            if item.ppid != item.pid && ids.contains(item.ppid) {
                children[item.ppid, default: []].append(item)
            } else {
                roots.append(item)
            }
        }
        func subtree(_ item: RawProcess) -> [RawProcess] {
            [item] + (children[item.pid] ?? []).flatMap(subtree)
        }

        var results: [RunningProcessInfo] = []

        // 1) Antigravity Desktop: merge main app + all helpers/subprocesses into one row.
        let desktopRoots = roots.filter {
            if case .desktop = $0.kind { return true }
            return false
        }
        if !desktopRoots.isEmpty {
            let mainRoot = desktopRoots.first(where: { $0.kind == .desktop(main: true) })
                ?? desktopRoots.min(by: { $0.pid < $1.pid })!
            let allDesktopMembers = desktopRoots.flatMap(subtree)
            let totalBytes = allDesktopMembers.reduce(Int64(0)) { $0 + $1.bytes }
            results.append(RunningProcessInfo(
                id: mainRoot.pid,
                memberPIDs: Array(Set(allDesktopMembers.map(\.pid))).sorted(),
                name: "Antigravity",
                detail: nil,
                kind: "App",
                tty: nil,
                isDetached: false,
                memoryBytes: totalBytes
            ))
        }

        // 2) Real agy CLI sessions: one row per root session with working directory, detached flag & summed memory.
        for root in roots.filter({ $0.kind == .cli }).sorted(by: { $0.pid < $1.pid }) {
            let members = subtree(root)
            let totalBytes = members.reduce(Int64(0)) { $0 + $1.bytes }
            let isDetached = (root.tty == nil && root.ppid == 1)
            results.append(RunningProcessInfo(
                id: root.pid,
                memberPIDs: Array(Set(members.map(\.pid))).sorted(),
                name: "agy CLI",
                detail: processWorkingDirectory(root.pid),
                kind: "CLI",
                tty: root.tty,
                isDetached: isDetached,
                memoryBytes: totalBytes
            ))
        }

        return results
    }

    private nonisolated static func collectLiveSubtreePIDs(rootPID: Int32, seedMembers: [Int32]) -> [Int32] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-axo", "pid=,ppid="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return seedMembers }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return seedMembers }

        var childrenByPPID: [Int32: [Int32]] = [:]
        var allPIDs = Set<Int32>()
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.trimmingCharacters(in: .whitespaces).split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { continue }
            allPIDs.insert(pid)
            if ppid != pid {
                childrenByPPID[ppid, default: []].append(pid)
            }
        }

        // BFS from rootPID + any still-alive seed members (covers Desktop helpers reparented to PID 1).
        var visited = Set<Int32>()
        var queue: [Int32] = []
        for candidate in ([rootPID] + seedMembers) where allPIDs.contains(candidate) && !visited.contains(candidate) {
            visited.insert(candidate)
            queue.append(candidate)
        }
        var idx = 0
        while idx < queue.count {
            let cur = queue[idx]
            idx += 1
            for child in childrenByPPID[cur] ?? [] where !visited.contains(child) {
                visited.insert(child)
                queue.append(child)
            }
        }
        return Array(visited)
    }

    private nonisolated static func processStartStamp(_ pid: Int32) -> (sec: UInt64, usec: UInt64)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return (sec: info.pbi_start_tvsec, usec: info.pbi_start_tvusec)
    }

    private nonisolated static func isSameProcessAlive(pid: Int32, startSec: UInt64, startUsec: UInt64) -> Bool {
        guard let current = processStartStamp(pid) else { return false }
        return current.sec == startSec && current.usec == startUsec
    }

    private nonisolated static func classifyProcess(pid: Int32, ucomm: String) -> ProcessKind? {
        let lower = ucomm.lowercased()
        if lower.hasPrefix("antigravityusage") { return nil }
        guard let path = processExecutablePath(pid) else {
            return lower == "agy" ? .cli : nil
        }
        let pathLower = path.lowercased()
        if pathLower.contains("antigravityusagemonitor") || pathLower.contains("antigravity usage monitor") {
            return nil
        }
        // Only match actual Antigravity.app bundle processes (excludes macOS XPC services like AutoFill / OpenPanel / QuickLook).
        if pathLower.contains("/antigravity.app/") {
            let isMain = pathLower.hasSuffix("/antigravity.app/contents/macos/antigravity")
            return .desktop(main: isMain)
        }
        let base = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        if base == "agy" {
            // Exclude our own ephemeral background quota probes.
            let args = processArguments(pid)
            if args.contains(where: { $0.contains("agy-silent-sync-") }) {
                return nil
            }
            return .cli
        }
        return nil
    }

    private nonisolated static func processExecutablePath(_ pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    private nonisolated static func processWorkingDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        guard !path.isEmpty else { return nil }
        if path == FileManager.default.homeDirectoryForCurrentUser.path { return "~" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private nonisolated static func processArguments(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
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

    private func startTimer() {
        let interval = TimeInterval(max(10, preferences.refreshIntervalSeconds))
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshNow()
            }
        }
    }

    private func startSnapshotWatcher() {
        directoryWatcher?.cancel()
        directoryWatcher = nil
        if watchedFD >= 0 {
            close(watchedFD)
            watchedFD = -1
        }

        let dirPath = bridgeInstaller.cliConfigDirectory.path
        guard FileManager.default.fileExists(atPath: dirPath) else { return }

        let fd = open(dirPath, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.watcherDebounceTask?.cancel()
                self.watcherDebounceTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    self?.refreshNow()
                }
            }
        }
        source.resume()
        directoryWatcher = source
    }
}
