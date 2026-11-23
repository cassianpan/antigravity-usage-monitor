import Foundation

public struct ModelPrice: Sendable, Equatable {
    /// USD per 1,000,000 uncached input tokens.
    public let inputPerMillion: Double
    /// USD per 1,000,000 cached read tokens.
    public let cacheReadPerMillion: Double
    /// USD per 1,000,000 output tokens.
    public let outputPerMillion: Double

    public init(inputPerMillion: Double, cacheReadPerMillion: Double, outputPerMillion: Double) {
        self.inputPerMillion = inputPerMillion
        self.cacheReadPerMillion = cacheReadPerMillion
        self.outputPerMillion = outputPerMillion
    }

    public func costUSD(uncachedInput: Int, cacheRead: Int, output: Int) -> Double {
        let inputCost = Double(uncachedInput) * inputPerMillion / 1_000_000.0
        let cacheCost = Double(cacheRead) * cacheReadPerMillion / 1_000_000.0
        let outputCost = Double(output) * outputPerMillion / 1_000_000.0
        return inputCost + cacheCost + outputCost
    }

    public func cacheSavingsUSD(cacheRead: Int) -> Double {
        guard cacheRead > 0 else { return 0 }
        let savedPerMillion = max(0, inputPerMillion - cacheReadPerMillion)
        return Double(cacheRead) * savedPerMillion / 1_000_000.0
    }
}

public struct PricingCatalog: Sendable {
    private struct Rule: Sendable {
        let keywords: [String]
        let price: ModelPrice
    }

    private let rules: [Rule]

    public init() {
        // Published list prices (USD / 1M tokens).
        // Unknown models intentionally return nil (Decision D5: never fabricate prices).
        self.rules = [
            // Gemini 4 family (2026 published paid-tier pricing)
            Rule(keywords: ["gemini", "neon"], price: ModelPrice(inputPerMillion: 3.00, cacheReadPerMillion: 0.15, outputPerMillion: 15.00)),
            Rule(keywords: ["gemini", "hydrogen"], price: ModelPrice(inputPerMillion: 1.50, cacheReadPerMillion: 0.075, outputPerMillion: 7.50)),
            Rule(keywords: ["gemini", "argon"], price: ModelPrice(inputPerMillion: 2.00, cacheReadPerMillion: 0.10, outputPerMillion: 10.00)),
            Rule(keywords: ["gemini", "carbon"], price: ModelPrice(inputPerMillion: 2.00, cacheReadPerMillion: 0.10, outputPerMillion: 10.00)),
            // Gemini 3.x family
            Rule(keywords: ["gemini-3", "flash-lite"], price: ModelPrice(inputPerMillion: 0.25, cacheReadPerMillion: 0.025, outputPerMillion: 1.50)),
            Rule(keywords: ["gemini-3", "flash"], price: ModelPrice(inputPerMillion: 0.75, cacheReadPerMillion: 0.075, outputPerMillion: 3.75)),
            Rule(keywords: ["gemini-3", "pro"], price: ModelPrice(inputPerMillion: 2.00, cacheReadPerMillion: 0.20, outputPerMillion: 12.00)),
            // Gemini 2.5 / generic Flash & Pro families
            Rule(keywords: ["gemini", "flash-lite"], price: ModelPrice(inputPerMillion: 0.10, cacheReadPerMillion: 0.025, outputPerMillion: 0.40)),
            Rule(keywords: ["gemini", "flash"], price: ModelPrice(inputPerMillion: 0.30, cacheReadPerMillion: 0.075, outputPerMillion: 2.50)),
            Rule(keywords: ["gemini", "pro"], price: ModelPrice(inputPerMillion: 1.25, cacheReadPerMillion: 0.3125, outputPerMillion: 10.00)),
            // Claude 4 / 3.7 / 3.5 families
            Rule(keywords: ["claude", "opus"], price: ModelPrice(inputPerMillion: 15.00, cacheReadPerMillion: 1.50, outputPerMillion: 75.00)),
            Rule(keywords: ["claude", "sonnet"], price: ModelPrice(inputPerMillion: 3.00, cacheReadPerMillion: 0.30, outputPerMillion: 15.00)),
            Rule(keywords: ["claude", "haiku"], price: ModelPrice(inputPerMillion: 0.80, cacheReadPerMillion: 0.08, outputPerMillion: 4.00)),
            // GPT families
            Rule(keywords: ["gpt-5"], price: ModelPrice(inputPerMillion: 1.25, cacheReadPerMillion: 0.125, outputPerMillion: 10.00)),
            Rule(keywords: ["gpt-4.1"], price: ModelPrice(inputPerMillion: 2.00, cacheReadPerMillion: 0.50, outputPerMillion: 8.00)),
            Rule(keywords: ["gpt-4o-mini"], price: ModelPrice(inputPerMillion: 0.15, cacheReadPerMillion: 0.075, outputPerMillion: 0.60)),
            Rule(keywords: ["gpt-4o"], price: ModelPrice(inputPerMillion: 2.50, cacheReadPerMillion: 1.25, outputPerMillion: 10.00)),
        ]
    }

    public static let `default` = PricingCatalog()

    public func price(for model: String) -> ModelPrice? {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        for rule in rules {
            if rule.keywords.allSatisfy({ normalized.contains($0) }) {
                return rule.price
            }
        }
        return nil
    }

    public static func displayName(for rawModel: String) -> String {
        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Unknown" }
        if trimmed.contains(" ") {
            return trimmed
        }
        return trimmed
            .split(separator: "-")
            .map { part -> String in
                let lower = part.lowercased()
                if lower == "gpt" { return "GPT" }
                return part.prefix(1).uppercased() + part.dropFirst()
            }
            .joined(separator: " ")
    }
}
