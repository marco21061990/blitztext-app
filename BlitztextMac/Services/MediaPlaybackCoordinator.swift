import Foundation
import AppKit
import ApplicationServices
import os

protocol MediaPlaybackAdapter: AnyObject {
    var provider: MediaPlaybackProvider { get }

    func inspect() -> MediaPlaybackSnapshot
    func pause(expectedSourceIdentifier: String, before deadline: Date) -> MediaPlaybackSnapshot?
    func resume(expectedSourceIdentifier: String) -> MediaPlaybackSnapshot?
}

final class MediaPlaybackCoordinator {
    static let recordingPreparationBudget: TimeInterval = 0.5
    private static let monitorInterval: TimeInterval = 0.2

    private let adapters: [any MediaPlaybackAdapter]
    private let controlQueue = DispatchQueue(
        label: "app.blitztext.mac.media-playback",
        qos: .userInitiated
    )
    private let timerQueue = DispatchQueue(
        label: "app.blitztext.mac.media-playback-timers",
        qos: .utility
    )
    private let stateLock = NSLock()
    private let logger = Logger(subsystem: "app.blitztext.mac", category: "MediaPlayback")
    private let frontmostBundleIdentifier: () -> String?

    private var pendingPreparation: PendingPreparation?
    private var activeSession: ActiveSession?

    init(
        adapters: [any MediaPlaybackAdapter] = [
            SpotifyMediaPlaybackAdapter(),
            ChromeYouTubeMediaPlaybackAdapter()
        ],
        frontmostBundleIdentifier: @escaping () -> String? = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
    ) {
        self.adapters = adapters
        self.frontmostBundleIdentifier = frontmostBundleIdentifier
    }

