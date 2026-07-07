import SwiftUI
import Observation
import AppKit
import os

enum PopoverPage: Equatable {
    case main
    case onboarding
    case settings
    case workflow
}

@Observable
@MainActor
final class AppState {
    private static let pasteRetryInitialAttempts = 70
    private static let concealedPasteboardType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let autoPasteLogger = Logger(subsystem: "app.blitztext.mac", category: "AutoPaste")

    var activeWorkflow: (any Workflow)?
    var page: PopoverPage = .main
    var isPopoverShown = false
    var menuBarStatus: MenuBarStatus = .idle {
        didSet {
            guard oldValue != menuBarStatus else { return }
            onMenuBarStatusChange?(menuBarStatus)
        }
    }
    var accessibilityPermissionGranted = false
    var localModelDownloadProgress: Double?
    var localModelDownloadStatusText: String?
    var localModelDownloadErrorText: String?
    var autoPasteSucceeded = false
    var autoPasteStatusText: String?
    var autoPasteStatusIsVisible = false
    var onMenuBarStatusChange: ((MenuBarStatus) -> Void)?
    var onRecordingOverlayStateChange: ((RecordingOverlayState) -> Void)?
    private var activeLaunchSource: WorkflowLaunchSource = .manual
    private var activePasteTarget: PasteTarget?
    private var lastPopoverPasteTarget: PasteTarget?
    private var menuBarStatusResetTask: Task<Void, Never>?
    private var workflowCleanupTask: Task<Void, Never>?

    // Persisted settings
    var appSettings: AppSettings {
        didSet {
            saveSettings()
            prewarmLocalTranscriptionIfNeeded()
        }
    }
    var transcriptionSettings: TranscriptionSettings {
        didSet { saveSettings() }
    }
    var textImprovementSettings: TextImprovementSettings {
        didSet { saveSettings() }
    }
    var dampfAblassenSettings: DampfAblassenSettings {
        didSet { saveSettings() }
    }
    var emojiTextSettings: EmojiTextSettings {
        didSet { saveSettings() }
    }

    // Hotkeys
    let hotkeyService = HotkeyService()

    // Computed
    var isConfigured: Bool {
        KeychainService.isConfigured || !LocalTranscriptionService.installedModels().isEmpty
    }
    var shouldShowOnboarding: Bool {
        !isConfigured && !appSettings.hasSeenOnboarding
    }

    var currentPhase: WorkflowPhase {
        activeWorkflow?.phase ?? .idle
    }

    var recordingOverlayState: RecordingOverlayState {
        guard let activeWorkflow else { return .hidden }

        let isRunningPhase: Bool
        if case .running = activeWorkflow.phase {
            isRunningPhase = true
        } else {
            isRunningPhase = false
        }

        return RecordingOverlayState.make(
            isRecording: activeWorkflow.isRecording,
            isRunningPhase: isRunningPhase,
            audioLevel: activeWorkflow.audioLevel,
            targetScreenFrame: activePasteTarget?.targetScreenFrame
        )
    }

    init() {
        self.appSettings = Self.loadAppSettings()
        self.transcriptionSettings = Self.loadTranscriptionSettings()
        self.textImprovementSettings = Self.loadTextImprovementSettings()
        self.dampfAblassenSettings = Self.loadDampfAblassenSettings()
        self.emojiTextSettings = Self.loadEmojiTextSettings()
        refreshAccessibilityPermission()
        autoSelectFastLocalModelIfNeeded()
        prewarmLocalTranscriptionIfNeeded()
    }

    // MARK: - Custom Display Names

    func displayName(for type: WorkflowType) -> String {
        switch type {
        case .textImprover:
            let name = textImprovementSettings.customName.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? type.displayName : name
        case .dampfAblassen:
            let name = dampfAblassenSettings.customName.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? type.displayName : name
        case .emojiText:
            let name = emojiTextSettings.customName.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? type.displayName : name
        default:
            return type.displayName
        }
    }

