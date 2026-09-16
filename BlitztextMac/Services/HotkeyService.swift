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

    private struct ActiveShortcut {
        let type: WorkflowType
        let binding: ShortcutBinding
    }

    private struct PendingModifierActivation {
        let type: WorkflowType
        let binding: ShortcutBinding
        let expectedFlags: NSEvent.ModifierFlags
    }

    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var activeShortcut: ActiveShortcut?
    private var pendingModifierActivation: PendingModifierActivation?
    private var pendingComboTask: Task<Void, Never>?
    private var latestFlags: NSEvent.ModifierFlags = []
    private var isWaitingForModifierReset = false
    private var isCapturingShortcuts = false

    private(set) var shortcutBindings: [String: ShortcutBinding]
    var onHotkeyEvent: ((HotkeyEvent) -> Void)?

    init(bindings: [String: ShortcutBinding] = ShortcutConfiguration.defaultBindings) {
        shortcutBindings = ShortcutConfiguration.migratedBindings(bindings)
    }

    func start() {
        guard globalFlagsMonitor == nil, localFlagsMonitor == nil else { return }

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleFlags(event)
            }
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleFlags(event)
            }
            return event
        }

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleKeyEvent(event)
            }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleKeyEvent(event)
            }
            return event
        }
    }

    func stop() {
        if let globalFlagsMonitor { NSEvent.removeMonitor(globalFlagsMonitor) }
        if let localFlagsMonitor { NSEvent.removeMonitor(localFlagsMonitor) }
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }

        cancelPendingActivation()
        globalFlagsMonitor = nil
        localFlagsMonitor = nil
        globalKeyMonitor = nil
        localKeyMonitor = nil
        activeShortcut = nil
        latestFlags = []
        isWaitingForModifierReset = false
        isCapturingShortcuts = false
    }

    /// Atomically replaces the monitored configuration. An active shortcut is
    /// retained until its old key/modifier release so a hold-mode recording can
    /// finish normally after the user edits its assignment.
    @discardableResult
    func updateConfiguration(_ bindings: [String: ShortcutBinding]) -> ShortcutUpdateResult {
        guard let error = ShortcutConfiguration.validationError(for: bindings) else {
            let normalized = bindings.reduce(into: [String: ShortcutBinding]()) { result, entry in
                result[entry.key] = entry.value.normalized
            }
            cancelPendingActivation()
            shortcutBindings = normalized
            if activeShortcut == nil, latestFlags.intersection(ShortcutConfiguration.workflowModifierMask).isEmpty {
                isWaitingForModifierReset = false
            }
            return .applied
        }

        return .rejected(error)
    }

    /// Prevents new global shortcuts while a settings row records a shortcut.
    /// An already active shortcut is still observed until release.
    func setCapturingShortcuts(_ isCapturing: Bool) {
        isCapturingShortcuts = isCapturing
        cancelPendingActivation()

        if isCapturing {
            if activeShortcut == nil {
                isWaitingForModifierReset = false
            }
        } else if activeShortcut == nil {
            latestFlags = []
            isWaitingForModifierReset = false
        }
    }

    private func handleFlags(_ event: NSEvent) {
        let flags = normalizedFlags(from: event)
        latestFlags = flags

        if let activeShortcut {
            guard flags == activeShortcut.binding.modifiers else {
                finishActiveShortcut(after: flags)
                return
            }
            return
        }

        if isCapturingShortcuts {
            cancelPendingActivation()
            return
        }

        if isWaitingForModifierReset {
            if flags.intersection(ShortcutConfiguration.workflowModifierMask).isEmpty {
                isWaitingForModifierReset = false
            }
            return
        }

        guard let candidate = modifierShortcut(for: flags) else {
            cancelPendingActivation()
            return
        }

        scheduleActivation(for: candidate, flags: flags)
    }

    private func handleKeyEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            handleKeyDown(event)
        case .keyUp:
            handleKeyUp(event)
        default:
            break
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        if event.keyCode == 53 {
            // Escape belongs to cancellation, not to user-configurable
            // shortcuts. During capture the recorder owns Escape instead.
            if isCapturingShortcuts && activeShortcut == nil {
                return
            }
            handleEscape()
            return
        }

        if isCapturingShortcuts && activeShortcut == nil {
            return
        }

        guard activeShortcut == nil, !isWaitingForModifierReset, !event.isARepeat else { return }

        // A key press completes a possible modifier-only prefix. Do not let
        // the prefix fire after the standard key has arrived.
        cancelPendingActivation()

        let flags = normalizedFlags(from: event)
        guard let candidate = keyShortcut(for: event.keyCode, flags: flags) else { return }
        activate(candidate)
    }

    private func handleKeyUp(_ event: NSEvent) {
        if isCapturingShortcuts && activeShortcut == nil {
            return
        }

        guard let activeShortcut,
              activeShortcut.binding.keyCode == event.keyCode else {
            return
        }

        finishActiveShortcut(after: normalizedFlags(from: event))
    }

    private func modifierShortcut(for flags: NSEvent.ModifierFlags) -> (WorkflowType, ShortcutBinding)? {
        guard !flags.isEmpty else { return nil }

        for type in WorkflowType.allCases {
            guard let binding = shortcutBindings[type.rawValue]?.normalized,
                  binding.isEnabled,
                  binding.keyCode == nil,
                  binding.modifiers == flags else {
                continue
            }
            return (type, binding)
        }

        return nil
    }

    private func keyShortcut(
        for keyCode: UInt16,
        flags: NSEvent.ModifierFlags
    ) -> (WorkflowType, ShortcutBinding)? {
        for type in WorkflowType.allCases {
            guard let binding = shortcutBindings[type.rawValue]?.normalized,
                  binding.isEnabled,
                  binding.keyCode == keyCode,
                  binding.modifiers == flags else {
                continue
            }
            return (type, binding)
        }

        return nil
    }

    private func scheduleActivation(
        for candidate: (WorkflowType, ShortcutBinding),
        flags: NSEvent.ModifierFlags
    ) {
        cancelPendingActivation()

        let (type, binding) = candidate
        guard shouldDelayModifierActivation(for: flags) else {
            activate(candidate)
            return
        }

        pendingModifierActivation = PendingModifierActivation(
            type: type,
            binding: binding,
            expectedFlags: flags
        )

        pendingComboTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.chordResolutionDelay)
            guard !Task.isCancelled,
                  let self,
                  let pending = self.pendingModifierActivation,
                  pending.type == type,
                  pending.binding.signature == binding.signature,
                  pending.expectedFlags == flags,
                  self.activeShortcut == nil,
                  !self.isCapturingShortcuts,
                  !self.isWaitingForModifierReset,
                  self.latestFlags == flags else {
                return
            }

            self.pendingModifierActivation = nil
            self.pendingComboTask = nil
            self.activate((type, binding))
        }
    }

    private func shouldDelayModifierActivation(for flags: NSEvent.ModifierFlags) -> Bool {
        // Preserve the existing 90 ms grace period for two-modifier defaults,
        // which lets a third modifier arrive before the shorter chord fires.
        if flags.rawValue.nonzeroBitCount == 2 {
            return true
        }

        for type in WorkflowType.allCases {
            guard let other = shortcutBindings[type.rawValue]?.normalized,
                  other.isEnabled else {
                continue
            }

            if other.keyCode != nil && other.modifiers == flags {
                // Give a standard-key shortcut using the same modifier prefix
                // a chance to arrive before the modifier-only assignment.
                return true
            }

            guard other.keyCode == nil,
                  other.modifiers != flags,
                  other.modifiers.intersection(flags) == flags else {
                continue
            }

            // This is the generalized form of the historical two-modifier
            // prefix delay used by the Fn+Shift defaults.
            return true
        }

        return false
    }

    private func activate(_ candidate: (WorkflowType, ShortcutBinding)) {
        guard activeShortcut == nil, !isCapturingShortcuts else { return }

        let (type, binding) = candidate
        activeShortcut = ActiveShortcut(type: type, binding: binding)
        onHotkeyEvent?(.down(type))
    }

    private func finishActiveShortcut(after flags: NSEvent.ModifierFlags) {
        guard let activeShortcut else { return }

        self.activeShortcut = nil
        cancelPendingActivation()
        isWaitingForModifierReset = !flags.intersection(ShortcutConfiguration.workflowModifierMask).isEmpty
        onHotkeyEvent?(.up(activeShortcut.type))
    }

    private func handleEscape() {
        cancelPendingActivation()
        activeShortcut = nil
        isWaitingForModifierReset = false
        onHotkeyEvent?(.cancel)
    }

    private func cancelPendingActivation() {
        pendingComboTask?.cancel()
        pendingComboTask = nil
        pendingModifierActivation = nil
    }

    private func normalizedFlags(from event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags.intersection(ShortcutConfiguration.workflowModifierMask)
    }
}