    /// Prepares media control off the main thread and always releases the
    /// recording start after the fixed budget, even if a player call stalls.
    func prepareForRecording(
        enabled: Bool,
        completion: @escaping (MediaPlaybackSessionHandle?) -> Void
    ) {
        guard enabled else {
            DispatchQueue.main.async {
                completion(nil)
            }
            return
        }

        let requestID = UUID()
        let startedAt = Date()
        let pending = PendingPreparation(requestID: requestID, completion: completion)

        withStateLock {
            self.pendingPreparation = pending
        }

        controlQueue.async { [weak self] in
            self?.performPreparation(requestID: requestID, startedAt: startedAt)
        }
        timerQueue.asyncAfter(deadline: .now() + Self.recordingPreparationBudget) { [weak self] in
            self?.timeoutPreparation(requestID: requestID)
        }
        timerQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.discardExpiredPreparation(requestID: requestID)
        }
    }

    /// Cancels only a preparation that has not yet produced a session. A
    /// confirmed pause is restored separately through finish methods.
    func cancelPendingPreparation() {
        withStateLock {
            pendingPreparation = nil
        }
    }

    func finish(_ handle: MediaPlaybackSessionHandle, outcome: MediaPlaybackOutcome) {
        controlQueue.async { [weak self] in
            self?.finishOnControlQueue(handle, outcome: outcome)
        }
    }

    func finishActiveSession(outcome: MediaPlaybackOutcome) {
        controlQueue.async { [weak self] in
            guard let self,
                  let handle = self.withStateLock({ self.activeSession?.handle }) else {
                return
            }
            self.finishOnControlQueue(handle, outcome: outcome)
        }
    }

    private func performPreparation(requestID: UUID, startedAt: Date) {
        let deadline = startedAt.addingTimeInterval(Self.recordingPreparationBudget)

        guard isPending(requestID: requestID) else { return }
        finishAnyActiveSessionOnControlQueue()

        guard let candidate = selectCandidate(before: deadline) else {
            completeWithoutSession(requestID: requestID)
            return
        }

        guard isPending(requestID: requestID) else { return }

        guard Date() < deadline, candidate.snapshot.state == .playing,
              let sourceIdentifier = candidate.snapshot.sourceIdentifier else {
            completeWithoutSession(requestID: requestID)
            return
        }

        var stateMachine = MediaPlaybackSessionStateMachine()
        guard let handle = stateMachine.begin(
            sourceIdentifier: sourceIdentifier,
            initialState: candidate.snapshot.state
        ) else {
            completeWithoutSession(requestID: requestID)
            return
        }

        guard Date() < deadline, isPending(requestID: requestID) else {
            completeWithoutSession(requestID: requestID)
            return
        }

        guard let pausedSnapshot = candidate.adapter.pause(
            expectedSourceIdentifier: sourceIdentifier,
            before: deadline
        ) else {
            logger.info("Media pause was not confirmed; continuing without ownership")
            completeWithoutSession(requestID: requestID)
            return
        }

        guard pausedSnapshot.sourceIdentifier == sourceIdentifier,
              pausedSnapshot.state == .paused,
              stateMachine.confirmPause(
                  handle,
                  sourceIdentifier: sourceIdentifier,
                  observedState: pausedSnapshot.state
              ) else {
            logger.info("Media pause was not confirmed; continuing without ownership")
            completeWithoutSession(requestID: requestID)
            return
        }

        let prepared = ActiveSession(
            handle: handle,
            adapter: candidate.adapter,
            stateMachine: stateMachine,
            outcome: nil
        )

        guard Date() < deadline else {
            // A player call may have started before the deadline but return
            // after it. Do not adopt a late pause for the recording; restore
            // the confirmed side effect immediately and continue fail-open.
            logger.info("Media pause completed after the 500 ms budget; restoring immediately")
            restorePreparedSession(prepared)
            completeWithoutSession(requestID: requestID)
            return
        }

        let completion: ((MediaPlaybackSessionHandle?) -> Void)? = withStateLock {
            guard let pending = pendingPreparation, pending.requestID == requestID else {
                return nil
            }
            activeSession = prepared
            pendingPreparation = nil
            return pending.completion
        }

        guard let completion else {
            // The request was cancelled while the player operation was in
            // flight. Resume only after re-checking the same owned source.
            restorePreparedSession(prepared)
            return
        }

        logger.info("Media pause confirmed provider=\(candidate.snapshot.provider.rawValue, privacy: .public)")
        deliver(completion, value: handle)
        scheduleMonitoring(for: prepared)
    }

    private func selectCandidate(before deadline: Date) -> (adapter: any MediaPlaybackAdapter, snapshot: MediaPlaybackSnapshot)? {
        var snapshots: [(adapter: any MediaPlaybackAdapter, snapshot: MediaPlaybackSnapshot)] = []

        for adapter in adapters {
            guard Date() < deadline else { break }
            snapshots.append((adapter, adapter.inspect()))
        }

        guard !snapshots.isEmpty else { return nil }

        if let frontmostProvider = provider(for: frontmostBundleIdentifier()) {
            guard let frontmost = snapshots.first(where: { $0.snapshot.provider == frontmostProvider }) else {
                return nil
            }

            // When a supported app is frontmost but its active tab/player is
            // paused, stopped, unsupported, or unreadable, never reach into a
            // different background player.
            guard frontmost.snapshot.state == .playing else { return nil }
            return frontmost
        }

        let playing = snapshots.filter { $0.snapshot.state == .playing }
        guard playing.count == 1 else {
            // Multiple playing sources are ambiguous; fail open instead of
            // pausing a source that may not be the one the user hears.
            return nil
        }
        return playing[0]
    }

    private func provider(for bundleIdentifier: String?) -> MediaPlaybackProvider? {
        switch bundleIdentifier {
        case "com.spotify.client":
            return .spotify
        case "com.google.Chrome":
            return .youtubeChrome
        default:
            return nil
        }
    }

    private func timeoutPreparation(requestID: UUID) {
        let completion: ((MediaPlaybackSessionHandle?) -> Void)? = withStateLock {
            guard let pending = pendingPreparation,
                  pending.requestID == requestID,
                  !pending.completionDelivered else {
                return nil
            }
            pending.completionDelivered = true
            return pending.completion
        }

        guard let completion else { return }
        logger.info("Media preparation reached the 500 ms budget; recording continues")
        deliver(completion, value: nil)
    }

    private func discardExpiredPreparation(requestID: UUID) {
        withStateLock {
            guard pendingPreparation?.requestID == requestID else { return }
            pendingPreparation = nil
        }
    }

    private func completeWithoutSession(requestID: UUID) {
        let completion: ((MediaPlaybackSessionHandle?) -> Void)? = withStateLock {
            guard let pending = pendingPreparation, pending.requestID == requestID else {
                return nil
            }
            pendingPreparation = nil
            guard !pending.completionDelivered else { return nil }
            pending.completionDelivered = true
            return pending.completion
        }

        if let completion {
            deliver(completion, value: nil)
        }
    }

    private func isPending(requestID: UUID) -> Bool {
        withStateLock {
            pendingPreparation?.requestID == requestID
        }
    }

    private func finishAnyActiveSessionOnControlQueue() {
        guard let handle = withStateLock({ activeSession?.handle }) else { return }
        finishOnControlQueue(handle, outcome: .cancelled)
    }

    private func finishOnControlQueue(_ handle: MediaPlaybackSessionHandle, outcome: MediaPlaybackOutcome) {
        let active: ActiveSession? = withStateLock {
            guard let activeSession,
                  activeSession.handle == handle,
                  !activeSession.isFinishing else {
                return nil
            }
            activeSession.isFinishing = true
            activeSession.outcome = outcome
            return activeSession
        }

        guard let active else { return }
        restorePreparedSession(active)

        withStateLock {
            if self.activeSession === active {
                self.activeSession = nil
            }
        }
    }

    private func restorePreparedSession(_ active: ActiveSession) {
        let current = active.adapter.inspect()
        let currentSourceIdentifier = current.sourceIdentifier ?? ""
        let shouldRestore: Bool = withStateLock {
            active.stateMachine.shouldRestore(
                active.handle,
                sourceIdentifier: currentSourceIdentifier,
                currentState: current.state
            )
        }

        guard shouldRestore else {
            logger.info("Media restore skipped provider=\(active.adapter.provider.rawValue, privacy: .public) state=\(current.state.logValue, privacy: .public)")
            return
        }

        let restored = active.adapter.resume(expectedSourceIdentifier: active.handleSourceIdentifier)
        let resultingState = restored?.state ?? .unknown
        if resultingState == .playing {
            logger.info("Media restored provider=\(active.adapter.provider.rawValue, privacy: .public)")
        } else {
            logger.error("Media restore was not confirmed provider=\(active.adapter.provider.rawValue, privacy: .public) state=\(resultingState.logValue, privacy: .public)")
        }
    }

    private func scheduleMonitoring(for active: ActiveSession) {
        controlQueue.asyncAfter(deadline: .now() + Self.monitorInterval) { [weak self, weak active] in
            guard let self, let active else { return }
            self.observe(active)
        }
    }

    private func observe(_ active: ActiveSession) {
        let shouldObserve: Bool = withStateLock {
            self.activeSession === active && !active.isFinishing
        }
        guard shouldObserve else { return }

        let snapshot = active.adapter.inspect()
        let shouldContinue: Bool = withStateLock {
            guard self.activeSession === active, !active.isFinishing else { return false }
            active.stateMachine.observe(
                active.handle,
                sourceIdentifier: snapshot.sourceIdentifier ?? "",
                state: snapshot.state
            )
            return true
        }

        if shouldContinue {
            scheduleMonitoring(for: active)
        }
    }

    private func deliver(_ completion: @escaping (MediaPlaybackSessionHandle?) -> Void, value: MediaPlaybackSessionHandle?) {
        DispatchQueue.main.async {
            completion(value)
        }
    }

    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    private final class PendingPreparation {
        let requestID: UUID
        let completion: (MediaPlaybackSessionHandle?) -> Void
        var completionDelivered = false

        init(requestID: UUID, completion: @escaping (MediaPlaybackSessionHandle?) -> Void) {
            self.requestID = requestID
            self.completion = completion
        }
    }

    private final class ActiveSession {
        let handle: MediaPlaybackSessionHandle
        let adapter: any MediaPlaybackAdapter
        var stateMachine: MediaPlaybackSessionStateMachine
        var isFinishing = false
        var outcome: MediaPlaybackOutcome?

        var handleSourceIdentifier: String {
            stateMachine.session?.sourceIdentifier ?? ""
        }

        init(
            handle: MediaPlaybackSessionHandle,
            adapter: any MediaPlaybackAdapter,
            stateMachine: MediaPlaybackSessionStateMachine,
            outcome: MediaPlaybackOutcome?
        ) {
            self.handle = handle
            self.adapter = adapter
            self.stateMachine = stateMachine
            self.outcome = outcome
        }
    }
}