    func workflowSubtitle(for type: WorkflowType) -> String {
        switch type {
        case .transcription:
            if appSettings.secureLocalModeEnabled {
                let modelName = selectedLocalModelName
                return LocalTranscriptionService.isModelInstalled(modelName)
                    ? "Lokal: \(LocalTranscriptionModel.displayName(for: modelName))."
                    : "Lokales WhisperKit-Modell fehlt."
            }
            return "Online: Whisper über OpenAI."
        case .localTranscription:
            return "Nur lokal. Kein Server."
        case .textImprover, .dampfAblassen, .emojiText:
            if appSettings.secureLocalModeEnabled {
                return "Im lokalen Modus pausiert."
            }
            return type.subtitle
        }
    }

    var resolvedLocalModelName: String {
        LocalTranscriptionService.resolvedModelName(appSettings.selectedLocalTranscriptionModelName)
    }

    var selectedLocalModelDisplayName: String {
        LocalTranscriptionModel.displayName(for: selectedLocalModelName)
    }

    var selectedLocalModelName: String {
        LocalTranscriptionService.normalizedModelName(appSettings.selectedLocalTranscriptionModelName)
    }

    var selectedLocalModelIsInstalled: Bool {
        LocalTranscriptionService.isModelInstalled(selectedLocalModelName)
    }

    var isDownloadingLocalModel: Bool {
        localModelDownloadProgress != nil
    }

    var localModelDownloadButtonTitle: String {
        selectedLocalModelIsInstalled
            ? "\(LocalTranscriptionModel.displayName(for: selectedLocalModelName)) ist installiert"
            : "\(LocalTranscriptionModel.displayName(for: selectedLocalModelName)) installieren"
    }

    // MARK: - Workflow Management

    func startWorkflow(_ type: WorkflowType, source: WorkflowLaunchSource = .manual) {
        guard isWorkflowAvailable(type) else {
            if source == .manual {
                page = .settings
            }
            return
        }

        activeWorkflow?.stop()
        menuBarStatusResetTask?.cancel()
        workflowCleanupTask?.cancel()
        autoPasteSucceeded = false
        autoPasteStatusText = nil
        autoPasteStatusIsVisible = false
        activeLaunchSource = source
        activePasteTarget = capturePasteTarget(for: source)

        switch type {
        case .transcription:
            let workflow = TranscriptionWorkflow(
                customTerms: textImprovementSettings.customTerms,
                language: transcriptionSettings.language,
                backend: appSettings.secureLocalModeEnabled ? .local : .remote,
                localModelName: selectedLocalModelName
            )
            configureWorkflowHandlers(workflow)
            activeWorkflow = workflow
            workflow.start()

        case .localTranscription:
            let workflow = TranscriptionWorkflow(
                type: .localTranscription,
                customTerms: textImprovementSettings.customTerms,
                language: transcriptionSettings.language,
                backend: .local,
                localModelName: selectedLocalModelName
            )
            configureWorkflowHandlers(workflow)
            activeWorkflow = workflow
            workflow.start()

        case .textImprover:
            let workflow = TextImprovementWorkflow(
                settings: textImprovementSettings,
                language: transcriptionSettings.language
            )
            configureWorkflowHandlers(workflow)
            activeWorkflow = workflow
            workflow.start()

        case .dampfAblassen:
            let workflow = DampfAblassenWorkflow(
                settings: dampfAblassenSettings,
                customTerms: textImprovementSettings.customTerms,
                language: transcriptionSettings.language
            )
            configureWorkflowHandlers(workflow)
            activeWorkflow = workflow
            workflow.start()

        case .emojiText:
            let workflow = EmojiTextWorkflow(
                settings: emojiTextSettings,
                customTerms: textImprovementSettings.customTerms,
                language: transcriptionSettings.language
            )
            configureWorkflowHandlers(workflow)
            activeWorkflow = workflow
            workflow.start()
        }

        page = source.presentsWorkflowPage ? .workflow : .main
        notifyRecordingOverlayStateChanged()
    }

