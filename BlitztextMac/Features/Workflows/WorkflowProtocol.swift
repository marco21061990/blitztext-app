import AppKit
import Foundation

// MARK: - Workflow Types

enum WorkflowType: String, CaseIterable, Identifiable, Codable, Hashable {
    case transcription
    case localTranscription
    case textImprover
    case translateEN
    case dampfAblassen
    case emojiText

    var id: String { rawValue }

    static var mainMenuCases: [WorkflowType] {
        allCases.filter { $0 != .localTranscription }
    }

    var displayName: String {
        switch self {
        case .transcription: return "Blitztext"
        case .localTranscription: return "Blitztext Lokal"
        case .textImprover: return "Blitztext+"
        case .translateEN: return "Translate EN"
        case .dampfAblassen: return "Blitztext $%&!"
        case .emojiText: return "Blitztext :)"
        }
    }

    var icon: String {
        switch self {
        case .transcription: return "mic.fill"
        case .localTranscription: return "lock.shield.fill"
        case .textImprover: return "text.badge.checkmark"
        case .translateEN: return "character.bubble.fill"
        case .dampfAblassen: return "flame.fill"
        case .emojiText: return "face.smiling"
        }
    }

    var subtitle: String {
        switch self {
        case .transcription: return "Sprache rein. Text raus."
        case .localTranscription: return "Nur lokal. Kein Server."
        case .textImprover: return "Geschrieben sprechen."
        case .translateEN: return "Deutsch sprechen. Englisch prompten."
        case .dampfAblassen: return "Frust rein. Entspannt raus."
        case .emojiText: return "Text rein. Emojis dazu."
        }
    }

    var hotkeyLabel: String {
        ShortcutConfiguration.defaultBinding(for: self).displayLabel
    }

    var accentColor: String {
        switch self {
        case .transcription: return "blue"
        case .localTranscription: return "green"
        case .textImprover: return "purple"
        case .translateEN: return "indigo"
        case .dampfAblassen: return "orange"
        case .emojiText: return "cyan"
        }
    }
}

// MARK: - Customizable Shortcuts

struct ShortcutBinding: Codable, Equatable, Hashable {
    var keyCode: UInt16?
    var modifiersRawValue: UInt64
    var keyLabel: String?
    var isEnabled: Bool

    init(
        keyCode: UInt16? = nil,
        modifiers: NSEvent.ModifierFlags = [],
        keyLabel: String? = nil,
        isEnabled: Bool = true
    ) {
        self.keyCode = keyCode
        self.modifiersRawValue = UInt64(modifiers.rawValue)
        self.keyLabel = keyLabel
        self.isEnabled = isEnabled
    }

    var modifiers: NSEvent.ModifierFlags {
        get { NSEvent.ModifierFlags(rawValue: UInt(modifiersRawValue)) }
        set { modifiersRawValue = UInt64(newValue.rawValue) }
    }

    var displayLabel: String {
        var components: [String] = []
        let flags = modifiers.intersection(ShortcutConfiguration.workflowModifierMask)

        if flags.contains(.function) { components.append("Fn") }
        if flags.contains(.shift) { components.append("Shift") }
        if flags.contains(.control) { components.append("Ctrl") }
        if flags.contains(.option) { components.append("Option") }
        if flags.contains(.command) { components.append("Cmd") }

        if let keyCode {
            let label = keyLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
            components.append(label?.isEmpty == false ? label! : ShortcutConfiguration.fallbackKeyLabel(for: keyCode))
        }

        return components.isEmpty ? "Kein Shortcut" : components.joined(separator: " + ")
    }

    var normalized: ShortcutBinding {
        var copy = self
        copy.modifiers = modifiers.intersection(ShortcutConfiguration.workflowModifierMask)
        if copy.keyCode == nil {
            copy.keyLabel = nil
        }
        return copy
    }

    var signature: ShortcutSignature {
        let normalizedBinding = self.normalized
        return ShortcutSignature(
            keyCode: normalizedBinding.keyCode,
            modifiersRawValue: normalizedBinding.modifiersRawValue
        )
    }

    struct ShortcutSignature: Hashable {
        let keyCode: UInt16?
        let modifiersRawValue: UInt64
    }