private extension MediaPlaybackState {
    var logValue: String {
        switch self {
        case .playing: return "playing"
        case .paused: return "paused"
        case .stopped: return "stopped"
        case .unknown: return "unknown"
        }
    }
}

final class SpotifyMediaPlaybackAdapter: MediaPlaybackAdapter {
    let provider: MediaPlaybackProvider = .spotify
    private let logger = Logger(subsystem: "app.blitztext.mac", category: "MediaPlayback.Spotify")

    func inspect() -> MediaPlaybackSnapshot {
        guard isRunning else {
            return snapshot(sourceIdentifier: nil, state: .unknown)
        }

        let script = """
        tell application id "com.spotify.client"
            set playbackState to player state as text
            set trackIdentifier to ""
            try
                set trackIdentifier to id of current track as text
            end try
            return playbackState & linefeed & trackIdentifier
        end tell
        """

        guard let output = execute(script) else {
            return snapshot(sourceIdentifier: nil, state: .unknown)
        }

        let components = output.components(separatedBy: .newlines)
        let state = Self.state(from: components.first?.trimmingCharacters(in: .whitespacesAndNewlines))
        let trackIdentifier = components.dropFirst().joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceIdentifier = trackIdentifier.isEmpty ? nil : "spotify:\(trackIdentifier)"
        return snapshot(sourceIdentifier: sourceIdentifier, state: state)
    }

