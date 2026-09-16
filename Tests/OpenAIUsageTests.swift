import Foundation

@main
struct OpenAIUsageTests {
    @MainActor
    static func main() throws {
        try assertCostForKnownModels()
        try assertCostIsNilForUnknownModelOrMissingUnits()
        try assertDayAggregation()
        try assertMonthAggregation()
        try assertPersistenceRoundTrip()
        try assertStorePersistenceAndCorruptFileRecovery()
        try assertChatUsageDecoding()
        try assertWhisperVerboseDecoding()
        print("OpenAIUsageTests passed")
    }

    // MARK: - Cost

    private static func assertCostForKnownModels() throws {
        // whisper-1: 90 s = 1.5 min * 0.006 = 0.009
        try expectCost(
            OpenAIUsageRecord(kind: .transcription, model: "whisper-1", audioSeconds: 90),
            equals: 0.009
        )
        // gpt-4o-mini: 500000/1M*0.15 + 100000/1M*0.60 = 0.075 + 0.06 = 0.135
        try expectCost(
            OpenAIUsageRecord(kind: .rewrite, model: "gpt-4o-mini", inputTokens: 500_000, outputTokens: 100_000),
            equals: 0.135
        )
        // gpt-4o: 1M*2.50 + 1M*10.00 = 12.5
        try expectCost(
            OpenAIUsageRecord(kind: .rewrite, model: "gpt-4o", inputTokens: 1_000_000, outputTokens: 1_000_000),
            equals: 12.5
        )
    }

    private static func assertCostIsNilForUnknownModelOrMissingUnits() throws {
        let unknown = OpenAIUsageRecord(kind: .rewrite, model: "gpt-5", inputTokens: 100, outputTokens: 100)
        guard OpenAIPricing.estimatedCostUSD(for: unknown) == nil else {
            throw TestFailure("Expected nil cost for unknown model")
        }

        let missingDuration = OpenAIUsageRecord(kind: .transcription, model: "whisper-1", audioSeconds: nil)
        guard OpenAIPricing.estimatedCostUSD(for: missingDuration) == nil else {
            throw TestFailure("Expected nil cost for whisper-1 without duration")
        }

        let missingTokens = OpenAIUsageRecord(kind: .rewrite, model: "gpt-4o-mini", inputTokens: nil, outputTokens: nil)
        guard OpenAIPricing.estimatedCostUSD(for: missingTokens) == nil else {
            throw TestFailure("Expected nil cost for rewrite without tokens")
        }
    }

    // MARK: - Aggregation

    private static var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private static var sampleRecords: [OpenAIUsageRecord] {
        [
            OpenAIUsageRecord(timestamp: date(2026, 7, 14, 9), kind: .transcription, model: "whisper-1", audioSeconds: 120),
            OpenAIUsageRecord(timestamp: date(2026, 7, 14, 10), kind: .rewrite, model: "gpt-4o-mini", inputTokens: 1000, outputTokens: 500),
            OpenAIUsageRecord(timestamp: date(2026, 7, 2, 8), kind: .rewrite, model: "gpt-4o", inputTokens: 2000, outputTokens: 1000),
            OpenAIUsageRecord(timestamp: date(2026, 6, 30, 23), kind: .transcription, model: "whisper-1", audioSeconds: 60),
        ]
    }

    private static func assertDayAggregation() throws {
        let totals = OpenAIUsageAggregation.totals(from: sampleRecords, inSameDayAs: date(2026, 7, 14), calendar: calendar)
        guard totals.callCount == 2 else { throw TestFailure("Day callCount \(totals.callCount) != 2") }
        try expect(totals.audioSeconds, equals: 120)
        guard totals.inputTokens == 1000, totals.outputTokens == 500 else {
            throw TestFailure("Day tokens \(totals.inputTokens)/\(totals.outputTokens)")
        }
        // 0.012 (whisper) + 0.00045 (mini) = 0.01245
        try expect(totals.estimatedCostUSD, equals: 0.01245)
        guard totals.hasCostEstimate else { throw TestFailure("Day should have cost estimate") }
    }