    enum CodingKeys: String, CodingKey {
        case keyCode
        case modifiersRawValue
        case keyLabel
        case isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decodeIfPresent(UInt16.self, forKey: .keyCode)
        modifiersRawValue = try container.decodeIfPresent(UInt64.self, forKey: .modifiersRawValue) ?? 0
        keyLabel = try container.decodeIfPresent(String.self, forKey: .keyLabel)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

enum ShortcutConfigurationError: Error, Equatable {
    case unsupportedKey
    case unsupportedModifier
    case escapeReserved
    case modifierRequired
    case modifierOnlyRequiresTwoModifiers
    case shortcutRequired
    case reservedSystemShortcut
    case duplicate(WorkflowType, WorkflowType)
}

extension ShortcutConfigurationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unsupportedKey:
            return "Diese Taste wird nicht unterstützt. Verwende Buchstaben, Zahlen, Leertaste oder F-Tasten. Medientasten sind ausgeschlossen."
        case .unsupportedModifier:
            return "Dieser Modifier wird nicht unterstützt. Verwende Fn, Shift, Ctrl, Option oder Cmd."
        case .escapeReserved:
            return "Escape ist fest zum Abbrechen reserviert."
        case .modifierRequired:
            return "Eine Standardtaste benötigt mindestens einen Modifier wie Fn, Shift, Ctrl, Option oder Cmd."
        case .modifierOnlyRequiresTwoModifiers:
            return "Ein Modifier-only-Shortcut benötigt mindestens zwei Modifier."
        case .shortcutRequired:
            return "Bitte zeichne zuerst eine gültige Shortcut-Kombination auf."
        case .reservedSystemShortcut:
            return "Diese Kombination ist für eine macOS-Systemfunktion reserviert."
        case let .duplicate(first, second):
            return "Dieses Kürzel wird bereits von \(first.displayName) verwendet und kann nicht zusätzlich für \(second.displayName) gespeichert werden."
        }
    }
}

enum ShortcutUpdateResult: Equatable {
    case applied
    case rejected(ShortcutConfigurationError)

    var errorDescription: String? {
        guard case .rejected(let error) = self else { return nil }
        return error.localizedDescription
    }
}

enum ShortcutConfiguration {
    static let currentVersion = 1

    static let workflowModifierMask: NSEvent.ModifierFlags = [
        .function,
        .shift,
        .control,
        .option,
        .command,
    ]

    // macOS virtual key codes for letters, number-row digits, Space, and F1-F20.
    // Punctuation, navigation keys, Escape, and media/system keys are excluded.
    static let standardKeyCodes: Set<UInt16> = [
        // Letters.
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11,
        12, 13, 14, 15, 16, 17, 31, 32, 34, 35, 37, 38, 40, 45, 46,
        // Number-row digits: 1, 2, 3, 4, 5, 6, 7, 8, 9, 0.
        18, 19, 20, 21, 23, 22, 26, 28, 25, 29,
        // Space.
        49,
        // F1 through F20.
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109,
        103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
    ]

    // Non-character keys that must stay excluded even when a malformed
    // persisted label claims that they are standard keys.
    private static let nonCharacterKeyCodes: Set<UInt16> = [
        36, 48, 51, 53, 71, 76, 110, 114, 115, 116, 117, 119, 121, 123, 124, 125, 126,
    ]

    static let defaultBindings: [String: ShortcutBinding] = [
        WorkflowType.transcription.rawValue: ShortcutBinding(modifiers: [.function, .shift]),
        WorkflowType.localTranscription.rawValue: ShortcutBinding(modifiers: [.function, .shift, .control]),
        WorkflowType.textImprover.rawValue: ShortcutBinding(modifiers: [.function, .control]),
        WorkflowType.translateEN.rawValue: ShortcutBinding(modifiers: [.function, .shift, .option]),
        WorkflowType.dampfAblassen.rawValue: ShortcutBinding(modifiers: [.function, .option]),
        WorkflowType.emojiText.rawValue: ShortcutBinding(modifiers: [.function, .command]),
    ]

    static func defaultBinding(for type: WorkflowType) -> ShortcutBinding {
        defaultBindings[type.rawValue] ?? ShortcutBinding(isEnabled: false)
    }

