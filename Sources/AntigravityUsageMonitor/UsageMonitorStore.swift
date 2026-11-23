import AppKit
import Foundation
import UsageCore

enum MetricSeverity {
    case normal
    case warning
    case danger

    var nsColor: NSColor {
        switch self {
        case .normal: return .labelColor
        case .warning: return .systemOrange
        case .danger: return .systemRed
        }
    }
}

struct MenuBarColumnItem {
    let label: String
    let value: String
    let severity: MetricSeverity
}

@MainActor
@Observable
final class UsageMonitorStore {
    private let transcriptIndex: TranscriptIndex
    private let aggregator: UsageAggregator
    private let quotaEvaluator: QuotaEvaluator
    let bridgeInstaller: StatusLineBridgeInstaller
    let preferences: AppPreferences

    var localReport: LocalUsageReport = LocalUsageReport()
    var officialReport: OfficialQuotaReport = OfficialQuotaReport()
    var bridgeStatus: BridgeStatus = .notInstalled(existingCommand: nil)
    var bridgeFeedback: String?
    var isRefreshing: Bool = false

    var onMenuBarUpdate: (() -> Void)?

    private var timer: Timer?
    private var directoryWatcher: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1

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

        refreshNow()
        startTimer()
        startSnapshotWatcher()
    }

    func refreshNow() {
        isRefreshing = true
        let now = Date()

        bridgeStatus = bridgeInstaller.status()
        let snapshot = quotaEvaluator.loadSnapshot(from: bridgeInstaller.snapshotURL)
        let evaluatedOfficial = quotaEvaluator.evaluate(snapshot: snapshot, now: now)
        officialReport = evaluatedOfficial

        let scan = transcriptIndex.refresh()
        localReport = aggregator.aggregate(
            records: scan.records,
            conversationCount: scan.conversationCount,
            now: now,
            officialWeeklyResetTime: evaluatedOfficial.primaryWeekly?.resetTime
        )

        isRefreshing = false
        onMenuBarUpdate?()
    }

    func restartTimer() {
        timer?.invalidate()
        startTimer()
    }

    func installBridge() {
        do {
            let status = try bridgeInstaller.install()
            bridgeStatus = status
            switch status {
            case .installedDirect:
                bridgeFeedback = "已安全接入 agy statusLine（已备份原 settings.json 并保留默认状态栏）。运行一次 agy 即可看到官方限额。"
            case .installedChained(let original):
                bridgeFeedback = "已安全接入并链式保留你的原状态栏脚本：\(original)"
            case .notInstalled:
                bridgeFeedback = nil
            }
            startSnapshotWatcher()
            refreshNow()
        } catch {
            bridgeFeedback = "接入失败：\(error.localizedDescription)"
        }
    }

    func uninstallBridge() {
        do {
            try bridgeInstaller.uninstall()
            bridgeStatus = bridgeInstaller.status()
            bridgeFeedback = "已卸载桥接脚本并还原 settings.json。"
            refreshNow()
        } catch {
            bridgeFeedback = "卸载失败：\(error.localizedDescription)"
        }
    }

    func menuBarColumns() -> [MenuBarColumnItem] {
        var columns: [MenuBarColumnItem] = []

        if preferences.showFiveHourInMenuBar {
            if let fiveHour = officialReport.primaryFiveHour {
                let severity: MetricSeverity = fiveHour.isOverPace || fiveHour.usedFraction >= 0.85
                    ? .danger
                    : (fiveHour.usedFraction >= 0.65 ? .warning : .normal)
                columns.append(MenuBarColumnItem(
                    label: "5h",
                    value: "\(fiveHour.usedPercentageInt)%",
                    severity: severity
                ))
            } else {
                columns.append(MenuBarColumnItem(label: "5h", value: "--", severity: .normal))
            }
        }

        if preferences.showWeeklyInMenuBar {
            if let weekly = officialReport.primaryWeekly {
                let severity: MetricSeverity = weekly.isOverPace || weekly.usedFraction >= 0.85
                    ? .danger
                    : (weekly.usedFraction >= 0.65 ? .warning : .normal)
                columns.append(MenuBarColumnItem(
                    label: "周",
                    value: "\(weekly.usedPercentageInt)%",
                    severity: severity
                ))
            } else {
                columns.append(MenuBarColumnItem(label: "周", value: "--", severity: .normal))
            }
        }

        if preferences.showCacheRateInMenuBar {
            let rate = localReport.today.cacheHitRate
            let value = localReport.today.totalInputTokens > 0 ? UsageFormatter.percentage(rate) : "--"
            columns.append(MenuBarColumnItem(label: "缓存", value: value, severity: .normal))
        }

        if preferences.showTodayCostInMenuBar {
            let cost = UsageFormatter.currency(localReport.today.estimatedCostUSD)
            columns.append(MenuBarColumnItem(label: "今", value: cost, severity: .normal))
        }

        if preferences.showContextInMenuBar {
            if let used = officialReport.contextWindow?.usedPercentage {
                let severity: MetricSeverity = used >= 85 ? .danger : (used >= 65 ? .warning : .normal)
                columns.append(MenuBarColumnItem(label: "Ctx", value: "\(Int(used))%", severity: severity))
            } else {
                columns.append(MenuBarColumnItem(label: "Ctx", value: "--", severity: .normal))
            }
        }

        return columns
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
