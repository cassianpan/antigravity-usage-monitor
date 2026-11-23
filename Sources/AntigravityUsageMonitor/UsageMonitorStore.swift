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

@MainActor
@Observable
final class UsageMonitorStore {
    private let transcriptIndex: TranscriptIndex
    private let aggregator: UsageAggregator
    private let quotaEvaluator: QuotaEvaluator
    private let silentSyncer: SilentCLISyncer
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

    var onMenuBarUpdate: (() -> Void)?

    private var timer: Timer?
    private var directoryWatcher: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1
    private var lastAutoSyncAttempt: Date = .distantPast
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

        refreshNow()
        startTimer()
        startSnapshotWatcher()

        // Silently fetch official limits on launch without requiring an open Terminal.
        Task { [weak self] in
            await self?.syncOfficialInBackground(force: true)
        }
    }

    func refreshNow() {
        isRefreshing = true
        let now = Date()

        bridgeStatus = bridgeInstaller.status()
        cliBinaryPath = SilentCLISyncer.locateAgyBinary()?.path
        let snapshot = quotaEvaluator.loadSnapshot(from: bridgeInstaller.snapshotURL)
        let evaluatedOfficial = quotaEvaluator.evaluate(snapshot: snapshot, now: now)
        officialReport = evaluatedOfficial

        let scan = transcriptIndex.refresh()
        localReport = aggregator.aggregate(
            records: scan.records,
            conversationCount: scan.conversationCount,
            now: now,
            officialWeeklyResetTime: evaluatedOfficial.primaryWeekly?.resetTime,
            billingDay: preferences.billingDay > 0 ? preferences.billingDay : nil
        )

        let currentTokens = localReport.week.totalTokens
        let tokensIncreased = currentTokens > lastSeenTotalTokens
        lastSeenTotalTokens = currentTokens

        runningProcesses = detectRunningProcesses()

        isRefreshing = false
        onMenuBarUpdate?()

        // Auto background official sync when stale (>= 5 min) or after new token activity (>= 2 min).
        let age = evaluatedOfficial.staleAgeSeconds ?? .infinity
        let sinceLastAttempt = now.timeIntervalSince(lastAutoSyncAttempt)
        if !isSyncingOfficial && sinceLastAttempt >= 90 {
            if !evaluatedOfficial.hasSnapshot || age >= 300 || (tokensIncreased && age >= 120) {
                Task { [weak self] in
                    await self?.syncOfficialInBackground(force: false)
                }
            }
        }
    }

    func syncOfficialInBackground(force: Bool) async {
        guard !isSyncingOfficial else { return }
        if !force, Date().timeIntervalSince(lastAutoSyncAttempt) < 90 {
            return
        }
        isSyncingOfficial = true
        lastAutoSyncAttempt = Date()

        let result = await silentSyncer.sync(timeoutSeconds: 12.0)
        isSyncingOfficial = false

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

    func restartTimer() {
        timer?.invalidate()
        startTimer()
    }

    /// Launches Terminal.app solely for one-time `agy` sign-in. Once signed in,
    /// the user can close Terminal and the app syncs official limits silently in the background.
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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        do {
            try process.run()
            bridgeFeedback = preferences.language.isChinese
                ? "已打开终端启动 agy。完成登录后即可关闭终端，App 会在后台自动刷新官方额度。"
                : "Opened Terminal with agy. After signing in you can close Terminal — limits sync automatically in the background."
        } catch {
            bridgeFeedback = preferences.language.isChinese
                ? "打开终端失败：\(error.localizedDescription)"
                : "Failed to open Terminal: \(error.localizedDescription)"
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
            let cost = localReport.today.estimatedCostUSD
            let formatted = cost >= 100 ? String(format: "$%.0f", cost) : UsageFormatter.currency(cost)
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

    private func detectRunningProcesses() -> [RunningProcessInfo] {
        var found: [RunningProcessInfo] = []
        let apps = NSWorkspace.shared.runningApplications
        for app in apps {
            guard let name = app.localizedName else { continue }
            let lower = name.lowercased()
            if lower.contains("antigravity") && !lower.contains("usage monitor") {
                found.append(RunningProcessInfo(id: app.processIdentifier, name: name, kind: "App"))
            }
        }

        // Also detect running `agy` CLI processes cleanly via pgrep.
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
                self?.refreshNow()
            }
        }
        source.resume()
        directoryWatcher = source
    }
}