    static func migratedBindings(_ stored: [String: ShortcutBinding]) -> [String: ShortcutBinding] {
        var result = defaultBindings

        for type in WorkflowType.allCases {
            guard let storedBinding = stored[type.rawValue] else { continue }

            let candidate = storedBinding
            var proposed = result
            proposed[type.rawValue] = candidate

            // Validate each entry against the defaults and already accepted
            // entries, so one corrupt entry cannot discard the other settings.
            if validationError(for: proposed) == nil {
                result[type.rawValue] = candidate.normalized
            }
        }

        return result
    }

    static func validationError(for binding: ShortcutBinding) -> ShortcutConfigurationError? {
        shapeValidationError(for: binding)
    }

    static func validationError(for bindings: [String: ShortcutBinding]) -> ShortcutConfigurationError? {
        var seen: [ShortcutBinding.ShortcutSignature: WorkflowType] = [:]

        for type in WorkflowType.allCases {
            guard let binding = bindings[type.rawValue] else { continue }

            if let shapeError = shapeValidationError(for: binding) {
                return shapeError
            }

            if isKnownSystemReserved(binding) {
                return .reservedSystemShortcut
            }

            guard binding.isEnabled else { continue }

            if let existing = seen[binding.signature] {
                return .duplicate(existing, type)
            }
            seen[binding.signature] = type
        }

        return nil
    }

    static func keyLabel(for event: NSEvent) -> String {
        if event.keyCode == 49 {
            return "Leertaste"
        }

        if let characters = event.charactersIgnoringModifiers,
           let firstCharacter = characters.first,
           firstCharacter.isLetter || firstCharacter.isNumber {
            return String(firstCharacter).uppercased()
        }

        return fallbackKeyLabel(for: event.keyCode)
    }

    static func isSupportedStandardKey(for event: NSEvent) -> Bool {
        isSupportedStandardKey(keyCode: event.keyCode, keyLabel: keyLabel(for: event))
    }

    static func fallbackKeyLabel(for keyCode: UInt16) -> String {
        let labels: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B",
            12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 30: "]", 31: "O", 32: "U", 33: "[",
            34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
            44: "/", 45: "N", 46: "M", 47: ".", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6",
            26: "7", 28: "8", 25: "9", 29: "0", 49: "Leertaste",
            122: "F1", 120: "F2", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
            109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16",
            64: "F17", 79: "F18", 80: "F19", 90: "F20",
        ]
        return labels[keyCode] ?? "Taste \(keyCode)"
    }

    private static func shapeValidationError(for binding: ShortcutBinding) -> ShortcutConfigurationError? {
        let normalizedFlags = binding.modifiers.intersection(workflowModifierMask)
        let supportedModifierBits = UInt64(workflowModifierMask.rawValue)

        if binding.modifiersRawValue & ~supportedModifierBits != 0 {
            return .unsupportedModifier
        }

        if binding.keyCode == 53 {
            return .escapeReserved
        }

        if let keyCode = binding.keyCode {
            guard isSupportedStandardKey(keyCode: keyCode, keyLabel: binding.keyLabel) else {
                return .unsupportedKey
            }
            guard !normalizedFlags.isEmpty else {
                return .modifierRequired
            }
        } else if !binding.isEnabled && normalizedFlags.isEmpty {
            // A disabled row may intentionally have no assignment.
            return nil
        } else if normalizedFlags.rawValue.nonzeroBitCount < 2 {
            return .modifierOnlyRequiresTwoModifiers
        }

        return nil
    }

    private static func isSupportedStandardKey(keyCode: UInt16, keyLabel: String?) -> Bool {
        if standardKeyCodes.contains(keyCode) {
            return true
        }

        guard !nonCharacterKeyCodes.contains(keyCode),
              let firstCharacter = keyLabel?.first else {
            return false
        }

        return firstCharacter.isLetter || firstCharacter.isNumber
    }

    private static func isKnownSystemReserved(_ binding: ShortcutBinding) -> Bool {
        guard let keyCode = binding.keyCode else { return false }
        let flags = binding.modifiers.intersection(workflowModifierMask)

        // These are stable, well-known defaults. macOS and user preferences can
        // reserve additional shortcuts, which event monitors cannot reliably
        // discover; those collisions remain an explicit limitation in the UI.
        let reserved: [(keyCode: UInt16, modifiers: NSEvent.ModifierFlags)] = [
            (49, [.command]), // Spotlight
            (20, [.command, .shift]), // Screenshot 3
            (21, [.command, .shift]), // Screenshot 4
            (23, [.command, .shift]), // Screenshot 5
            (12, [.command, .control]), // Lock screen
            (49, [.control]), // Input source switching
        ]

        return reserved.contains { $0.keyCode == keyCode && $0.modifiers == flags }
    }
}

