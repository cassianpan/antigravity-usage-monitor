import Foundation

// MARK: - Local Transcript Records

public struct TranscriptRecord: Sendable, Equatable, Codable {
    public let timestamp: Date
    public let model: String
    /// Uncached input tokens (`input_tokens` in transcript.jsonl).
    public let inputTokens: Int
    /// Cached input tokens (`cache_read_tokens` in transcript.jsonl).
    public let cacheReadTokens: Int
    /// Output tokens (`output_tokens` in transcript.jsonl).
    public let outputTokens: Int
    public let conversationId: String

    public init(
        timestamp: Date,
        model: String,
        inputTokens: Int,
        cacheReadTokens: Int,
        outputTokens: Int,
        conversationId: String
    ) {
        self.timestamp = timestamp
        self.model = model
        self.inputTokens = max(0, inputTokens)
        self.cacheReadTokens = max(0, cacheReadTokens)
        self.outputTokens = max(0, outputTokens)
        self.conversationId = conversationId
    }

    public var totalInputTokens: Int {
        inputTokens + cacheReadTokens
    }

    public var totalTokens: Int {
        inputTokens + cacheReadTokens + outputTokens
    }
}

// MARK: - Aggregated Local Usage

public struct UsageWindowSummary: Sendable, Equatable {
    public let uncachedInputTokens: Int
    public let cacheReadTokens: Int
    public let outputTokens: Int
    public let requestCount: Int
    public let estimatedCostUSD: Double
    public let cacheSavingsUSD: Double
    public let unpricedModels: [String]

    public init(
        uncachedInputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        outputTokens: Int = 0,
        requestCount: Int = 0,
        estimatedCostUSD: Double = 0,
        cacheSavingsUSD: Double = 0,
        unpricedModels: [String] = []
    ) {
        self.uncachedInputTokens = uncachedInputTokens
        self.cacheReadTokens = cacheReadTokens
        self.outputTokens = outputTokens
        self.requestCount = requestCount
        self.estimatedCostUSD = estimatedCostUSD
        self.cacheSavingsUSD = cacheSavingsUSD
        self.unpricedModels = unpricedModels
    }

    public var totalInputTokens: Int {
        uncachedInputTokens + cacheReadTokens
    }

    public var totalTokens: Int {
        uncachedInputTokens + cacheReadTokens + outputTokens
    }

    /// Cache hit rate in [0, 1].
    public var cacheHitRate: Double {
        let denom = totalInputTokens
        guard denom > 0 else { return 0 }
        return Double(cacheReadTokens) / Double(denom)
    }

    public var hasUnpricedModels: Bool {
        !unpricedModels.isEmpty
    }
}

public struct ModelUsageSummary: Sendable, Equatable, Identifiable {
    public var id: String { model }
    public let model: String
    public let displayName: String
    public let uncachedInputTokens: Int
    public let cacheReadTokens: Int
    public let outputTokens: Int
    public let requestCount: Int
    public let estimatedCostUSD: Double?
    public let cacheSavingsUSD: Double?

    public init(
        model: String,
        displayName: String,
        uncachedInputTokens: Int,
        cacheReadTokens: Int,
        outputTokens: Int,
        requestCount: Int,
        estimatedCostUSD: Double?,
        cacheSavingsUSD: Double?
    ) {
        self.model = model
        self.displayName = displayName
        self.uncachedInputTokens = uncachedInputTokens
        self.cacheReadTokens = cacheReadTokens
        self.outputTokens = outputTokens
        self.requestCount = requestCount
        self.estimatedCostUSD = estimatedCostUSD
        self.cacheSavingsUSD = cacheSavingsUSD
    }

    public var totalInputTokens: Int {
        uncachedInputTokens + cacheReadTokens
    }

    public var totalTokens: Int {
        uncachedInputTokens + cacheReadTokens + outputTokens
    }

    public var cacheHitRate: Double {
        let denom = totalInputTokens
        guard denom > 0 else { return 0 }
        return Double(cacheReadTokens) / Double(denom)
    }

    public var isPriced: Bool {
        estimatedCostUSD != nil
    }
}

public struct DailyUsagePoint: Sendable, Equatable, Identifiable {
    public var id: String { dayKey }
    public let dayKey: String
    public let date: Date
    public let uncachedInputTokens: Int
    public let cacheReadTokens: Int
    public let outputTokens: Int
    public let estimatedCostUSD: Double

