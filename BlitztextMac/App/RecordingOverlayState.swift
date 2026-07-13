import CoreGraphics

struct RecordingOverlayState: Equatable {
    static let hidden = RecordingOverlayState(
        isVisible: false,
        audioLevel: 0,
        targetElementFrame: nil,
        targetScreenFrame: nil
    )

    let isVisible: Bool
    let audioLevel: Float
    let targetElementFrame: CGRect?
    let targetScreenFrame: CGRect?

    static func make(
        isRecording: Bool,
        isRunningPhase: Bool,
        audioLevel: Float,
        targetElementFrame: CGRect? = nil,
        targetScreenFrame: CGRect? = nil
    ) -> RecordingOverlayState {
        guard isRecording, isRunningPhase else { return .hidden }

        return RecordingOverlayState(
            isVisible: true,
            audioLevel: min(max(audioLevel, 0), 1),
            targetElementFrame: targetElementFrame,
            targetScreenFrame: targetScreenFrame
        )
    }
}
