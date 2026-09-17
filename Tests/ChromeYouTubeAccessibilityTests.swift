import Foundation

@main
struct ChromeYouTubeAccessibilityTests {
    static func main() throws {
        try assertYouTubeHostAllowlist()
        try assertActionLabelsAreNarrow()
        try assertShortcutSuffixesAreNormalized()
        print("ChromeYouTubeAccessibilityTests passed")
    }

    private static func assertYouTubeHostAllowlist() throws {
        let allowed = [
            "https://www.youtube.com/watch?v=video",
            "https://youtube.com/watch?v=video",
            "https://youtu.be/video",
            "youtube.com/watch?v=video",
        ]
        guard allowed.allSatisfy(ChromeYouTubeAccessibility.isYouTubeURL) else {
            throw TestFailure("Expected supported YouTube hosts to be accepted")
        }

        let rejected = [
            "https://example.com/youtube.com/watch",
            "https://youtube.com.evil.example/watch",
            "https://notyoutube.com/watch",
            "https://www.youtube.com.evil.example/watch",
        ]
        guard rejected.allSatisfy({ !ChromeYouTubeAccessibility.isYouTubeURL($0) }) else {
            throw TestFailure("A URL containing YouTube text on another host must be rejected")
        }
    }

    private static func assertActionLabelsAreNarrow() throws {
        guard ChromeYouTubeAccessibility.actionIntent(for: "Pause") == .pause,
              ChromeYouTubeAccessibility.actionIntent(for: "Pausieren") == .pause,
              ChromeYouTubeAccessibility.actionIntent(for: "Play") == .play,
              ChromeYouTubeAccessibility.actionIntent(for: "Wiedergeben") == .play else {
            throw TestFailure("Expected the supported pause and play labels")
        }

        let ambiguousOrUnrelated = [
            "Wiedergabe",
            "Wiedergabegeschwindigkeit",
            "Wiedergabe pausieren und Einstellungen",
            "Autoplay deaktiviert",
            "Nächstes Video",
            "Replay",
        ]
        guard ambiguousOrUnrelated.allSatisfy({ ChromeYouTubeAccessibility.actionIntent(for: $0) == nil }) else {
            throw TestFailure("Unrelated or ambiguous controls must not be classified as Play/Pause")
        }
    }

    private static func assertShortcutSuffixesAreNormalized() throws {
        guard ChromeYouTubeAccessibility.actionIntent(for: "Pause (k)") == .pause,
              ChromeYouTubeAccessibility.actionIntent(for: "Wiedergeben (k)") == .play,
              ChromeYouTubeAccessibility.actionIntent(for: "Pause Tastenkombination k") == .pause,
              ChromeYouTubeAccessibility.actionIntent(for: "Wiedergeben Keyboard Shortcut k") == .play else {
            throw TestFailure("YouTube keyboard shortcut suffixes should not change the action intent")
        }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
