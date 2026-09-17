import Foundation

@main
struct MediaPlaybackCoordinatorTests {
    static func main() throws {
        try assertPlayingSourcePausesAndRestores()
        try assertPreexistingPauseIsUntouched()
        try assertStoppedSourceIsUntouched()
        try assertUnknownSourceIsUntouched()
        try assertDisabledSettingSkipsMediaControl()
        try assertMultiplePlayingSourcesPauseAndRestore()
        try assertUnconfirmedSourceDoesNotBlockConfirmedSource()
        try assertFrontmostSupportedSourceWins()
        try assertFrontmostSourceIsNotBlockedBySlowBackgroundInspection()
        try assertStatusLifecycleIsObservable()
        try assertPausedFrontmostSourceDoesNotFallBack()
        try assertSessionsAreSerializedAcrossRetry()
        try assertUnconfirmedPauseNeverResumes()
        try assertExternalPlaybackWins()
        try assertTimeoutFailsOpen()
        try assertLatePauseIsRestoredImmediately()
        print("MediaPlaybackCoordinatorTests passed")
    }

    private static func assertPlayingSourcePausesAndRestores() throws {
        let adapter = MockMediaPlaybackAdapter(
            provider: .spotify,
            state: .playing,
            sourceIdentifier: "spotify:one"
        )
        let coordinator = MediaPlaybackCoordinator(
            adapters: [adapter],
            frontmostBundleIdentifier: { nil }
        )

        var handle: MediaPlaybackSessionHandle?
        coordinator.prepareForRecording(enabled: true) { handle = $0 }
        try waitUntil { handle != nil }

        guard let handle else {
            throw TestFailure("A confirmed playing source should produce a session")
        }
        guard adapter.pauseCount == 1, adapter.state == .paused else {
            throw TestFailure("The coordinator should pause the selected source once")
        }

        coordinator.finish(handle, outcome: .successfulPaste)
        try waitUntil { adapter.resumeCount == 1 }
        guard adapter.state == .playing else {
            throw TestFailure("The owned pause should be restored")
        }
    }

    private static func assertPreexistingPauseIsUntouched() throws {
        let adapter = MockMediaPlaybackAdapter(
            provider: .spotify,
            state: .paused,
            sourceIdentifier: "spotify:paused"
        )
        let coordinator = MediaPlaybackCoordinator(
            adapters: [adapter],
            frontmostBundleIdentifier: { nil }
        )

        var callbackReceived = false
        var handle: MediaPlaybackSessionHandle?
        coordinator.prepareForRecording(enabled: true) {
            callbackReceived = true
            handle = $0
        }
        try waitUntil { callbackReceived }

        guard handle == nil, adapter.pauseCount == 0, adapter.resumeCount == 0 else {
            throw TestFailure("An already-paused source must remain untouched")
        }
    }

    private static func assertStoppedSourceIsUntouched() throws {
        let adapter = MockMediaPlaybackAdapter(
            provider: .spotify,
            state: .stopped,
            sourceIdentifier: "spotify:stopped"
        )
        let coordinator = MediaPlaybackCoordinator(
            adapters: [adapter],
            frontmostBundleIdentifier: { nil }
        )

        var callbackReceived = false
        var handle: MediaPlaybackSessionHandle?
        coordinator.prepareForRecording(enabled: true) {
            callbackReceived = true
            handle = $0
        }
        try waitUntil { callbackReceived }

        guard handle == nil, adapter.pauseCount == 0, adapter.resumeCount == 0 else {
            throw TestFailure("A stopped source must remain untouched")
        }
    }

    private static func assertUnknownSourceIsUntouched() throws {
        let adapter = MockMediaPlaybackAdapter(
            provider: .spotify,
            state: .unknown,
            sourceIdentifier: "spotify:unknown"
        )
        let coordinator = MediaPlaybackCoordinator(
            adapters: [adapter],
            frontmostBundleIdentifier: { nil }
        )

        var callbackReceived = false
        var handle: MediaPlaybackSessionHandle?
        coordinator.prepareForRecording(enabled: true) {
            callbackReceived = true
            handle = $0
        }
        try waitUntil { callbackReceived }

        guard handle == nil, adapter.pauseCount == 0 else {
            throw TestFailure("An unknown source must remain untouched")
        }
    }

