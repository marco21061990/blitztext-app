import AppKit
import Foundation

// The production model references the local transcription service for its
// default model name. This standalone test intentionally supplies only that
// dependency so it can run without WhisperKit or an Xcode test target.
enum LocalTranscriptionService {
    static let recommendedFastModelName = "test-model"
}

@main
struct ShortcutConfigurationTests {
    static func main() throws {
        testDefaults()
        testValidation()
        try testCodableMigration()
        print("Shortcut configuration tests passed")
    }

    private static func testDefaults() {
        let expected: [WorkflowType: NSEvent.ModifierFlags] = [
            .transcription: [.function, .shift],
            .localTranscription: [.function, .shift, .control],
            .textImprover: [.function, .control],
            .translateEN: [.function, .shift, .option],
            .dampfAblassen: [.function, .option],
            .emojiText: [.function, .command],
        ]

        require(ShortcutConfiguration.defaultBindings.count == WorkflowType.allCases.count, "all workflows have defaults")
        for type in WorkflowType.allCases {
            let binding = ShortcutConfiguration.defaultBinding(for: type)
            require(binding.keyCode == nil, "default \(type) is modifier-only")
            require(binding.modifiers == expected[type], "default modifiers for \(type)")
            require(binding.displayLabel.isEmpty == false, "default label for \(type)")
        }
    }

    private static func testValidation() {
        var bindings = ShortcutConfiguration.defaultBindings

        bindings[WorkflowType.textImprover.rawValue] = ShortcutConfiguration.defaultBinding(for: .transcription)
        require(
            ShortcutConfiguration.validationError(for: bindings) == .duplicate(.transcription, .textImprover),
            "duplicate active shortcuts are rejected"
        )

        bindings = ShortcutConfiguration.defaultBindings
        bindings[WorkflowType.transcription.rawValue] = ShortcutBinding(keyCode: 0, modifiers: [])
        require(
            ShortcutConfiguration.validationError(for: bindings) == .modifierRequired,
            "a standard key requires a modifier"
        )

        bindings = ShortcutConfiguration.defaultBindings
        bindings[WorkflowType.transcription.rawValue] = ShortcutBinding(modifiers: [.command])
        require(
            ShortcutConfiguration.validationError(for: bindings) == .modifierOnlyRequiresTwoModifiers,
            "a single modifier is rejected"
        )

        bindings = ShortcutConfiguration.defaultBindings
        bindings[WorkflowType.transcription.rawValue] = ShortcutBinding(keyCode: 53, modifiers: [.command])
        require(
            ShortcutConfiguration.validationError(for: bindings) == .escapeReserved,
            "Escape is reserved"
        )

        bindings = ShortcutConfiguration.defaultBindings
        bindings[WorkflowType.transcription.rawValue] = ShortcutBinding(keyCode: 48, modifiers: [.command])
        require(
            ShortcutConfiguration.validationError(for: bindings) == .unsupportedKey,
            "unsupported keys are rejected"
        )

        var unsupportedModifierBinding = ShortcutBinding(keyCode: 0, modifiers: [.command])
        unsupportedModifierBinding.modifiersRawValue |= UInt64(NSEvent.ModifierFlags.numericPad.rawValue)
        require(
            ShortcutConfiguration.validationError(for: unsupportedModifierBinding) == .unsupportedModifier,
            "unsupported modifiers are rejected"
        )

        let localizedLetter = ShortcutBinding(keyCode: 39, modifiers: [.function, .command], keyLabel: "Ä")
        require(
            ShortcutConfiguration.validationError(for: localizedLetter) == nil,
            "localized keyboard letters remain supported"
        )

        bindings = ShortcutConfiguration.defaultBindings
        bindings[WorkflowType.transcription.rawValue] = ShortcutBinding(keyCode: 49, modifiers: [.command])
        require(
            ShortcutConfiguration.validationError(for: bindings) == .reservedSystemShortcut,
            "known system shortcuts are rejected"
        )

        bindings[WorkflowType.transcription.rawValue] = ShortcutBinding(isEnabled: false)
        require(
            ShortcutConfiguration.validationError(for: bindings) == nil,
            "a disabled row may have no assignment"
        )
    }

    private static func testCodableMigration() throws {
        let legacyData = Data(#"{"hotkeyMode":"hold","hasSeenOnboarding":true}"#.utf8)
        let legacySettings = try JSONDecoder().decode(AppSettings.self, from: legacyData)
        require(
            legacySettings.shortcutBindings == ShortcutConfiguration.defaultBindings,
            "legacy settings receive all defaults"
        )
        require(
            legacySettings.shortcutConfigurationVersion == ShortcutConfiguration.currentVersion,
            "legacy settings receive the current shortcut version"
        )

        let customBinding = ShortcutBinding(
            keyCode: 0,
            modifiers: [.function, .command],
            keyLabel: "A"
        )
        let jsonObject: [String: Any] = [
            "hotkeyMode": "hold",
            "shortcutBindings": [
                WorkflowType.transcription.rawValue: [
                    "keyCode": 0,
                    "modifiersRawValue": Int(customBinding.modifiersRawValue),
                    "keyLabel": "A",
                    "isEnabled": true,
                ],
                WorkflowType.textImprover.rawValue: [
                    "keyCode": "not-a-key-code",
                    "modifiersRawValue": 0,
                    "isEnabled": true,
                ],
            ],
        ]
        let migratedData = try JSONSerialization.data(withJSONObject: jsonObject)
        let migratedSettings = try JSONDecoder().decode(AppSettings.self, from: migratedData)
        require(
            migratedSettings.shortcutBindings[WorkflowType.transcription.rawValue] == customBinding,
            "valid custom entries survive migration"
        )
        require(
            migratedSettings.shortcutBindings[WorkflowType.textImprover.rawValue] == ShortcutConfiguration.defaultBinding(for: .textImprover),
            "malformed entries fall back independently"
        )

        let roundTripData = try JSONEncoder().encode(migratedSettings)
        let roundTripSettings = try JSONDecoder().decode(AppSettings.self, from: roundTripData)
        require(roundTripSettings == migratedSettings, "shortcut settings round-trip through Codable")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fatalError("Shortcut configuration test failed: \(message)")
        }
    }
}
