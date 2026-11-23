import SwiftUI
import UsageCore

struct PanelView: View {
    @Bindable var store: UsageMonitorStore
    @Bindable var preferences: AppPreferences
    @Bindable var tipCenter: TipCenter
    @Bindable var interaction: PanelInteractionState
    let onOpenSettings: () -> Void
    let onRefresh: () -> Void
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
        .panelTipOverlay(center: tipCenter)
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
                    .panelTip("header.plan", center: tipCenter, alignment: .trailing) {
                        var rows = [Tip.Row(l10n.zh ? "订阅方案" : "Plan", tier)]
                        if let email = store.officialReport.email, !email.isEmpty {
                            rows.append(Tip.Row(l10n.zh ? "账号" : "Account", email))
                        }
                        return Tip(rows: rows)
                    }
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
                let needsLogin = store.officialReport.agentState == "authenticating"
                    || (store.officialReport.hasSnapshot && (store.officialReport.email?.isEmpty ?? true))

                if !store.officialReport.hasSnapshot || store.officialReport.buckets.isEmpty {
                    QuietNoticeRow(
                        systemImage: "chevron.forward.square",
                        title: l10n.cliSyncTitle,
                        subtitle: l10n.cliSyncSubtitle,
                        actionTitle: l10n.openTerminalConnect,
                        actionIcon: "chevron.forward.square",
                        isActionHovered: interaction.isLoginButtonHovered,
                        onActionHover: { interaction.isLoginButtonHovered = $0 },
                        onAction: { store.openTerminalToConnectCLI() }
                    )
                } else {
                    VStack(spacing: 9) {
                        ForEach(store.officialReport.buckets) { bucket in
                            limitRow(bucket: bucket, l10n: l10n, isSimple: preferences.quotaSectionDensity == .simple)
                        }
                    }

                    if needsLogin || store.officialReport.isStale {
                        QuietNoticeRow(
                            systemImage: "chevron.forward.square",
                            title: needsLogin
                                ? (l10n.zh ? "agy CLI 的登录已失效" : "agy CLI sign-in required")
                                : (l10n.zh ? "CLI 额度同步已过期" : "CLI limit snapshot is stale"),
                            subtitle: needsLogin
                                ? (l10n.zh ? "登录到期或已退出，重新登录后自动恢复" : "Session expired or signed out. Sign in again to resume.")
                                : l10n.cliSyncSubtitle,
                            actionTitle: l10n.openTerminalConnect,
                            actionIcon: "chevron.forward.square",
                            isActionHovered: interaction.isLoginButtonHovered,
                            onActionHover: { interaction.isLoginButtonHovered = $0 },
                            onAction: { store.openTerminalToConnectCLI() }
                        )
                        .padding(.top, 6)
                    }
                }
            }
        }
        .padding(.horizontal, Metrics.padding)
        .padding(.vertical, 10)
    }

    private func limitRow(bucket: QuotaBucketEvaluation, l10n: L10n, isSimple: Bool) -> some View {
        let levelColor = Palette.levelColor(for: bucket.usedFraction, overPace: bucket.isOverPace)
        let isHovered = interaction.hoveredBucketId == bucket.bucketId

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
                exceeded: bucket.isOverPace,
                isPointed: isHovered
            )
            .contentShape(Rectangle())
            .onHover { inside in
                withAnimation(.easeOut(duration: 0.14)) {
                    if inside {
                        interaction.hoveredBucketId = bucket.bucketId
                    } else if interaction.hoveredBucketId == bucket.bucketId {
                        interaction.hoveredBucketId = nil
                    }
                }
            }
            .panelTip("limit.\(bucket.bucketId)", center: tipCenter) {
                limitTip(bucket: bucket, l10n: l10n)
            }

            if !isSimple {
                HStack {
                    if isHovered, let safe = bucket.safeLineFraction, !bucket.isResetElapsed {
                        let headroom = max(0, safe - bucket.usedFraction)
                        Text(
                            bucket.isOverPace
                                ? "\(l10n.safeLine)\(UsageFormatter.percentage(safe)) · \(l10n.zh ? "已超速" : "Over pace")"
                                : "\(l10n.safeLine)\(UsageFormatter.percentage(safe)) · \(l10n.zh ? "安全余量 " : "Headroom ")\(UsageFormatter.percentage(headroom))"
                        )
                        .font(.system(size: 10.5))
                        .foregroundStyle(bucket.isOverPace ? Palette.critical : Palette.secondary)
                    } else if bucket.isResetElapsed {
                        Text(l10n.resetDone)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.tertiary)
                    } else if let secs = bucket.remainingSecondsUntilReset {
                        Text("\(l10n.resetsIn)\(UsageFormatter.countdown(secs))")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.tertiary)
                    }
                    Spacer()
                }
            }
        }
    }

    private func limitTip(bucket: QuotaBucketEvaluation, l10n: L10n) -> Tip {
        var rows: [Tip.Row] = [
            Tip.Row(l10n.zh ? "已用" : "Used", "\(bucket.usedPercentageInt)%"),
            Tip.Row(l10n.zh ? "剩余" : "Remaining", UsageFormatter.percentage(bucket.remainingFraction)),
        ]
        if let safe = bucket.safeLineFraction, !bucket.isResetElapsed {
            rows.append(Tip.Row(
                l10n.zh ? "此刻安全线" : "Safe line",
                UsageFormatter.percentage(safe),
                color: bucket.isOverPace ? Palette.critical : Palette.safeGreen
            ))
        }
        if let secs = bucket.remainingSecondsUntilReset, !bucket.isResetElapsed {
            rows.append(Tip.Row(l10n.zh ? "距离重置" : "Resets in", UsageFormatter.countdown(secs), separated: true))
        }
        return Tip(title: bucket.displayName, rows: rows)
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
                // Dark capsule segmented control (full-area hit target + hover + smooth transition)
                HStack(spacing: 2) {
                    ForEach(SpendWindowTab.allCases) { tab in
                        let selected = preferences.selectedSpendTab == tab
                        let hovered = interaction.hoveredTab == tab && !selected
                        Button {
                            guard preferences.selectedSpendTab != tab else { return }
                            withAnimation(.easeOut(duration: 0.14)) {
                                preferences.selectedSpendTab = tab
                            }
                        } label: {
                            Text(tab.label(l10n: l10n))
                                .font(.system(size: 11.5, weight: selected ? .medium : .regular))
                                .foregroundStyle(selected ? Palette.text : (hovered ? Palette.text.opacity(0.8) : Palette.secondary))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(selected ? Palette.controlSelected : (hovered ? Palette.hover : Color.clear))
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { inside in
                            withAnimation(.easeOut(duration: 0.12)) {
                                if inside {
                                    interaction.hoveredTab = tab
                                } else if interaction.hoveredTab == tab {
                                    interaction.hoveredTab = nil
                                }
                            }
                        }
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
                            .panelTip("spend.cost", center: tipCenter, alignment: .leading) {
                                Tip(
                                    title: l10n.zh ? "API 等价花费估算" : "API-equivalent spend estimate",
                                    note: l10n.zh
                                        ? "按各模型公开 API 单价折算本机历史会话消耗，并非订阅实际扣费。"
                                        : "Estimated from published API list prices for local sessions, not your subscription bill."
                                )
                            }

                        if summary.hasUnpricedModels {
                            Text(l10n.unpricedBadge)
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.warning)
                                .panelTip("spend.unpriced", center: tipCenter, alignment: .leading) {
                                    Tip(
                                        title: l10n.zh ? "未收录单价的模型" : "Unpriced models",
                                        note: summary.unpricedModels.joined(separator: ", ")
                                    )
                                }
                        } else if summary.cacheSavingsUSD > 0 {
                            Text("\(l10n.savedPrefix)\(UsageFormatter.currency(summary.cacheSavingsUSD))")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Palette.tertiary)
                                .panelTip("spend.saved.sub", center: tipCenter, alignment: .leading) {
                                    Tip(
                                        l10n.zh
                                            ? "如果没有 Prompt Caching，这些命中缓存的 token 需要按原价计费。"
                                            : "Without prompt caching, these cached tokens would be billed at full input price."
                                    )
                                }
                        }
                    }

                    Spacer()

                    if preferences.spendSectionDensity == .detailed, !store.localReport.dailyTrend.isEmpty {
                        MiniBarsView(
                            points: store.localReport.dailyTrend,
                            highlightIndex: max(0, store.localReport.dailyTrend.count - 1),
                            interaction: interaction,
                            tipCenter: tipCenter,
                            isChinese: l10n.zh
                        )
                    }
                }

                // Compact summary row: Tokens · Requests · Today
                HStack {
                    inlineStat(label: l10n.tokens, value: UsageFormatter.compactTokens(summary.totalTokens))
                        .panelTip("spend.tokens", center: tipCenter, alignment: .leading) {
                            Tip(
                                title: l10n.zh ? "总 Token 构成" : "Total tokens",
                                rows: [
                                    Tip.Row(l10n.input, "\(summary.uncachedInputTokens)", dot: Palette.input),
                                    Tip.Row(l10n.output, "\(summary.outputTokens)", dot: Palette.output),
                                    Tip.Row(l10n.cacheRead, "\(summary.cacheReadTokens)", dot: Palette.cacheRead),
                                ]
                            )
                        }
                    Spacer()
                    inlineStat(label: l10n.requests, value: "\(summary.requestCount)")
                        .panelTip("spend.requests", center: tipCenter, alignment: .center) {
                            Tip(
                                l10n.zh
                                    ? "当前周期内本机记录到的模型响应总次数（含桌面端与 agy CLI）。"
                                    : "Total recorded model responses on this Mac in the selected period."
                            )
                        }
                    Spacer()
                    inlineStat(label: l10n.todayShort, value: UsageFormatter.currency(store.localReport.today.estimatedCostUSD))
                        .panelTip("spend.today", center: tipCenter, alignment: .trailing) {
                            Tip(
                                title: l10n.zh ? "今日消耗" : "Today's spend",
                                rows: [
                                    Tip.Row("Tokens", UsageFormatter.compactTokens(store.localReport.today.totalTokens)),
                                    Tip.Row(l10n.requests, "\(store.localReport.today.requestCount)"),
                                    Tip.Row(l10n.cacheHitRate, UsageFormatter.percentageOneDecimal(store.localReport.today.cacheHitRate)),
                                ]
                            )
                        }
                }

                // Token breakdown columns with colored dots
                HStack(spacing: 0) {
                    tokenDotColumn(dot: Palette.input, label: l10n.input, value: UsageFormatter.compactTokens(summary.uncachedInputTokens))
                        .panelTip("spend.input", center: tipCenter, alignment: .leading) {
                            Tip(
                                l10n.zh
                                    ? "未命中缓存、新发送给模型的输入 token。"
                                    : "Uncached input tokens sent fresh to the model."
                            )
                        }
                    tokenDotColumn(dot: Palette.output, label: l10n.output, value: UsageFormatter.compactTokens(summary.outputTokens))
                        .panelTip("spend.output", center: tipCenter, alignment: .center) {
                            Tip(
                                l10n.zh
                                    ? "模型生成的回复 token（包含内部思考推理 token）。"
                                    : "Output tokens generated by the model (including thinking tokens)."
                            )
                        }
                    tokenDotColumn(dot: Palette.cacheRead, label: l10n.cacheRead, value: UsageFormatter.compactTokens(summary.cacheReadTokens))
                        .panelTip("spend.cacheRead", center: tipCenter, alignment: .trailing) {
                            Tip(
                                l10n.zh
                                    ? "直接复用上下文缓存的输入 token，按低价折扣计费。"
                                    : "Input tokens served from prompt cache at discounted read rates."
                            )
                        }
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
                                .panelTip("spend.saved.bar", center: tipCenter, alignment: .trailing) {
                                    Tip(
                                        l10n.zh
                                            ? "如果没有 Prompt Caching，这些命中缓存的 token 需要按原价计费。"
                                            : "Without prompt caching, these tokens would be billed at full input price."
                                    )
                                }
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
                .contentShape(Rectangle())
                .panelTip("spend.cacheRate", center: tipCenter, alignment: .center) {
                    Tip(
                        title: l10n.cacheHitRate,
                        rows: [
                            Tip.Row(l10n.cacheRead, UsageFormatter.compactTokens(summary.cacheReadTokens), dot: Palette.cacheRead),
                            Tip.Row(l10n.input, UsageFormatter.compactTokens(summary.uncachedInputTokens), dot: Palette.input),
                        ],
                        note: l10n.zh
                            ? "缓存命中 token 占全部输入 token（新增输入 + 缓存命中）的比例。"
                            : "Share of all input tokens served from prompt cache."
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
                            .contentShape(Rectangle())
                            .panelTip("model.\(model.id)", center: tipCenter, alignment: .center) {
                                var rows: [Tip.Row] = [
                                    Tip.Row(l10n.input, UsageFormatter.compactTokens(model.uncachedInputTokens), dot: Palette.input),
                                    Tip.Row(l10n.output, UsageFormatter.compactTokens(model.outputTokens), dot: Palette.output),
                                    Tip.Row(l10n.cacheRead, UsageFormatter.compactTokens(model.cacheReadTokens), dot: Palette.cacheRead),
                                    Tip.Row(l10n.cacheHitRate, UsageFormatter.percentageOneDecimal(model.cacheHitRate), separated: true),
                                    Tip.Row(l10n.requests, "\(model.requestCount)"),
                                ]
                                if let saved = model.cacheSavingsUSD, saved > 0 {
                                    rows.append(Tip.Row(l10n.zh ? "缓存节省" : "Cache saved", UsageFormatter.currency(saved), color: Palette.safeGreen))
                                }
                                return Tip(title: model.displayName, rows: rows)
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

    // MARK: - Footer (1:1 ported FooterActionButton + shortcut tips + spin animation)

    private func footerBar(l10n: L10n) -> some View {
        ZStack {
            HStack {
                FooterActionButton(
                    id: "settings",
                    systemImage: "slider.horizontal.3",
                    title: l10n.settings,
                    shortcut: "⌘,",
                    tipAlignment: .leading,
                    interaction: interaction,
                    tipCenter: tipCenter,
                    isChinese: l10n.zh,
                    action: onOpenSettings
                )
                Spacer()
                FooterActionButton(
                    id: "quit",
                    systemImage: "power",
                    title: l10n.quit,
                    shortcut: "⌘Q",
                    tipAlignment: .trailing,
                    interaction: interaction,
                    tipCenter: tipCenter,
                    isChinese: l10n.zh,
                    action: onQuit
                )
            }

            let lastSyncText: String = {
                if let age = store.officialReport.staleAgeSeconds {
                    return UsageFormatter.relativeAge(age)
                }
                return UsageFormatter.relativeAge(max(0, Date().timeIntervalSince(store.localReport.updatedAt)))
            }()

            FooterActionButton(
                id: "refresh",
                systemImage: "arrow.clockwise",
                title: l10n.refresh,
                shortcut: "⌘R",
                extraTipRows: [
                    Tip.Row(l10n.zh ? "上次同步" : "Last synced", lastSyncText),
                ],
                tipAlignment: .center,
                rotation: interaction.refreshSpinDegrees,
                interaction: interaction,
                tipCenter: tipCenter,
                isChinese: l10n.zh,
                action: onRefresh
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}
