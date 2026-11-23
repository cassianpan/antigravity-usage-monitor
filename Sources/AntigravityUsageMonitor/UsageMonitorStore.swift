import AppKit
import Foundation
import UsageCore

struct RunningProcessInfo: Identifiable, Sendable, Equatable {
    let id: Int32
    let name: String
    let kind: String
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
        guard Date().timeIntervalSince(lastUpdateCheckAt) >= 12 * 3600 else { return }
        await checkForUpdates(manual: false)
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

        // Capture running GUI apps on main thread (NSWorkspace is fast in-memory),
        // then run pgrep + file I/O + JSON parsing on a background utility task.
        let guiApps: [RunningProcessInfo] = NSWorkspace.shared.runningApplications.compactMap { app in
            guard let name = app.localizedName else { return nil }
            let lower = name.lowercased()
            guard lower.contains("antigravity") && !lower.contains("usage monitor") else { return nil }
            return RunningProcessInfo(id: app.processIdentifier, name: name, kind: "App")
        }

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
                let cliProcs = Self.detectAgyCLIProcesses()
                return RefreshPayload(
                    bridgeStatus: status,
                    cliBinaryPath: cliPath,
                    officialReport: official,
                    localReport: local,
                    runningProcesses: guiApps + cliProcs
                )
            }.value

            guard !Task.isCancelled, let self else { return }

            let now = Date()
            self.bridgeStatus = payload.bridgeStatus
            self.cliBinaryPath = payload.cliBinaryPath
            self.officialReport = payload.officialReport
            self.localReport = payload.localReport
            self.runningProcesses = payload.runningProcesses

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
        let terminalCommand = """
        export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"; \
        clear; echo "=== Antigravity Usage Monitor · agy CLI Sign-in ==="; echo ""; \
        if command -v agy >/dev/null 2>&1; then \
          echo "Complete sign-in in agy below. Once signed in, you can quit agy (Ctrl+D) and close this window."; \
          echo "The menu bar app will refresh official limits automatically in the background."; \
          echo ""; \
          agy; \
        else \
          echo "agy CLI not found in PATH."; \
          echo "Install Antigravity CLI first, then run 'agy' to sign in."; \
        fi
        """

        let escaped = terminalCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let appleScript = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """

        Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", appleScript]
            try? process.run()
        }

        bridgeFeedback = preferences.language.isChinese
            ? "已打开终端启动 agy。完成登录后即可关闭终端，App 会在后台自动刷新官方额度。"
            : "Opened Terminal with agy. After signing in you can close Terminal — limits sync automatically in the background."
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

    private nonisolated static func detectAgyCLIProcesses() -> [RunningProcessInfo] {
        var found: [RunningProcessInfo] = []
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-x", "agy"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        if (try? proc.run()) != nil {
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                for line in output.split(separator: "\n") {
                    if let pid = Int32(line.trimmingCharacters(in: .whitespaces)) {
                        found.append(RunningProcessInfo(id: pid, name: "agy CLI", kind: "CLI"))
                    }
                }
            }
        }
        return found
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