    public init(
        dayKey: String,
        date: Date,
        uncachedInputTokens: Int,
        cacheReadTokens: Int,
        outputTokens: Int,
        estimatedCostUSD: Double
    ) {
        self.dayKey = dayKey
        self.date = date
        self.uncachedInputTokens = uncachedInputTokens
        self.cacheReadTokens = cacheReadTokens
        self.outputTokens = outputTokens
        self.estimatedCostUSD = estimatedCostUSD
    }

    public var totalTokens: Int {
        uncachedInputTokens + cacheReadTokens + outputTokens
    }
}

public struct BillingPeriodInfo: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public let currentDay: Int
    public let totalDays: Int
    public let remainingDays: Int

    public init(start: Date, end: Date, currentDay: Int, totalDays: Int, remainingDays: Int) {
        self.start = start
        self.end = end
        self.currentDay = currentDay
        self.totalDays = totalDays
        self.remainingDays = remainingDays
    }
}

public struct OutputSpeedSample: Sendable, Equatable, Identifiable {
    public let id: Int
    public let timestamp: Date
    public let tokensPerSec: Double
    public let outputTokens: Int
    public let modelDisplayName: String

    public init(id: Int, timestamp: Date, tokensPerSec: Double, outputTokens: Int, modelDisplayName: String) {
        self.id = id
        self.timestamp = timestamp
        self.tokensPerSec = tokensPerSec
        self.outputTokens = outputTokens
        self.modelDisplayName = modelDisplayName
    }
}

public struct OutputSpeedSnapshot: Sendable, Equatable {
    public let recent5mTokPerSec: Double?
    public let recent1hTokPerSec: Double?
    public let recent1hReplyCount: Int
    public let latestModelName: String?
    public let sparkline: [Double]
    public let samples: [OutputSpeedSample]
    public let isRecentlyActive: Bool
    public let lastResponseAgeSeconds: TimeInterval?

    public init(
        recent5mTokPerSec: Double? = nil,
        recent1hTokPerSec: Double? = nil,
        recent1hReplyCount: Int = 0,
        latestModelName: String? = nil,
        sparkline: [Double] = [],
        samples: [OutputSpeedSample] = [],
        isRecentlyActive: Bool = false,
        lastResponseAgeSeconds: TimeInterval? = nil
    ) {
        self.recent5mTokPerSec = recent5mTokPerSec
        self.recent1hTokPerSec = recent1hTokPerSec
        self.recent1hReplyCount = recent1hReplyCount
        self.latestModelName = latestModelName
        self.sparkline = sparkline
        self.samples = samples
        self.isRecentlyActive = isRecentlyActive
        self.lastResponseAgeSeconds = lastResponseAgeSeconds
    }

    public var displayTokPerSec: Double? {
        recent5mTokPerSec ?? recent1hTokPerSec
    }
}

public struct LocalUsageReport: Sendable, Equatable {
    public let today: UsageWindowSummary
    public let fiveHour: UsageWindowSummary
    public let week: UsageWindowSummary
    public let month: UsageWindowSummary
    public let allTime: UsageWindowSummary
    public let earliestRecordDate: Date?
    public let weekPeriod: BillingPeriodInfo?
    public let monthPeriod: BillingPeriodInfo?
    public let outputSpeed: OutputSpeedSnapshot
    public let byModel: [ModelUsageSummary]
    public let dailyTrend: [DailyUsagePoint]
    public let conversationCount: Int
    public let updatedAt: Date

    public init(
        today: UsageWindowSummary = .init(),
        fiveHour: UsageWindowSummary = .init(),
        week: UsageWindowSummary = .init(),
        month: UsageWindowSummary = .init(),
        allTime: UsageWindowSummary = .init(),
        earliestRecordDate: Date? = nil,
        weekPeriod: BillingPeriodInfo? = nil,
        monthPeriod: BillingPeriodInfo? = nil,
        outputSpeed: OutputSpeedSnapshot = .init(),
        byModel: [ModelUsageSummary] = [],
        dailyTrend: [DailyUsagePoint] = [],
        conversationCount: Int = 0,
        updatedAt: Date = Date()
    ) {
        self.today = today
        self.fiveHour = fiveHour
        self.week = week
        self.month = month
        self.allTime = allTime
        self.earliestRecordDate = earliestRecordDate
        self.weekPeriod = weekPeriod
        self.monthPeriod = monthPeriod
        self.outputSpeed = outputSpeed
        self.byModel = byModel
        self.dailyTrend = dailyTrend
        self.conversationCount = conversationCount
        self.updatedAt = updatedAt
    }
}

// MARK: - Official StatusLine Snapshot

public struct StatusLineModelInfo: Sendable, Equatable, Codable {
    public let id: String?
    public let displayName: String?
    public let effort: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case effort
    }

    public init(id: String? = nil, displayName: String? = nil, effort: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.effort = effort
    }
}

