import Foundation
import AppKit
import ApplicationServices
import os

protocol MediaPlaybackAdapter: AnyObject {
    var provider: MediaPlaybackProvider { get }

    func inspect() -> MediaPlaybackSnapshot
    func pause(expectedSourceIdentifier: String, before deadline: Date) -> MediaPlaybackSnapshot?
    func resume(expectedSourceIdentifier: String) -> MediaPlaybackSnapshot?

    func inspect(selectionContext: MediaPlaybackSelectionContext) -> MediaPlaybackSnapshot
    func pause(
        expectedSourceIdentifier: String,
        selectionContext: MediaPlaybackSelectionContext,
        before deadline: Date
    ) -> MediaPlaybackPauseResult
    func resume(
        expectedSourceIdentifier: String,
        selectionContext: MediaPlaybackSelectionContext
    ) -> MediaPlaybackSnapshot?
}

extension MediaPlaybackAdapter {
    func inspect(selectionContext: MediaPlaybackSelectionContext) -> MediaPlaybackSnapshot {
        inspect()
    }

    func pause(
        expectedSourceIdentifier: String,
        selectionContext: MediaPlaybackSelectionContext,
        before deadline: Date
    ) -> MediaPlaybackPauseResult {
        guard let snapshot = pause(expectedSourceIdentifier: expectedSourceIdentifier, before: deadline) else {
            return .issuedUnconfirmed(snapshot: nil, reason: "no_confirmation")
        }
        return .confirmed(snapshot)
    }

    func resume(
        expectedSourceIdentifier: String,
        selectionContext: MediaPlaybackSelectionContext
    ) -> MediaPlaybackSnapshot? {
        resume(expectedSourceIdentifier: expectedSourceIdentifier)
    }
}

final class MediaPlaybackCoordinator {
    static let recordingPreparationBudget = MediaPlaybackTiming.preparationBudget
    private static let monitorInterval: TimeInterval = 0.2

    private let adapters: [any MediaPlaybackAdapter]
    private let inspectionQueue = DispatchQueue(
        label: "app.blitztext.mac.media-playback-inspections",
        qos: .userInitiated,
        attributes: .concurrent
    )
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