// MARK: - Workflow State

enum WorkflowPhase: Equatable {
    case idle
    case running(String)
    case done(String)
    case error(String)

    var isActive: Bool {
        switch self {
        case .idle: return false
        default: return true
        }
    }
}

enum WorkflowLaunchSource: Equatable {
    case manual
    case hotkeyBackground

    var presentsWorkflowPage: Bool {
        switch self {
        case .manual:
            return true
        case .hotkeyBackground:
            return false
        }
    }
}

typealias WorkflowOutputHandler = @MainActor (String) -> Void
typealias WorkflowPhaseChangeHandler = @MainActor (WorkflowPhase) -> Void

// MARK: - Workflow Protocol

@MainActor
protocol Workflow: AnyObject, Observable {
    var type: WorkflowType { get }
    var phase: WorkflowPhase { get set }
    var isRecording: Bool { get }
    var audioLevel: Float { get }
    var onOutput: WorkflowOutputHandler? { get set }
    var onPhaseChange: WorkflowPhaseChangeHandler? { get set }

    func start()
    func stop()
    func reset()
}

// MARK: - App Settings

struct AppSettings: Codable, Equatable {
    var hotkeyMode: HotkeyMode = .hold
    var hasSeenOnboarding: Bool = false
    var secureLocalModeEnabled: Bool = false
    var selectedLocalTranscriptionModelName: String = LocalTranscriptionService.recommendedFastModelName
    var hasAutoSelectedFastLocalModel: Bool = false
    var shortcutBindings: [String: ShortcutBinding] = ShortcutConfiguration.defaultBindings
    var shortcutConfigurationVersion: Int = ShortcutConfiguration.currentVersion
    var pauseMediaDuringDictation: Bool = true

    init(
        hotkeyMode: HotkeyMode = .hold,
        hasSeenOnboarding: Bool = false,
        secureLocalModeEnabled: Bool = false,
        selectedLocalTranscriptionModelName: String = LocalTranscriptionService.recommendedFastModelName,
        hasAutoSelectedFastLocalModel: Bool = false,
        shortcutBindings: [String: ShortcutBinding] = ShortcutConfiguration.defaultBindings,
        pauseMediaDuringDictation: Bool = true
    ) {
        self.hotkeyMode = hotkeyMode
        self.hasSeenOnboarding = hasSeenOnboarding
        self.secureLocalModeEnabled = secureLocalModeEnabled
        self.selectedLocalTranscriptionModelName = selectedLocalTranscriptionModelName
        self.hasAutoSelectedFastLocalModel = hasAutoSelectedFastLocalModel
        self.shortcutBindings = ShortcutConfiguration.migratedBindings(shortcutBindings)
        self.shortcutConfigurationVersion = ShortcutConfiguration.currentVersion
        self.pauseMediaDuringDictation = pauseMediaDuringDictation
    }

    enum CodingKeys: String, CodingKey {
        case hotkeyMode
        case hasSeenOnboarding
        case secureLocalModeEnabled
        case selectedLocalTranscriptionModelName
        case hasAutoSelectedFastLocalModel
        case shortcutBindings
        case shortcuts
        case shortcutConfigurationVersion
        case pauseMediaDuringDictation
    }