public struct StatusLineCurrentUsage: Sendable, Equatable, Codable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cacheCreationInputTokens: Int?
    public let cacheReadInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }

    public init(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheCreationInputTokens: Int? = nil,
        cacheReadInputTokens: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
    }
}

public struct StatusLineContextWindow: Sendable, Equatable, Codable {
    public let totalInputTokens: Int?
    public let totalOutputTokens: Int?
    public let contextWindowSize: Int?
    public let usedPercentage: Double?
    public let remainingPercentage: Double?
    public let currentUsage: StatusLineCurrentUsage?

    enum CodingKeys: String, CodingKey {
        case totalInputTokens = "total_input_tokens"
        case totalOutputTokens = "total_output_tokens"
        case contextWindowSize = "context_window_size"
        case usedPercentage = "used_percentage"
        case remainingPercentage = "remaining_percentage"
        case currentUsage = "current_usage"
    }

    public init(
        totalInputTokens: Int? = nil,
        totalOutputTokens: Int? = nil,
        contextWindowSize: Int? = nil,
        usedPercentage: Double? = nil,
        remainingPercentage: Double? = nil,
        currentUsage: StatusLineCurrentUsage? = nil
    ) {
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.contextWindowSize = contextWindowSize
        self.usedPercentage = usedPercentage
        self.remainingPercentage = remainingPercentage
        self.currentUsage = currentUsage
    }
}

public struct StatusLineQuotaBucket: Sendable, Equatable, Codable {
    public let remainingFraction: Double?
    public let remainingAmount: Double?
    public let resetTime: String?
    public let resetInSeconds: Int?
    public let disabled: Bool?

    enum CodingKeys: String, CodingKey {
        case remainingFraction = "remaining_fraction"
        case remainingAmount = "remaining_amount"
        case resetTime = "reset_time"
        case resetInSeconds = "reset_in_seconds"
        case disabled
    }

    public init(
        remainingFraction: Double? = nil,
        remainingAmount: Double? = nil,
        resetTime: String? = nil,
        resetInSeconds: Int? = nil,
        disabled: Bool? = nil
    ) {
        self.remainingFraction = remainingFraction
        self.remainingAmount = remainingAmount
        self.resetTime = resetTime
        self.resetInSeconds = resetInSeconds
        self.disabled = disabled
    }
}

public struct StatusLineCostInfo: Sendable, Equatable, Codable {
    public let totalUSD: Double?
    public let subagentUSD: Double?
    public let estimated: Bool?

    enum CodingKeys: String, CodingKey {
        case totalUSD = "total_usd"
        case subagentUSD = "subagent_usd"
        case estimated
    }

    public init(totalUSD: Double? = nil, subagentUSD: Double? = nil, estimated: Bool? = nil) {
        self.totalUSD = totalUSD
        self.subagentUSD = subagentUSD
        self.estimated = estimated
    }
}

public struct StatusLineSnapshot: Sendable, Equatable, Codable {
    public let conversationId: String?
    public let conversationTitle: String?
    public let model: StatusLineModelInfo?
    public let version: String?
    public let contextWindow: StatusLineContextWindow?
    public let quota: [String: StatusLineQuotaBucket]?
    public let agentState: String?
    public let planTier: String?
    public let email: String?
    public let cost: StatusLineCostInfo?
    /// Timestamp written by our bridge wrapper (or file mtime fallback).
    public let capturedAt: Date?

    enum CodingKeys: String, CodingKey {
        case conversationId = "conversation_id"
        case conversationTitle = "conversation_title"
        case model
        case version
        case contextWindow = "context_window"
        case quota
        case agentState = "agent_state"
        case planTier = "plan_tier"
        case email
        case cost
        case capturedAt = "_captured_at"
    }

    public init(
        conversationId: String? = nil,
        conversationTitle: String? = nil,
        model: StatusLineModelInfo? = nil,
        version: String? = nil,
        contextWindow: StatusLineContextWindow? = nil,
        quota: [String: StatusLineQuotaBucket]? = nil,
        agentState: String? = nil,
        planTier: String? = nil,
        email: String? = nil,
        cost: StatusLineCostInfo? = nil,
        capturedAt: Date? = nil
    ) {
        self.conversationId = conversationId
        self.conversationTitle = conversationTitle
        self.model = model
        self.version = version
        self.contextWindow = contextWindow
        self.quota = quota
        self.agentState = agentState
        self.planTier = planTier
        self.email = email
        self.cost = cost
        self.capturedAt = capturedAt
    }
}