    private static func assertMonthAggregation() throws {
        let totals = OpenAIUsageAggregation.totals(from: sampleRecords, inSameMonthAs: date(2026, 7, 14), calendar: calendar)
        guard totals.callCount == 3 else { throw TestFailure("Month callCount \(totals.callCount) != 3") }
        try expect(totals.audioSeconds, equals: 120)
        guard totals.inputTokens == 3000, totals.outputTokens == 1500 else {
            throw TestFailure("Month tokens \(totals.inputTokens)/\(totals.outputTokens)")
        }
        // 0.012 + 0.00045 + 0.015 (gpt-4o) = 0.02745
        try expect(totals.estimatedCostUSD, equals: 0.02745)
    }

    // MARK: - Persistence

    private static func assertPersistenceRoundTrip() throws {
        // Integer reference timestamps round-trip exactly through the default Date encoding.
        let records = [
            OpenAIUsageRecord(id: UUID(), timestamp: Date(timeIntervalSinceReferenceDate: 700_000_000), kind: .transcription, model: "whisper-1", audioSeconds: 42),
            OpenAIUsageRecord(id: UUID(), timestamp: Date(timeIntervalSinceReferenceDate: 700_000_100), kind: .rewrite, model: "gpt-4o", inputTokens: 10, outputTokens: 20),
        ]
        let data = try JSONEncoder().encode(records)
        let decoded = try JSONDecoder().decode([OpenAIUsageRecord].self, from: data)
        guard decoded == records else {
            throw TestFailure("Persistence round-trip mismatch")
        }
    }

    @MainActor
    private static func assertStorePersistenceAndCorruptFileRecovery() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("blitztext-usage-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("api-usage.json")
        let record = OpenAIUsageRecord(
            timestamp: Date(timeIntervalSinceReferenceDate: 700_000_000),
            kind: .rewrite,
            model: "gpt-4o-mini",
            inputTokens: 12,
            outputTokens: 34
        )

        let store = OpenAIUsageStore(fileURL: fileURL)
        store.add(record)

        let reloaded = OpenAIUsageStore(fileURL: fileURL)
        guard reloaded.records == [record] else {
            throw TestFailure("Store persistence round-trip mismatch")
        }

        reloaded.clear()
        guard reloaded.records.isEmpty else {
            throw TestFailure("Cleared usage store should be empty")
        }
        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            throw TestFailure("Cleared usage store should remove its file")
        }

        try Data("not-json".utf8).write(to: fileURL, options: .atomic)
        let recovered = OpenAIUsageStore(fileURL: fileURL)
        guard recovered.records.isEmpty else {
            throw TestFailure("Corrupt usage file should load as an empty log")
        }
    }

    // MARK: - Response decoding

    private static func assertChatUsageDecoding() throws {
        let json = Data(#"{"prompt_tokens":11,"completion_tokens":22,"total_tokens":33}"#.utf8)
        let usage = try JSONDecoder().decode(OpenAIChatUsage.self, from: json)
        guard usage.prompt_tokens == 11, usage.completion_tokens == 22, usage.total_tokens == 33 else {
            throw TestFailure("Chat usage decode mismatch: \(usage)")
        }
    }

    private static func assertWhisperVerboseDecoding() throws {
        let json = Data(#"{"task":"transcribe","language":"german","duration":3.5,"text":"Hallo Welt","segments":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(WhisperVerboseTranscription.self, from: json)
        guard decoded.text == "Hallo Welt", decoded.duration == 3.5 else {
            throw TestFailure("Whisper verbose decode mismatch: \(decoded)")
        }
    }

    // MARK: - Helpers

    private static func expectCost(_ record: OpenAIUsageRecord, equals expected: Double) throws {
        guard let cost = OpenAIPricing.estimatedCostUSD(for: record) else {
            throw TestFailure("Expected cost for \(record.model), got nil")
        }
        try expect(cost, equals: expected)
    }

    private static func expect(_ value: Double, equals expected: Double) throws {
        guard abs(value - expected) < 1e-9 else {
            throw TestFailure("Expected \(expected), got \(value)")
        }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
