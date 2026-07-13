import Foundation
import AppKit
import Observation

@Observable
@MainActor
final class TranslateENWorkflow: Workflow {
    let type = WorkflowType.translateEN
    var phase: WorkflowPhase = .idle {
        didSet { onPhaseChange?(phase) }
    }
    var onOutput: WorkflowOutputHandler?
    var onPhaseChange: WorkflowPhaseChangeHandler?

    private let recorder = AudioRecorder()
    private let customTerms: [String]
    private let language: String
    private var processingTask: Task<Void, Never>?

    init(customTerms: [String] = [], language: String = "de") {
        self.customTerms = customTerms
        self.language = language
    }

    var isRecording: Bool { recorder.isRecording }
    var audioLevel: Float { recorder.audioLevel }

    func start() {
        recorder.startRecording()

        if let error = recorder.errorMessage {
            phase = .error(error)
        } else {
            phase = .running("Aufnahme läuft ...")
        }
    }

    func stop() {
        if recorder.isRecording {
            recorder.stopRecording()
            guard !TranscriptionQualityService.shouldRejectRecording(duration: recorder.lastRecordingDuration) else {
                recorder.discardRecording()
                phase = .error("Keine Aufnahme erkannt.")
                return
            }
            processRecording()
        } else {
            processingTask?.cancel()
            phase = .idle
        }
    }

    func reset() {
        processingTask?.cancel()
        if recorder.isRecording {
            recorder.stopRecording()
        }
        recorder.discardRecording()
        phase = .idle
    }

    private func processRecording() {
        guard let url = recorder.recordingURL else {
            phase = .error("Keine Aufnahme vorhanden.")
            return
        }

        phase = .running("Wird transkribiert ...")
        let recordingDuration = recorder.lastRecordingDuration
        let vocabularyHints = recordingDuration >= 0.9 ? customTerms : []

        processingTask = Task {
            defer {
                try? FileManager.default.removeItem(at: url)
            }

            do {
                let rawText = try await TranscriptionService.transcribe(
                    audioURL: url,
                    customTerms: vocabularyHints,
                    language: language
                )
                let cleanedRawText = TranscriptionQualityService.cleanedTranscript(rawText)
                guard !TranscriptionQualityService.isLikelyArtifact(cleanedRawText, recordingDuration: recordingDuration) else {
                    phase = .error("Keine Aufnahme erkannt.")
                    return
                }

                if Task.isCancelled { return }

                phase = .running("Wird übersetzt ...")

                let translated = try await LLMService.translateToEnglishPrompt(text: cleanedRawText)
                let cleanedTranslated = TranscriptionQualityService.cleanedTranscript(translated)
                phase = .done(cleanedTranslated)
                onOutput?(cleanedTranslated)
            } catch {
                phase = .error(error.localizedDescription)
            }
        }
    }
}