// MARK: - Evaluated Official Quota

public enum QuotaWindowKind: String, Sendable, Equatable {
    case fiveHour
    case weekly
    case other

    public var durationSeconds: TimeInterval? {
        switch self {
        case .fiveHour: return 5 * 3600
        case .weekly: return 7 * 24 * 3600
        case .other: return nil
        }
    }
}

public struct QuotaBucketEvaluation: Sendable, Equatable, Identifiable {
    public var id: String { bucketId }
    public let bucketId: String
    public let displayName: String
    public let windowKind: QuotaWindowKind
    /// Used fraction in [0, 1]. Automatically drops to 0 when reset time has elapsed.
    public let usedFraction: Double
    /// Remaining fraction in [0, 1].
    public let remainingFraction: Double
    /// Safe pace line in [0, 1], if window duration and reset time are known.
    public let safeLineFraction: Double?
    /// True during the initial settling phase of a 5-hour window (first 10% / 30 min),
    /// where low safe lines should not trigger over-pace warnings.
    public let isPaceSettling: Bool
    public let resetTime: Date?
    public let remainingSecondsUntilReset: TimeInterval?
    public let isResetElapsed: Bool
    public let isDisabled: Bool

    public init(
        bucketId: String,
        displayName: String,
        windowKind: QuotaWindowKind,
        usedFraction: Double,
        remainingFraction: Double,
        safeLineFraction: Double?,
        isPaceSettling: Bool = false,
        resetTime: Date?,
        remainingSecondsUntilReset: TimeInterval?,
        isResetElapsed: Bool,
        isDisabled: Bool
    ) {
        self.bucketId = bucketId
        self.displayName = displayName
        self.windowKind = windowKind
        self.usedFraction = usedFraction
        self.remainingFraction = remainingFraction
        self.safeLineFraction = safeLineFraction
        self.isPaceSettling = isPaceSettling
        self.resetTime = resetTime
        self.remainingSecondsUntilReset = remainingSecondsUntilReset
        self.isResetElapsed = isResetElapsed
        self.isDisabled = isDisabled
    }

    /// Rounded down integer percentage (matching Claude Usage Monitor / official rounding).
    public var usedPercentageInt: Int {
        Int(floor(max(0, min(1, usedFraction)) * 100.0 + 1e-9))
    }

    public var remainingPercentageInt: Int {
        max(0, 100 - usedPercentageInt)
    }

    public var safeLinePercentageInt: Int? {
        guard let safe = safeLineFraction else { return nil }
        return Int(floor(max(0, min(1, safe)) * 100.0 + 1e-9))
    }

    public var isOverPace: Bool {
        guard !isPaceSettling, let safePct = safeLinePercentageInt, !isResetElapsed else { return false }
        return usedPercentageInt > safePct
    }
}

public struct OfficialQuotaReport: Sendable, Equatable {
    public let buckets: [QuotaBucketEvaluation]
    public let primaryFiveHour: QuotaBucketEvaluation?
    public let primaryWeekly: QuotaBucketEvaluation?
    public let snapshotCapturedAt: Date?
    public let isStale: Bool
    public let staleAgeSeconds: TimeInterval?
    public let activeModelName: String?
    public let contextWindow: StatusLineContextWindow?
    public let conversationTitle: String?
    public let agentState: String?
    public let planTier: String?
    public let email: String?
    public let sessionCostUSD: Double?

    public init(
        buckets: [QuotaBucketEvaluation] = [],
        primaryFiveHour: QuotaBucketEvaluation? = nil,
        primaryWeekly: QuotaBucketEvaluation? = nil,
        snapshotCapturedAt: Date? = nil,
        isStale: Bool = true,
        staleAgeSeconds: TimeInterval? = nil,
        activeModelName: String? = nil,
        contextWindow: StatusLineContextWindow? = nil,
        conversationTitle: String? = nil,
        agentState: String? = nil,
        planTier: String? = nil,
        email: String? = nil,
        sessionCostUSD: Double? = nil
    ) {
        self.buckets = buckets
        self.primaryFiveHour = primaryFiveHour
        self.primaryWeekly = primaryWeekly
        self.snapshotCapturedAt = snapshotCapturedAt
        self.isStale = isStale
        self.staleAgeSeconds = staleAgeSeconds
        self.activeModelName = activeModelName
        self.contextWindow = contextWindow
        self.conversationTitle = conversationTitle
        self.agentState = agentState
        self.planTier = planTier
        self.email = email
        self.sessionCostUSD = sessionCostUSD
    }

    public var hasSnapshot: Bool {
        snapshotCapturedAt != nil
    }
}
