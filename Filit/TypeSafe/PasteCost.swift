import Foundation

struct TokenUsage: Equatable {
    var inputTokens: Int
    var outputTokens: Int

    var totalTokens: Int { inputTokens + outputTokens }

    /// Published Jev pricing: $0.042 / MTok input, output free.
    static let inputUSDPerMillion: Double = 0.042
    static let outputUSDPerMillion: Double = 0.0

    var estimatedUSD: Double {
        Double(inputTokens) / 1_000_000.0 * Self.inputUSDPerMillion
            + Double(outputTokens) / 1_000_000.0 * Self.outputUSDPerMillion
    }

    var costDescription: String {
        if estimatedUSD < 0.000001 {
            return String(format: "%d tokens · <$0.000001", totalTokens)
        }
        if estimatedUSD < 0.01 {
            return String(format: "%d tokens · ~$%.6f", totalTokens, estimatedUSD)
        }
        return String(format: "%d tokens · ~$%.4f", totalTokens, estimatedUSD)
    }

    var shortCostDescription: String {
        if estimatedUSD < 0.000001 {
            return "<$0.000001"
        }
        if estimatedUSD < 0.01 {
            return String(format: "~$%.6f", estimatedUSD)
        }
        return String(format: "~$%.4f", estimatedUSD)
    }

    /// Rough “how many of these pastes per dollar” for human context.
    var pastesPerDollar: Int? {
        guard estimatedUSD > 0 else { return nil }
        let n = (1.0 / estimatedUSD).rounded()
        guard n.isFinite, n > 0 else { return nil }
        return Int(n)
    }

    var friendlyCostLine: String {
        if let n = pastesPerDollar {
            if n >= 1_000_000 {
                return String(format: "~%.1fM pastes per $1", Double(n) / 1_000_000)
            }
            if n >= 1_000 {
                return String(format: "~%@ pastes per $1", Self.compact(n))
            }
            return "~\(n) pastes per $1"
        }
        return "Essentially free per paste"
    }

    /// Compact value for right-aligned stats rows.
    var friendlyCostValue: String {
        if let n = pastesPerDollar {
            if n >= 1_000_000 {
                return String(format: "~%.1fM / $1", Double(n) / 1_000_000)
            }
            if n >= 1_000 {
                return String(format: "~%@ / $1", Self.compact(n))
            }
            return "~\(n) / $1"
        }
        return "Free"
    }

    var friendlyTokenLine: String {
        "~\(totalTokens) tokens this time"
    }

    private static func compact(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

enum PasteCostEstimator {
    /// Rough pre-flight estimate from payload size (chars ≈ tokens / 4 is a common heuristic).
    static func estimate(
        field: FieldContext,
        sourceExcerpt: String?,
        candidates: [Candidate]
    ) -> TokenUsage {
        var chars = 180 // instructions / schema overhead
        chars += field.summary.count
        chars += sourceExcerpt?.count ?? 0
        for c in candidates {
            chars += c.value.count + c.id.count + 24
        }
        let input = max(80, chars / 4)
        let output = 40 + candidates.count * 2
        return TokenUsage(inputTokens: input, outputTokens: output)
    }
}

struct PickResult {
    let choice: String
    let usage: TokenUsage
}
