import Foundation
import os

public struct ModelPrice: Sendable, Equatable {
    /// USD per 1,000,000 uncached input tokens.
    public let inputPerMillion: Double
    /// USD per 1,000,000 cached read tokens.
    public let cacheReadPerMillion: Double
    /// USD per 1,000,000 output tokens (thinking tokens billed at output rate).
    public let outputPerMillion: Double
    /// Optional prompt-length threshold (uncached + cacheRead) where long-context pricing kicks in.
    public let longContextThreshold: Int?
    /// Long-context USD/1M rates applied when a single request exceeds `longContextThreshold`.
    public let longInputPerMillion: Double?
    public let longCacheReadPerMillion: Double?
    public let longOutputPerMillion: Double?

    public init(
        inputPerMillion: Double,
        cacheReadPerMillion: Double,
        outputPerMillion: Double,
        longContextThreshold: Int? = nil,
        longInputPerMillion: Double? = nil,
        longCacheReadPerMillion: Double? = nil,
        longOutputPerMillion: Double? = nil
    ) {
        self.inputPerMillion = inputPerMillion
        self.cacheReadPerMillion = cacheReadPerMillion
        self.outputPerMillion = outputPerMillion
        self.longContextThreshold = longContextThreshold
        self.longInputPerMillion = longInputPerMillion
        self.longCacheReadPerMillion = longCacheReadPerMillion
        self.longOutputPerMillion = longOutputPerMillion
    }

    public func effectiveRates(requestTotalInput: Int) -> (input: Double, cacheRead: Double, output: Double) {
        if let threshold = longContextThreshold,
           requestTotalInput > threshold,
           let li = longInputPerMillion,
           let lc = longCacheReadPerMillion,
           let lo = longOutputPerMillion {
            return (li, lc, lo)
        }
        return (inputPerMillion, cacheReadPerMillion, outputPerMillion)
    }

    public func costUSD(uncachedInput: Int, cacheRead: Int, output: Int) -> Double {
        let rates = effectiveRates(requestTotalInput: uncachedInput + cacheRead)
        let inputCost = Double(uncachedInput) * rates.input / 1_000_000.0
        let cacheCost = Double(cacheRead) * rates.cacheRead / 1_000_000.0
        let outputCost = Double(output) * rates.output / 1_000_000.0
        return inputCost + cacheCost + outputCost
    }

    public func cacheSavingsUSD(cacheRead: Int, uncachedInput: Int = 0) -> Double {
        guard cacheRead > 0 else { return 0 }
        let rates = effectiveRates(requestTotalInput: uncachedInput + cacheRead)
        let savedPerMillion = max(0, rates.input - rates.cacheRead)
        return Double(cacheRead) * savedPerMillion / 1_000_000.0
    }
}

public struct PricingCatalog: Sendable {
    public static let `default` = PricingCatalog()

    // Bounded thread-safe cache so 2.5s hot-path aggregations avoid repeated string tokenization.
    private static let keyCache = OSAllocatedUnfairLock(initialState: [String: String]())

    // UTC date boundaries for scheduled official API list-price transitions.
    private static let dec2026Cutoff: TimeInterval = {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 12; comps.day = 1
        comps.hour = 0; comps.minute = 0; comps.second = 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal.date(from: comps)!.timeIntervalSince1970
    }()

    private static let jan2027Cutoff: TimeInterval = {
        var comps = DateComponents()
        comps.year = 2027; comps.month = 1; comps.day = 1
        comps.hour = 0; comps.minute = 0; comps.second = 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal.date(from: comps)!.timeIntervalSince1970
    }()

    private static let gemini4Codenames: [String: String] = [
        "neon": "gemini 4 neon",
        "hydrogen": "gemini 4 hydrogen",
        "carbon": "gemini 4 carbon",
        "argon": "gemini 4 argon",
        "argon trial": "gemini 4 argon trial",
    ]

    public init() {}

    /// Normalizes model identifiers (handling `models/` prefixes, `Orchestrator (...)`, `-n`,
    /// 8-digit release dates like `20250514`, effort tiers, and hyphen/version variants)
    /// into a canonical lowercase space-separated key used for pricing lookups.
    public static func normalizePricingKey(_ rawModel: String) -> String {
        if let cached = keyCache.withLock({ $0[rawModel] }) {
            return cached
        }
        let computed = computeNormalizedKey(rawModel)
        keyCache.withLock { cache in
            if cache.count >= 2048 {
                cache.removeAll(keepingCapacity: true)
            }
            cache[rawModel] = computed
        }
        return computed
    }

    private static func computeNormalizedKey(_ rawModel: String) -> String {
        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return "" }