    func pause(expectedSourceIdentifier: String, before deadline: Date) -> MediaPlaybackSnapshot? {
        guard Date() < deadline else { return nil }
        let current = inspect()
        guard Date() < deadline,
              current.sourceIdentifier == expectedSourceIdentifier,
              current.state == .playing,
              executeCommand("tell application id \"com.spotify.client\" to pause") else {
            return current
        }
        return inspect()
    }

    func resume(expectedSourceIdentifier: String) -> MediaPlaybackSnapshot? {
        let current = inspect()
        guard current.sourceIdentifier == expectedSourceIdentifier,
              current.state == .paused,
              executeCommand("tell application id \"com.spotify.client\" to play") else {
            return current
        }
        return inspect()
    }

    private var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty
    }

    private func snapshot(sourceIdentifier: String?, state: MediaPlaybackState) -> MediaPlaybackSnapshot {
        MediaPlaybackSnapshot(provider: provider, sourceIdentifier: sourceIdentifier, state: state)
    }

    private func execute(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if error != nil {
            logger.info("Spotify Apple Events inspection unavailable")
            return nil
        }
        return result.stringValue
    }

    private func executeCommand(_ source: String) -> Bool {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        _ = script.executeAndReturnError(&error)
        if error != nil {
            logger.info("Spotify Apple Events command unavailable")
            return false
        }
        return true
    }

    private static func state(from value: String?) -> MediaPlaybackState {
        switch value?.lowercased() {
        case "playing": return .playing
        case "paused": return .paused
        case "stopped": return .stopped
        default: return .unknown
        }
    }
}

final class ChromeYouTubeMediaPlaybackAdapter: MediaPlaybackAdapter {
    let provider: MediaPlaybackProvider = .youtubeChrome
    private let logger = Logger(subsystem: "app.blitztext.mac", category: "MediaPlayback.Chrome")

    func inspect() -> MediaPlaybackSnapshot {
        guard let located = locateControl() else {
            return snapshot(sourceIdentifier: nil, state: .unknown)
        }
        return located.snapshot
    }

    func pause(expectedSourceIdentifier: String, before deadline: Date) -> MediaPlaybackSnapshot? {
        guard Date() < deadline,
              let located = locateControl(),
              located.snapshot.sourceIdentifier == expectedSourceIdentifier,
              located.snapshot.state == .playing,
              Date() < deadline,
              press(located.actionButton) else {
            return locateControl()?.snapshot
        }
        return inspect()
    }

    func resume(expectedSourceIdentifier: String) -> MediaPlaybackSnapshot? {
        guard let located = locateControl(),
              located.snapshot.sourceIdentifier == expectedSourceIdentifier,
              located.snapshot.state == .paused,
              press(located.actionButton) else {
            return locateControl()?.snapshot
        }
        return inspect()
    }

    private func locateControl() -> LocatedControl? {
        guard AXIsProcessTrusted() else {
            if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").isEmpty {
                logger.info("Chrome YouTube Accessibility inspection unavailable")
            }
            return nil
        }
        guard let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome")
            .first else {
            return nil
        }

        let application = AXUIElementCreateApplication(chrome.processIdentifier)
        guard let window = focusedWindow(for: application) else { return nil }
        let players = findPlayers(
            in: window,
            inheritedURL: nil,
            processIdentifier: chrome.processIdentifier,
            depth: 0
        )
        guard players.count == 1, let player = players.first else { return nil }

        let pauseButton = findActionButton(in: player.element, intent: .pause, depth: 0)
        let playButton = findActionButton(in: player.element, intent: .play, depth: 0)
        guard !(pauseButton != nil && playButton != nil) else {
            // Both controls being exposed at once is ambiguous. Do not guess
            // which one represents the current player state.
            return nil
        }
        let state: MediaPlaybackState
        let actionButton: AXUIElement

        if let pauseButton {
            state = .playing
            actionButton = pauseButton
        } else if let playButton {
            state = .paused
            actionButton = playButton
        } else {
            return nil
        }

