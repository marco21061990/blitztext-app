import Foundation

// MARK: - Usage Record

/// One successful, billed OpenAI call. Stores only raw usage metadata so cost can
/// be recomputed later from the recorded model and units. Never stores audio,
/// transcript text, prompt text, completions, or API keys.
enum OpenAIUsageKind: String, Codable, Sendable {
    case transcription
    case rewrite
}

struct OpenAIUsageRecord: Codable, Sendable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let kind: OpenAIUsageKind
    /// Exact model string as sent to OpenAI, e.g. "whisper-1", "gpt-4o-mini", "gpt-4o".
    let model: String
    /// Billed audio duration in seconds for transcription calls.
    let audioSeconds: Double?
    /// Prompt/input tokens for rewrite calls.
    let inputTokens: Int?
    /// Completion/output tokens for rewrite calls.
    let outputTokens: Int?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        kind: OpenAIUsageKind,
        model: String,
        audioSeconds: Double? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.model = model
        self.audioSeconds = audioSeconds
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

// MARK: - Pricing

/// Centralized OpenAI pricing snapshot for local cost estimates.
///
/// Pricing snapshot captured 2026-09-16. These are estimates only; the OpenAI
/// account billing is authoritative. Update the constants and `snapshotDate`
/// together when OpenAI changes prices.
///
/// Official sources:
///   whisper-1:   https://developers.openai.com/api/docs/models/whisper-1
///   gpt-4o-mini: https://developers.openai.com/api/docs/models/gpt-4o-mini
///   gpt-4o:      https://developers.openai.com/api/docs/models/gpt-4o
///   Usage dashboard: https://platform.openai.com/usage
enum OpenAIPricing {
    static let snapshotDate = "2026-09-16"
    static let usageDashboardURL = URL(string: "https://platform.openai.com/usage")!

    // whisper-1: USD 0.006 per audio minute.
    private static let whisperUSDPerMinute = 0.006
    // gpt-4o-mini: USD 0.15 per 1M input tokens, USD 0.60 per 1M output tokens.
    private static let gpt4oMiniInputUSDPerMillion = 0.15
    private static let gpt4oMiniOutputUSDPerMillion = 0.60
    // gpt-4o: USD 2.50 per 1M input tokens, USD 10.00 per 1M output tokens.
    private static let gpt4oInputUSDPerMillion = 2.50
    private static let gpt4oOutputUSDPerMillion = 10.00

    /// Estimated USD cost for a single record, or nil when the model or units are unknown.
    static func estimatedCostUSD(for record: OpenAIUsageRecord) -> Double? {
        switch record.model {
        case "whisper-1":
            guard let seconds = record.audioSeconds else { return nil }
            return seconds / 60.0 * whisperUSDPerMinute
        case "gpt-4o-mini":
            return tokenCostUSD(
                input: record.inputTokens,
                output: record.outputTokens,
                inputPerMillion: gpt4oMiniInputUSDPerMillion,
                outputPerMillion: gpt4oMiniOutputUSDPerMillion
            )
        case "gpt-4o":
            return tokenCostUSD(
                input: record.inputTokens,
                output: record.outputTokens,
                inputPerMillion: gpt4oInputUSDPerMillion,
                outputPerMillion: gpt4oOutputUSDPerMillion
            )
        default:
            return nil
        }
    }

    private static func tokenCostUSD(
        input: Int?,
        output: Int?,
        inputPerMillion: Double,
        outputPerMillion: Double
    ) -> Double? {
        guard input != nil || output != nil else { return nil }
        let inputCost = Double(input ?? 0) / 1_000_000 * inputPerMillion
        let outputCost = Double(output ?? 0) / 1_000_000 * outputPerMillion
        return inputCost + outputCost
    }
}

// MARK: - Aggregation

struct OpenAIUsageTotals: Equatable {
    var callCount: Int = 0
    var audioSeconds: Double = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var estimatedCostUSD: Double = 0
    /// True when at least one included record produced a cost estimate.
    var hasCostEstimate: Bool = false

    var isEmpty: Bool { callCount == 0 }
}

enum OpenAIUsageAggregation {
    static func totals(
        from records: [OpenAIUsageRecord],
        matching predicate: (OpenAIUsageRecord) -> Bool
    ) -> OpenAIUsageTotals {
        var totals = OpenAIUsageTotals()
        for record in records where predicate(record) {
            totals.callCount += 1
            totals.audioSeconds += record.audioSeconds ?? 0
            totals.inputTokens += record.inputTokens ?? 0
            totals.outputTokens += record.outputTokens ?? 0
            if let cost = OpenAIPricing.estimatedCostUSD(for: record) {
                totals.estimatedCostUSD += cost
                totals.hasCostEstimate = true
            }
        }
        return totals
    }

    /// Totals for records in the same local calendar day as `date`.
    static func totals(
        from records: [OpenAIUsageRecord],
        inSameDayAs date: Date,
        calendar: Calendar = .current
    ) -> OpenAIUsageTotals {
        totals(from: records) { calendar.isDate($0.timestamp, inSameDayAs: date) }
    }

    /// Totals for records in the same local calendar month (and year) as `date`.
    static func totals(
        from records: [OpenAIUsageRecord],
        inSameMonthAs date: Date,
        calendar: Calendar = .current
    ) -> OpenAIUsageTotals {
        totals(from: records) { calendar.isDate($0.timestamp, equalTo: date, toGranularity: .month) }
    }
}

// MARK: - Wire Decode Types

/// `usage` object returned by OpenAI Chat Completions.
struct OpenAIChatUsage: Decodable {
    let prompt_tokens: Int?
    let completion_tokens: Int?
    let total_tokens: Int?
}

/// Subset of the whisper-1 `verbose_json` transcription response we consume:
/// the transcript text and billed audio duration in seconds.
struct WhisperVerboseTranscription: Decodable {
    let text: String
    let duration: Double?
}