    private struct DynamicCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(intValue: Int) {
            stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hotkeyMode = try container.decodeIfPresent(HotkeyMode.self, forKey: .hotkeyMode) ?? .hold
        hasSeenOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasSeenOnboarding) ?? false
        secureLocalModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .secureLocalModeEnabled) ?? false
        selectedLocalTranscriptionModelName = try container.decodeIfPresent(
            String.self,
            forKey: .selectedLocalTranscriptionModelName
        ) ?? LocalTranscriptionService.recommendedFastModelName
        hasAutoSelectedFastLocalModel = try container.decodeIfPresent(
            Bool.self,
            forKey: .hasAutoSelectedFastLocalModel
        ) ?? false

        var storedBindings = Self.decodeShortcutBindings(from: container, key: .shortcutBindings)
        if storedBindings.isEmpty {
            // Accept the shorter name used by early development snapshots.
            storedBindings = Self.decodeShortcutBindings(from: container, key: .shortcuts)
        }
        shortcutBindings = ShortcutConfiguration.migratedBindings(storedBindings)
        // Unknown future versions still get the current safe defaults/migration
        // path instead of making the complete settings file undecodable.
        shortcutConfigurationVersion = ShortcutConfiguration.currentVersion
        pauseMediaDuringDictation = try container.decodeIfPresent(
            Bool.self,
            forKey: .pauseMediaDuringDictation
        ) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hotkeyMode, forKey: .hotkeyMode)
        try container.encode(hasSeenOnboarding, forKey: .hasSeenOnboarding)
        try container.encode(secureLocalModeEnabled, forKey: .secureLocalModeEnabled)
        try container.encode(selectedLocalTranscriptionModelName, forKey: .selectedLocalTranscriptionModelName)
        try container.encode(hasAutoSelectedFastLocalModel, forKey: .hasAutoSelectedFastLocalModel)
        try container.encode(shortcutBindings, forKey: .shortcutBindings)
        try container.encode(ShortcutConfiguration.currentVersion, forKey: .shortcutConfigurationVersion)
        try container.encode(pauseMediaDuringDictation, forKey: .pauseMediaDuringDictation)
    }

    private static func decodeShortcutBindings<C: CodingKey>(
        from container: KeyedDecodingContainer<C>,
        key: C
    ) -> [String: ShortcutBinding] {
        guard container.contains(key),
              let decoder = try? container.superDecoder(forKey: key),
              let shortcutContainer = try? decoder.container(keyedBy: DynamicCodingKey.self) else {
            return [:]
        }

        var bindings: [String: ShortcutBinding] = [:]
        for shortcutKey in shortcutContainer.allKeys {
            // Decode each workflow independently. A malformed entry falls back
            // to that workflow's default without discarding valid entries.
            if let binding = try? shortcutContainer.decode(ShortcutBinding.self, forKey: shortcutKey) {
                bindings[shortcutKey.stringValue] = binding
            }
        }
        return bindings
    }
}

enum TranscriptionBackend: String, Codable {
    case remote
    case local
}

// MARK: - Workflow Settings

struct TranscriptionSettings: Codable {
    var language: String = "de"
}

struct DampfAblassenSettings: Codable {
    var systemPrompt: String = "Du erhältst ein emotional gesprochenes Transkript. Erkenne zuerst das eigentliche Ziel, Anliegen und den wahren Frust der Person. Formuliere daraus eine klare, respektvolle und wirksame Nachricht, mit der die Person ihr Ziel eher erreicht. Bewahre relevante Fakten, konkrete Probleme, Grenzen, Erwartungen und die nötige Dringlichkeit. Entferne Beleidigungen, Drohungen, Sarkasmus, Unterstellungen und unnötige Eskalation. Wenn mehrere Vorwürfe genannt werden, verdichte sie auf die entscheidenden Kernpunkte. Der Ton soll ruhig, menschlich, bestimmt und lösungsorientiert sein. Gib NUR die fertige Nachricht zurück."
    var customName: String = ""
}

struct EmojiTextSettings: Codable {
    var emojiDensity: EmojiDensity = .mittel
    var customName: String = ""

    enum EmojiDensity: String, Codable, CaseIterable, Identifiable {
        case wenig
        case mittel
        case viel

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .wenig: return "Wenig"
            case .mittel: return "Mittel"
            case .viel: return "Viel"
            }
        }
    }
}

struct TextImprovementSettings: Codable {
    var systemPrompt: String = ""
    var customTerms: [String] = []
    var context: String = ""
    var tone: TextTone = .neutral
    var customName: String = ""

    enum TextTone: String, Codable, CaseIterable, Identifiable {
        case formal
        case neutral
        case casual

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .formal: return "Formell"
            case .neutral: return "Neutral"
            case .casual: return "Locker"
            }
        }
    }
}
