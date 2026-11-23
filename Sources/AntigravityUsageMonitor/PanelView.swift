import SwiftUI
import UsageCore

struct PanelView: View {
    @Bindable var store: UsageMonitorStore
    @Bindable var preferences: AppPreferences
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    if !store.bridgeStatus.isInstalled {
                        bridgeSetupBanner
                    }

                    if preferences.quotaSectionDensity != .hidden {
                        quotaSection
                    }

                    if preferences.contextSectionDensity != .hidden {
                        contextSection
                    }

                    if preferences.localSectionDensity != .hidden {
                        localUsageSection
                    }
                }
                .padding(14)
            }
            .frame(maxHeight: 560)

            Divider()
            footerBar
        }
        .frame(width: 364)
        .background(.regularMaterial)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.tint)

            Text("Antigravity Usage")
                .font(.system(size: 13, weight: .semibold))

            if let tier = store.officialReport.planTier, !tier.isEmpty {
                Text(tier.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }

            Spacer()

            Button {
                store.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .rotationEffect(.degrees(store.isRefreshing ? 360 : 0))
            }
            .buttonStyle(.borderless)
            .help("立即刷新")

            Button {
                onOpenSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("设置")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Bridge Setup Banner

    private var bridgeSetupBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "link.badge.plus")
                    .foregroundStyle(.orange)
                Text("未接入 agy statusLine 桥接")
                    .font(.system(size: 12, weight: .semibold))
            }
            Text("接入后可零抓包读取官方 5 小时/周限额与重置倒计时（自动备份 settings.json，支持一键还原）。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("一键安全接入") {
                    store.installBridge()
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)

                Button("查看详情") {
                    onOpenSettings()
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Official Quota Section

    private var quotaSection: some View {
        SectionCard(
            title: "官方限额",
            subtitle: quotaSubtitle,
            isCollapsed: $preferences.quotaCollapsed
        ) {
            if !store.officialReport.hasSnapshot {
                VStack(alignment: .leading, spacing: 4) {
                    Text("暂无官方限额快照")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("在终端运行一次 agy CLI 产生交互后，这里会自动显示官方 5 小时与周限额（绝不用本地估算冒充）。")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            } else if store.officialReport.buckets.isEmpty {
                Text("最新快照未包含配额桶信息")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(store.officialReport.buckets) { bucket in
                        QuotaBucketRow(
                            bucket: bucket,
                            isSimple: preferences.quotaSectionDensity == .simple
                        )
                    }
                }
            }
        }
    }

    private var quotaSubtitle: String? {
        guard let age = store.officialReport.staleAgeSeconds else { return nil }
        if store.officialReport.isStale {
            return "更新于 \(UsageFormatter.relativeAge(age))"
        }
        return UsageFormatter.relativeAge(age)
    }

    // MARK: - Active Context Window Section

    private var contextSection: some View {
        SectionCard(
            title: "活跃会话上下文",
            subtitle: store.officialReport.activeModelName,
            isCollapsed: $preferences.contextCollapsed
        ) {
            if let ctx = store.officialReport.contextWindow {
                let usedPct = max(0, min(100, ctx.usedPercentage ?? 0))
                let usedFraction = usedPct / 100.0
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(String(format: "已用 %.1f%%", usedPct))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(usedPct >= 85 ? .red : (usedPct >= 65 ? .orange : .primary))
                        Spacer()
                        if let size = ctx.contextWindowSize, size > 0 {
                            let usedTokens = (ctx.totalInputTokens ?? 0) + (ctx.totalOutputTokens ?? 0)
                            Text("\(UsageFormatter.compactTokens(usedTokens)) / \(UsageFormatter.compactTokens(size))")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }

                    ProgressBarWithSafeLine(
                        fraction: usedFraction,
                        safeLine: nil,
                        isOverPace: usedPct >= 85
                    )

                    if preferences.contextSectionDensity == .detailed, let current = ctx.currentUsage {
                        HStack(spacing: 12) {
                            MiniStat(label: "输入", value: UsageFormatter.compactTokens(current.inputTokens ?? 0))
                            MiniStat(label: "缓存读", value: UsageFormatter.compactTokens(current.cacheReadInputTokens ?? 0))
                            MiniStat(label: "输出", value: UsageFormatter.compactTokens(current.outputTokens ?? 0))
                        }
                    }
                }
            } else {
                Text("暂无活跃 agy CLI 会话上下文数据")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Local Token / Cache / Cost Section

    private var localUsageSection: some View {
        let currentSummary: UsageWindowSummary = {
            switch preferences.selectedLocalTab {
            case .today: return store.localReport.today
            case .fiveHour: return store.localReport.fiveHour
            case .week: return store.localReport.week
            }
        }()

        return SectionCard(
            title: "本地 Token 与缓存",
            subtitle: "\(store.localReport.conversationCount) 个会话",
            isCollapsed: $preferences.localCollapsed
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $preferences.selectedLocalTab) {
                    ForEach(LocalWindowTab.allCases) { tab in
                        Text(tab.label).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                // Key metrics grid
                HStack(spacing: 8) {
                    MetricPill(
                        title: "缓存命中率",
                        value: currentSummary.totalInputTokens > 0
                            ? UsageFormatter.percentageOneDecimal(currentSummary.cacheHitRate)
                            : "--",
                        accent: .green
                    )
                    MetricPill(
                        title: "缓存命中",
                        value: UsageFormatter.compactTokens(currentSummary.cacheReadTokens),
                        accent: .teal
                    )
                    MetricPill(
                        title: "输出 Token",
                        value: UsageFormatter.compactTokens(currentSummary.outputTokens),
                        accent: .blue
                    )
                }

                // Cost & uncached input row
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("新增输入 \(UsageFormatter.compactTokens(currentSummary.uncachedInputTokens)) · 请求 \(currentSummary.requestCount) 次")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Text("估算 \(UsageFormatter.currency(currentSummary.estimatedCostUSD))")
                                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            if currentSummary.cacheSavingsUSD > 0 {
                                Text("缓存省 \(UsageFormatter.currency(currentSummary.cacheSavingsUSD))")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.green)
                            }
                            if currentSummary.hasUnpricedModels {
                                Text("含未定价模型")
                                    .font(.system(size: 9.5, weight: .medium))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.orange.opacity(0.16), in: Capsule())
                                    .foregroundStyle(.orange)
                                    .help("未收录单价的模型：\(currentSummary.unpricedModels.joined(separator: ", "))")
                            }
                        }
                    }
                    Spacer()
                }

                if preferences.localSectionDensity == .detailed {
                    if !store.localReport.byModel.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 5) {
                            Text("本周按模型拆分")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                            ForEach(store.localReport.byModel.prefix(5)) { model in
                                HStack(spacing: 6) {
                                    Text(model.displayName)
                                        .font(.system(size: 11))
                                        .lineLimit(1)
                                    Spacer()
                                    Text("缓存 \(UsageFormatter.percentage(model.cacheHitRate))")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    Text(UsageFormatter.compactTokens(model.totalTokens))
                                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                        .frame(width: 52, alignment: .trailing)
                                    if let cost = model.estimatedCostUSD {
                                        Text(UsageFormatter.currency(cost))
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 48, alignment: .trailing)
                                    } else {
                                        Text("未定价")
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(.orange)
                                            .frame(width: 48, alignment: .trailing)
                                    }
                                }
                            }
                        }
                    }

                    if !store.localReport.dailyTrend.isEmpty {
                        Divider()
                        DailyTrendChartView(points: store.localReport.dailyTrend)
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack {
            Text("纯本地统计 · 零抓包")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            Button("设置…") {
                onOpenSettings()
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))

            Button("退出") {
                onQuit()
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

// MARK: - Reusable Subviews

private struct SectionCard<Content: View>: View {
    let title: String
    let subtitle: String?
    @Binding var isCollapsed: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isCollapsed.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                content()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct QuotaBucketRow: View {
    let bucket: QuotaBucketEvaluation
    let isSimple: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(bucket.displayName)
                    .font(.system(size: 11.5, weight: .medium))
                Spacer()
                if bucket.isResetElapsed {
                    Text("0% · 已重置")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.green)
                } else {
                    Text("\(bucket.usedPercentageInt)%")
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(bucket.isOverPace || bucket.usedFraction >= 0.85 ? .red : .primary)
                }
            }

            ProgressBarWithSafeLine(
                fraction: bucket.usedFraction,
                safeLine: bucket.safeLineFraction,
                isOverPace: bucket.isOverPace || bucket.usedFraction >= 0.85
            )
            .help(tooltipText)

            if !isSimple {
                HStack {
                    if let safe = bucket.safeLineFraction {
                        Text("安全线 \(UsageFormatter.percentage(safe))")
                            .font(.system(size: 10))
                            .foregroundStyle(bucket.isOverPace ? .red : .secondary)
                    }
                    Spacer()
                    if let secs = bucket.remainingSecondsUntilReset, !bucket.isResetElapsed {
                        Text("重置倒计时 \(UsageFormatter.countdown(secs))")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var tooltipText: String {
        var parts = ["已用 \(bucket.usedPercentageInt)%，剩余 \(UsageFormatter.percentage(bucket.remainingFraction))"]
        if let safe = bucket.safeLineFraction {
            parts.append("当前安全配速线：\(UsageFormatter.percentage(safe))")
        }
        if let secs = bucket.remainingSecondsUntilReset, !bucket.isResetElapsed {
            parts.append("距离重置：\(UsageFormatter.countdown(secs))")
        }
        return parts.joined(separator: " ｜ ")
    }
}

private struct ProgressBarWithSafeLine: View {
    let fraction: Double
    let safeLine: Double?
    let isOverPace: Bool

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let clamped = max(0, min(1, fraction))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(isOverPace ? Color.red : Color.accentColor)
                    .frame(width: max(clamped > 0 ? 4 : 0, width * clamped))

                if let safe = safeLine {
                    let safeClamped = max(0, min(1, safe))
                    Rectangle()
                        .fill(Color.primary.opacity(0.65))
                        .frame(width: 1.5, height: 10)
                        .offset(x: max(0, min(width - 1.5, width * safeClamped)))
                }
            }
        }
        .frame(height: 7)
    }
}

private struct MetricPill: View {
    let title: String
    let value: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(accent)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct MiniStat: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        }
    }
}

private struct DailyTrendChartView: View {
    let points: [DailyUsagePoint]

    var body: some View {
        let maxTokens = max(1, points.map(\.totalTokens).max() ?? 1)
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("近 14 天消耗趋势")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("峰值 \(UsageFormatter.compactTokens(maxTokens))")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            HStack(alignment: .bottom, spacing: 4) {
                ForEach(points) { point in
                    let ratio = Double(point.totalTokens) / Double(maxTokens)
                    VStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(point.totalTokens > 0 ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.08))
                            .frame(height: max(3, CGFloat(ratio) * 38))
                    }
                    .frame(maxWidth: .infinity)
                    .help("\(point.dayKey)：\(UsageFormatter.compactTokens(point.totalTokens)) tokens（估算 \(UsageFormatter.currency(point.estimatedCostUSD))）")
                }
            }
            .frame(height: 40, alignment: .bottom)
        }
    }
}
