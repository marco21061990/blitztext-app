import Cocoa
import Observation

enum HotkeyMode: String, Codable, CaseIterable, Identifiable {
    case hold    // Tasten halten = aufnehmen, loslassen = stoppen
    case toggle  // Einmal drücken = starten, nochmal/Escape = stoppen

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hold: return "Halten"
        case .toggle: return "Drücken"
        }
    }

    var description: String {
        switch self {
        case .hold: return "Tasten halten zum Aufnehmen, loslassen zum Stoppen"
        case .toggle: return "Einmal drücken zum Starten, nochmal oder Escape zum Stoppen"
        }
    }
}

enum HotkeyEvent {
    case down(WorkflowType)  // Keys pressed
    case up(WorkflowType)    // Keys released (for hold mode)
    case cancel              // Escape pressed
}

@Observable
@MainActor
final class HotkeyService {
    private static let chordResolutionDelay: Duration = .milliseconds(90)

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyMonitor: Any?
    private var activeCombo: WorkflowType?  // Which combo is currently held
    private var pendingComboTask: Task<Void, Never>?
    private var latestFlags: NSEvent.ModifierFlags = []
    private var isWaitingForModifierReset = false

    var onHotkeyEvent: ((HotkeyEvent) -> Void)?

    func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlags(event)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlags(event)
            }
            return event
        }
        // Escape key monitor for toggle mode
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                if event.keyCode == 53 { // Escape
                    self?.handleEscape()
                }
            }
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        pendingComboTask?.cancel()
        globalMonitor = nil
        localMonitor = nil
        keyMonitor = nil
        pendingComboTask = nil
        activeCombo = nil
        latestFlags = []
        isWaitingForModifierReset = false
    }

    private func handleFlags(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        latestFlags = flags

        if isWaitingForModifierReset {
            if flags.intersection(Self.workflowModifierMask).isEmpty {
                isWaitingForModifierReset = false
            }
            return
        }

        if let activeCombo {
            guard Self.workflow(for: flags) != activeCombo else { return }

            pendingComboTask?.cancel()
            pendingComboTask = nil
            self.activeCombo = nil
            isWaitingForModifierReset = !flags.intersection(Self.workflowModifierMask).isEmpty
            onHotkeyEvent?(.up(activeCombo))
            return
        }

        guard let combo = Self.workflow(for: flags) else {
            pendingComboTask?.cancel()
            pendingComboTask = nil
            return
        }

        pendingComboTask?.cancel()

        // Three-modifier chords are unambiguous and should override a pending
        // two-modifier prefix immediately.
        if Self.isExtendedChord(combo) {
            pendingComboTask = nil
            activate(combo)
            return
        }

        let expectedFlags = flags
        pendingComboTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.chordResolutionDelay)
            guard !Task.isCancelled,
                  let self,
                  self.activeCombo == nil,
                  !self.isWaitingForModifierReset,
                  self.latestFlags == expectedFlags else {
                return
            }

            self.pendingComboTask = nil
            self.activate(combo)
        }
    }

    private func activate(_ combo: WorkflowType) {
        guard activeCombo == nil else { return }
        activeCombo = combo
        onHotkeyEvent?(.down(combo))
    }

    private static let workflowModifierMask: NSEvent.ModifierFlags = [
        .function,
        .shift,
        .control,
        .option,
        .command,
    ]

    private static func workflow(for flags: NSEvent.ModifierFlags) -> WorkflowType? {
        switch flags.intersection(workflowModifierMask) {
        case [.function, .shift, .control]:
            return .localTranscription
        case [.function, .shift, .option]:
            return .translateEN
        case [.function, .shift]:
            return .transcription
        case [.function, .control]:
            return .textImprover
        case [.function, .option]:
            return .dampfAblassen
        case [.function, .command]:
            return .emojiText
        default:
            return nil
        }
    }

    private static func isExtendedChord(_ combo: WorkflowType) -> Bool {
        combo == .localTranscription || combo == .translateEN
    }

    private func handleEscape() {
        pendingComboTask?.cancel()
        pendingComboTask = nil
        activeCombo = nil
        isWaitingForModifierReset = false
        onHotkeyEvent?(.cancel)
    }
}