    private static func assertDisabledSettingSkipsMediaControl() throws {
        let adapter = MockMediaPlaybackAdapter(
            provider: .spotify,
            state: .playing,
            sourceIdentifier: "spotify:disabled"
        )
        let coordinator = MediaPlaybackCoordinator(
            adapters: [adapter],
            frontmostBundleIdentifier: { nil }
        )

        var callbackReceived = false
        var handle: MediaPlaybackSessionHandle?
        coordinator.prepareForRecording(enabled: false) {
            callbackReceived = true
            handle = $0
        }
        try waitUntil { callbackReceived }

        guard handle == nil, adapter.inspectCount == 0, adapter.pauseCount == 0 else {
            throw TestFailure("Disabled media control must not inspect or control a player")
        }
    }

    private static func assertUnconfirmedPauseNeverResumes() throws {
        let adapter = MockMediaPlaybackAdapter(
            provider: .spotify,
            state: .playing,
            sourceIdentifier: "spotify:unconfirmed",
            pauseResult: .unconfirmed
        )
        let coordinator = MediaPlaybackCoordinator(
            adapters: [adapter],
            frontmostBundleIdentifier: { nil }
        )

        var callbackReceived = false
        var handle: MediaPlaybackSessionHandle?
        coordinator.prepareForRecording(enabled: true) {
            callbackReceived = true
            handle = $0
        }
        try waitUntil { callbackReceived }

        guard handle == nil, adapter.pauseCount == 1 else {
            throw TestFailure("An unconfirmed pause must not create a session")
        }
        try assertDoesNotBecomeTrue(timeout: 0.25, { adapter.resumeCount > 0 }) {
            TestFailure("An unconfirmed pause must never trigger Play")
        }
    }

    private static func assertMultiplePlayingSourcesPauseAndRestore() throws {
        let first = MockMediaPlaybackAdapter(
            provider: .spotify,
            state: .playing,
            sourceIdentifier: "spotify:first"
        )
        let second = MockMediaPlaybackAdapter(
            provider: .youtubeChrome,
            state: .playing,
            sourceIdentifier: "youtube:second"
        )
        let coordinator = MediaPlaybackCoordinator(
            adapters: [first, second],
            frontmostBundleIdentifier: { nil }
        )

        var callbackReceived = false
        var handle: MediaPlaybackSessionHandle?
        coordinator.prepareForRecording(enabled: true) { receivedHandle in
            callbackReceived = true
            handle = receivedHandle
        }
        try waitUntil { callbackReceived }

        guard let handle else {
            throw TestFailure("Multiple explicitly playing sources should produce one group session")
        }
        guard first.pauseCount == 1, second.pauseCount == 1,
              first.state == .paused, second.state == .paused else {
            throw TestFailure("Each explicitly playing source should be paused once")
        }

        coordinator.finish(handle, outcome: .successfulPaste)
        try waitUntil { first.resumeCount == 1 && second.resumeCount == 1 }
        guard first.state == .playing, second.state == .playing else {
            throw TestFailure("Each owned pause should be restored")
        }
    }

    private static func assertUnconfirmedSourceDoesNotBlockConfirmedSource() throws {
        let confirmed = MockMediaPlaybackAdapter(
            provider: .spotify,
            state: .playing,
            sourceIdentifier: "spotify:confirmed"
        )
        let unconfirmed = MockMediaPlaybackAdapter(
            provider: .youtubeChrome,
            state: .playing,
            sourceIdentifier: "youtube:unconfirmed",
            pauseResult: .unconfirmed
        )
        let coordinator = MediaPlaybackCoordinator(
            adapters: [confirmed, unconfirmed],
            frontmostBundleIdentifier: { nil }
        )

        var handle: MediaPlaybackSessionHandle?
        coordinator.prepareForRecording(enabled: true) { handle = $0 }
        try waitUntil { handle != nil }

        guard let handle,
              confirmed.pauseCount == 1,
              unconfirmed.pauseCount == 1,
              confirmed.state == .paused else {
            throw TestFailure("A confirmed source should remain owned when another source cannot be confirmed")
        }

        coordinator.finish(handle, outcome: .cancelled)
        try waitUntil { confirmed.resumeCount == 1 }
        guard unconfirmed.resumeCount == 0 else {
            throw TestFailure("An unconfirmed source must never be resumed")
        }
    }

