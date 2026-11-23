import Foundation
import ServiceManagement
import SwiftUI

enum SectionDensity: String, CaseIterable, Identifiable {
    case detailed = "detailed"
    case simple = "simple"
    case hidden = "hidden"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .detailed: return "详细"
        case .simple: return "简洁"
        case .hidden: return "隐藏"
        }
    }
}

enum LocalWindowTab: String, CaseIterable, Identifiable {
    case today = "today"
    case fiveHour = "fiveHour"
    case week = "week"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: return "今日"
        case .fiveHour: return "近 5 小时"
        case .week: return "本周"
        }
    }
}

@MainActor
@Observable
final class AppPreferences {
    private let defaults = UserDefaults.standard

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

    var quotaSectionDensity: SectionDensity {
        didSet { defaults.set(quotaSectionDensity.rawValue, forKey: Keys.quotaDensity) }
    }
    var contextSectionDensity: SectionDensity {
        didSet { defaults.set(contextSectionDensity.rawValue, forKey: Keys.contextDensity) }
    }
    var localSectionDensity: SectionDensity {
        didSet { defaults.set(localSectionDensity.rawValue, forKey: Keys.localDensity) }
    }

    var refreshIntervalSeconds: Int {
        didSet { defaults.set(refreshIntervalSeconds, forKey: Keys.refreshInterval) }
    }

    var selectedLocalTab: LocalWindowTab {
        didSet { defaults.set(selectedLocalTab.rawValue, forKey: Keys.localTab) }
    }

    var quotaCollapsed: Bool = false
    var contextCollapsed: Bool = false
    var localCollapsed: Bool = false
    var launchAtLoginEnabled: Bool = false

    var launchAtLoginError: String?

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
            launchAtLoginError = "设置开机自启失败（请确保已将 App 放入 /Applications）：\(error.localizedDescription)"
        }
        syncLaunchAtLoginStatus()
    }

    private enum Keys {
        static let showFiveHour = "menubar.showFiveHour"
        static let showWeekly = "menubar.showWeekly"
        static let showCacheRate = "menubar.showCacheRate"
        static let showTodayCost = "menubar.showTodayCost"
        static let showContext = "menubar.showContext"
        static let quotaDensity = "panel.quotaDensity"
        static let contextDensity = "panel.contextDensity"
        static let localDensity = "panel.localDensity"
        static let refreshInterval = "refresh.intervalSeconds"
        static let localTab = "panel.localTab"
    }

    init() {
        defaults.register(defaults: [
            Keys.showFiveHour: true,
            Keys.showWeekly: false,
            Keys.showCacheRate: false,
            Keys.showTodayCost: false,
            Keys.showContext: false,
            Keys.quotaDensity: SectionDensity.detailed.rawValue,
            Keys.contextDensity: SectionDensity.detailed.rawValue,
            Keys.localDensity: SectionDensity.detailed.rawValue,
            Keys.refreshInterval: 30,
            Keys.localTab: LocalWindowTab.today.rawValue,
        ])

        self.showFiveHourInMenuBar = defaults.bool(forKey: Keys.showFiveHour)
        self.showWeeklyInMenuBar = defaults.bool(forKey: Keys.showWeekly)
        self.showCacheRateInMenuBar = defaults.bool(forKey: Keys.showCacheRate)
        self.showTodayCostInMenuBar = defaults.bool(forKey: Keys.showTodayCost)
        self.showContextInMenuBar = defaults.bool(forKey: Keys.showContext)

        self.quotaSectionDensity = SectionDensity(rawValue: defaults.string(forKey: Keys.quotaDensity) ?? "") ?? .detailed
        self.contextSectionDensity = SectionDensity(rawValue: defaults.string(forKey: Keys.contextDensity) ?? "") ?? .detailed
        self.localSectionDensity = SectionDensity(rawValue: defaults.string(forKey: Keys.localDensity) ?? "") ?? .detailed
        self.refreshIntervalSeconds = max(10, defaults.integer(forKey: Keys.refreshInterval))
        self.selectedLocalTab = LocalWindowTab(rawValue: defaults.string(forKey: Keys.localTab) ?? "") ?? .today
    }
}
