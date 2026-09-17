import Foundation

enum MediaPlaybackProvider: String, CaseIterable {
    case spotify
    case youtubeChrome

    var displayName: String {
        switch self {
        case .spotify:
            return "Spotify"
        case .youtubeChrome:
            return "YouTube in Chrome"
        }
    }
}

enum MediaPlaybackState: Equatable {
    case playing
    case paused
    case stopped
    case unknown
}

struct MediaPlaybackSnapshot: Equatable {
    let provider: MediaPlaybackProvider
    let sourceIdentifier: String?
    let state: MediaPlaybackState
}

struct MediaPlaybackSessionHandle: Hashable {
    let id: UUID
}

struct MediaPlaybackPreparationDeadline {
    let startedAt: Date
    let budget: TimeInterval

    init(startedAt: Date, budget: TimeInterval = MediaPlaybackTiming.preparationBudget) {
        self.startedAt = startedAt
        self.budget = budget
    }

    func hasExpired(at date: Date) -> Bool {
        date.timeIntervalSince(startedAt) >= budget
    }
}

enum MediaPlaybackStatus: Equatable {
    case idle
    case preparing
    case paused(MediaPlaybackProvider)
    case restoring(MediaPlaybackProvider)
    case restored(MediaPlaybackProvider)
    case externalChange(MediaPlaybackProvider)
    case restoreFailed(MediaPlaybackProvider)

    var isTerminal: Bool {
        switch self {
        case .restored, .externalChange, .restoreFailed:
            return true
        case .idle, .preparing, .paused, .restoring:
            return false
        }
    }
}

enum MediaPlaybackTiming {
    static let preparationBudget: TimeInterval = 0.5
    static let confirmationPollInterval: TimeInterval = 0.025
    static let restorationBudget: TimeInterval = 0.4
}

enum MediaPlaybackOutcome: String {
    case successfulPaste
    case cancelled
    case rejected
    case failed
}

struct MediaPlaybackSession: Equatable {
    let id: UUID
    let sourceIdentifier: String
    let initialState: MediaPlaybackState
    var lastObservedState: MediaPlaybackState
    var pauseConfirmedByBlitztext = false
    var externalChangeDetected = false
    var restorationAttempted = false
}

/// Pure ownership state for one recording. System I/O is intentionally kept
/// outside this type so the safety rules can be tested without live players.
struct MediaPlaybackSessionStateMachine {
    private(set) var session: MediaPlaybackSession?

    mutating func begin(
        sourceIdentifier: String,
        initialState: MediaPlaybackState,
        sessionID: UUID = UUID()
    ) -> MediaPlaybackSessionHandle? {
        guard initialState == .playing, !sourceIdentifier.isEmpty else { return nil }

        session = MediaPlaybackSession(
            id: sessionID,
            sourceIdentifier: sourceIdentifier,
            initialState: initialState,
            lastObservedState: initialState
        )
        return MediaPlaybackSessionHandle(id: sessionID)
    }

    @discardableResult
    mutating func confirmPause(
        _ handle: MediaPlaybackSessionHandle,
        sourceIdentifier: String,
        observedState: MediaPlaybackState
    ) -> Bool {
        guard var session,
              session.id == handle.id,
              session.sourceIdentifier == sourceIdentifier,
              session.initialState == .playing,
              observedState == .paused else {
            return false
        }

        session.pauseConfirmedByBlitztext = true
        session.lastObservedState = observedState
        self.session = session
        return true
    }

    mutating func observe(
        _ handle: MediaPlaybackSessionHandle,
        sourceIdentifier: String,
        state: MediaPlaybackState
    ) {
        guard var session,
              session.id == handle.id,
              session.pauseConfirmedByBlitztext else {
            return
        }

        if sourceIdentifier != session.sourceIdentifier {
            session.externalChangeDetected = true
        } else if state != session.lastObservedState || state == .unknown {
            session.externalChangeDetected = true
        }
        session.lastObservedState = state
        self.session = session
    }

    @discardableResult
    mutating func shouldRestore(
        _ handle: MediaPlaybackSessionHandle,
        sourceIdentifier: String,
        currentState: MediaPlaybackState
    ) -> Bool {
        guard var session,
              session.id == handle.id,
              session.sourceIdentifier == sourceIdentifier,
              session.pauseConfirmedByBlitztext,
              !session.externalChangeDetected,
              !session.restorationAttempted,
              currentState == .paused else {
            return false
        }

        session.restorationAttempted = true
        self.session = session
        return true
    }

    mutating func invalidate(_ handle: MediaPlaybackSessionHandle) {
        guard session?.id == handle.id else { return }
        session = nil
    }
}