    private static func assertFrontmostSupportedSourceWins() throws {
        let spotify = MockMediaPlaybackAdapter(
            provider: .spotify,
            state: .playing,
            sourceIdentifier: "spotify:frontmost"
        )
        let youtube = MockMediaPlaybackAdapter(
            provider: .youtubeChrome,
            state: .playing,
            sourceIdentifier: "youtube:background"
        )
        let coordinator = MediaPlaybackCoordinator(
            adapters: [spotify, youtube],
            frontmostBundleIdentifier: { "com.spotify.client" }
        )

        var handle: MediaPlaybackSessionHandle?
        coordinator.prepareForRecording(enabled: true) { handle = $0 }
        try waitUntil { handle != nil }

        guard let handle else { throw TestFailure("Expected the frontmost supported source") }
        guard spotify.pauseCount == 1, youtube.pauseCount == 0 else {
            throw TestFailure("Only the frontmost supported source may be paused")
        }
        coordinator.finish(handle, outcome: .successfulPaste)
        try waitUntil { spotify.resumeCount == 1 }
    }

    private static func assertFrontmostSourceIsNotBlockedBySlowBackgroundInspection() throws {
        let slowSpotify = MockMediaPlaybackAdapter(
            provider: .spotify,
            state: .playing,
            sourceIdentifier: "spotify:slow-background",
            inspectDelay: 1.0
        )
        let chrome = MockMediaPlaybackAdapter(
            provider: .youtubeChrome,
            state: .playing,
            sourceIdentifier: "youtube:frontmost"
        )
        let coordinator = MediaPlaybackCoordinator(
            adapters: [slowSpotify, chrome],
            frontmostBundleIdentifier: { "com.google.Chrome" }
        )

        var handle: MediaPlaybackSessionHandle?
        coordinator.prepareForRecording(enabled: true) { handle = $0 }
        try waitUntil(timeout: 0.45) { handle != nil }

        guard let handle else {
            throw TestFailure("A foreground source should not wait for a slow background inspection")
        }
        guard chrome.pauseCount == 1, slowSpotify.pauseCount == 0 else {
            throw TestFailure("Only the active foreground provider may be paused")
        }

        coordinator.finish(handle, outcome: .successfulPaste)
        try waitUntil { chrome.resumeCount == 1 }
    }

    private static func assertPausedFrontmostSourceDoesNotFallBack() throws {
        let spotify = MockMediaPlaybackAdapter(
            provider: .spotify,
            state: .paused,
            sourceIdentifier: "spotify:paused-frontmost"
        )
        let youtube = MockMediaPlaybackAdapter(
            provider: .youtubeChrome,
            state: .playing,
            sourceIdentifier: "youtube:background"
        )
        let coordinator = MediaPlaybackCoordinator(
            adapters: [spotify, youtube],
            frontmostBundleIdentifier: { "com.spotify.client" }
        )

        var callbackReceived = false
        var handle: MediaPlaybackSessionHandle?
        coordinator.prepareForRecording(enabled: true) {
            callbackReceived = true
            handle = $0
        }
        try waitUntil { callbackReceived }

        guard handle == nil, spotify.pauseCount == 0, youtube.pauseCount == 0 else {
            throw TestFailure("A paused frontmost source must block fallback to a background player")
        }
    }