    var onStatusChange: ((MediaPlaybackStatus) -> Void)?

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
        selectionContext: MediaPlaybackSelectionContext? = nil,
        completion: @escaping (MediaPlaybackSessionHandle?) -> Void
    ) {
        guard enabled else {
            DispatchQueue.main.async {
                completion(nil)
            }
            return
        }

        notifyStatus(.preparing)

        let requestID = UUID()
        let startedAt = Date()
        let selectionContext = selectionContext ?? captureSelectionContext(trigger: "coordinator")
        let pending = PendingPreparation(requestID: requestID, completion: completion)

        withStateLock {
            self.pendingPreparation = pending
        }

        controlQueue.async { [weak self] in
            self?.performPreparation(
                requestID: requestID,
                startedAt: startedAt,
                selectionContext: selectionContext
            )
        }
        timerQueue.asyncAfter(deadline: .now() + Self.recordingPreparationBudget) { [weak self] in
            self?.timeoutPreparation(requestID: requestID)
        }
        timerQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.discardExpiredPreparation(requestID: requestID)
        }
    }

    func captureSelectionContext(trigger: String) -> MediaPlaybackSelectionContext {
        MediaPlaybackSelectionContext(
            frontmostBundleIdentifier: frontmostBundleIdentifier(),
            trigger: trigger
        )
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

    private func performPreparation(
        requestID: UUID,
        startedAt: Date,
        selectionContext: MediaPlaybackSelectionContext
    ) {
        let deadline = startedAt.addingTimeInterval(Self.recordingPreparationBudget)

        guard isPending(requestID: requestID) else { return }
        finishAnyActiveSessionOnControlQueue()

        guard let candidates = selectCandidates(
            before: deadline,
            selectionContext: selectionContext
        ) else {
            completeWithoutSession(requestID: requestID)
            return
        }

        guard isPending(requestID: requestID) else { return }

        guard Date() < deadline else {
            completeWithoutSession(requestID: requestID)
            return
        }

        let handle = MediaPlaybackSessionHandle(id: UUID())
        var ownedSources: [OwnedSource] = []

        for candidate in candidates {
            guard Date() < deadline else { break }
            guard isPending(requestID: requestID) else { break }
            guard candidate.snapshot.state == .playing,
                  let sourceIdentifier = candidate.snapshot.sourceIdentifier,
                  !sourceIdentifier.isEmpty else {
                continue
            }

            var stateMachine = MediaPlaybackSessionStateMachine()
            guard stateMachine.begin(
                sourceIdentifier: sourceIdentifier,
                initialState: candidate.snapshot.state,
                sessionID: handle.id
            ) != nil else {
                continue
            }

            let pauseStartedAt = Date()
            let pauseResult = candidate.adapter.pause(
                expectedSourceIdentifier: sourceIdentifier,
                selectionContext: selectionContext,
                before: deadline
            )
            let pauseDuration = Int((Date().timeIntervalSince(pauseStartedAt) * 1000).rounded())
            let pausedSnapshot = pauseResult.snapshot
            logger.info(
                "Media pause provider=\(candidate.snapshot.provider.rawValue, privacy: .public) result=\(pauseResult.reason, privacy: .public) state=\(pausedSnapshot?.state.logValue ?? "none", privacy: .public) duration_ms=\(pauseDuration, privacy: .public)"
            )

            guard case .confirmed(let pausedSnapshot) = pauseResult,
                  pausedSnapshot.sourceIdentifier == sourceIdentifier,
                  pausedSnapshot.state == .paused,
                  stateMachine.confirmPause(
                      handle,
                      sourceIdentifier: sourceIdentifier,
                      observedState: pausedSnapshot.state,
                      receipt: MediaPlaybackCommandReceipt(
                          sessionID: handle.id,
                          sourceIdentifier: sourceIdentifier
                      )
                  ) else {
                logger.info("Media pause was not confirmed; continuing without ownership")
                continue
            }

            ownedSources.append(
                OwnedSource(
                    adapter: candidate.adapter,
                    selectionContext: selectionContext,
                    stateMachine: stateMachine
                )
            )
        }

        guard !ownedSources.isEmpty else {
            completeWithoutSession(requestID: requestID)
            return
        }

        let prepared = ActiveSession(
            handle: handle,
            ownedSources: ownedSources,
            selectionContext: selectionContext,
            outcome: nil
        )

        guard Date() < deadline, isPending(requestID: requestID) else {
            // A player call may have started before the deadline but return
            // after it, or preparation may have been cancelled while a
            // player call was in flight. Do not adopt the confirmed side
            // effects for the recording; restore them immediately.
            if Date() >= deadline {
                logger.info("Media pause completed after the 500 ms budget; restoring immediately")
            }
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
            // The request was cancelled while one of the player operations
            // was in flight. Resume only after re-checking each owned source.
            restorePreparedSession(prepared)
            return
        }

        for source in prepared.ownedSources {
            logger.info("Media pause confirmed provider=\(source.adapter.provider.rawValue, privacy: .public)")
            notifyStatus(.paused(source.adapter.provider))
        }
        deliver(completion, value: handle)
        scheduleMonitoring(for: prepared)
    }

    private func selectCandidates(
        before deadline: Date,
        selectionContext: MediaPlaybackSelectionContext
    ) -> [(adapter: any MediaPlaybackAdapter, snapshot: MediaPlaybackSnapshot)]? {
        let frontmostProvider = provider(for: selectionContext.frontmostBundleIdentifier)
        let collector = InspectionCollector(count: adapters.count)
        let group = DispatchGroup()
        let completionSignals = adapters.map { _ in DispatchSemaphore(value: 0) }

        for (index, adapter) in adapters.enumerated() {
            group.enter()
            inspectionQueue.async { [weak self] in
                let startedAt = Date()
                let snapshot = adapter.inspect(selectionContext: selectionContext)
                collector.store(snapshot, at: index)
                let duration = Int((Date().timeIntervalSince(startedAt) * 1000).rounded())
                self?.logger.info(
                    "Media inspect provider=\(snapshot.provider.rawValue, privacy: .public) state=\(snapshot.state.logValue, privacy: .public) source_present=\(snapshot.sourceIdentifier != nil, privacy: .public) duration_ms=\(duration, privacy: .public)"
                )
                group.leave()
                completionSignals[index].signal()
            }
        }

        let inspectionTimedOut: Bool
        if let frontmostProvider,
           let frontmostIndex = adapters.firstIndex(where: { $0.provider == frontmostProvider }) {
            // A slow background provider must not consume the foreground
            // provider's recording budget. Its result is irrelevant when the
            // active app is a supported provider.
            inspectionTimedOut = completionSignals[frontmostIndex]
                .wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .timedOut
        } else {
            inspectionTimedOut = group.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .timedOut
        }
        let completedSnapshots = collector.values
        let snapshots: [(adapter: any MediaPlaybackAdapter, snapshot: MediaPlaybackSnapshot)] = adapters.enumerated()
            .compactMap { index, adapter in
                guard let snapshot = completedSnapshots[index] else { return nil }
                return (adapter: adapter, snapshot: snapshot)
            }

        guard !snapshots.isEmpty else { return nil }

        if let frontmostProvider {
            guard let frontmost = snapshots.first(where: { $0.snapshot.provider == frontmostProvider }) else {
                return nil
            }

            // When a supported app is frontmost but its active tab/player is
            // paused, stopped, unsupported, or unreadable, never reach into a
            // different background player.
            guard frontmost.snapshot.state == .playing,
                  let sourceIdentifier = frontmost.snapshot.sourceIdentifier,
                  !sourceIdentifier.isEmpty else { return nil }
            return [frontmost]
        }

        guard !inspectionTimedOut, completedSnapshots.allSatisfy({ $0 != nil }) else {
            // Without a complete inspection, a missing result could hide a
            // second playing source. Keep the selection fail-open.
            return nil
        }

        let playing = snapshots.filter { $0.snapshot.state == .playing }
        guard !playing.isEmpty,
              playing.allSatisfy({
                  guard let sourceIdentifier = $0.snapshot.sourceIdentifier else { return false }
                  return !sourceIdentifier.isEmpty
              }) else {
            return nil
        }

        if playing.count > 1 {
            let providers = playing
                .map { $0.snapshot.provider.rawValue }
                .joined(separator: ",")
            logger.info(
                "Media selection multiple playing sources providers=\(providers, privacy: .public); attempting explicit pause confirmation for each"
            )
        }
        return playing
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
        for source in active.ownedSources {
            restorePreparedSource(source, handle: active.handle)
        }
    }

    private func restorePreparedSource(_ source: OwnedSource, handle: MediaPlaybackSessionHandle) {
        let current = source.adapter.inspect(selectionContext: source.selectionContext)
        let currentSourceIdentifier = current.sourceIdentifier ?? ""
        let decision: (shouldRestore: Bool, externalChangeDetected: Bool) = withStateLock {
            let shouldRestore = source.stateMachine.shouldRestore(
                handle,
                sourceIdentifier: currentSourceIdentifier,
                currentState: current.state
            )
            return (
                shouldRestore: shouldRestore,
                externalChangeDetected: source.stateMachine.session?.externalChangeDetected == true
            )
        }

        guard decision.shouldRestore else {
            if decision.externalChangeDetected {
                notifyStatus(.externalChange(source.adapter.provider))
            }
            logger.info("Media restore skipped provider=\(source.adapter.provider.rawValue, privacy: .public) state=\(current.state.logValue, privacy: .public)")
            return
        }

        notifyStatus(.restoring(source.adapter.provider))
        let restoreStartedAt = Date()
        let restored = source.adapter.resume(
            expectedSourceIdentifier: source.handleSourceIdentifier,
            selectionContext: source.selectionContext
        )
        let resultingState = restored?.state ?? .unknown
        let restoreDuration = Int((Date().timeIntervalSince(restoreStartedAt) * 1000).rounded())
        if resultingState == .playing {
            notifyStatus(.restored(source.adapter.provider))
            logger.info(
                "Media restore provider=\(source.adapter.provider.rawValue, privacy: .public) result=confirmed duration_ms=\(restoreDuration, privacy: .public)"
            )
            logger.info("Media restored provider=\(source.adapter.provider.rawValue, privacy: .public)")
        } else {
            notifyStatus(.restoreFailed(source.adapter.provider))
            logger.error(
                "Media restore provider=\(source.adapter.provider.rawValue, privacy: .public) result=unconfirmed state=\(resultingState.logValue, privacy: .public) duration_ms=\(restoreDuration, privacy: .public)"
            )
            logger.error("Media restore was not confirmed provider=\(source.adapter.provider.rawValue, privacy: .public) state=\(resultingState.logValue, privacy: .public)")
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

        for source in active.ownedSources {
            let snapshot = source.adapter.inspect(selectionContext: source.selectionContext)
            withStateLock {
                guard self.activeSession === active, !active.isFinishing else { return }
                source.stateMachine.observe(
                    active.handle,
                    sourceIdentifier: snapshot.sourceIdentifier ?? "",
                    state: snapshot.state
                )
            }
        }

        let shouldContinue: Bool = withStateLock {
            guard self.activeSession === active, !active.isFinishing else { return false }
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

    private func notifyStatus(_ status: MediaPlaybackStatus) {
        onStatusChange?(status)
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
        let ownedSources: [OwnedSource]
        let selectionContext: MediaPlaybackSelectionContext
        var isFinishing = false
        var outcome: MediaPlaybackOutcome?

        init(
            handle: MediaPlaybackSessionHandle,
            ownedSources: [OwnedSource],
            selectionContext: MediaPlaybackSelectionContext,
            outcome: MediaPlaybackOutcome?
        ) {
            self.handle = handle
            self.ownedSources = ownedSources
            self.selectionContext = selectionContext
            self.outcome = outcome
        }
    }

    private final class OwnedSource {
        let adapter: any MediaPlaybackAdapter
        let selectionContext: MediaPlaybackSelectionContext
        var stateMachine: MediaPlaybackSessionStateMachine

        var handleSourceIdentifier: String {
            stateMachine.session?.sourceIdentifier ?? ""
        }

        init(
            adapter: any MediaPlaybackAdapter,
            selectionContext: MediaPlaybackSelectionContext,
            stateMachine: MediaPlaybackSessionStateMachine
        ) {
            self.adapter = adapter
            self.selectionContext = selectionContext
            self.stateMachine = stateMachine
        }
    }

    private final class InspectionCollector {
        private let lock = NSLock()
        private var snapshots: [MediaPlaybackSnapshot?]

        init(count: Int) {
            snapshots = Array(repeating: nil, count: count)
        }

        func store(_ snapshot: MediaPlaybackSnapshot, at index: Int) {
            lock.lock()
            snapshots[index] = snapshot
            lock.unlock()
        }

        var values: [MediaPlaybackSnapshot?] {
            lock.lock()
            defer { lock.unlock() }
            return snapshots
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

private func pollForConfirmedSnapshot(
    inspect: () -> MediaPlaybackSnapshot,
    expectedSourceIdentifier: String,
    expectedState: MediaPlaybackState,
    timeout: TimeInterval
) -> MediaPlaybackSnapshot {
    let deadline = Date().addingTimeInterval(timeout)
    var latest = inspect()

    while true {
        if latest.sourceIdentifier == expectedSourceIdentifier,
           latest.state == expectedState {
            return latest
        }

        if latest.sourceIdentifier != nil,
           latest.sourceIdentifier != expectedSourceIdentifier,
           latest.state != .unknown {
            // A different source is an explicit external change. Do not wait
            // for it to become suitable for the old command.
            return latest
        }

        if latest.state == .stopped || Date() >= deadline {
            return latest
        }

        let remaining = deadline.timeIntervalSinceNow
        Thread.sleep(forTimeInterval: min(MediaPlaybackTiming.confirmationPollInterval, remaining))
        latest = inspect()
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
        let result = pause(
            expectedSourceIdentifier: expectedSourceIdentifier,
            selectionContext: MediaPlaybackSelectionContext(
                frontmostBundleIdentifier: nil,
                trigger: "legacy"
            ),
            before: deadline
        )
        return result.snapshot
    }

    func pause(
        expectedSourceIdentifier: String,
        selectionContext: MediaPlaybackSelectionContext,
        before deadline: Date
    ) -> MediaPlaybackPauseResult {
        guard Date() < deadline else {
            return .notIssued(snapshot: nil, reason: "deadline_before_command")
        }
        let current = inspect()
        guard Date() < deadline,
              current.sourceIdentifier == expectedSourceIdentifier,
              current.state == .playing else {
            return .notIssued(snapshot: current, reason: "preflight_not_playing")
        }
        guard executeCommand("tell application id \"com.spotify.client\" to pause") else {
            return .issuedUnconfirmed(snapshot: current, reason: "action_failed")
        }
        let confirmed = pollForConfirmedSnapshot(
            inspect: inspect,
            expectedSourceIdentifier: expectedSourceIdentifier,
            expectedState: .paused,
            timeout: max(0, deadline.timeIntervalSinceNow)
        )
        guard confirmed.sourceIdentifier == expectedSourceIdentifier,
              confirmed.state == .paused else {
            return .issuedUnconfirmed(snapshot: confirmed, reason: "confirmation_timeout")
        }
        return .confirmed(confirmed)
    }

    func resume(expectedSourceIdentifier: String) -> MediaPlaybackSnapshot? {
        let current = inspect()
        guard current.sourceIdentifier == expectedSourceIdentifier,
              current.state == .paused,
              executeCommand("tell application id \"com.spotify.client\" to play") else {
            return current
        }
        return pollForConfirmedSnapshot(
            inspect: inspect,
            expectedSourceIdentifier: expectedSourceIdentifier,
            expectedState: .playing,
            timeout: MediaPlaybackTiming.restorationBudget
        )
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
    private let locatedControlLock = NSLock()
    private var locatedControlCache: (context: MediaPlaybackSelectionContext, control: LocatedControl)?

    func inspect() -> MediaPlaybackSnapshot {
        inspect(
            selectionContext: MediaPlaybackSelectionContext(
                frontmostBundleIdentifier: nil,
                trigger: "legacy"
            )
        )
    }

    func inspect(selectionContext: MediaPlaybackSelectionContext) -> MediaPlaybackSnapshot {
        guard let located = locateControl(selectionContext: selectionContext, before: Date().addingTimeInterval(0.12)) else {
            clearLocatedControlCache()
            return snapshot(sourceIdentifier: nil, state: .unknown)
        }
        storeLocatedControl(located, context: selectionContext)
        return located.snapshot
    }

    func pause(expectedSourceIdentifier: String, before deadline: Date) -> MediaPlaybackSnapshot? {
        pause(
            expectedSourceIdentifier: expectedSourceIdentifier,
            selectionContext: MediaPlaybackSelectionContext(
                frontmostBundleIdentifier: nil,
                trigger: "legacy"
            ),
            before: deadline
        ).snapshot
    }

    func pause(
        expectedSourceIdentifier: String,
        selectionContext: MediaPlaybackSelectionContext,
        before deadline: Date
    ) -> MediaPlaybackPauseResult {
        let cachedLocated = takeCachedLocatedControl(
            expectedSourceIdentifier: expectedSourceIdentifier,
            selectionContext: selectionContext,
            expectedState: .playing,
            expectedIntent: .pause
        )
        let located = cachedLocated ?? locateControl(selectionContext: selectionContext, before: deadline)
        guard Date() < deadline,
              let located,
              located.snapshot.sourceIdentifier == expectedSourceIdentifier,
              located.snapshot.state == .playing else {
            let snapshot = inspect(selectionContext: selectionContext)
            let reason = Date() >= deadline ? "deadline_before_command" : "preflight_not_playing"
            return .notIssued(snapshot: snapshot, reason: reason)
        }
        guard Date() < deadline else {
            return .notIssued(snapshot: located.snapshot, reason: "deadline_before_command")
        }
        guard actionIntent(of: located.actionButton) == .pause,
              isSameTarget(located) else {
            let snapshot = isSameTarget(located)
                ? snapshot(sourceIdentifier: expectedSourceIdentifier, state: .unknown)
                : snapshot(sourceIdentifier: nil, state: .unknown)
            return .notIssued(snapshot: snapshot, reason: "target_changed")
        }
        guard press(located.actionButton) else {
            return .issuedUnconfirmed(snapshot: located.snapshot, reason: "action_failed")
        }

        let confirmed = pollForConfirmedAction(
            located: located,
            expectedSourceIdentifier: expectedSourceIdentifier,
            expectedIntent: .play,
            resultingState: .paused,
            before: deadline
        )
        guard confirmed.sourceIdentifier == expectedSourceIdentifier,
              confirmed.state == .paused else {
            return .issuedUnconfirmed(snapshot: confirmed, reason: "confirmation_timeout")
        }
        return .confirmed(confirmed)
    }

    func resume(expectedSourceIdentifier: String) -> MediaPlaybackSnapshot? {
        resume(
            expectedSourceIdentifier: expectedSourceIdentifier,
            selectionContext: MediaPlaybackSelectionContext(
                frontmostBundleIdentifier: nil,
                trigger: "legacy"
            )
        )
    }

    func resume(
        expectedSourceIdentifier: String,
        selectionContext: MediaPlaybackSelectionContext
    ) -> MediaPlaybackSnapshot? {
        // Re-resolve the restoration control after the pause. Chrome can
        // accept AXPress on the pre-pause button reference while leaving that
        // reference stale for the opposite action, so restoration must use a
        // fresh target-bound lookup before issuing Play.
        clearLocatedControlCache()
        let located = locateControl(
            selectionContext: selectionContext,
            before: Date().addingTimeInterval(MediaPlaybackTiming.restorationBudget)
        )
        guard let located,
              located.snapshot.sourceIdentifier == expectedSourceIdentifier,
              located.snapshot.state == .paused,
              actionIntent(of: located.actionButton) == .play,
              isSameTarget(located) else {
            return inspect(selectionContext: selectionContext)
        }
        guard press(located.actionButton) else {
            return inspect(selectionContext: selectionContext)
        }
        return pollForConfirmedAction(
            located: located,
            expectedSourceIdentifier: expectedSourceIdentifier,
            expectedIntent: .pause,
            resultingState: .playing,
            before: Date().addingTimeInterval(MediaPlaybackTiming.restorationBudget)
        )
    }

    /// Chrome's AX tree is expensive to traverse and can return the old
    /// control state for a short period after AXPress. Once a validated
    /// control has been pressed, confirm the state on that same target instead
    /// of repeatedly searching every browser window. This keeps the fixed
    /// preparation budget usable without accepting an uncorrelated snapshot.
    private func pollForConfirmedAction(
        located: LocatedControl,
        expectedSourceIdentifier: String,
        expectedIntent: ChromeYouTubeAccessibility.ActionIntent,
        resultingState: MediaPlaybackState,
        before deadline: Date
    ) -> MediaPlaybackSnapshot {
        var latest = located.snapshot

        while true {
            guard isSameTarget(located) else {
                return snapshot(sourceIdentifier: nil, state: .unknown)
            }

            if actionIntent(of: located.actionButton) == expectedIntent {
                return snapshot(sourceIdentifier: expectedSourceIdentifier, state: resultingState)
            }

            guard Date() < deadline else { return latest }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return latest }
            Thread.sleep(forTimeInterval: min(MediaPlaybackTiming.confirmationPollInterval, remaining))
            latest = located.snapshot
        }
    }

    private func locateControl(
        selectionContext: MediaPlaybackSelectionContext,
        before deadline: Date
    ) -> LocatedControl? {
        guard AXIsProcessTrusted() else {
            if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").isEmpty {
                logger.info("Chrome YouTube Accessibility inspection unavailable")
            }
            return nil
        }
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome")
        guard applications.count == 1, let chrome = applications.first else {
            return nil
        }

        let application = AXUIElementCreateApplication(chrome.processIdentifier)
        let windows = candidateWindows(
            for: application,
            isForegroundChrome: selectionContext.frontmostBundleIdentifier == "com.google.Chrome"
        )
        logger.info(
            "Chrome locator start foreground=\(selectionContext.frontmostBundleIdentifier == "com.google.Chrome", privacy: .public) trigger=\(selectionContext.trigger, privacy: .public) windows=\(windows.count, privacy: .public)"
        )
        var controls: [LocatedControl] = []

        for window in windows {
            guard Date() < deadline else { return nil }
            let windowIdentifier = elementIdentifier(window)
            var traversal = AXTraversalState(deadline: deadline, maximumNodes: 700)
            let players = findPlayers(
                in: window,
                inheritedURL: nil,
                documentIdentifier: nil,
                documentElement: nil,
                windowIdentifier: windowIdentifier,
                processIdentifier: chrome.processIdentifier,
                traversal: &traversal
            )
            logger.info(
                "Chrome locator window players=\(players.count, privacy: .public) visited=\(traversal.visitedNodes, privacy: .public) incomplete=\(traversal.isIncomplete, privacy: .public)"
            )
            guard !traversal.isIncomplete else { return nil }

            for player in players {
                guard Date() < deadline else { return nil }
                var actionTraversal = AXTraversalState(deadline: deadline, maximumNodes: 350)
                let actions = findActionButtons(
                    in: player.element,
                    depth: 0,
                    inheritedHidden: false,
                    traversal: &actionTraversal
                )
                logger.info(
                    "Chrome locator player actions=\(actions.count, privacy: .public) visited=\(actionTraversal.visitedNodes, privacy: .public) incomplete=\(actionTraversal.isIncomplete, privacy: .public)"
                )
                guard !actionTraversal.isIncomplete else { return nil }
                guard let control = locatedControl(for: player, actions: actions) else {
                    logger.info("Chrome locator player control=ambiguous_or_missing")
                    continue
                }
                controls.append(control)
            }
        }

        let playing = controls.filter { $0.snapshot.state == .playing }
        if playing.count == 1 {
            logger.info("Chrome locator result=playing_unique controls=\(controls.count, privacy: .public)")
            return playing[0]
        }
        if playing.count > 1 {
            logger.info("Chrome locator result=playing_ambiguous controls=\(controls.count, privacy: .public)")
            return nil
        }

        let paused = controls.filter { $0.snapshot.state == .paused }
        if paused.count == 1 {
            logger.info("Chrome locator result=paused_unique controls=\(controls.count, privacy: .public)")
            return paused[0]
        }
        logger.info("Chrome locator result=paused_ambiguous_or_missing controls=\(controls.count, privacy: .public)")
        return nil
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

    private func candidateWindows(
        for application: AXUIElement,
        isForegroundChrome: Bool
    ) -> [AXUIElement] {
        let focused = focusedWindow(for: application)
        let main = elementAttribute(application, kAXMainWindowAttribute as CFString)
        let listed = elementArrayAttribute(application, kAXWindowsAttribute as CFString)
        let all = uniqueElements([focused, main].compactMap { $0 } + listed)

        if isForegroundChrome {
            if let focused { return [focused] }
            if all.count == 1, let onlyWindow = all.first { return [onlyWindow] }
            return []
        }

        return all
    }

    private func elementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        guard let value = attributeValue(element, attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func elementArrayAttribute(_ element: AXUIElement, _ attribute: CFString) -> [AXUIElement] {
        guard let value = attributeValue(element, attribute),
              let elements = value as? [AXUIElement] else {
            return []
        }
        return elements
    }

    private func uniqueElements(_ elements: [AXUIElement]) -> [AXUIElement] {
        var seen = Set<String>()
        return elements.filter { seen.insert(elementIdentifier($0)).inserted }
    }

    private func elementIdentifier(_ element: AXUIElement) -> String {
        String(CFHash(element))
    }

    private func findPlayers(
        in element: AXUIElement,
        inheritedURL: String?,
        documentIdentifier: String?,
        documentElement: AXUIElement?,
        windowIdentifier: String,
        processIdentifier: pid_t,
        traversal: inout AXTraversalState
    ) -> [LocatedPlayer] {
        guard traversal.enter() else { return [] }

        let url = stringAttribute(element, kAXURLAttribute as CFString) ?? inheritedURL
        let role = stringAttribute(element, kAXRoleAttribute as CFString)?.lowercased()
        let currentDocumentIdentifier = role == "axwebarea"
            ? elementIdentifier(element)
            : documentIdentifier
        let currentDocumentElement = role == "axwebarea" ? element : documentElement
        let identifier = stringAttribute(element, kAXIdentifierAttribute as CFString)
        let description = stringAttribute(element, kAXDescriptionAttribute as CFString)
        if identifier == "movie_player" || description?.localizedLowercase.contains("youtube-videoplayer") == true {
            guard let url, ChromeYouTubeAccessibility.isYouTubeURL(url) else { return [] }
            let documentToken = currentDocumentIdentifier ?? windowIdentifier
            return [LocatedPlayer(
                element: element,
                playerIdentifier: elementIdentifier(element),
                sourceURL: url,
                documentElement: currentDocumentElement,
                sourceIdentifier: "chrome:\(processIdentifier):window:\(windowIdentifier):document:\(documentToken):player:\(elementIdentifier(element)):url:\(url)"
            )]
        }

        var players: [LocatedPlayer] = []
        for child in children(of: element, traversal: &traversal) {
            players.append(contentsOf: findPlayers(
                in: child,
                inheritedURL: url,
                documentIdentifier: currentDocumentIdentifier,
                documentElement: currentDocumentElement,
                windowIdentifier: windowIdentifier,
                processIdentifier: processIdentifier,
                traversal: &traversal
            ))
            // Chrome exposes the active tab as the document below each
            // candidate window. Once that document yields one YouTube player,
            // continuing through the rest of the large AX tree only burns the
            // preparation budget. Ambiguity across windows is still handled
            // by the aggregate control selection below.
            if !players.isEmpty || traversal.isIncomplete { break }
        }
        return players
    }

    private func findActionButtons(
        in element: AXUIElement,
        depth: Int,
        inheritedHidden: Bool,
        traversal: inout AXTraversalState
    ) -> [ActionCandidate] {
        guard depth < 24, traversal.enter() else { return [] }

        let hidden = inheritedHidden || boolAttribute(element, kAXHiddenAttribute as CFString) == true
        let role = stringAttribute(element, kAXRoleAttribute as CFString)?.lowercased() ?? ""
        var actions: [ActionCandidate] = []

        if (role == "axbutton" || role == "button"),
           !hidden,
           isUsableActionButton(element),
           hasPressAction(element) {
            if let intent = actionIntent(of: element) {
                actions.append(ActionCandidate(element: element, intent: intent))
            }
        }

        for child in children(of: element, traversal: &traversal) {
            actions.append(contentsOf: findActionButtons(
                in: child,
                depth: depth + 1,
                inheritedHidden: hidden,
                traversal: &traversal
            ))
            if actions.count >= 8 || traversal.isIncomplete { break }
        }
        return actions
    }

    private func locatedControl(
        for player: LocatedPlayer,
        actions: [ActionCandidate]
    ) -> LocatedControl? {
        let pauseButtons = actions.filter { $0.intent == .pause }
        let playButtons = actions.filter { $0.intent == .play }

        guard !(pauseButtons.isEmpty && playButtons.isEmpty),
              !(pauseButtons.count > 0 && playButtons.count > 0) else {
            return nil
        }

        if pauseButtons.count == 1, let pauseButton = pauseButtons.first {
            return LocatedControl(
                player: player,
                snapshot: snapshot(sourceIdentifier: player.sourceIdentifier, state: .playing),
                actionButton: pauseButton.element
            )
        }
        if playButtons.count == 1, let playButton = playButtons.first {
            return LocatedControl(
                player: player,
                snapshot: snapshot(sourceIdentifier: player.sourceIdentifier, state: .paused),
                actionButton: playButton.element
            )
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

    private func storeLocatedControl(
        _ control: LocatedControl,
        context: MediaPlaybackSelectionContext
    ) {
        locatedControlLock.lock()
        locatedControlCache = (context: context, control: control)
        locatedControlLock.unlock()
    }

    private func clearLocatedControlCache() {
        locatedControlLock.lock()
        locatedControlCache = nil
        locatedControlLock.unlock()
    }

    private func takeCachedLocatedControl(
        expectedSourceIdentifier: String,
        selectionContext: MediaPlaybackSelectionContext,
        expectedState: MediaPlaybackState,
        expectedIntent: ChromeYouTubeAccessibility.ActionIntent
    ) -> LocatedControl? {
        locatedControlLock.lock()
        let cached = locatedControlCache
        locatedControlCache = nil
        locatedControlLock.unlock()

        guard let cached,
              cached.context == selectionContext,
              cached.control.snapshot.sourceIdentifier == expectedSourceIdentifier,
              cached.control.snapshot.state == expectedState,
              actionIntent(of: cached.control.actionButton) == expectedIntent,
              isSameTarget(cached.control) else {
            return nil
        }
        return cached.control
    }

    private func actionIntent(of element: AXUIElement) -> ChromeYouTubeAccessibility.ActionIntent? {
        let intents = [
            stringAttribute(element, kAXDescriptionAttribute as CFString),
            stringAttribute(element, kAXTitleAttribute as CFString),
            stringAttribute(element, kAXValueAttribute as CFString),
        ]
            .compactMap { $0 }
            .compactMap { ChromeYouTubeAccessibility.actionIntent(for: $0) }

        let uniqueIntents = Set(intents)
        guard uniqueIntents.count == 1 else { return nil }
        return uniqueIntents.first
    }

    private func isSameTarget(_ located: LocatedControl) -> Bool {
        guard elementIdentifier(located.player.element) == located.player.playerIdentifier else {
            return false
        }

        let identifier = stringAttribute(
            located.player.element,
            kAXIdentifierAttribute as CFString
        )
        let description = stringAttribute(
            located.player.element,
            kAXDescriptionAttribute as CFString
        )
        guard identifier == "movie_player"
                || description?.localizedLowercase.contains("youtube-videoplayer") == true else {
            return false
        }

        let playerURL = stringAttribute(located.player.element, kAXURLAttribute as CFString)
        let documentURL = located.player.documentElement.flatMap {
            stringAttribute($0, kAXURLAttribute as CFString)
        }
        if let currentURL = playerURL ?? documentURL {
            return currentURL == located.player.sourceURL
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

    private func hasPressAction(_ element: AXUIElement) -> Bool {
        var value: CFArray?
        guard AXUIElementCopyActionNames(element, &value) == .success,
              let actions = value as? [String] else {
            return false
        }
        return actions.contains(kAXPressAction as String)
    }

    private func children(
        of element: AXUIElement,
        traversal: inout AXTraversalState
    ) -> [AXUIElement] {
        guard let value = attributeValue(element, kAXChildrenAttribute as CFString) else {
            return []
        }
        guard let children = value as? [AXUIElement] else {
            traversal.isIncomplete = true
            return []
        }
        return children
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
        let playerIdentifier: String
        let sourceURL: String
        let documentElement: AXUIElement?
        let sourceIdentifier: String
    }

    private struct LocatedControl {
        let player: LocatedPlayer
        let snapshot: MediaPlaybackSnapshot
        let actionButton: AXUIElement
    }

    private struct ActionCandidate {
        let element: AXUIElement
        let intent: ChromeYouTubeAccessibility.ActionIntent
    }
}

private struct AXTraversalState {
    let deadline: Date
    let maximumNodes: Int
    private(set) var visitedNodes = 0
    var isIncomplete = false

    mutating func enter() -> Bool {
        guard !isIncomplete, Date() < deadline else {
            isIncomplete = true
            return false
        }
        visitedNodes += 1
        guard visitedNodes <= maximumNodes else {
            isIncomplete = true
            return false
        }
        return true
    }
}
