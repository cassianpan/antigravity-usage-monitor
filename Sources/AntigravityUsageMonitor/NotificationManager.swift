import AppKit
import Foundation
import UsageCore
import UserNotifications

@MainActor
final class NotificationManager {
    static let shared = NotificationManager()

    private let defaults = UserDefaults.standard
    private var sentKeys: Set<String>
    private let sentKeysStorageKey = "notifications.sentKeys"

    private init() {
        let saved = defaults.stringArray(forKey: sentKeysStorageKey) ?? []
        self.sentKeys = Set(saved)
    }

    private var hasBundleIdentifier: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    func requestPermissionIfNeeded() {
        guard hasBundleIdentifier else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func openSystemNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func evaluateAlerts(
        official: OfficialQuotaReport,
        local: LocalUsageReport,
        preferences: AppPreferences
    ) {
        guard hasBundleIdentifier else { return }
        let zh = preferences.language.isChinese

        if preferences.enableUsageAlerts && official.hasSnapshot {
            for bucket in official.buckets where !bucket.isResetElapsed && !bucket.isDisabled {
                let resetStamp = bucket.resetTime.map { String(Int($0.timeIntervalSince1970)) } ?? "none"

                if bucket.usedFraction >= 0.95 {
                    let key = "95.\(bucket.bucketId).\(resetStamp)"
                    if markIfNew(key) {
                        post(
                            id: key,
                            title: zh ? "Antigravity 额度即将耗尽" : "Antigravity limit nearly reached",
                            body: zh
                                ? "\(bucket.displayName) 已使用 \(bucket.usedPercentageInt)%，请注意控制节奏。"
                                : "\(bucket.displayName) reached \(bucket.usedPercentageInt)%."
                        )
                    }
                } else if bucket.isOverPace, let safe = bucket.safeLineFraction {
                    let key = "pace.\(bucket.bucketId).\(resetStamp)"
                    if markIfNew(key) {
                        post(
                            id: key,
                            title: zh ? "Antigravity 消耗超过安全线" : "Antigravity usage past safe line",
                            body: zh
                                ? "\(bucket.displayName) 已用 \(bucket.usedPercentageInt)%（当前安全线 \(UsageFormatter.percentage(safe))）。"
                                : "\(bucket.displayName) is at \(bucket.usedPercentageInt)% (safe line \(UsageFormatter.percentage(safe)))."
                        )
                    }
                }
            }
        }

        if preferences.enableBillingReminders,
           preferences.billingDay > 0,
           let period = local.monthPeriod {
            let days = period.remainingDays
            if days == 3 || days == 1 {
                let dayStamp = CachedFormatters.enDay.string(from: Date())
                let key = "billing.\(days)d.\(dayStamp)"
                if markIfNew(key) {
                    post(
                        id: key,
                        title: zh ? "Antigravity 订阅即将续费" : "Antigravity subscription renewal soon",
                        body: zh
                            ? "距离本账单周期结束还剩 \(days) 天（每月 \(preferences.billingDay) 日）。"
                            : "\(days) day(s) left in your current billing cycle (day \(preferences.billingDay))."
                    )
                }
            }
        }
    }

    private func markIfNew(_ key: String) -> Bool {
        guard !sentKeys.contains(key) else { return false }
        sentKeys.insert(key)
        // Keep bounded history
        if sentKeys.count > 120 {
            sentKeys = Set(sentKeys.suffix(80))
        }
        defaults.set(Array(sentKeys), forKey: sentKeysStorageKey)
        return true
    }

    private func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
