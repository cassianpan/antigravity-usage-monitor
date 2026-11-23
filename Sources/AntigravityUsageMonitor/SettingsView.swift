import SwiftUI
import UsageCore

struct SettingsView: View {
    @Bindable var store: UsageMonitorStore
    @Bindable var preferences: AppPreferences

    var body: some View {
        let l10n = preferences.l10n
        VStack(spacing: 0) {
            topTabBar(l10n: l10n)
            Hairline()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    switch preferences.selectedSettingsTab {
                    case .menuBar:
                        menuBarContent(l10n: l10n)
                    case .panel:
                        panelContent(l10n: l10n)
                    case .data:
                        dataContent(l10n: l10n)
                    case .general:
                        generalContent(l10n: l10n)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
            }
        }
        .frame(width: 520, height: 460)
        .background {
            ZStack {
                GlassEffect(material: .hudWindow)
                Color(hex: 0x1C1B1A).opacity(0.84)
            }
            .ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
        .onAppear {
            preferences.syncLaunchAtLoginStatus()
        }
    }

    // MARK: - Top Icon Tab Bar (fused into translucent glass titlebar)

    private func topTabBar(l10n: L10n) -> some View {
        HStack(spacing: 6) {
            tabButton(.menuBar, icon: "menubar.rectangle", title: l10n.tabMenuBar)
            tabButton(.panel, icon: "rectangle.3.group", title: l10n.tabPanel)
            tabButton(.data, icon: "externaldrive", title: l10n.tabData)
            tabButton(.general, icon: "slider.horizontal.3", title: l10n.tabGeneral)
        }
        .padding(.horizontal, 16)
        .padding(.top, 26)
        .padding(.bottom, 10)
    }

    private func tabButton(_ tab: SettingsTab, icon: String, title: String) -> some View {
        let active = preferences.selectedSettingsTab == tab
        return Button {
            preferences.selectedSettingsTab = tab
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .regular))
                Text(title)
                    .font(.system(size: 11, weight: active ? .medium : .regular))
            }
            .foregroundStyle(active ? Palette.text : Palette.tertiary)
            .frame(width: 72, height: 48)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(active ? Color.white.opacity(0.09) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Menu Bar Tab

    private func menuBarContent(l10n: L10n) -> some View {
        let zh = l10n.zh
        let columns = store.menuBarColumns()
        return VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(zh ? "菜单栏" : "Menu bar")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.secondary)

                HStack(spacing: 12) {
                    Spacer()
                    Capsule()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 14, height: 3)

                    HStack(spacing: columns.count == 1 ? 5 : 8) {
                        BrandMarkView(size: 15, color: Palette.accent)
                        if columns.count == 1, let only = columns.first {
                            Text(only.value)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color(hex: only.valueHex))
                        } else {
                            ForEach(columns) { col in
                                VStack(spacing: 0) {
                                    Text(col.topLabel)
                                        .font(.system(size: 7, weight: .semibold))
                                        .foregroundStyle(Palette.secondary)
                                    Text(col.value)
                                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Color(hex: col.valueHex))
                                }
                            }
                        }
                    }

                    Capsule()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: 14, height: 3)

                    Text("9:41")
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Palette.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Palette.previewBar, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
            }

            Hairline()

            VStack(alignment: .leading, spacing: 8) {
                Text(zh ? "菜单栏显示项" : "Menu bar values")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.text)
                Text(zh ? "亮起的数值会显示在菜单栏，点击即可开启或关闭（默认仅显示 5H）。" : "Lit values appear in the menu bar. Click to toggle (5H only by default).")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)

                HStack(spacing: 0) {
                    metricTogglePill(
                        label: "5H",
                        sample: store.officialReport.primaryFiveHour.map { "\($0.usedPercentageInt)%" } ?? "--",
                        isOn: $preferences.showFiveHourInMenuBar,
                        accentHex: 0x5EC27B
                    )
                    pillSeparator
                    metricTogglePill(
                        label: "WEEK",
                        sample: store.officialReport.primaryWeekly.map { "\($0.usedPercentageInt)%" } ?? "--",
                        isOn: $preferences.showWeeklyInMenuBar,
                        accentHex: 0x5EC27B
                    )
                    pillSeparator
                    metricTogglePill(
                        label: "CACHE",
                        sample: store.localReport.today.totalInputTokens > 0
                            ? UsageFormatter.percentage(store.localReport.today.cacheHitRate)
                            : "--",
                        isOn: $preferences.showCacheRateInMenuBar,
                        accentHex: Palette.accentHex
                    )
                    pillSeparator
                    metricTogglePill(
                        label: "TODAY",
                        sample: UsageFormatter.currency(store.localReport.today.estimatedCostUSD),
                        isOn: $preferences.showTodayCostInMenuBar,
                        accentHex: 0xECECEC
                    )
                    pillSeparator
                    metricTogglePill(
                        label: "CTX",
                        sample: store.officialReport.contextWindow?.usedPercentage.map { "\(Int($0))%" } ?? "--",
                        isOn: $preferences.showContextInMenuBar,
                        accentHex: 0xE3A24B
                    )
                }
                .padding(.vertical, 7)
                .background(Palette.previewBar, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
            }
        }
    }

    private var pillSeparator: some View {
        Rectangle()
            .fill(Palette.divider)
            .frame(width: 1, height: 26)
    }

    private func metricTogglePill(label: String, sample: String, isOn: Binding<Bool>, accentHex: UInt32) -> some View {
        Button {
            isOn.wrappedValue.toggle()
            store.onMenuBarUpdate?()
        } label: {
            VStack(spacing: 2) {
                Text(label)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(isOn.wrappedValue ? Palette.secondary : Palette.quaternary)
                Text(sample)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isOn.wrappedValue ? Color(hex: accentHex) : Palette.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Panel Layout Tab

    private func panelContent(l10n: L10n) -> some View {
        let zh = l10n.zh
        return VStack(alignment: .leading, spacing: 14) {
            Text(zh ? "每个区块可设为详细、简洁或隐藏" : "Choose Detailed, Simple, or Hidden for each section")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.secondary)

            densityRow(title: l10n.processes, selection: $preferences.processesSectionDensity, zh: zh)
            Hairline()
            densityRow(title: l10n.limits, selection: $preferences.quotaSectionDensity, zh: zh)
            Hairline()
            densityRow(title: l10n.context, selection: $preferences.contextSectionDensity, zh: zh)
            Hairline()
            densityRow(title: l10n.spend, selection: $preferences.spendSectionDensity, zh: zh)
        }
    }

    private func densityRow(title: String, selection: Binding<SectionDensity>, zh: Bool) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.text)
            Spacer()
            HStack(spacing: 2) {
                ForEach(SectionDensity.allCases) { mode in
                    let active = selection.wrappedValue == mode
                    Button {
                        selection.wrappedValue = mode
                    } label: {
                        Text(mode.label(zh: zh))
                            .font(.system(size: 11, weight: active ? .medium : .regular))
                            .foregroundStyle(active ? Palette.text : Palette.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(active ? Palette.controlSelected : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(Palette.controlSurface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    // MARK: - Data & CLI Sync Tab

    private func dataContent(l10n: L10n) -> some View {
        let zh = l10n.zh
        return VStack(alignment: .leading, spacing: 16) {
            QuietNoticeRow(
                systemImage: "terminal",
                title: zh ? "agy CLI 官方额度同步" : "agy CLI Official Limits Sync",
                subtitle: l10n.cliSyncSubtitle,
                actionTitle: l10n.openTerminalConnect,
                actionIcon: "chevron.forward.square",
                onAction: { store.openTerminalToConnectCLI() }
            )

            Hairline()

            HStack {
                Text(zh ? "桥接状态" : "Bridge status")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                Spacer()
                switch store.bridgeStatus {
                case .installedDirect:
                    Text(zh ? "已接入（保留默认状态栏）" : "Connected (default status line kept)")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Palette.safeGreen)
                case .installedChained(let orig):
                    Text(zh ? "已链式包装原脚本" : "Chained with custom script")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Palette.safeGreen)
                        .help(orig)
                case .notInstalled:
                    Text(zh ? "未接入" : "Not connected")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.tertiary)
                }
            }

            if store.bridgeStatus.isInstalled {
                Button {
                    store.uninstallBridge()
                } label: {
                    Text(zh ? "移除桥接并还原 settings.json" : "Disconnect & restore settings.json")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Palette.controlSurface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            if let feedback = store.bridgeFeedback {
                Text(feedback)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Hairline()

            VStack(alignment: .leading, spacing: 4) {
                Text(zh ? "本地数据路径（纯只读）" : "Local data paths (read-only)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.secondary)
                Text("~/.gemini/antigravity/brain/**/transcript.jsonl")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Palette.tertiary)
                Text(store.bridgeInstaller.snapshotURL.path)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Palette.tertiary)
            }
        }
    }

    // MARK: - General Tab

    private func generalContent(l10n: L10n) -> some View {
        let zh = l10n.zh
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(zh ? "界面语言" : "Language")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.text)
                Spacer()
                HStack(spacing: 2) {
                    ForEach(AppLanguage.allCases) { lang in
                        let active = preferences.language == lang
                        Button {
                            preferences.language = lang
                        } label: {
                            Text(lang.label(isChinese: zh))
                                .font(.system(size: 11, weight: active ? .medium : .regular))
                                .foregroundStyle(active ? Palette.text : Palette.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(active ? Palette.controlSelected : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(Palette.controlSurface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }

            Hairline()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(zh ? "订阅账单日" : "Billing day")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.text)
                    Text(zh ? "设置后在顶部显示订阅剩余天数，并按账单日切分本月周期" : "Shows days left next to your plan badge and aligns the monthly spend cycle")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.tertiary)
                }
                Spacer()
                Picker("", selection: $preferences.billingDay) {
                    Text(zh ? "未设置" : "Unset").tag(0)
                    ForEach(1...31, id: \.self) { day in
                        Text(zh ? "每月 \(day) 日" : "Day \(day)").tag(day)
                    }
                }
                .labelsHidden()
                .frame(width: 105)
                .onChange(of: preferences.billingDay) {
                    store.refreshNow()
                }
            }

            Hairline()

            HStack {
                Text(zh ? "刷新频率" : "Refresh interval")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.text)
                Spacer()
                Picker("", selection: $preferences.refreshIntervalSeconds) {
                    Text("10s").tag(10)
                    Text("30s").tag(30)
                    Text("60s").tag(60)
                    Text("5m").tag(300)
                }
                .labelsHidden()
                .frame(width: 90)
                .onChange(of: preferences.refreshIntervalSeconds) {
                    store.restartTimer()
                }
            }

            Hairline()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(zh ? "开机自动启动" : "Launch at login")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.text)
                    Text(zh ? "登录 macOS 时自动常驻菜单栏" : "Start automatically when you sign in")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.tertiary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { preferences.launchAtLoginEnabled },
                    set: { preferences.setLaunchAtLogin($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Palette.accent)
            }

            if let err = preferences.launchAtLoginError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.critical)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
