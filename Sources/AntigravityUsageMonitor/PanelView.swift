import SwiftUI
import UsageCore

struct PanelView: View {
    @Bindable var store: UsageMonitorStore
    @Bindable var preferences: AppPreferences
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        let l10n = preferences.l10n
        VStack(spacing: 0) {
            headerBar(l10n: l10n)

            VStack(alignment: .leading, spacing: 0) {
                if preferences.processesSectionDensity != .hidden {
                    processesRow(l10n: l10n)
                    panelDivider
                }

                if preferences.quotaSectionDensity != .hidden {
                    limitsSection(l10n: l10n)
                    panelDivider
                }

                if preferences.contextSectionDensity != .hidden {
                    contextSection(l10n: l10n)
                    panelDivider
                }

                if preferences.spendSectionDensity != .hidden {
                    spendSection(l10n: l10n)
                }
            }

            panelDivider
            footerBar(l10n: l10n)
        }
        .frame(width: Metrics.popoverWidth)
        .background(PanelBackground())
        .padding(Metrics.shadowInset)
        .preferredColorScheme(.dark)
    }

    private var panelDivider: some View {
        Hairline()
            .padding(.horizontal, Metrics.padding)
    }

    // MARK: - Header

    private func headerBar(l10n: L10n) -> some View {
        HStack(spacing: 8) {
            BrandMarkView(size: 14, color: Palette.accent)

            Text(l10n.appTitle)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Palette.text)

            Spacer()

            if let tier = store.officialReport.planTier, !tier.isEmpty {
                PlanTagView(rawTier: tier)
            }
        }
        .padding(.horizontal, Metrics.padding)
        .padding(.top, 13)
        .padding(.bottom, 9)
    }

    // MARK: - Processes Row

    private func processesRow(l10n: L10n) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                preferences.processesExpanded.toggle()
            } label: {
                HStack(spacing: 5) {
                    Text(l10n.processes)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Palette.secondary)
                    Image(systemName: preferences.processesExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.tertiary)
                    Spacer()
                    Text("\(store.runningProcesses.count)")
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Palette.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if preferences.processesExpanded || preferences.processesSectionDensity == .detailed {
                if store.runningProcesses.isEmpty {
                    Text(l10n.noActiveProcess)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(store.runningProcesses) { proc in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Palette.live)
                                    .frame(width: 5, height: 5)
                                Text(proc.name)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Palette.text)
                                Spacer()
                                Text("PID \(proc.id)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Palette.tertiary)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, Metrics.padding)
        .padding(.vertical, 8)
    }

    // MARK: - Limits Section

    private func limitsSection(l10n: L10n) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                preferences.limitsCollapsed.toggle()
            } label: {
                HStack {
                    Text(l10n.limits)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Palette.secondary)
                    Spacer()
                    if let age = store.officialReport.staleAgeSeconds {
                        let ageText = UsageFormatter.relativeAge(age)
                        let label = l10n.zh ? "\(ageText)同步" : "Synced \(ageText)"
                        Text(store.officialReport.isStale && l10n.zh ? "\(label) · 建议刷新" : label)
                            .font(.system(size: 10.5))
                            .foregroundStyle(store.officialReport.isStale ? Palette.warning : Palette.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !preferences.limitsCollapsed {
                if !store.officialReport.hasSnapshot || store.officialReport.buckets.isEmpty {
                    QuietNoticeRow(
                        systemImage: "terminal",
                        title: l10n.cliSyncTitle,
                        subtitle: l10n.cliSyncSubtitle,
                        actionTitle: l10n.openTerminalConnect,
                        actionIcon: "chevron.forward.square",
                        onAction: { store.openTerminalToConnectCLI() }
                    )
                } else {
                    VStack(spacing: 9) {
                        ForEach(store.officialReport.buckets) { bucket in
                            limitRow(bucket: bucket, l10n: l10n, isSimple: preferences.quotaSectionDensity == .simple)
                        }
                    }

                    if store.officialReport.isStale {
                        QuietNoticeRow(
                            systemImage: "terminal",
                            title: l10n.zh ? "CLI 快照已有一段时间未更新" : "CLI snapshot is stale",
                            subtitle: l10n.cliSyncSubtitle,
                            actionTitle: l10n.openTerminalConnect,
                            actionIcon: "chevron.forward.square",
                            onAction: { store.openTerminalToConnectCLI() }
                        )
                        .padding(.top, 4)
                    }
                }
            }
        }
        .padding(.horizontal, Metrics.padding)
        .padding(.vertical, 10)
    }

    private func limitRow(bucket: QuotaBucketEvaluation, l10n: L10n, isSimple: Bool) -> some View {
        let levelColor = Palette.levelColor(for: bucket.usedFraction, overPace: bucket.isOverPace)
        let tooltip = limitTooltip(bucket: bucket, l10n: l10n)

        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(bucket.displayName)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(Palette.text)
                Spacer()
                Text("\(bucket.usedPercentageInt)%")
                    .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(bucket.isResetElapsed ? Palette.safeGreen : levelColor)
            }

            ThinBar(
                fraction: bucket.usedFraction,
                color: Palette.levelColor(for: bucket.usedFraction, overPace: false),
                height: 4,
                safeLine: bucket.safeLineFraction,
                exceeded: bucket.isOverPace
            )
            .help(tooltip)

            if !isSimple {
                HStack {
                    if bucket.isResetElapsed {
                        Text(l10n.resetDone)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.tertiary)
                    } else if let secs = bucket.remainingSecondsUntilReset {
                        Text("\(l10n.resetsIn)\(UsageFormatter.countdown(secs))")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.tertiary)
                    }
                    Spacer()
                    if let safe = bucket.safeLineFraction, bucket.isOverPace {
                        Text("\(l10n.safeLine)\(UsageFormatter.percentage(safe))")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.critical)
                    }
                }
            }
        }
    }

    private func limitTooltip(bucket: QuotaBucketEvaluation, l10n: L10n) -> String {
        var parts = ["\(bucket.usedPercentageInt)%"]
        if let safe = bucket.safeLineFraction {
            parts.append("\(l10n.safeLine)\(UsageFormatter.percentage(safe))")
        }
        if let secs = bucket.remainingSecondsUntilReset, !bucket.isResetElapsed {
            parts.append("\(l10n.resetsIn)\(UsageFormatter.countdown(secs))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Active Context Window Section

    private func contextSection(l10n: L10n) -> some View {
        let ctx = store.officialReport.contextWindow
        let usedPct = max(0, min(100, ctx?.usedPercentage ?? 0))
        let usedTokens = (ctx?.totalInputTokens ?? 0) + (ctx?.totalOutputTokens ?? 0)
        let hasActiveUsage = ctx != nil && (usedTokens > 0 || usedPct > 0)

        return VStack(alignment: .leading, spacing: 7) {
            Button {
                preferences.contextCollapsed.toggle()
            } label: {
                HStack {
                    Text(l10n.context)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Palette.secondary)
                    Spacer()
                    if let modelName = store.officialReport.activeModelName, hasActiveUsage {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Palette.live)
                                .frame(width: 5, height: 5)
                            Text(modelName)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Palette.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !preferences.contextCollapsed {
                if hasActiveUsage, let ctx {
                    let usedFrac = usedPct / 100.0
                    HStack(alignment: .lastTextBaseline) {
                        HStack(alignment: .lastTextBaseline, spacing: 3) {
                            Text(String(format: "%.1f", usedPct))
                                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Palette.text)
                            Text("%")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Palette.secondary)
                        }
                        Spacer()
                        if let size = ctx.contextWindowSize, size > 0 {
                            Text("\(UsageFormatter.compactTokens(usedTokens)) / \(UsageFormatter.compactTokens(size))")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Palette.tertiary)
                        }
                    }

                    if preferences.contextSectionDensity == .detailed {
                        ThinBar(
                            fraction: usedFrac,
                            color: Palette.levelColor(for: usedFrac),
                            height: 4
                        )
                    }
                } else {
                    QuietNoticeRow(
                        systemImage: "waveform.path.ecg",
                        title: l10n.contextIdleTitle,
                        subtitle: l10n.contextIdleSubtitle
                    )
                }
            }
        }
        .padding(.horizontal, Metrics.padding)
        .padding(.vertical, 10)
    }

    // MARK: - Spend & Cache Section

    private func spendSection(l10n: L10n) -> some View {
        let summary: UsageWindowSummary = {
            switch preferences.selectedSpendTab {
            case .month: return store.localReport.month
            case .week: return store.localReport.week
            case .today: return store.localReport.today
            }
        }()

        return VStack(alignment: .leading, spacing: 9) {
            Button {
                preferences.spendCollapsed.toggle()
            } label: {
                HStack {
                    Text(l10n.spend)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Palette.secondary)
                    Spacer()
                    Text("\(store.localReport.conversationCount) \(l10n.zh ? "会话" : "sessions")")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !preferences.spendCollapsed {
                // Dark capsule segmented control
                HStack(spacing: 2) {
                    ForEach(SpendWindowTab.allCases) { tab in
                        let selected = preferences.selectedSpendTab == tab
                        Button {
                            preferences.selectedSpendTab = tab
                        } label: {
                            Text(tab.label(l10n: l10n))
                                .font(.system(size: 11.5, weight: selected ? .medium : .regular))
                                .foregroundStyle(selected ? Palette.text : Palette.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(selected ? Palette.controlSelected : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(Palette.controlSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                // Big cost + 14-day mini bars side by side
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(UsageFormatter.currency(summary.estimatedCostUSD))
                            .font(.system(size: 25, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Palette.text)

                        if summary.hasUnpricedModels {
                            Text(l10n.unpricedBadge)
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.warning)
                                .help(summary.unpricedModels.joined(separator: ", "))
                        } else if summary.cacheSavingsUSD > 0 {
                            Text("\(l10n.savedPrefix)\(UsageFormatter.currency(summary.cacheSavingsUSD))")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Palette.tertiary)
                        }
                    }

                    Spacer()

                    if preferences.spendSectionDensity == .detailed, !store.localReport.dailyTrend.isEmpty {
                        let vals = store.localReport.dailyTrend.map { Double($0.totalTokens) }
                        let labels = store.localReport.dailyTrend.map {
                            "\($0.dayKey): \(UsageFormatter.compactTokens($0.totalTokens)) tokens · \(UsageFormatter.currency($0.estimatedCostUSD))"
                        }
                        MiniBarsView(values: vals, labels: labels, highlightIndex: max(0, vals.count - 1))
                    }
                }

                // Compact summary row: Tokens · Requests · Today
                HStack {
                    inlineStat(label: l10n.tokens, value: UsageFormatter.compactTokens(summary.totalTokens))
                    Spacer()
                    inlineStat(label: l10n.requests, value: "\(summary.requestCount)")
                    Spacer()
                    inlineStat(label: l10n.todayShort, value: UsageFormatter.currency(store.localReport.today.estimatedCostUSD))
                }

                // Token breakdown columns with colored dots
                HStack(spacing: 0) {
                    tokenDotColumn(dot: Palette.input, label: l10n.input, value: UsageFormatter.compactTokens(summary.uncachedInputTokens))
                    tokenDotColumn(dot: Palette.output, label: l10n.output, value: UsageFormatter.compactTokens(summary.outputTokens))
                    tokenDotColumn(dot: Palette.cacheRead, label: l10n.cacheRead, value: UsageFormatter.compactTokens(summary.cacheReadTokens))
                }

                // Cache hit rate bar
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(l10n.cacheHitRate)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.text)
                        Spacer()
                        if summary.cacheSavingsUSD > 0 {
                            Text("\(l10n.savedPrefix)\(UsageFormatter.currency(summary.cacheSavingsUSD))")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Palette.tertiary)
                        }
                        Text(summary.totalInputTokens > 0 ? UsageFormatter.percentageOneDecimal(summary.cacheHitRate) : "--")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Palette.text)
                    }

                    ThinBar(
                        fraction: summary.cacheHitRate,
                        color: Color.white.opacity(0.45),
                        height: 3.5
                    )
                }

                // Per-model breakdown
                if preferences.spendSectionDensity == .detailed, !store.localReport.byModel.isEmpty {
                    let weekTotalTokens = max(1, store.localReport.byModel.reduce(0) { $0 + $1.totalTokens })
                    VStack(spacing: 5) {
                        ForEach(store.localReport.byModel.prefix(3)) { model in
                            let share = Double(model.totalTokens) / Double(weekTotalTokens)
                            HStack(spacing: 8) {
                                Text(model.displayName)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Palette.secondary)
                                    .lineLimit(1)
                                Spacer()
                                Text(UsageFormatter.percentageOneDecimal(share))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Palette.tertiary)
                                if let cost = model.estimatedCostUSD {
                                    Text(UsageFormatter.currency(cost))
                                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                                        .foregroundStyle(Palette.text)
                                        .frame(minWidth: 54, alignment: .trailing)
                                } else {
                                    Text(l10n.unpricedLabel)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(Palette.warning)
                                        .frame(minWidth: 54, alignment: .trailing)
                                }
                            }
                        }
                    }
                    .padding(.top, 1)
                }
            }
        }
        .padding(.horizontal, Metrics.padding)
        .padding(.vertical, 10)
    }

    private func inlineStat(label: String, value: String) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.tertiary)
            Text(value)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.text)
        }
    }

    private func tokenDotColumn(dot: Color, label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle()
                    .fill(dot)
                    .frame(width: 5, height: 5)
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.tertiary)
            }
            Text(value)
                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    private func footerBar(l10n: L10n) -> some View {
        HStack {
            Button {
                onOpenSettings()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11))
                    Text(l10n.settings)
                        .font(.system(size: 11.5))
                }
                .foregroundStyle(Palette.secondary)
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                store.refreshNow()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                    Text(l10n.refresh)
                        .font(.system(size: 11.5))
                }
                .foregroundStyle(Palette.secondary)
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                onQuit()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "power")
                        .font(.system(size: 11))
                    Text(l10n.quit)
                        .font(.system(size: 11.5))
                }
                .foregroundStyle(Palette.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Metrics.padding)
        .padding(.vertical, 10)
    }
}
