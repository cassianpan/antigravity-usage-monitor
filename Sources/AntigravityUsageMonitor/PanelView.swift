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

            ScrollView(.vertical, showsIndicators: false) {
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
            }
            .frame(maxHeight: 590)

            panelDivider
            footerBar(l10n: l10n)
        }
        .frame(width: Metrics.popoverWidth)
        .background(
            RoundedRectangle(cornerRadius: Metrics.popoverCorner, style: .continuous)
                .fill(Palette.panelBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.popoverCorner, style: .continuous)
                .stroke(Color.white.opacity(0.09), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Metrics.popoverCorner, style: .continuous))
        .preferredColorScheme(.dark)
    }

    private var panelDivider: some View {
        Rectangle()
            .fill(Palette.divider)
            .frame(height: 1)
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
                Text(tier)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.secondary)
            }
        }
        .padding(.horizontal, Metrics.padding)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: - Processes Row

    private func processesRow(l10n: L10n) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                preferences.processesExpanded.toggle()
            } label: {
                HStack(spacing: 5) {
                    Text(l10n.processes)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.secondary)
                    Image(systemName: preferences.processesExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.tertiary)
                    Spacer()
                    Text("\(store.runningProcesses.count)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
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
                    VStack(alignment: .leading, spacing: 4) {
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
        .padding(.vertical, 10)
    }

    // MARK: - Limits Section

    private func limitsSection(l10n: L10n) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Button {
                preferences.limitsCollapsed.toggle()
            } label: {
                HStack {
                    Text(l10n.limits)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Palette.secondary)
                    Spacer()
                    if let age = store.officialReport.staleAgeSeconds {
                        Text("\(l10n.syncedPrefix)\(UsageFormatter.relativeAge(age))")
                            .font(.system(size: 10.5))
                            .foregroundStyle(store.officialReport.isStale ? Palette.warning : Palette.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !preferences.limitsCollapsed {
                if !store.officialReport.hasSnapshot || store.officialReport.buckets.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(l10n.noSnapshotHint)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Button {
                            store.openTerminalToConnectCLI()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "terminal")
                                    .font(.system(size: 11, weight: .medium))
                                Text(l10n.openTerminalConnect)
                                    .font(.system(size: 11.5, weight: .medium))
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(Palette.accent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        if let feedback = store.bridgeFeedback {
                            Text(feedback)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Palette.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    VStack(spacing: 12) {
                        ForEach(store.officialReport.buckets) { bucket in
                            limitRow(bucket: bucket, l10n: l10n, isSimple: preferences.quotaSectionDensity == .simple)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Metrics.padding)
        .padding(.vertical, 12)
    }

    private func limitRow(bucket: QuotaBucketEvaluation, l10n: L10n, isSimple: Bool) -> some View {
        let levelColor = Palette.levelColor(for: bucket.usedFraction, overPace: bucket.isOverPace)
        let tooltip = limitTooltip(bucket: bucket, l10n: l10n)

        return VStack(alignment: .leading, spacing: 4) {
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
                            .foregroundStyle(Palette.safeGreen)
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
        VStack(alignment: .leading, spacing: 8) {
            Button {
                preferences.contextCollapsed.toggle()
            } label: {
                HStack {
                    Text(l10n.context)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Palette.secondary)
                    Spacer()
                    if let modelName = store.officialReport.activeModelName {
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
                if let ctx = store.officialReport.contextWindow {
                    let usedPct = max(0, min(100, ctx.usedPercentage ?? 0))
                    let usedFrac = usedPct / 100.0
                    let usedTokens = (ctx.totalInputTokens ?? 0) + (ctx.totalOutputTokens ?? 0)

                    HStack(alignment: .lastTextBaseline) {
                        HStack(alignment: .lastTextBaseline, spacing: 3) {
                            Text(String(format: "%.1f", usedPct))
                                .font(.system(size: 24, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Palette.text)
                            Text("%")
                                .font(.system(size: 12, weight: .medium))
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
                    Text(l10n.noActiveContext)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.tertiary)
                }
            }
        }
        .padding(.horizontal, Metrics.padding)
        .padding(.vertical, 12)
    }

    // MARK: - Spend & Cache Section (1:1 aligned with claude-usage-monitor)

    private func spendSection(l10n: L10n) -> some View {
        let summary: UsageWindowSummary = {
            switch preferences.selectedSpendTab {
            case .month: return store.localReport.month
            case .week: return store.localReport.week
            case .today: return store.localReport.today
            }
        }()

        return VStack(alignment: .leading, spacing: 11) {
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
                    VStack(alignment: .leading, spacing: 3) {
                        Text(UsageFormatter.currency(summary.estimatedCostUSD))
                            .font(.system(size: 26, weight: .semibold, design: .monospaced))
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
                    inlineStat(label: l10n.today, value: UsageFormatter.currency(store.localReport.today.estimatedCostUSD))
                }

                // Token breakdown columns with colored dots
                HStack(spacing: 0) {
                    tokenDotColumn(dot: Palette.input, label: l10n.input, value: UsageFormatter.compactTokens(summary.uncachedInputTokens))
                    tokenDotColumn(dot: Palette.output, label: l10n.output, value: UsageFormatter.compactTokens(summary.outputTokens))
                    tokenDotColumn(dot: Palette.cacheRead, label: l10n.cacheRead, value: UsageFormatter.compactTokens(summary.cacheReadTokens))
                }

                // Cache hit rate bar
                VStack(alignment: .leading, spacing: 5) {
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

                // Per-model breakdown (detailed mode)
                if preferences.spendSectionDensity == .detailed, !store.localReport.byModel.isEmpty {
                    let weekTotalTokens = max(1, store.localReport.byModel.reduce(0) { $0 + $1.totalTokens })
                    VStack(spacing: 6) {
                        ForEach(store.localReport.byModel.prefix(4)) { model in
                            let share = Double(model.totalTokens) / Double(weekTotalTokens)
                            HStack(spacing: 8) {
                                Text(model.displayName)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Palette.secondary)
                                    .lineLimit(1)
                                Spacer()
                                Text(UsageFormatter.percentage(share))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Palette.tertiary)
                                if let cost = model.estimatedCostUSD {
                                    Text(UsageFormatter.currency(cost))
                                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                                        .foregroundStyle(Palette.text)
                                        .frame(minWidth: 52, alignment: .trailing)
                                } else {
                                    Text(l10n.unpricedLabel)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(Palette.warning)
                                        .frame(minWidth: 52, alignment: .trailing)
                                }
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, Metrics.padding)
        .padding(.vertical, 12)
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
        VStack(alignment: .leading, spacing: 3) {
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

    // MARK: - Footer (3-way bottom bar matching claude-usage-monitor)

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
        .padding(.vertical, 11)
    }
}
