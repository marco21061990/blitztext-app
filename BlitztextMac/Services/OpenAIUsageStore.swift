import Foundation
import Observation

/// Local, on-device log of successful OpenAI API usage. Persists only usage
/// metadata (model + raw units + timestamp) under Application Support. It never
/// stores audio, transcripts, prompt text, completions, or API keys.
///
/// The store is `@MainActor`/`@Observable` so the settings UI updates live when a
/// new record arrives. Services record from background contexts through the
/// nonisolated `OpenAIUsageRecorder` shim, which hops to the main actor.
@MainActor
@Observable
final class OpenAIUsageStore {
    static let shared = OpenAIUsageStore()

    /// Soft cap on retained records. Aggregation only ever needs the current
    /// calendar month, so this is generous head-room, not a functional limit.
    // ponytail: fixed cap keeps the file bounded; prune by calendar month if a
    // user ever exceeds this in a single month.
    private static let maxRecords = 10_000

    private(set) var records: [OpenAIUsageRecord]
    private let fileURL: URL

    init(fileURL: URL = AppSupportPaths.usageURL) {
        self.fileURL = fileURL
        self.records = Self.load(from: fileURL)
    }

    func add(_ record: OpenAIUsageRecord) {
        records.append(record)
        if records.count > Self.maxRecords {
            records.removeFirst(records.count - Self.maxRecords)
        }
        save()
    }

    var lastRecord: OpenAIUsageRecord? {
        records.max { $0.timestamp < $1.timestamp }
    }

    var todayTotals: OpenAIUsageTotals {
        OpenAIUsageAggregation.totals(from: records, inSameDayAs: Date())
    }

    var monthTotals: OpenAIUsageTotals {
        OpenAIUsageAggregation.totals(from: records, inSameMonthAs: Date())
    }

    // MARK: - Persistence

    private func save() {
        try? AppSupportPaths.ensureAppSupportDirectoryExists()
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Loads persisted records. A missing or corrupt file yields an empty log; the
    /// next successful call overwrites it atomically.
    private static func load(from fileURL: URL) -> [OpenAIUsageRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([OpenAIUsageRecord].self, from: data)) ?? []
    }
}

/// Entry point for recording usage from background service code. The caller
/// awaits the main-actor append so the latest successful call is persisted
/// before its service method returns.
enum OpenAIUsageRecorder {
    static func recordTranscription(model: String, audioSeconds: Double?) async {
        let record = OpenAIUsageRecord(
            kind: .transcription,
            model: model,
            audioSeconds: audioSeconds
        )
        await MainActor.run {
            OpenAIUsageStore.shared.add(record)
        }
    }

    static func recordRewrite(model: String, inputTokens: Int?, outputTokens: Int?) async {
        let record = OpenAIUsageRecord(
            kind: .rewrite,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens
        )
        await MainActor.run {
            OpenAIUsageStore.shared.add(record)
        }
    }
}