        // Tokenize on '/', '-', '_', '(', ')', and whitespace so `models/gemini-2.5-pro`
        // and `Orchestrator (Neon-n)` decompose cleanly regardless of delimiter nesting.
        var tokens = trimmed
            .split(whereSeparator: { ch in
                ch == "/" || ch == "-" || ch == "_" || ch == "(" || ch == ")" || ch.isWhitespace
            })
            .map(String.init)

        // Drop leading provider/path prefixes (`models`, `publishers`, `google`, `anthropic`, `openai`, `orchestrator`).
        let leadingNoise: Set<String> = ["models", "publishers", "google", "anthropic", "openai", "orchestrator"]
        while let first = tokens.first, tokens.count > 1, leadingNoise.contains(first) {
            tokens.removeFirst()
        }

        // Drop trailing 8-digit release dates (e.g. `20250514`), standalone `n` suffix (`-n`),
        // and effort/tier descriptors (`minimal`, `low`, `medium`, `high`, `xhigh`, `tiered`, etc.).
        let trailingNoise: Set<String> = [
            "n", "minimal", "low", "medium", "med", "high", "xhigh",
            "extra", "max", "thinking", "tiered", "orchestrator", "latest", "preview",
        ]
        while let last = tokens.last, tokens.count > 1 {
            let isEightDigitDate = last.count == 8 && last.allSatisfy(\.isNumber)
            if isEightDigitDate || trailingNoise.contains(last) {
                tokens.removeLast()
            } else {
                break
            }
        }

        // Merge version number pairs such as `4` + `6` -> `4.6`, `4` + `0` -> `4.0`.
        var merged: [String] = []
        var i = 0
        while i < tokens.count {
            let tok = tokens[i]
            if i + 1 < tokens.count,
               tok.allSatisfy(\.isNumber),
               tokens[i + 1].allSatisfy(\.isNumber),
               tokens[i + 1].count == 1 {
                merged.append("\(tok).\(tokens[i + 1])")
                i += 2
            } else {
                merged.append(tok)
                i += 1
            }
        }

