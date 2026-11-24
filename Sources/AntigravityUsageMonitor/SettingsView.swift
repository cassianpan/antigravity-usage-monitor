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
            guard preferences.selectedSettingsTab != tab else { return }
            withAnimation(.easeOut(duration: 0.14)) {
                preferences.selectedSettingsTab = tab
            }
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
                        sample: preferences.formatMoneyCompact(store.localReport.today.estimatedCostUSD),
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

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(zh ? "近似输出速度（估算）" : "Estimated output speed")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.text)
                    Text(zh ? "基于本地日志间隔近似估算，非真实生成速度，可随时关闭" : "Approximated from local transcript intervals, not real token timing")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.tertiary)
                }
                Spacer()
                Toggle("", isOn: $preferences.showEstimatedOutputSpeed)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Palette.accent)
            }

            if preferences.showEstimatedOutputSpeed {
                densityRow(title: zh ? "输出速度密度" : "Speed section density", selection: $preferences.contextSectionDensity, zh: zh)
            }

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
            SegmentSwitch(
                options: SectionDensity.allCases,
                selection: selection.wrappedValue,
                label: { $0.label(zh: zh) },
                onSelect: { selection.wrappedValue = $0 }
            )
        }
    }

    // MARK: - Data & CLI Sync Tab

    private func dataContent(l10n: L10n) -> some View {
        let zh = l10n.zh
        return VStack(alignment: .leading, spacing: 16) {
            QuietNoticeRow(
                systemImage: "chevron.forward.square",
                title: zh ? "后台自动同步官方额度（免值守终端）" : "Silent Background Sync (No Terminal Needed)",
                subtitle: zh
                    ? "App 通过官方 agy --settings 在后台短时拉取官方 5 小时与每周额度，不修改 settings.json，也无需保持终端开启。仅在首次登录或登录失效时打开一次终端即可。"
                    : "Fetches official 5-hour & weekly limits silently via agy --settings without keeping Terminal open or modifying settings.json.",
                actionTitle: l10n.openTerminalConnect,
                actionIcon: "chevron.forward.square",
                onAction: { store.openTerminalToConnectCLI() }
            )

            Hairline()

            HStack {
                Text(zh ? "agy CLI 路径" : "agy CLI binary")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                Spacer()
                if let path = store.cliBinaryPath {
                    Text(path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Palette.safeGreen)
                        .lineLimit(1)
                } else {
                    Text(zh ? "未找到 agy" : "Not found")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.critical)
                }
            }

            HStack(spacing: 10) {
                Button {
                    Task { await store.syncOfficialInBackground(force: true) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                        Text(store.isSyncingOfficial ? (zh ? "正在后台同步…" : "Syncing…") : (zh ? "立即后台同步" : "Sync now in background"))
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(PressableStyle())
                .disabled(store.isSyncingOfficial)

                if store.bridgeStatus.isInstalled {
                    Button {
                        store.uninstallBridge()
                    } label: {
                        Text(zh ? "移除旧版桥接配置" : "Remove legacy bridge")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Palette.controlSurface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(PressableStyle())
                }
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
                SegmentSwitch(
                    options: AppLanguage.allCases,
                    selection: preferences.language,
                    label: { $0.label(isChinese: zh) },
                    onSelect: { preferences.language = $0 }
                )
            }

            Hairline()

            HStack {
                Text(zh ? "货币单位" : "Currency")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.text)
                Spacer()
                SegmentSwitch(
                    options: DisplayCurrency.allCases,
                    selection: preferences.displayCurrency,
                    label: { $0 == .usd ? "USD ($)" : "CNY (¥)" },
                    onSelect: {
                        preferences.displayCurrency = $0
                        store.onMenuBarUpdate?()
                    }
                )
            }

            if preferences.displayCurrency == .cny {
                HStack {
                    Text(zh ? "美元兑人民币汇率" : "USD → CNY rate")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.secondary)
                    Spacer()
                    Picker("", selection: $preferences.cnyExchangeRate) {
                        Text("7.00").tag(7.00)
                        Text("7.15").tag(7.15)
                        Text("7.25").tag(7.25)
                        Text("7.30").tag(7.30)
                        Text("7.35").tag(7.35)
                    }
                    .labelsHidden()
                    .frame(width: 86)
                    .onChange(of: preferences.cnyExchangeRate) {
                        store.onMenuBarUpdate?()
                    }
                }
            }

            Hairline()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(zh ? "额度预警通知" : "Usage alerts")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.text)
                    Text(zh ? "超过安全配速线或达到 95% 时发送系统通知" : "Notify once past safe line and again at 95%")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.tertiary)
                }
                Spacer()
                Toggle("", isOn: $preferences.enableUsageAlerts)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Palette.accent)
                    .onChange(of: preferences.enableUsageAlerts) { _, on in
                        if on { NotificationManager.shared.requestPermissionIfNeeded() }
                    }
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(zh ? "订阅到期提醒" : "Billing reminders")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.text)
                    Text(zh ? "账单日前 3 天与前 1 天发送提醒" : "Remind 3 days and 1 day before billing day")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.tertiary)
                }
                Spacer()
                Toggle("", isOn: $preferences.enableBillingReminders)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Palette.accent)
                    .onChange(of: preferences.enableBillingReminders) { _, on in
                        if on { NotificationManager.shared.requestPermissionIfNeeded() }
                    }
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

            Hairline()

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(zh ? "软件更新" : "App update")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.text)

                        let statusLabel: String = {
                            if let status = store.updateStatusText, !status.isEmpty {
                                return status
                            }
                            return zh ? "当前版本 v\(store.currentAppVersion)" : "Current v\(store.currentAppVersion)"
                        }()

                        if store.availableUpdate != nil {
                            Button {
                                withAnimation(.easeOut(duration: 0.16)) {
                                    store.toggleUpdateNotes()
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(statusLabel)
                                        .underline(store.isUpdateStatusHovered || store.updateNotesVisible)
                                    Image(systemName: store.updateNotesVisible ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 8.5, weight: .semibold))
                                }
                                .font(.system(size: 11))
                                .foregroundStyle(
                                    store.isUpdateStatusHovered || store.updateNotesVisible
                                        ? Palette.accent
                                        : Palette.accent.opacity(0.88)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { store.isUpdateStatusHovered = $0 }
                            .help(zh ? "点击展开或收起更新说明" : "Click to show or hide release notes")
                        } else {
                            Text(statusLabel)
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.tertiary)
                        }
                    }

                    Spacer(minLength: 10)

                    if let update = store.availableUpdate {
                        HStack(spacing: 8) {
                            if !store.isUpdateDismissed && !store.updatePhase.isBusy {
                                Button {
                                    store.dismissAvailableUpdate()
                                } label: {
                                    Text(zh ? "忽略" : "Skip")
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundStyle(Palette.secondary)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Palette.controlSurface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .help(zh ? "仅忽略当前版本，下个新版本发布时会再次提醒" : "Skips only this version; a newer release will notify again")
                            }

                            Button {
                                Task { await store.installAvailableUpdate() }
                            } label: {
                                Text(store.updatePhase.isBusy
                                     ? (zh ? "更新中…" : "Updating…")
                                     : (zh ? "立即更新到 v\(update.version)" : "Update to v\(update.version)"))
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(Color(hex: 0x0A1930))
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 5)
                                    .background(Palette.accent, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .disabled(!store.canInstallUpdateInPlace)
                        }
                    } else if store.updateDownloadFraction == nil {
                        Button {
                            Task { await store.checkForUpdates(manual: true) }
                        } label: {
                            Text(store.isCheckingUpdates ? (zh ? "检查中…" : "Checking…") : (zh ? "检查更新" : "Check"))
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Palette.text)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Palette.controlSurface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.75)
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(store.updatePhase.isBusy)
                    }
                }

                if let fraction = store.updateDownloadFraction {
                    HStack(spacing: 8) {
                        ThinBar(
                            fraction: fraction,
                            color: Palette.accent,
                            height: 5
                        )
                        Text("\(Int(round(fraction * 100)))%")
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(Palette.accent)
                            .frame(width: 34, alignment: .trailing)
                    }
                }

                if store.updateNotesVisible, let update = store.availableUpdate {
                    let renderedBody = MarkdownBlocks.extractLocalizedReleaseNotes(
                        update.releaseNotes,
                        preferChinese: zh
                    )
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(zh ? "版本 v\(update.version) 更新说明" : "Version v\(update.version) notes")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(Palette.text)
                            Spacer()
                            Button {
                                store.openUpdateReleasePage()
                            } label: {
                                HStack(spacing: 3) {
                                    Text(zh ? "在浏览器中打开" : "Open in browser")
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 9, weight: .semibold))
                                }
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(store.isUpdateBrowserLinkHovered ? Palette.accent : Palette.tertiary)
                            }
                            .buttonStyle(.plain)
                            .onHover { store.isUpdateBrowserLinkHovered = $0 }
                        }

                        ScrollView(.vertical, showsIndicators: false) {
                            MarkdownNotesView(markdown: renderedBody.isEmpty ? update.releaseNotes : renderedBody)
                                .padding(.vertical, 2)
                        }
                        .frame(maxHeight: 150)
                    }
                    .padding(12)
                    .background(Palette.controlSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.75)
                    )
                }

                HStack {
                    Text(zh ? "每 4 小时自动检查新版本并推送提醒" : "Check for new releases automatically every 4h")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.tertiary)
                    Spacer()
                    Toggle("", isOn: $preferences.autoCheckUpdates)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(Palette.accent)
                }
            }
        }
    }
}
