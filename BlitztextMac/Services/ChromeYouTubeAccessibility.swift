import Foundation

enum ChromeYouTubeAccessibility {
    enum ActionIntent: Equatable {
        case pause
        case play
    }

    static func isYouTubeURL(_ value: String) -> Bool {
        let candidate = value.contains("://") ? value : "https://\(value)"
        guard let host = URLComponents(string: candidate)?.host?.lowercased() else {
            return false
        }

        return [
            "youtube.com",
            "www.youtube.com",
            "m.youtube.com",
            "music.youtube.com",
            "youtu.be",
            "www.youtu.be",
        ].contains(host.trimmingCharacters(in: CharacterSet(charactersIn: ".")))
    }

    static func actionIntent(for label: String) -> ActionIntent? {
        let normalized = normalize(label)
        let withoutShortcut = normalized.replacingOccurrences(
            of: #"\s*\([a-z]\)\s*$"#,
            with: "",
            options: .regularExpression
        )
            .replacingOccurrences(
                of: #"\s+(?:tastenkombination|keyboard shortcut)\s+[a-z]\s*$"#,
                with: "",
                options: .regularExpression
            )

        switch withoutShortcut {
        case "pause", "pausieren", "video pausieren", "wiedergabe pausieren":
            return .pause
        case "play", "wiedergeben", "abspielen", "fortsetzen":
            return .play
        default:
            return nil
        }
    }

    static func normalize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .localizedLowercase
    }
}
