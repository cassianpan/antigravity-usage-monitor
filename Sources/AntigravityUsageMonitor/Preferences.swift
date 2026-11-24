import Foundation
import ServiceManagement
import SwiftUI
import UsageCore

enum SectionDensity: String, CaseIterable, Identifiable {
    case detailed = "detailed"
    case simple = "simple"
    case hidden = "hidden"

    var id: String { rawValue }

    func label(zh: Bool) -> String {
        switch self {
        case .detailed: return zh ? "详细" : "Detailed"
        case .simple: return zh ? "简洁" : "Simple"
        case .hidden: return zh ? "隐藏" : "Hidden"
        }
    }
}

enum SpendWindowTab: String, CaseIterable, Identifiable {
    case month = "month"
    case week = "week"
    case today = "today"

    var id: String { rawValue }

    func label(l10n: L10n) -> String {
        switch self {
        case .month: return l10n.thisMonth
        case .week: return l10n.thisWeek
        case .today: return l10n.today
        }
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case menuBar = "menuBar"
    case panel = "panel"
    case data = "data"
    case general = "general"

    var id: String { rawValue }
}

@MainActor
@Observable
final class AppPreferences {
    private let defaults = UserDefaults.standard

    var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: Keys.language) }
    }

    var showFiveHourInMenuBar: Bool {
        didSet { defaults.set(showFiveHourInMenuBar, forKey: Keys.showFiveHour) }
    }
    var showWeeklyInMenuBar: Bool {
        didSet { defaults.set(showWeeklyInMenuBar, forKey: Keys.showWeekly) }
    }
    var showCacheRateInMenuBar: Bool {
        didSet { defaults.set(showCacheRateInMenuBar, forKey: Keys.showCacheRate) }
    }
    var showTodayCostInMenuBar: Bool {
        didSet { defaults.set(showTodayCostInMenuBar, forKey: Keys.showTodayCost) }
    }
    var showContextInMenuBar: Bool {
        didSet { defaults.set(showContextInMenuBar, forKey: Keys.showContext) }
    }

    var processesSectionDensity: SectionDensity {
        didSet { defaults.set(processesSectionDensity.rawValue, forKey: Keys.processesDensity) }
    }
    var quotaSectionDensity: SectionDensity {
        didSet { defaults.set(quotaSectionDensity.rawValue, forKey: Keys.quotaDensity) }
    }
    var contextSectionDensity: SectionDensity {
        didSet { defaults.set(contextSectionDensity.rawValue, forKey: Keys.contextDensity) }
    }
    var showEstimatedOutputSpeed: Bool {
        didSet { defaults.set(showEstimatedOutputSpeed, forKey: Keys.showEstimatedOutputSpeed) }
    }
    var spendSectionDensity: SectionDensity {
        didSet { defaults.set(spendSectionDensity.rawValue, forKey: Keys.spendDensity) }
    }

    var refreshIntervalSeconds: Int {
        didSet { defaults.set(refreshIntervalSeconds, forKey: Keys.refreshInterval) }
    }

    /// 0 = unset (natural month), 1...31 = subscription billing day of month.
    var billingDay: Int {
        didSet { defaults.set(billingDay, forKey: Keys.billingDay) }
    }

    var displayCurrency: DisplayCurrency {
        didSet { defaults.set(displayCurrency.rawValue, forKey: Keys.displayCurrency) }
    }

    var cnyExchangeRate: Double {
        didSet { defaults.set(cnyExchangeRate, forKey: Keys.cnyRate) }
    }

    var enableUsageAlerts: Bool {
        didSet { defaults.set(enableUsageAlerts, forKey: Keys.enableUsageAlerts) }
    }

    var enableBillingReminders: Bool {
        didSet { defaults.set(enableBillingReminders, forKey: Keys.enableBillingReminders) }
    }

    var autoCheckUpdates: Bool {
        didSet { defaults.set(autoCheckUpdates, forKey: Keys.autoCheckUpdates) }
    }

    var dismissedUpdateVersion: String {
        didSet { defaults.set(dismissedUpdateVersion, forKey: Keys.dismissedUpdateVersion) }
    }

    /// Persisted full-week cost/token basis learned from a previous week with >= 10% usage.
    var savedFullWeekCostUSD: Double {
        didSet { defaults.set(savedFullWeekCostUSD, forKey: Keys.savedFullWeekCostUSD) }
    }

    var savedFullWeekTokens: Int {
        didSet { defaults.set(savedFullWeekTokens, forKey: Keys.savedFullWeekTokens) }
    }

    func formatMoney(_ usd: Double) -> String {
        UsageFormatter.money(usd, currency: displayCurrency, cnyRate: cnyExchangeRate)
    }

    func formatMoneyCompact(_ usd: Double) -> String {
        UsageFormatter.moneyCompact(usd, currency: displayCurrency, cnyRate: cnyExchangeRate)
    }

    var selectedSpendTab: SpendWindowTab {
        didSet { defaults.set(selectedSpendTab.rawValue, forKey: Keys.spendTab) }
    }

    // Ephemeral UI disclosure states (no @State macro needed for CLT build)
    var processesExpanded: Bool = false
    var limitsCollapsed: Bool = false
    var contextCollapsed: Bool = false
    var spendCollapsed: Bool = false
    var selectedSettingsTab: SettingsTab = .menuBar
    var launchAtLoginEnabled: Bool = false
    var launchAtLoginError: String?

    var l10n: L10n {
        L10n(zh: language.isChinese)
    }

    func syncLaunchAtLoginStatus() {
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLoginError = language.isChinese
                ? "设置开机自启失败（请先将 App 放入 /Applications）：\(error.localizedDescription)"
                : "Failed to update Login Item (move App to /Applications first): \(error.localizedDescription)"
        }
        syncLaunchAtLoginStatus()
    }

    private enum Keys {
        static let prefsVersion = "prefs.schemaVersion"
        static let language = "general.language"
        static let showFiveHour = "menubar.showFiveHour"
        static let showWeekly = "menubar.showWeekly"
        static let showCacheRate = "menubar.showCacheRate"
        static let showTodayCost = "menubar.showTodayCost"
        static let showContext = "menubar.showContext"
        static let processesDensity = "panel.processesDensity"
        static let quotaDensity = "panel.quotaDensity"
        static let contextDensity = "panel.contextDensity"
        static let showEstimatedOutputSpeed = "panel.showEstimatedOutputSpeed"
        static let spendDensity = "panel.spendDensity"
        static let refreshInterval = "refresh.intervalSeconds"
        static let billingDay = "subscription.billingDay"
        static let displayCurrency = "general.displayCurrency"
        static let cnyRate = "general.cnyExchangeRate"
        static let enableUsageAlerts = "alerts.usage"
        static let enableBillingReminders = "alerts.billing"
        static let autoCheckUpdates = "updates.autoCheck"
        static let dismissedUpdateVersion = "updates.dismissedVersion"
        static let savedFullWeekCostUSD = "quota.savedFullWeekCostUSD"
        static let savedFullWeekTokens = "quota.savedFullWeekTokens"
        static let spendTab = "panel.spendTab"
    }

    init() {
        defaults.register(defaults: [
            Keys.language: AppLanguage.system.rawValue,
            Keys.showFiveHour: true,
            Keys.showWeekly: false,
            Keys.showCacheRate: false,
            Keys.showTodayCost: false,
            Keys.showContext: false,
            Keys.processesDensity: SectionDensity.simple.rawValue,
            Keys.quotaDensity: SectionDensity.detailed.rawValue,
            Keys.contextDensity: SectionDensity.detailed.rawValue,
            Keys.showEstimatedOutputSpeed: true,
            Keys.spendDensity: SectionDensity.detailed.rawValue,
            Keys.refreshInterval: 30,
            Keys.billingDay: 0,
            Keys.displayCurrency: DisplayCurrency.usd.rawValue,
            Keys.cnyRate: 7.25,
            Keys.enableUsageAlerts: true,
            Keys.enableBillingReminders: true,
            Keys.autoCheckUpdates: true,
            Keys.dismissedUpdateVersion: "",
            Keys.savedFullWeekCostUSD: 0.0,
            Keys.savedFullWeekTokens: 0,
            Keys.spendTab: SpendWindowTab.week.rawValue,
        ])

        // One-time migration: align default menu bar to 5H-only (matching claude-usage-monitor).
        if defaults.integer(forKey: Keys.prefsVersion) < 2 {
            defaults.set(true, forKey: Keys.showFiveHour)
            defaults.set(false, forKey: Keys.showWeekly)
            defaults.set(false, forKey: Keys.showTodayCost)
            defaults.set(false, forKey: Keys.showCacheRate)
            defaults.set(false, forKey: Keys.showContext)
            defaults.set(2, forKey: Keys.prefsVersion)
        }

        self.language = AppLanguage(rawValue: defaults.string(forKey: Keys.language) ?? "") ?? .system
        self.showFiveHourInMenuBar = defaults.bool(forKey: Keys.showFiveHour)
        self.showWeeklyInMenuBar = defaults.bool(forKey: Keys.showWeekly)
        self.showCacheRateInMenuBar = defaults.bool(forKey: Keys.showCacheRate)
        self.showTodayCostInMenuBar = defaults.bool(forKey: Keys.showTodayCost)
        self.showContextInMenuBar = defaults.bool(forKey: Keys.showContext)

        self.processesSectionDensity = SectionDensity(rawValue: defaults.string(forKey: Keys.processesDensity) ?? "") ?? .simple
        self.quotaSectionDensity = SectionDensity(rawValue: defaults.string(forKey: Keys.quotaDensity) ?? "") ?? .detailed
        self.contextSectionDensity = SectionDensity(rawValue: defaults.string(forKey: Keys.contextDensity) ?? "") ?? .detailed
        self.showEstimatedOutputSpeed = defaults.bool(forKey: Keys.showEstimatedOutputSpeed)
        self.spendSectionDensity = SectionDensity(rawValue: defaults.string(forKey: Keys.spendDensity) ?? "") ?? .detailed
        self.refreshIntervalSeconds = max(10, defaults.integer(forKey: Keys.refreshInterval))
        self.billingDay = max(0, min(31, defaults.integer(forKey: Keys.billingDay)))
        self.displayCurrency = DisplayCurrency(rawValue: defaults.string(forKey: Keys.displayCurrency) ?? "") ?? .usd
        let savedRate = defaults.double(forKey: Keys.cnyRate)
        self.cnyExchangeRate = savedRate > 0.5 ? savedRate : 7.25
        self.enableUsageAlerts = defaults.bool(forKey: Keys.enableUsageAlerts)
        self.enableBillingReminders = defaults.bool(forKey: Keys.enableBillingReminders)
        self.autoCheckUpdates = defaults.bool(forKey: Keys.autoCheckUpdates)
        self.dismissedUpdateVersion = defaults.string(forKey: Keys.dismissedUpdateVersion) ?? ""
        self.savedFullWeekCostUSD = max(0, defaults.double(forKey: Keys.savedFullWeekCostUSD))
        self.savedFullWeekTokens = max(0, defaults.integer(forKey: Keys.savedFullWeekTokens))
        self.selectedSpendTab = SpendWindowTab(rawValue: defaults.string(forKey: Keys.spendTab) ?? "") ?? .week
    }
}
