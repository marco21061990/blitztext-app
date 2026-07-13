import Foundation
import CoreGraphics

@main
struct RecordingOverlayStateTests {
    static func main() throws {
        try assertRecordingIsVisible()
        try assertProcessingIsHidden()
        try assertIdleRecordingFlagIsHidden()
        try assertAudioLevelIsClamped()
        try assertTargetScreenFrameIsPreserved()
        try assertTargetElementFrameIsPreserved()
    }

    private static func assertRecordingIsVisible() throws {
        let state = RecordingOverlayState.make(
            isRecording: true,
            isRunningPhase: true,
            audioLevel: 0.42
        )

        guard state == RecordingOverlayState(isVisible: true, audioLevel: 0.42, targetElementFrame: nil, targetScreenFrame: nil) else {
            throw TestFailure("Expected visible recording state, got \(state)")
        }
    }

    private static func assertProcessingIsHidden() throws {
        let state = RecordingOverlayState.make(
            isRecording: false,
            isRunningPhase: true,
            audioLevel: 0.7
        )

        guard state == .hidden else {
            throw TestFailure("Expected processing state to hide overlay, got \(state)")
        }
    }

    private static func assertIdleRecordingFlagIsHidden() throws {
        let state = RecordingOverlayState.make(
            isRecording: true,
            isRunningPhase: false,
            audioLevel: 0.7
        )

        guard state == .hidden else {
            throw TestFailure("Expected non-running state to hide overlay, got \(state)")
        }
    }

    private static func assertAudioLevelIsClamped() throws {
        let high = RecordingOverlayState.make(
            isRecording: true,
            isRunningPhase: true,
            audioLevel: 1.8
        )
        let low = RecordingOverlayState.make(
            isRecording: true,
            isRunningPhase: true,
            audioLevel: -0.5
        )

        guard high.audioLevel == 1, low.audioLevel == 0 else {
            throw TestFailure("Expected clamped levels, got high=\(high.audioLevel) low=\(low.audioLevel)")
        }
    }

    private static func assertTargetScreenFrameIsPreserved() throws {
        let frame = CGRect(x: 100, y: 200, width: 1600, height: 900)
        let state = RecordingOverlayState.make(
            isRecording: true,
            isRunningPhase: true,
            audioLevel: 0.25,
            targetScreenFrame: frame
        )

        guard state.targetScreenFrame == frame else {
            throw TestFailure("Expected target screen frame to be preserved, got \(String(describing: state.targetScreenFrame))")
        }
    }

    private static func assertTargetElementFrameIsPreserved() throws {
        let frame = CGRect(x: 420, y: 260, width: 360, height: 28)
        let state = RecordingOverlayState.make(
            isRecording: true,
            isRunningPhase: true,
            audioLevel: 0.25,
            targetElementFrame: frame
        )

        guard state.targetElementFrame == frame else {
            throw TestFailure("Expected target element frame to be preserved, got \(String(describing: state.targetElementFrame))")
        }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