    private static func assertStatusLifecycleIsObservable() throws {
        let adapter = MockMediaPlaybackAdapter(
            provider: .spotify,
            state: .playing,
            sourceIdentifier: "spotify:status"
        )
        let coordinator = MediaPlaybackCoordinator(
            adapters: [adapter],
            frontmostBundleIdentifier: { nil }
        )
        let statusLock = NSLock()
        var statuses: [MediaPlaybackStatus] = []
        coordinator.onStatusChange = { status in
            statusLock.lock()
            statuses.append(status)
            statusLock.unlock()
        }

        var handle: MediaPlaybackSessionHandle?
        coordinator.prepareForRecording(enabled: true) { handle = $0 }
        try waitUntil { handle != nil }
        guard let handle else { throw TestFailure("Expected a confirmed session") }

        coordinator.finish(handle, outcome: .successfulPaste)
        try waitUntil {
            statusLock.lock()
            defer { statusLock.unlock() }
            return statuses.contains(.restored(.spotify))
        }

        statusLock.lock()
        let observedStatuses = statuses
        statusLock.unlock()
        guard observedStatuses == [
            .preparing,
            .paused(.spotify),
            .restoring(.spotify),
            .restored(.spotify),
        ] else {
            throw TestFailure("Media status should expose the complete pause and restore lifecycle")
        }
    }

    private static func assertSessionsAreSerializedAcrossRetry() throws {
        let adapter = MockMediaPlaybackAdapter(
            provider: .spotify,
            state: .playing,
            sourceIdentifier: "spotify:retry"
        )
        let coordinator = MediaPlaybackCoordinator(
            adapters: [adapter],
            frontmostBundleIdentifier: { nil }
        )

        var firstHandle: MediaPlaybackSessionHandle?
        coordinator.prepareForRecording(enabled: true) { firstHandle = $0 }
        try waitUntil { firstHandle != nil }
        guard let firstHandle else { throw TestFailure("Expected the first session") }

        coordinator.finish(firstHandle, outcome: .cancelled)
        var secondHandle: MediaPlaybackSessionHandle?
        coordinator.prepareForRecording(enabled: true) { secondHandle = $0 }
        try waitUntil { secondHandle != nil }

        guard adapter.events == ["pause", "resume", "pause"] else {
            throw TestFailure("A retry must restore the old session before pausing the new one")
        }
        if let secondHandle { coordinator.finish(secondHandle, outcome: .successfulPaste) }
        try waitUntil { adapter.resumeCount == 2 }
    }

    private static func assertExternalPlaybackWins() throws {
        let adapter = MockMediaPlaybackAdapter(
            provider: .spotify,
            state: .playing,
            sourceIdentifier: "spotify:external"
        )
        let coordinator = MediaPlaybackCoordinator(
            adapters: [adapter],
            frontmostBundleIdentifier: { nil }
        )

        var handle: MediaPlaybackSessionHandle?
        coordinator.prepareForRecording(enabled: true) { handle = $0 }
        try waitUntil { handle != nil }
        guard let handle else { throw TestFailure("Expected a confirmed session") }

        adapter.setState(.playing)
        coordinator.finish(handle, outcome: .cancelled)
        try assertDoesNotBecomeTrue(timeout: 0.25, { adapter.resumeCount > 0 }) {
            TestFailure("External playback must prevent restoration")
        }
    }

    private static func assertTimeoutFailsOpen() throws {
        let adapter = MockMediaPlaybackAdapter(
            provider: .spotify,
            state: .playing,
            sourceIdentifier: "spotify:slow",
            inspectDelay: 1.0
        )
        let coordinator = MediaPlaybackCoordinator(
            adapters: [adapter],
            frontmostBundleIdentifier: { nil }
        )

        var callbackReceived = false
        var handle: MediaPlaybackSessionHandle?
        coordinator.prepareForRecording(enabled: true) {
            callbackReceived = true
            handle = $0
        }
        try waitUntil(timeout: 0.7) { callbackReceived }

        guard handle == nil, adapter.pauseCount == 0 else {
            throw TestFailure("Preparation must fail open at the 500 ms budget")
        }
    }

