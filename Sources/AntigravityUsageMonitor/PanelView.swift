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
    var onToggleDisclosure: (String, Bool) -> Void = { _, _ in }
    var onPreferredHeightChange: @MainActor @Sendable (CGFloat) -> Void = { _ in }

    var body: some View {
        let l10n = preferences.l10n
        TopPinnedRootLayout {
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

                    if preferences.showEstimatedOutputSpeed && preferences.contextSectionDensity != .hidden {
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
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { newHeight in
                Task { @MainActor in
                    onPreferredHeightChange(newHeight)
                }
            }
        }
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
                HStack(spacing: 6) {
                    PlanTagView(rawTier: tier)
                    if preferences.billingDay > 0,
                       let monthPeriod = store.localReport.monthPeriod,
                       monthPeriod.remainingDays <= 5 {
                        let days = monthPeriod.remainingDays
                        Text(l10n.zh ? "还剩 \(days) 天" : "\(days)d left")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(days <= 3 ? Palette.warning : Palette.secondary)
                    }
                }
                .panelTip("header.plan", center: tipCenter, alignment: .trailing) {
                    var rows = [Tip.Row(l10n.zh ? "订阅方案" : "Plan", tier)]
                    if let email = store.officialReport.email, !email.isEmpty {
                        rows.append(Tip.Row(l10n.zh ? "账号" : "Account", email))
                    }
                    if preferences.billingDay > 0, let monthPeriod = store.localReport.monthPeriod {
                        rows.append(Tip.Row(
                            l10n.zh ? "账单日" : "Billing day",
                            l10n.zh ? "每月 \(preferences.billingDay) 日" : "Day \(preferences.billingDay)",
                            separated: true
                        ))
                        rows.append(Tip.Row(
                            l10n.zh ? "本周期剩余" : "Period left",
                            l10n.zh ? "\(monthPeriod.remainingDays) 天" : "\(monthPeriod.remainingDays) days"
                        ))
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
                    if store.isSyncingOfficial {
                        Text(l10n.zh ? "正在同步…" : "Syncing…")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.accent)
                    } else if let age = store.officialReport.staleAgeSeconds {
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
                let needsLogin = store.officialAuthRequired
                    || store.officialReport.agentState == "authenticating"
                    || (store.officialReport.hasSnapshot && (store.officialReport.email?.isEmpty ?? true))

                if !store.officialReport.hasSnapshot || store.officialReport.buckets.isEmpty {
                    QuietNoticeRow(
                        systemImage: "chevron.forward.square",
                        title: store.isSyncingOfficial
                            ? (l10n.zh ? "正在后台同步官方额度…" : "Syncing official limits in background…")
                            : l10n.cliSyncTitle,
                        subtitle: l10n.cliSyncSubtitle,
                        actionTitle: l10n.openTerminalConnect,
                        actionIcon: "chevron.forward.square",
                        isActionHovered: interaction.isLoginButtonHovered,
                        onActionHover: { interaction.isLoginButtonHovered = $0 },
                        onAction: { store.openTerminalToConnectCLI() }
                    )
                } else {
                    let groups = groupedQuotaBuckets(store.officialReport.buckets, l10n: l10n)
                    let isSimple = preferences.quotaSectionDensity == .simple
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(groups.enumerated()), id: \.element.id) { idx, group in
                            if idx > 0 {
                                Hairline()
                            }
                            quotaGroupView(group: group, l10n: l10n, isSimple: isSimple)
                        }
                    }

                    if needsLogin {
                        QuietNoticeRow(
                            systemImage: "chevron.forward.square",
                            title: l10n.zh ? "agy CLI 的登录已失效" : "agy CLI sign-in required",
                            subtitle: l10n.zh ? "登录到期或已退出，重新登录后即可关闭终端" : "Session expired or signed out. Sign in once, then close Terminal.",
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

    private struct QuotaBucketGroup: Identifiable {
        let id: String
        let title: String
        let accent: Color
        let isPrimary: Bool
        let buckets: [QuotaBucketEvaluation]

        var isAllUnused: Bool {
            buckets.allSatisfy { $0.usedPercentageInt == 0 && $0.resetTime == nil && !$0.isResetElapsed }
        }
    }

    private func groupedQuotaBuckets(_ buckets: [QuotaBucketEvaluation], l10n: L10n) -> [QuotaBucketGroup] {
        var bucketMap: [String: [QuotaBucketEvaluation]] = [:]
        for bucket in buckets {
            let key = quotaGroupKey(for: bucket.bucketId)
            bucketMap[key, default: []].append(bucket)
        }

        let orderRank: (String) -> Int = { key in
            switch key {
            case "gemini": return 0
            case "3p": return 1
            default: return 2
            }
        }
        let windowRank: (QuotaWindowKind) -> Int = { kind in
            switch kind {
            case .fiveHour: return 0
            case .weekly: return 1
            case .other: return 2
            }
        }

        return bucketMap.keys.sorted { lhs, rhs in
            if orderRank(lhs) != orderRank(rhs) {
                return orderRank(lhs) < orderRank(rhs)
            }
            return lhs < rhs
        }.map { key in
            let sortedBuckets = (bucketMap[key] ?? []).sorted { a, b in
                if windowRank(a.windowKind) != windowRank(b.windowKind) {
                    return windowRank(a.windowKind) < windowRank(b.windowKind)
                }
                return a.bucketId < b.bucketId
            }
            let title: String
            let accent: Color
            switch key {
            case "gemini":
                title = "Gemini"
                accent = Palette.accent
            case "3p":
                title = l10n.zh ? "第三方模型" : "Third-Party"
                accent = Color(hex: 0xC4B5FD)
            default:
                title = key.capitalized
                accent = Palette.secondary
            }
            return QuotaBucketGroup(
                id: key,
                title: title,
                accent: accent,
                isPrimary: key == "gemini",
                buckets: sortedBuckets
            )
        }
    }

    private func quotaGroupKey(for bucketId: String) -> String {
        let lower = bucketId.lowercased()
        if lower.contains("gemini") { return "gemini" }
        if lower.contains("3p") || lower.contains("third") { return "3p" }
        if lower.contains("claude") { return "claude" }
        if lower.contains("gpt") { return "gpt" }
        return lower
            .replacingOccurrences(of: "-5h", with: "")
            .replacingOccurrences(of: "-weekly", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func quotaRowShortTitle(for bucket: QuotaBucketEvaluation, l10n: L10n) -> String {
        switch bucket.windowKind {
        case .fiveHour:
            return l10n.zh ? "5 小时" : "5-hour"
        case .weekly:
            return l10n.zh ? "本周" : "Weekly"
        case .other:
            return bucket.displayName
        }
    }

    @ViewBuilder
    private func quotaGroupView(group: QuotaBucketGroup, l10n: L10n, isSimple: Bool) -> some View {
        let canAutoCollapse = !group.isPrimary && group.isAllUnused
        let isExpanded = !canAutoCollapse || interaction.expandedUnusedQuotaGroups.contains(group.id)
        let disclosureKey = "quota.\(group.id)"
        let revealProgress = canAutoCollapse
            ? interaction.progress(for: disclosureKey, defaultExpanded: isExpanded)
            : 1.0

        VStack(alignment: .leading, spacing: 0) {
            if canAutoCollapse {
                Button {
                    let nextExpanded = !interaction.expandedUnusedQuotaGroups.contains(group.id)
                    if nextExpanded {
                        _ = interaction.expandedUnusedQuotaGroups.insert(group.id)
                    } else {
                        _ = interaction.expandedUnusedQuotaGroups.remove(group.id)
                    }
                    onToggleDisclosure(disclosureKey, nextExpanded)
                } label: {
                    HStack(spacing: 6) {
                        Text(group.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(group.accent)
                        Text(l10n.zh ? "本周期未使用" : "Not used yet")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.tertiary)
                            .opacity(max(0, 1.0 - revealProgress * 2.0))
                        Spacer()
                        HStack(spacing: 4) {
                            ZStack(alignment: .trailing) {
                                Text("0%")
                                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Palette.tertiary)
                                    .opacity(max(0, 1.0 - revealProgress * 2.0))
                                Text(l10n.zh ? "收起" : "Hide")
                                    .font(.system(size: 10.5, weight: .regular))
                                    .foregroundStyle(Palette.tertiary)
                                    .opacity(max(0, (revealProgress - 0.5) * 2.0))
                            }
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundStyle(Palette.tertiary)
                                .rotationEffect(.degrees(revealProgress * 180.0))
                        }
                    }
                    .frame(height: 16)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(FlatDisclosureButtonStyle())
            } else {
                HStack {
                    Text(group.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(group.accent)
                    Spacer()
                }
            }

            DisclosureRevealContainer(progress: revealProgress) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(group.buckets) { bucket in
                        limitRow(
                            bucket: bucket,
                            rowTitle: quotaRowShortTitle(for: bucket, l10n: l10n),
                            l10n: l10n,
                            isSimple: isSimple
                        )
                    }
                }
                .padding(.top, 8)
            }
            .opacity(min(1.0, revealProgress * 1.15))
            .allowsHitTesting(revealProgress > 0.5)
            .accessibilityHidden(revealProgress <= 0.01)
        }
    }

    private func limitRow(bucket: QuotaBucketEvaluation, rowTitle: String, l10n: L10n, isSimple: Bool) -> some View {
        let levelColor = Palette.levelColor(for: bucket.usedFraction, overPace: bucket.isOverPace)
        let isHovered = interaction.hoveredBucketId == bucket.bucketId

        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(rowTitle)
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
                    if isHovered, let safePct = bucket.safeLinePercentageInt, !bucket.isResetElapsed {
                        let headroomPct = max(0, safePct - bucket.usedPercentageInt)
                        let paceText: String = {
                            if bucket.isPaceSettling {
                                return "\(l10n.safeLine)\(safePct)% · \(l10n.zh ? "刚开启周期" : "Settling")"
                            }
                            if bucket.isOverPace {
                                return "\(l10n.safeLine)\(safePct)% · \(l10n.zh ? "已超速" : "Over pace")"
                            }
                            return "\(l10n.safeLine)\(safePct)% · \(l10n.zh ? "安全余量 " : "Headroom ")\(headroomPct)%"
                        }()
                        Text(paceText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(bucket.isOverPace ? Palette.critical : Palette.secondary)
                        .lineLimit(1)
                    } else if bucket.isResetElapsed {
                        Text(l10n.resetDone)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.tertiary)
                    } else if let secs = bucket.remainingSecondsUntilReset {
                        Text("\(l10n.resetsIn)\(UsageFormatter.countdown(secs))")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.tertiary)
                    } else {
                        Text(l10n.zh ? "本周期未使用" : "Not used yet")
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
            Tip.Row(l10n.zh ? "剩余" : "Remaining", "\(bucket.remainingPercentageInt)%"),
        ]
        if let safePct = bucket.safeLinePercentageInt, !bucket.isResetElapsed {
            rows.append(Tip.Row(
                l10n.zh ? "此刻安全线" : "Safe line",
                "\(safePct)%",
                color: bucket.isOverPace ? Palette.critical : Palette.safeGreen
            ))
        }
        if let secs = bucket.remainingSecondsUntilReset, !bucket.isResetElapsed {
            rows.append(Tip.Row(l10n.zh ? "距离重置" : "Resets in", UsageFormatter.countdown(secs), separated: true))
        } else if bucket.resetTime == nil && !bucket.isResetElapsed {
            rows.append(Tip.Row(l10n.zh ? "周期状态" : "Window", l10n.zh ? "本周期未使用" : "Not used yet", separated: true))
        }
        return Tip(title: bucket.displayName, rows: rows)
    }

    // MARK: - Output Speed & Active Context Section

    private func contextSection(l10n: L10n) -> some View {
        let speed = store.localReport.outputSpeed
        let ctx = store.officialReport.contextWindow
        let usedPct = max(0, min(100, ctx?.usedPercentage ?? 0))
        let usedTokens = (ctx?.totalInputTokens ?? 0) + (ctx?.totalOutputTokens ?? 0)
        let hasActiveCtx = ctx != nil && (usedTokens > 0 || usedPct > 0)

        return VStack(alignment: .leading, spacing: 7) {
            Button {
                preferences.contextCollapsed.toggle()
            } label: {
                HStack {
                    Text(l10n.zh ? "输出速度" : "Output speed")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Palette.secondary)
                    Spacer()
                    if speed.isRecentlyActive, let age = speed.lastResponseAgeSeconds {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Palette.live)
                                .frame(width: 5, height: 5)
                            Text(l10n.zh ? "生成活跃 · \(Int(age))s 前" : "Active · \(Int(age))s ago")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Palette.secondary)
                        }
                    } else if let modelName = store.officialReport.activeModelName, hasActiveCtx {
                        Text(modelName)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.tertiary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !preferences.contextCollapsed {
                if let tokPerSec = speed.displayTokPerSec {
                    let recentSpark = Array(speed.samples.suffix(18))
                    let hoveredSparkSample: OutputSpeedSample? = {
                        guard let idx = interaction.hoveredSparkSampleIndex, idx >= 0, idx < recentSpark.count else { return nil }
                        return recentSpark[idx]
                    }()
                    let hoveredDotSample: OutputSpeedSample? = {
                        guard let id = interaction.hoveredDotSampleId else { return nil }
                        return speed.samples.first(where: { $0.id == id })
                    }()
                    let timeFmt = CachedFormatters.hhmm

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(alignment: .lastTextBaseline, spacing: 3) {
                                    Text("~\(Int(round(tokPerSec)))")
                                        .font(.system(size: 24, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Palette.text)
                                    Text("tok/s")
                                        .font(.system(size: 11.5, weight: .regular))
                                        .foregroundStyle(Palette.secondary)
                                }

                                if let hs = hoveredSparkSample {
                                    Text("\(timeFmt.string(from: hs.timestamp)) · ~\(Int(round(hs.tokensPerSec))) tok/s · \(UsageFormatter.compactTokens(hs.outputTokens))")
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(Palette.secondary)
                                        .lineLimit(1)
                                } else {
                                    let windowLabel = speed.recent5mTokPerSec != nil
                                        ? (l10n.zh ? "近 5 分钟" : "Last 5 min")
                                        : (l10n.zh ? "近 1 小时" : "Last 1 hr")
                                    let modelSuffix = speed.latestModelName.map { " · \($0)" } ?? ""
                                    Text(windowLabel + modelSuffix)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(Palette.tertiary)
                                        .lineLimit(1)
                                }
                            }
                            .contentShape(Rectangle())
                            .panelTip("speed.approx", center: tipCenter, alignment: .leading) {
                                var rows: [Tip.Row] = []
                                if let s5 = speed.recent5mTokPerSec {
                                    rows.append(Tip.Row(l10n.zh ? "近 5 分钟均值" : "Last 5 min avg", "~\(Int(round(s5))) tok/s"))
                                }
                                if let s1 = speed.recent1hTokPerSec {
                                    rows.append(Tip.Row(l10n.zh ? "近 1 小时均值" : "Last 1 hr avg", "~\(Int(round(s1))) tok/s · \(speed.recent1hReplyCount)"))
                                }
                                return Tip(
                                    title: l10n.zh ? "近似输出速度" : "Approximate output speed",
                                    rows: rows,
                                    note: l10n.zh
                                        ? "点击右侧图表可在「折线图」与「1 小时回复热点图」间切换。"
                                        : "Click the chart to toggle between sparkline and 1-hour reply dot plot."
                                )
                            }

                            Spacer()

                            if interaction.showSpeedDotChart {
                                // Detailed mode header right: 1-hour summary (tap to switch back)
                                Button {
                                    interaction.showSpeedDotChart = false
                                    interaction.hoveredDotSampleId = nil
                                    onToggleDisclosure("speedDotChart", false)
                                } label: {
                                    VStack(alignment: .trailing, spacing: 2) {
                                        if let s1 = speed.recent1hTokPerSec {
                                            Text("~\(Int(round(s1))) tok/s")
                                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                                .foregroundStyle(Palette.secondary)
                                        }
                                        Text(l10n.zh ? "近 1 小时 · \(speed.recent1hReplyCount) 次" : "Last 1h · \(speed.recent1hReplyCount)")
                                            .font(.system(size: 10))
                                            .foregroundStyle(Palette.tertiary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            } else if speed.samples.count >= 2 {
                                SparklineView(
                                    samples: speed.samples,
                                    hoveredIndex: interaction.hoveredSparkSampleIndex,
                                    onHoverIndex: { interaction.hoveredSparkSampleIndex = $0 },
                                    onTap: {
                                        interaction.hoveredSparkSampleIndex = nil
                                        interaction.showSpeedDotChart = true
                                        onToggleDisclosure("speedDotChart", true)
                                    }
                                )
                            }
                        }

                        let speedChartProgress = interaction.progress(
                            for: "speedDotChart",
                            defaultExpanded: interaction.showSpeedDotChart
                        )
                        if speedChartProgress > 0 && !speed.samples.isEmpty {
                            DisclosureRevealContainer(progress: speedChartProgress) {
                                VStack(alignment: .leading, spacing: 4) {
                                    SpeedDotChartView(
                                        samples: speed.samples,
                                        now: store.localReport.updatedAt,
                                        hoveredSampleId: interaction.hoveredDotSampleId,
                                        onHoverSample: { interaction.hoveredDotSampleId = $0 },
                                        onTap: {
                                            interaction.hoveredDotSampleId = nil
                                            interaction.showSpeedDotChart = false
                                            onToggleDisclosure("speedDotChart", false)
                                        }
                                    )

                                    HStack {
                                        if let dot = hoveredDotSample {
                                            Text("\(timeFmt.string(from: dot.timestamp)) · ~\(Int(round(dot.tokensPerSec))) tok/s · \(UsageFormatter.compactTokens(dot.outputTokens)) tokens · \(dot.modelDisplayName)")
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundStyle(Palette.secondary)
                                                .lineLimit(1)
                                        } else {
                                            Text(l10n.zh ? "1 小时前" : "1h ago")
                                                .font(.system(size: 9.5))
                                                .foregroundStyle(Palette.tertiary)
                                            Spacer()
                                            Text(l10n.zh ? "点击图表切换折线" : "Click to toggle sparkline")
                                                .font(.system(size: 9.5))
                                                .foregroundStyle(Palette.quaternary)
                                            Spacer()
                                            Text(l10n.zh ? "现在" : "Now")
                                                .font(.system(size: 9.5))
                                                .foregroundStyle(Palette.tertiary)
                                        }
                                    }
                                }
                            }
                            .opacity(min(1.0, speedChartProgress * 1.15))
                        }

                        if hasActiveCtx, let ctx, preferences.contextSectionDensity == .detailed {
                            HStack {
                                Text(l10n.zh ? "活跃上下文" : "Context")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(Palette.tertiary)
                                Spacer()
                                if let size = ctx.contextWindowSize, size > 0 {
                                    Text("\(String(format: "%.1f%%", usedPct)) · \(UsageFormatter.compactTokens(usedTokens)) / \(UsageFormatter.compactTokens(size))")
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(Palette.secondary)
                                }
                            }
                            .padding(.top, 1)
                        }
                    }
                } else {
                    QuietNoticeRow(
                        systemImage: "waveform.path.ecg",
                        title: l10n.zh ? "最近 1 小时没有回复" : "No replies in the last hour",
                        subtitle: l10n.zh
                            ? "Antigravity 写完回复后，这里显示估算的每秒输出 token"
                            : "Approximate tokens per second appear here after a reply"
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

        let activePeriod: BillingPeriodInfo? = {
            switch preferences.selectedSpendTab {
            case .month: return store.localReport.monthPeriod
            case .week: return store.localReport.weekPeriod
            case .today: return nil
            }
        }()

        let periodHeaderText: String = {
            if let period = activePeriod {
                let fmt = l10n.zh ? CachedFormatters.zhPeriodDateTime : CachedFormatters.enPeriodDateTime
                return "\(fmt.string(from: period.start)) – \(fmt.string(from: period.end))"
            } else {
                let fmt = l10n.zh ? CachedFormatters.zhDay : CachedFormatters.enDay
                return fmt.string(from: store.localReport.updatedAt)
            }
        }()

        let needsBillingDayPrompt = preferences.selectedSpendTab == .month && activePeriod == nil

        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Button {
                    preferences.spendCollapsed.toggle()
                } label: {
                    Text(l10n.spend)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Palette.secondary)
                }
                .buttonStyle(.plain)

                Spacer()

                if needsBillingDayPrompt {
                    Button {
                        preferences.selectedSettingsTab = .general
                        onOpenSettings()
                    } label: {
                        Text(l10n.zh ? "设置订阅日…" : "Set billing day…")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Palette.accent)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(periodHeaderText)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Palette.tertiary)
                        .lineLimit(1)
                        .panelTip("spend.period", center: tipCenter, alignment: .trailing) {
                            Tip(rows: [
                                Tip.Row(l10n.zh ? "本地扫描会话" : "Local sessions", "\(store.localReport.conversationCount)"),
                            ])
                        }
                }
            }

            if !preferences.spendCollapsed {
                // Dark capsule segmented control (full-area hit target + hover + smooth transition)
                HStack(spacing: 2) {
                    ForEach(SpendWindowTab.allCases) { tab in
                        let selected = preferences.selectedSpendTab == tab
                        let hovered = interaction.hoveredTab == tab && !selected
                        Button {
                            guard preferences.selectedSpendTab != tab else { return }
                            preferences.selectedSpendTab = tab
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

                // Projected spend & tokens:
                // 1) Current week official ratio (>= 10% usage),
                // 2) Borrowed full-week basis from a previous >= 10% week (matching claude-usage-monitor),
                // 3) Fallback to daily run-rate when neither exists yet.
                let projection: (costUSD: Double, tokens: Int, isRunRate: Bool)? = {
                    guard preferences.selectedSpendTab != .today else { return nil }
                    let isMonth = preferences.selectedSpendTab == .month
                    let weeksInMonth = Double(store.localReport.monthPeriod?.totalDays ?? 30) / 7.0

                    if let weekly = store.officialReport.primaryWeekly,
                       !weekly.isResetElapsed,
                       weekly.usedFraction >= 0.10,
                       store.localReport.week.estimatedCostUSD > 0 {
                        let fullWeekCost = store.localReport.week.estimatedCostUSD / weekly.usedFraction
                        let fullWeekTokens = Double(store.localReport.week.totalTokens) / weekly.usedFraction
                        return isMonth
                            ? (fullWeekCost * weeksInMonth, Int(fullWeekTokens * weeksInMonth), false)
                            : (fullWeekCost, Int(fullWeekTokens), false)
                    }

                    if preferences.savedFullWeekCostUSD > 0 {
                        let fullWeekCost = preferences.savedFullWeekCostUSD
                        let fullWeekTokens = Double(preferences.savedFullWeekTokens)
                        return isMonth
                            ? (fullWeekCost * weeksInMonth, Int(fullWeekTokens * weeksInMonth), false)
                            : (fullWeekCost, Int(fullWeekTokens), false)
                    }

                    if let period = activePeriod, period.currentDay >= 1, summary.estimatedCostUSD > 0 {
                        let scale = Double(period.totalDays) / Double(period.currentDay)
                        return (summary.estimatedCostUSD * scale, Int(Double(summary.totalTokens) * scale), true)
                    }
                    return nil
                }()

                // Big cost + projected total + 14-day mini bars side by side
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .lastTextBaseline, spacing: 6) {
                            Text(preferences.formatMoney(summary.estimatedCostUSD))
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

                            if let proj = projection {
                                let projCostStr = preferences.formatMoneyCompact(proj.costUSD)
                                Text(l10n.zh ? "预计 \(projCostStr)" : "→ \(projCostStr)")
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(Palette.tertiary)
                                    .panelTip("spend.projected", center: tipCenter, alignment: .leading) {
                                        Tip(
                                            title: proj.isRunRate
                                                ? (l10n.zh ? "按当前节奏预计" : "Projected at current pace")
                                                : (l10n.zh ? "满额预计用量" : "Projected full-limit usage"),
                                            rows: [
                                                Tip.Row(l10n.zh ? "预计花费" : "Projected spend", projCostStr),
                                                Tip.Row(l10n.zh ? "预计 Tokens" : "Projected tokens", "~\(UsageFormatter.compactTokens(proj.tokens))"),
                                            ],
                                            note: proj.isRunRate
                                                ? (l10n.zh
                                                    ? "本周额度尚不足 10%，暂按本周期日均消耗推算；达到 10% 后自动切换为官方配额满额推算。"
                                                    : "Weekly usage is under 10%; extrapolated from current daily pace until 10% is reached.")
                                                : (l10n.zh
                                                    ? "按官方周限额已用比例推算用满 100% 时的大致总量，仅供体感参考。"
                                                    : "Extrapolated from official weekly limit percentage assuming 100% usage.")
                                        )
                                    }
                            }
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
                        } else if let period = activePeriod {
                            let dayLabel = l10n.zh
                                ? "第 \(period.currentDay) / \(period.totalDays) 天"
                                : "Day \(period.currentDay) of \(period.totalDays)"
                            let extraPart: String = {
                                if let proj = projection {
                                    let left = max(0, proj.costUSD - summary.estimatedCostUSD)
                                    let leftStr = preferences.formatMoneyCompact(left)
                                    return l10n.zh ? " · 预计还剩 \(leftStr)" : " · \(leftStr) left"
                                }
                                if summary.cacheSavingsUSD > 0 {
                                    return " · \(l10n.savedPrefix)\(preferences.formatMoney(summary.cacheSavingsUSD))"
                                }
                                return ""
                            }()
                            Text(dayLabel + extraPart)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Palette.tertiary)
                        } else if summary.cacheSavingsUSD > 0 {
                            Text("\(l10n.savedPrefix)\(preferences.formatMoney(summary.cacheSavingsUSD))")
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
                            isChinese: l10n.zh,
                            formatMoney: { preferences.formatMoney($0) }
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
                    inlineStat(label: l10n.todayShort, value: preferences.formatMoney(store.localReport.today.estimatedCostUSD))
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
                            Text("\(l10n.savedPrefix)\(preferences.formatMoney(summary.cacheSavingsUSD))")
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
                                    Text(preferences.formatMoney(cost))
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
                                    rows.append(Tip.Row(l10n.zh ? "缓存节省" : "Cache saved", preferences.formatMoney(saved), color: Palette.safeGreen))
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
                    extraTipRows: store.visibleAvailableUpdate.map { update in
                        [Tip.Row(l10n.zh ? "发现新版本" : "Update available", "v\(update.version)", color: Palette.accent)]
                    } ?? [],
                    tipAlignment: .leading,
                    interaction: interaction,
                    tipCenter: tipCenter,
                    isChinese: l10n.zh,
                    action: {
                        if store.showsSettingsUpdateBadge {
                            preferences.selectedSettingsTab = .general
                            store.showUpdateNotes()
                        }
                        onOpenSettings()
                    }
                )
                .overlay(alignment: .topTrailing) {
                    if store.showsSettingsUpdateBadge {
                        Circle()
                            .fill(Palette.accent)
                            .frame(width: 6, height: 6)
                            .offset(x: -2, y: 2)
                            .allowsHitTesting(false)
                    }
                }
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

private struct TopPinnedRootLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let childSize = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        if let proposedHeight = proposal.height, proposedHeight.isFinite, proposedHeight < 10_000 {
            return CGSize(width: childSize.width, height: proposedHeight)
        }
        return childSize
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let childSize = child.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        child.place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: childSize.height)
        )
    }
}

private struct FlatDisclosureButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

private struct DisclosureRevealLayout: Layout {
    var progress: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let clamped = max(0, min(1, progress))
        guard clamped > 0, let child = subviews.first else {
            return CGSize(width: proposal.width ?? 0, height: 0)
        }
        let full = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: full.width, height: full.height * clamped)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard progress > 0, let child = subviews.first else { return }
        let full = child.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        child.place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: full.height)
        )
    }
}

private struct DisclosureRevealContainer<Content: View>: View {
    let progress: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        DisclosureRevealLayout(progress: progress) {
            content
        }
        .clipped()
    }
}