    func isWorkflowAvailable(_ type: WorkflowType) -> Bool {
        switch type {
        case .localTranscription:
            return selectedLocalModelIsInstalled
        case .transcription:
            return appSettings.secureLocalModeEnabled
                ? selectedLocalModelIsInstalled
                : KeychainService.isConfigured
        case .textImprover, .dampfAblassen, .emojiText:
            return !appSettings.secureLocalModeEnabled && KeychainService.isConfigured
        }
    }

    func stopCurrentWorkflow() {
        activeWorkflow?.stop()
    }

    func resetCurrentWorkflow() {
        activeWorkflow?.reset()
        activeWorkflow = nil
        activePasteTarget = nil
        activeLaunchSource = .manual
        menuBarStatusResetTask?.cancel()
        workflowCleanupTask?.cancel()
        menuBarStatus = .idle
        page = .main
        notifyRecordingOverlayStateChanged()
    }

    func enableSecureLocalMode() {
        appSettings.secureLocalModeEnabled = true
        if !selectedLocalModelIsInstalled {
            installSelectedLocalModel()
        }
    }

    func installSelectedLocalModel() {
        guard !isDownloadingLocalModel else { return }

        let modelName = selectedLocalModelName
        localModelDownloadProgress = 0
        localModelDownloadStatusText = "Download startet..."
        localModelDownloadErrorText = nil

        Task {
            do {
                let installedURL = try await LocalTranscriptionService.shared.downloadAndInstall(
                    modelName: modelName
                ) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let clampedProgress = min(max(progress, 0), 1)
                        self.localModelDownloadProgress = clampedProgress
                        self.localModelDownloadStatusText = "Download \(Int(clampedProgress * 100)) %"
                    }
                }

                appSettings.selectedLocalTranscriptionModelName = installedURL.lastPathComponent
                appSettings.secureLocalModeEnabled = true
                localModelDownloadProgress = nil
                localModelDownloadStatusText = "\(LocalTranscriptionModel.displayName(for: modelName)) ist installiert."
                localModelDownloadErrorText = nil

                try? await LocalTranscriptionService.shared.prepare(modelName: modelName)
            } catch {
                localModelDownloadProgress = nil
                localModelDownloadStatusText = nil
                localModelDownloadErrorText = error.localizedDescription
            }
        }
    }

    func copyToClipboard(_ text: String) {
        writeSensitiveTextToPasteboard(text)
    }

    func testAutoPaste() {
        let testText = "Blitztext Test"
        pasteAtCursor(testText, target: lastPopoverPasteTarget)
        scheduleWorkflowCleanup(after: 2.5)
    }

    // MARK: - Auto-Paste

    /// Restores focus, inserts through Accessibility when possible, then falls back to clipboard Cmd+V.
    /// The text intentionally remains on the clipboard if the fallback path is needed.
    private func pasteAtCursor(_ text: String, target: PasteTarget? = nil) {
        autoPasteSucceeded = false
        autoPasteStatusText = nil
        autoPasteStatusIsVisible = false

        let trusted = AccessibilityPermissionService.isTrusted(promptIfNeeded: true)
        accessibilityPermissionGranted = trusted
        Self.autoPasteLogger.info("Output ready. trusted=\(trusted) target=\(target?.diagnosticName ?? "nil", privacy: .public) popoverShown=\(self.isPopoverShown)")
        guard trusted else {
            writeSensitiveTextToPasteboard(text)
            markAutoPasteFallback("Nicht automatisch eingefügt. Text wurde kopiert, aber Bedienungshilfen sind für diese App-Version nicht freigegeben.")
            menuBarStatus = .error(activeWorkflow?.type)
            return
        }

        guard let target else {
            writeSensitiveTextToPasteboard(text)
            markAutoPasteFallback("Nicht automatisch eingefügt. Text wurde kopiert, aber es wurde kein Ziel-App-Fenster erkannt.")
            return
        }

        if isPopoverShown {
            NotificationCenter.default.post(name: .dismissPopover, object: nil)
        }

        attemptPasteTrusted(
            text: text,
            target: target,
            attemptsRemaining: Self.pasteRetryInitialAttempts
        )
    }

    private func writeSensitiveTextToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general

        pasteboard.clearContents()
        pasteboard.declareTypes([.string, Self.concealedPasteboardType], owner: nil)
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("", forType: Self.concealedPasteboardType)
    }

    func prepareForPopoverPresentation() {
        lastPopoverPasteTarget = captureCurrentFrontmostApp()
        if let activeWorkflow, activeWorkflow.phase.isActive {
            page = .workflow
        } else if shouldShowOnboarding {
            page = .onboarding
            markOnboardingSeen()
        } else if page == .workflow {
            page = .main
        } else if page == .onboarding {
            page = .main
        }
    }

    func markOnboardingSeen() {
        guard !appSettings.hasSeenOnboarding else { return }
        appSettings.hasSeenOnboarding = true
    }

    // MARK: - API Key Status

    func apiKeyDisplayValue(for key: KeychainKey) -> String {
        guard let value = KeychainService.load(key: key), !value.isEmpty else {
            return ""
        }
        if value.count > 8 {
            return String(value.prefix(4)) + " \u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}"
        }
        return "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}"
    }

    func hasValue(for key: KeychainKey) -> Bool {
        guard let value = KeychainService.load(key: key) else { return false }
        return !value.isEmpty
    }

    // MARK: - Settings Persistence

    private static let settingsURL: URL = {
        try? AppSupportPaths.ensureAppSupportDirectoryExists()
        return AppSupportPaths.settingsURL
    }()

    private func saveSettings() {
        let container = SettingsContainer(
            app: appSettings,
            transcription: transcriptionSettings,
            textImprovement: textImprovementSettings,
            dampfAblassen: dampfAblassenSettings,
            emojiText: emojiTextSettings
        )
        if let data = try? JSONEncoder().encode(container) {
            try? data.write(to: Self.settingsURL)
        }
    }

    private static func loadAppSettings() -> AppSettings {
        loadContainer()?.app ?? AppSettings()
    }

    private static func loadTranscriptionSettings() -> TranscriptionSettings {
        loadContainer()?.transcription ?? TranscriptionSettings()
    }

    private static func loadTextImprovementSettings() -> TextImprovementSettings {
        loadContainer()?.textImprovement ?? TextImprovementSettings()
    }

    private static func loadDampfAblassenSettings() -> DampfAblassenSettings {
        loadContainer()?.dampfAblassen ?? DampfAblassenSettings()
    }

    private static func loadEmojiTextSettings() -> EmojiTextSettings {
        loadContainer()?.emojiText ?? EmojiTextSettings()
    }

    private static func loadContainer() -> SettingsContainer? {
        guard let data = try? Data(contentsOf: settingsURL) else { return nil }
        return try? JSONDecoder().decode(SettingsContainer.self, from: data)
    }

    func refreshAccessibilityPermission() {
        accessibilityPermissionGranted = AccessibilityPermissionService.currentStatus()
    }

    func requestAccessibilityPermission() {
        accessibilityPermissionGranted = AccessibilityPermissionService.requestPermissionPrompt()
        AccessibilityPermissionService.openSystemSettings()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshAccessibilityPermission()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.refreshAccessibilityPermission()
        }
    }

    private func autoSelectFastLocalModelIfNeeded() {
        guard !appSettings.hasAutoSelectedFastLocalModel,
              LocalTranscriptionService.shouldAutoSelectRecommendedFastModel(
                currentModelName: appSettings.selectedLocalTranscriptionModelName
              ) else {
            return
        }

        appSettings.selectedLocalTranscriptionModelName = LocalTranscriptionService.recommendedFastModelName
        appSettings.hasAutoSelectedFastLocalModel = true
    }

    private func prewarmLocalTranscriptionIfNeeded() {
        guard appSettings.secureLocalModeEnabled,
              LocalTranscriptionService.isModelInstalled(resolvedLocalModelName) else {
            return
        }

        let modelName = resolvedLocalModelName
        Task.detached(priority: .utility) {
            try? await LocalTranscriptionService.shared.prepare(modelName: modelName)
        }
    }

    private func handleWorkflowOutput(_ text: String) {
        pasteAtCursor(text, target: activePasteTarget)
        if activeLaunchSource == .hotkeyBackground {
            page = .main
        }
        scheduleWorkflowCleanup(after: 2.5)
    }

    private func configureWorkflowHandlers<T: Workflow>(_ workflow: T) {
        workflow.onOutput = { [weak self] text in
            self?.handleWorkflowOutput(text)
        }
        workflow.onPhaseChange = { [weak self, weak workflow] phase in
            guard let self, let workflow else { return }
            self.handleWorkflowPhaseChange(phase, workflow: workflow)
        }
    }

    private func handleWorkflowPhaseChange(_ phase: WorkflowPhase, workflow: any Workflow) {
        menuBarStatusResetTask?.cancel()

        switch phase {
        case .idle:
            if activeWorkflow == nil {
                menuBarStatus = .idle
            }

        case .running:
            menuBarStatus = workflow.isRecording
                ? .recording(workflow.type)
                : .processing(workflow.type)

        case .done:
            menuBarStatus = .success(workflow.type)

        case .error:
            menuBarStatus = .error(workflow.type)
            if activeLaunchSource == .hotkeyBackground {
                activeWorkflow = nil
                activePasteTarget = nil
                page = .main
            }
            scheduleMenuBarStatusReset(after: 1.6)
        }

        notifyRecordingOverlayStateChanged()
    }

    private func scheduleWorkflowCleanup(after delay: TimeInterval) {
        guard let workflow = activeWorkflow else { return }

        workflowCleanupTask?.cancel()
        let workflowID = ObjectIdentifier(workflow)

        workflowCleanupTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, let activeWorkflow = self.activeWorkflow else { return }
            guard ObjectIdentifier(activeWorkflow) == workflowID else { return }

            activeWorkflow.reset()
            self.activeWorkflow = nil
            self.activePasteTarget = nil
            self.activeLaunchSource = .manual
            if !self.isPopoverShown {
                self.page = .main
            }
            self.menuBarStatus = .idle
            self.notifyRecordingOverlayStateChanged()
        }
    }

    private func scheduleMenuBarStatusReset(after delay: TimeInterval) {
        menuBarStatusResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            if self.activeWorkflow == nil || !(self.activeWorkflow?.phase.isActive ?? false) {
                self.menuBarStatus = .idle
            }
        }
    }

    private func notifyRecordingOverlayStateChanged() {
        onRecordingOverlayStateChange?(recordingOverlayState)
    }

    private func capturePasteTarget(for source: WorkflowLaunchSource) -> PasteTarget? {
        switch source {
        case .manual:
            return lastPopoverPasteTarget
        case .hotkeyBackground:
            return captureCurrentFrontmostApp()
        }
    }

    private func attemptPasteTrusted(
        text: String,
        target: PasteTarget,
        attemptsRemaining: Int
    ) {
        let frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier

        if frontmostPid == target.processIdentifier {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
                self?.performPaste(text: text, target: target)
            }
            return
        }

        if attemptsRemaining == Self.pasteRetryInitialAttempts {
            Self.autoPasteLogger.info("Activating target app for paste: \(target.diagnosticName, privacy: .public)")
        }
        target.application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])

        guard attemptsRemaining > 0 else {
            Self.autoPasteLogger.error("Target activation timed out: \(target.diagnosticName, privacy: .public)")
            writeSensitiveTextToPasteboard(text)
            markAutoPasteFallback("Nicht automatisch eingefügt. Text wurde kopiert, aber \(target.displayName) konnte nicht aktiviert werden.")
            menuBarStatus = .error(activeWorkflow?.type)
            return
        }

        let delay: TimeInterval
        switch attemptsRemaining {
        case 45...:
            delay = 0.025
        case 20...44:
            delay = 0.04
        default:
            delay = 0.075
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.attemptPasteTrusted(
                text: text,
                target: target,
                attemptsRemaining: attemptsRemaining - 1
            )
        }
    }

    private func performPaste(text: String, target: PasteTarget) {
        let frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard frontmostPid == target.processIdentifier else {
            Self.autoPasteLogger.error("Paste cancelled because focus changed before Cmd+V. expected=\(target.processIdentifier) actual=\(frontmostPid ?? -1)")
            writeSensitiveTextToPasteboard(text)
            markAutoPasteFallback("Nicht automatisch eingefügt. Text wurde kopiert, aber der Fokus wechselte vor dem Einfügen.")
            menuBarStatus = .error(activeWorkflow?.type)
            return
        }

        switch AutoPasteService.pasteWithTemporaryClipboard(
            text,
            targetProcessIdentifier: target.processIdentifier
        ) {
        case .pasteCommandDispatched(let method):
            autoPasteSucceeded = true
            autoPasteStatusText = "Einfügen ausgelöst"
            autoPasteStatusIsVisible = true
            Self.autoPasteLogger.info("Paste command dispatched. method=\(method.rawValue, privacy: .public) target=\(target.diagnosticName, privacy: .public)")

        case .copiedOnly:
            markAutoPasteFallback("Einfügen konnte nicht ausgelöst werden. Text bleibt kopiert.")
            menuBarStatus = .error(activeWorkflow?.type)

        case .failedToCopy:
            markAutoPasteFallback("Nicht automatisch eingefügt. Text konnte nicht in die Zwischenablage kopiert werden.")
            menuBarStatus = .error(activeWorkflow?.type)
        }
    }

    private func markAutoPasteFallback(_ message: String) {
        autoPasteSucceeded = false
        autoPasteStatusText = message
        autoPasteStatusIsVisible = true
        Self.autoPasteLogger.error("\(message, privacy: .public)")
    }

    private func captureCurrentFrontmostApp() -> PasteTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }

        let ownPid = NSRunningApplication.current.processIdentifier
        guard app.processIdentifier != ownPid else { return nil }

        return PasteTarget(
            bundleIdentifier: app.bundleIdentifier,
            localizedName: app.localizedName,
            processIdentifier: app.processIdentifier,
            application: app,
            targetScreenFrame: screenFrameForFrontmostWindow(of: app)
        )
    }

    private func screenFrameForFrontmostWindow(of app: NSRunningApplication) -> CGRect? {
        guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else {
            return nil
        }

        for window in windowInfo {
            guard let ownerPid = window[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPid == app.processIdentifier,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let boundsDictionary = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  !bounds.isEmpty,
                  let screen = screen(containingCGWindowBounds: bounds) else {
                continue
            }

            return screen.frame
        }

        return nil
    }

    private func screen(containingCGWindowBounds bounds: CGRect) -> NSScreen? {
        let candidates = NSScreen.screens.map { screen in
            let intersection = cgRect(fromAppKitScreenFrame: screen.frame).intersection(bounds)
            return (screen: screen, area: intersection.area)
        }

        guard let best = candidates.max(by: { $0.area < $1.area }),
              best.area > 0 else {
            return nil
        }

        return best.screen
    }

    private func cgRect(fromAppKitScreenFrame frame: CGRect) -> CGRect {
        guard let primaryScreenHeight = NSScreen.screens.first?.frame.height else {
            return frame
        }

        return CGRect(
            x: frame.origin.x,
            y: primaryScreenHeight - frame.origin.y - frame.height,
            width: frame.width,
            height: frame.height
        )
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
    }
}

private struct SettingsContainer: Codable {
    var app: AppSettings?
    var transcription: TranscriptionSettings
    var textImprovement: TextImprovementSettings
    var dampfAblassen: DampfAblassenSettings?
    var emojiText: EmojiTextSettings?
}

// MARK: - Notification for Popover Dismissal

extension Notification.Name {
    static let dismissPopover = Notification.Name("dismissPopover")
}

private struct PasteTarget {
    let bundleIdentifier: String?
    let localizedName: String?
    let processIdentifier: pid_t
    let application: NSRunningApplication
    let targetScreenFrame: CGRect?

    var displayName: String {
        localizedName ?? bundleIdentifier ?? "Die Ziel-App"
    }

    var diagnosticName: String {
        "\(displayName) pid=\(processIdentifier)"
    }
}