        let joined = merged.joined(separator: " ")
        if let expanded = gemini4Codenames[joined] {
            return expanded
        }
        return joined
    }

    /// Returns true when the model belongs to the Gemini quota bucket (excluding Claude / GPT / o-series 3P models).
    public static func isGeminiQuotaFamily(_ rawModel: String) -> Bool {
        let key = normalizePricingKey(rawModel)
        guard !key.isEmpty else { return false }
        if key.contains("claude") || key.contains("gpt") || key.hasPrefix("o1") || key.hasPrefix("o3") || key.hasPrefix("o4") {
            return false
        }
        return key.contains("gemini") || key.contains("neon") || key.contains("hydrogen") || key.contains("carbon") || key.contains("argon")
    }

    /// Returns published API list pricing (USD / 1M tokens) at the given timestamp, or `nil` for unknown models (Decision D5).
    public func price(for model: String, at date: Date = Date()) -> ModelPrice? {
        let key = Self.normalizePricingKey(model)
        guard !key.isEmpty else { return nil }
        let tokens = Set(key.split(separator: " ").map(String.init))

        let ts = date.timeIntervalSince1970
        let afterDec2026 = ts >= Self.dec2026Cutoff
        let afterJan2027 = ts >= Self.jan2027Cutoff

        // --- Gemini 4 family ---
        if key.hasPrefix("gemini 4 neon") || key.contains("gemini 4 neon") {
            return ModelPrice(inputPerMillion: 3.00, cacheReadPerMillion: 0.15, outputPerMillion: 15.00)
        }
        if key.hasPrefix("gemini 4 hydrogen") || key.contains("gemini 4 hydrogen") {
            return ModelPrice(inputPerMillion: 1.50, cacheReadPerMillion: 0.075, outputPerMillion: 7.50)
        }
        if key.hasPrefix("gemini 4 carbon") || key.hasPrefix("gemini 4 argon") {
            return afterDec2026
                ? ModelPrice(inputPerMillion: 4.00, cacheReadPerMillion: 0.20, outputPerMillion: 20.00)
                : ModelPrice(inputPerMillion: 2.00, cacheReadPerMillion: 0.10, outputPerMillion: 10.00)
        }

        // --- Gemini 3.x / 2.x family ---
        if key.hasPrefix("gemini 3.6 flash") || key.hasPrefix("gemini 3.7 flash") || key.hasPrefix("gemini 3.8 flash") {
            return afterJan2027
                ? ModelPrice(inputPerMillion: 1.50, cacheReadPerMillion: 0.15, outputPerMillion: 7.50)
                : ModelPrice(inputPerMillion: 0.75, cacheReadPerMillion: 0.075, outputPerMillion: 3.75)
        }
        if key.hasPrefix("gemini 3.5 flash lite") {
            return ModelPrice(inputPerMillion: 0.30, cacheReadPerMillion: 0.03, outputPerMillion: 2.50)
        }
        if key.hasPrefix("gemini 3.1 flash lite") {
            return ModelPrice(inputPerMillion: 0.25, cacheReadPerMillion: 0.025, outputPerMillion: 1.50)
        }
        if key.hasPrefix("gemini 2.5 flash lite") {
            return ModelPrice(inputPerMillion: 0.10, cacheReadPerMillion: 0.01, outputPerMillion: 0.40)
        }
        if key.hasPrefix("gemini 2.5 flash") {
            return ModelPrice(inputPerMillion: 0.30, cacheReadPerMillion: 0.03, outputPerMillion: 2.50)
        }
        if key.hasPrefix("gemini 2.0 flash") {
            return ModelPrice(inputPerMillion: 0.10, cacheReadPerMillion: 0.025, outputPerMillion: 0.40)
        }
        if key.hasPrefix("gemini 3") && tokens.contains("flash") {
            return ModelPrice(inputPerMillion: 0.50, cacheReadPerMillion: 0.05, outputPerMillion: 3.00)
        }
        if key.hasPrefix("gemini 2.5 pro") {
            return ModelPrice(
                inputPerMillion: 1.25, cacheReadPerMillion: 0.125, outputPerMillion: 10.00,
                longContextThreshold: 200_000,
                longInputPerMillion: 2.50, longCacheReadPerMillion: 0.25, longOutputPerMillion: 15.00
            )
        }
        if key.hasPrefix("gemini 3") && tokens.contains("pro") {
            return ModelPrice(
                inputPerMillion: 2.00, cacheReadPerMillion: 0.20, outputPerMillion: 12.00,
                longContextThreshold: 200_000,
                longInputPerMillion: 4.00, longCacheReadPerMillion: 0.40, longOutputPerMillion: 18.00
            )
        }
        if tokens.contains("gemini") && key.contains("flash lite") {
            return ModelPrice(inputPerMillion: 0.25, cacheReadPerMillion: 0.025, outputPerMillion: 1.50)
        }
        if tokens.contains("gemini") && tokens.contains("flash") {
            return ModelPrice(inputPerMillion: 0.50, cacheReadPerMillion: 0.05, outputPerMillion: 3.00)
        }
        if tokens.contains("gemini") && tokens.contains("pro") {
            return ModelPrice(
                inputPerMillion: 2.00, cacheReadPerMillion: 0.20, outputPerMillion: 12.00,
                longContextThreshold: 200_000,
                longInputPerMillion: 4.00, longCacheReadPerMillion: 0.40, longOutputPerMillion: 18.00
            )
        }

        // --- Claude family (5.5 / 4.6 / 4.5 / 4.1 / 4 / 3.x) ---
        if tokens.contains("claude") && tokens.contains("5.5") && tokens.contains("opus") {
            return ModelPrice(inputPerMillion: 4.00, cacheReadPerMillion: 0.20, outputPerMillion: 20.00)
        }
        if tokens.contains("claude") && tokens.contains("5.5") && tokens.contains("sonnet") {
            return ModelPrice(inputPerMillion: 2.00, cacheReadPerMillion: 0.10, outputPerMillion: 10.00)
        }
        if tokens.contains("claude") && tokens.contains("5.5") && tokens.contains("haiku") {
            return ModelPrice(
                inputPerMillion: 0.10, cacheReadPerMillion: 0.01, outputPerMillion: 0.50,
                longContextThreshold: 100_000,
                longInputPerMillion: 0.50, longCacheReadPerMillion: 0.05, longOutputPerMillion: 2.50
            )
        }
        if tokens.contains("claude") && tokens.contains("opus") {
            // Exact version-token check: legacy Opus 3 / 3.0 / 4 / 4.0 / 4.1 are $15/$75; Opus 4.5 / 4.6+ are $5/$25.
            let legacyVersions: Set<String> = ["3", "3.0", "4", "4.0", "4.1"]
            if !tokens.isDisjoint(with: legacyVersions) {
                return ModelPrice(inputPerMillion: 15.00, cacheReadPerMillion: 1.50, outputPerMillion: 75.00)
            }
            return ModelPrice(inputPerMillion: 5.00, cacheReadPerMillion: 0.50, outputPerMillion: 25.00)
        }
        if tokens.contains("claude") && tokens.contains("sonnet") {
            return ModelPrice(inputPerMillion: 3.00, cacheReadPerMillion: 0.30, outputPerMillion: 15.00)
        }
        if tokens.contains("claude") && tokens.contains("haiku") {
            if tokens.contains("3.5") || tokens.contains("3") || tokens.contains("3.0") {
                return ModelPrice(inputPerMillion: 0.80, cacheReadPerMillion: 0.08, outputPerMillion: 4.00)
            }
            return ModelPrice(inputPerMillion: 1.00, cacheReadPerMillion: 0.10, outputPerMillion: 5.00)
        }

        // --- OpenAI / GPT / o-series family (most specific child variants BEFORE parent prefixes) ---
        if key.hasPrefix("gpt 5.4 nano") {
            return ModelPrice(inputPerMillion: 0.20, cacheReadPerMillion: 0.02, outputPerMillion: 1.25)
        }
        if key.hasPrefix("gpt 5.4 mini") {
            return ModelPrice(inputPerMillion: 0.75, cacheReadPerMillion: 0.075, outputPerMillion: 4.50)
        }
        if key.hasPrefix("gpt 5.4") {
            return ModelPrice(
                inputPerMillion: 2.50, cacheReadPerMillion: 0.25, outputPerMillion: 15.00,
                longContextThreshold: 272_000,
                longInputPerMillion: 5.00, longCacheReadPerMillion: 0.50, longOutputPerMillion: 22.50
            )
        }
        if key.hasPrefix("gpt 5 nano") {
            return ModelPrice(inputPerMillion: 0.05, cacheReadPerMillion: 0.005, outputPerMillion: 0.40)
        }
        if key.hasPrefix("gpt 5 mini") {
            return ModelPrice(inputPerMillion: 0.25, cacheReadPerMillion: 0.025, outputPerMillion: 2.00)
        }
        if key == "gpt 5" || key.hasPrefix("gpt 5 ") {
            return ModelPrice(inputPerMillion: 1.25, cacheReadPerMillion: 0.125, outputPerMillion: 10.00)
        }
        if key.hasPrefix("gpt oss 120b") {
            return ModelPrice(inputPerMillion: 0.15, cacheReadPerMillion: 0.075, outputPerMillion: 0.60)
        }
        if key.hasPrefix("gpt 4.1 nano") {
            return ModelPrice(inputPerMillion: 0.10, cacheReadPerMillion: 0.025, outputPerMillion: 0.40)
        }
        if key.hasPrefix("gpt 4.1 mini") {
            return ModelPrice(inputPerMillion: 0.40, cacheReadPerMillion: 0.10, outputPerMillion: 1.60)
        }
        if key == "gpt 4.1" || key.hasPrefix("gpt 4.1 ") {
            return ModelPrice(inputPerMillion: 2.00, cacheReadPerMillion: 0.50, outputPerMillion: 8.00)
        }
        if key.hasPrefix("gpt 4o mini") {
            return ModelPrice(inputPerMillion: 0.15, cacheReadPerMillion: 0.075, outputPerMillion: 0.60)
        }
        if key == "gpt 4o" || key.hasPrefix("gpt 4o ") {
            return ModelPrice(inputPerMillion: 2.50, cacheReadPerMillion: 1.25, outputPerMillion: 10.00)
        }
        if key.hasPrefix("o3 pro") {
            return ModelPrice(inputPerMillion: 20.00, cacheReadPerMillion: 5.00, outputPerMillion: 80.00)
        }
        if key.hasPrefix("o3 mini") {
            return ModelPrice(inputPerMillion: 1.10, cacheReadPerMillion: 0.55, outputPerMillion: 4.40)
        }
        if key == "o3" || key.hasPrefix("o3 ") {
            return ModelPrice(inputPerMillion: 2.00, cacheReadPerMillion: 0.50, outputPerMillion: 8.00)
        }
        if key.hasPrefix("o4 mini") {
            return ModelPrice(inputPerMillion: 1.10, cacheReadPerMillion: 0.275, outputPerMillion: 4.40)
        }

        return nil
    }

    public static func displayName(for rawModel: String) -> String {
        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Unknown" }
        if trimmed.contains(" ") {
            return trimmed
        }
        let parts = trimmed.split(separator: "-")
        var rendered: [String] = []
        var i = 0
        while i < parts.count {
            let part = String(parts[i])
            let lower = part.lowercased()
            if i + 1 < parts.count,
               part.allSatisfy(\.isNumber),
               parts[i + 1].allSatisfy(\.isNumber),
               parts[i + 1].count == 1 {
                rendered.append("\(part).\(parts[i + 1])")
                i += 2
            } else if lower == "gpt" {
                rendered.append("GPT")
                i += 1
            } else if lower == "xhigh" {
                rendered.append("XHigh")
                i += 1
            } else if lower.hasPrefix("o"), lower.dropFirst().allSatisfy(\.isNumber), lower.count >= 2 {
                rendered.append(lower)
                i += 1
            } else {
                rendered.append(part.prefix(1).uppercased() + part.dropFirst())
                i += 1
            }
        }
        return rendered.joined(separator: " ")
    }
}