    private static func assertLatePauseIsRestoredImmediately() throws {
        let adapter = MockMediaPlaybackAdapter(
            provider: .spotify,
            state: .playing,
            sourceIdentifier: "spotify:late-pause",
            pauseDelay: 0.7
        )
        let coordinator = MediaPlaybackCoordinator(
            adapters: [adapter],
            frontmostBundleIdentifier: { nil }
        )

        var callbackReceived = false
        var handle: MediaPlaybackSessionHandle?
        coordinator.prepareForRecording(enabled: true) {
            callbackReceived = true
            handle = $0
        }
        try waitUntil(timeout: 0.7) { callbackReceived }
        guard handle == nil else {
            throw TestFailure("A pause completed after the deadline must not become a late recording session")
        }

        try waitUntil(timeout: 1.2) { adapter.resumeCount == 1 }
        guard adapter.state == .playing else {
            throw TestFailure("A confirmed late pause must be restored immediately")
        }
    }

    private static func waitUntil(
        timeout: TimeInterval = 1.5,
        _ predicate: @escaping () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        guard predicate() else {
            throw TestFailure("Timed out waiting for coordinator state")
        }
    }

    private static func assertDoesNotBecomeTrue(
        timeout: TimeInterval,
        _ predicate: @escaping () -> Bool,
        _ failure: () -> Error
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        if predicate() { throw failure() }
    }
}

private final class MockMediaPlaybackAdapter: MediaPlaybackAdapter {
    enum PauseResult {
        case confirm
        case unconfirmed
    }

    let provider: MediaPlaybackProvider
    private let lock = NSLock()
    private var currentState: MediaPlaybackState
    private let sourceIdentifier: String
    private let inspectDelay: TimeInterval
    private let pauseDelay: TimeInterval
    private let pauseResult: PauseResult
    private var pauseCountValue = 0
    private var resumeCountValue = 0
    private var inspectCountValue = 0
    private var eventsValue: [String] = []

    var state: MediaPlaybackState {
        withLock { currentState }
    }

    var pauseCount: Int {
        withLock { pauseCountValue }
    }

    var inspectCount: Int {
        withLock { inspectCountValue }
    }

    var resumeCount: Int {
        withLock { resumeCountValue }
    }

    var events: [String] {
        withLock { eventsValue }
    }

    init(
        provider: MediaPlaybackProvider,
        state: MediaPlaybackState,
        sourceIdentifier: String,
        pauseResult: PauseResult = .confirm,
        inspectDelay: TimeInterval = 0,
        pauseDelay: TimeInterval = 0
    ) {
        self.provider = provider
        self.currentState = state
        self.sourceIdentifier = sourceIdentifier
        self.pauseResult = pauseResult
        self.inspectDelay = inspectDelay
        self.pauseDelay = pauseDelay
    }

    func inspect() -> MediaPlaybackSnapshot {
        if inspectDelay > 0 { Thread.sleep(forTimeInterval: inspectDelay) }
        return withLock {
            inspectCountValue += 1
            return snapshot()
        }
    }

    func pause(expectedSourceIdentifier: String, before deadline: Date) -> MediaPlaybackSnapshot? {
        if pauseDelay > 0 { Thread.sleep(forTimeInterval: pauseDelay) }
        return withLock { () -> MediaPlaybackSnapshot? in
            pauseCountValue += 1
            eventsValue.append("pause")
            guard expectedSourceIdentifier == sourceIdentifier,
                  currentState == .playing else { return snapshot() }
            currentState = .paused
            switch pauseResult {
            case .confirm:
                return snapshot()
            case .unconfirmed:
                return nil
            }
        }
    }

    func resume(expectedSourceIdentifier: String) -> MediaPlaybackSnapshot? {
        withLock {
            resumeCountValue += 1
            eventsValue.append("resume")
            guard expectedSourceIdentifier == sourceIdentifier,
                  currentState == .paused else { return snapshot() }
            currentState = .playing
            return snapshot()
        }
    }

    func setState(_ state: MediaPlaybackState) {
        withLock { currentState = state }
    }

    private func snapshot() -> MediaPlaybackSnapshot {
        MediaPlaybackSnapshot(
            provider: provider,
            sourceIdentifier: sourceIdentifier,
            state: currentState
        )
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