        return LocatedControl(
            snapshot: snapshot(sourceIdentifier: player.sourceIdentifier, state: state),
            actionButton: actionButton
        )
    }

    private func focusedWindow(for application: AXUIElement) -> AXUIElement? {
        guard let value = attributeValue(application, kAXFocusedWindowAttribute as CFString) else {
            return nil
        }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func findPlayers(
        in element: AXUIElement,
        inheritedURL: String?,
        processIdentifier: pid_t,
        depth: Int
    ) -> [LocatedPlayer] {
        guard depth < 32 else { return [] }

        let url = stringAttribute(element, kAXURLAttribute as CFString) ?? inheritedURL
        let identifier = stringAttribute(element, kAXIdentifierAttribute as CFString)
        let description = stringAttribute(element, kAXDescriptionAttribute as CFString)
        if identifier == "movie_player" || description?.localizedLowercase.contains("youtube-videoplayer") == true {
            guard let url, Self.isYouTubeURL(url) else { return [] }
            return [LocatedPlayer(
                element: element,
                sourceIdentifier: "chrome:\(processIdentifier):\(url)"
            )]
        }

        var players: [LocatedPlayer] = []
        for child in children(of: element) {
            players.append(contentsOf: findPlayers(
                in: child,
                inheritedURL: url,
                processIdentifier: processIdentifier,
                depth: depth + 1
            ))
            if players.count > 1 { break }
        }
        return players
    }

    private enum ActionIntent {
        case pause
        case play
    }

    private func findActionButton(
        in element: AXUIElement,
        intent: ActionIntent,
        depth: Int
    ) -> AXUIElement? {
        guard depth < 24 else { return nil }

        let role = stringAttribute(element, kAXRoleAttribute as CFString)?.lowercased() ?? ""
        if (role == "axbutton" || role == "button") && isUsableActionButton(element) {
            let label = [
                stringAttribute(element, kAXDescriptionAttribute as CFString),
                stringAttribute(element, kAXTitleAttribute as CFString),
                stringAttribute(element, kAXValueAttribute as CFString)
            ]
                .compactMap { $0 }
                .joined(separator: " ")
                .localizedLowercase

            switch intent {
            case .pause where Self.isPauseLabel(label):
                return element
            case .play where Self.isPlayLabel(label):
                return element
            default:
                break
            }
        }

        for child in children(of: element) {
            if let button = findActionButton(in: child, intent: intent, depth: depth + 1) {
                return button
            }
        }
        return nil
    }

    private func press(_ button: AXUIElement) -> Bool {
        let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
        if result != .success {
            logger.info("Chrome YouTube Accessibility action unavailable")
            return false
        }
        return true
    }

    private func isUsableActionButton(_ element: AXUIElement) -> Bool {
        if boolAttribute(element, kAXHiddenAttribute as CFString) == true {
            return false
        }
        if boolAttribute(element, kAXEnabledAttribute as CFString) == false {
            return false
        }
        return true
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        guard let value = attributeValue(element, kAXChildrenAttribute as CFString) else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        guard let value = attributeValue(element, attribute) else { return nil }
        if let string = value as? String { return string }
        if let url = value as? URL { return url.absoluteString }
        if let url = value as? NSURL { return url.absoluteString }
        return nil
    }

    private func attributeValue(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value
    }

    private func boolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
        guard let value = attributeValue(element, attribute) else { return nil }
        return value as? Bool
    }

    private func snapshot(sourceIdentifier: String?, state: MediaPlaybackState) -> MediaPlaybackSnapshot {
        MediaPlaybackSnapshot(provider: provider, sourceIdentifier: sourceIdentifier, state: state)
    }

    private struct LocatedPlayer {
        let element: AXUIElement
        let sourceIdentifier: String
    }

    private struct LocatedControl {
        let snapshot: MediaPlaybackSnapshot
        let actionButton: AXUIElement
    }

    private static func isYouTubeURL(_ value: String) -> Bool {
        let lowercased = value.localizedLowercase
        return lowercased.contains("youtube.com/") || lowercased.contains("youtu.be/")
    }

    private static func isPauseLabel(_ label: String) -> Bool {
        label.contains("pause") || label.contains("pausieren")
    }

    private static func isPlayLabel(_ label: String) -> Bool {
        guard !label.contains("autoplay") else { return false }
        return label == "play"
            || label.hasPrefix("play ")
            || label.contains("wiedergeben")
            || label.contains("wiedergabe")
            || label.contains("abspielen")
            || label.contains("fortsetzen")
    }
}
