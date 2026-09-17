import Foundation

@main
struct MediaPlaybackSessionTests {
    static func main() throws {
        try assertPausedAndUnknownSourcesDoNotCreateSessions()
        try assertPauseMustBeConfirmed()
        try assertOwnedPauseRestoresOnlyOnce()
        try assertExternalPlaybackBlocksRestore()
        try assertSourceChangeBlocksRestore()
        try assertStaleCallbacksCannotAffectNewSession()
        try assertPreparationBudget()
        print("MediaPlaybackSessionTests passed")
    }

    private static func assertPausedAndUnknownSourcesDoNotCreateSessions() throws {
        var state = MediaPlaybackSessionStateMachine()
        guard state.begin(sourceIdentifier: "spotify:paused", initialState: .paused) == nil else {
            throw TestFailure("A source that was already paused must not create an owned session")
        }
        guard state.begin(sourceIdentifier: "spotify:unknown", initialState: .unknown) == nil else {
            throw TestFailure("An unknown source must not create an owned session")
        }
        guard state.begin(sourceIdentifier: "", initialState: .playing) == nil else {
            throw TestFailure("A source without an identity must not create an owned session")
        }
    }

    private static func assertPauseMustBeConfirmed() throws {
        var state = MediaPlaybackSessionStateMachine()
        guard let handle = state.begin(sourceIdentifier: "spotify:one", initialState: .playing) else {
            throw TestFailure("Expected a playing source to create a session")
        }
        guard !state.confirmPause(
            handle,
            sourceIdentifier: "spotify:one",
            observedState: .playing,
            receipt: receipt(for: handle, sourceIdentifier: "spotify:one")
        ) else {
            throw TestFailure("A pause must not be owned while the source is still playing")
        }
        guard !state.shouldRestore(handle, sourceIdentifier: "spotify:one", currentState: .paused) else {
            throw TestFailure("An unconfirmed pause must never trigger restoration")
        }
    }

    private static func assertOwnedPauseRestoresOnlyOnce() throws {
        var state = MediaPlaybackSessionStateMachine()
        let handle = try requireHandle(
            state.begin(sourceIdentifier: "spotify:one", initialState: .playing)
        )
        guard state.confirmPause(
            handle,
            sourceIdentifier: "spotify:one",
            observedState: .paused,
            receipt: receipt(for: handle, sourceIdentifier: "spotify:one")
        ) else {
            throw TestFailure("Expected the paused result to confirm ownership")
        }
        guard state.shouldRestore(handle, sourceIdentifier: "spotify:one", currentState: .paused) else {
            throw TestFailure("Expected the owned paused source to be restorable")
        }
        guard !state.shouldRestore(handle, sourceIdentifier: "spotify:one", currentState: .paused) else {
            throw TestFailure("Duplicate restoration must be suppressed")
        }
    }

    private static func assertExternalPlaybackBlocksRestore() throws {
        var state = MediaPlaybackSessionStateMachine()
        let handle = try requireHandle(
            state.begin(sourceIdentifier: "spotify:one", initialState: .playing)
        )
        _ = state.confirmPause(
            handle,
            sourceIdentifier: "spotify:one",
            observedState: .paused,
            receipt: receipt(for: handle, sourceIdentifier: "spotify:one")
        )
        state.observe(handle, sourceIdentifier: "spotify:one", state: .playing)
        state.observe(handle, sourceIdentifier: "spotify:one", state: .paused)

        guard !state.shouldRestore(handle, sourceIdentifier: "spotify:one", currentState: .paused) else {
            throw TestFailure("User or external playback changes must win")
        }
    }

    private static func assertSourceChangeBlocksRestore() throws {
        var state = MediaPlaybackSessionStateMachine()
        let handle = try requireHandle(
            state.begin(sourceIdentifier: "youtube:one", initialState: .playing)
        )
        _ = state.confirmPause(
            handle,
            sourceIdentifier: "youtube:one",
            observedState: .paused,
            receipt: receipt(for: handle, sourceIdentifier: "youtube:one")
        )
        state.observe(handle, sourceIdentifier: "youtube:two", state: .paused)

        guard !state.shouldRestore(handle, sourceIdentifier: "youtube:two", currentState: .paused) else {
            throw TestFailure("A changed active player must not be restored")
        }
    }

    private static func assertStaleCallbacksCannotAffectNewSession() throws {
        var state = MediaPlaybackSessionStateMachine()
        let stale = try requireHandle(
            state.begin(sourceIdentifier: "spotify:old", initialState: .playing)
        )

        state.invalidate(stale)
        let current = try requireHandle(
            state.begin(sourceIdentifier: "spotify:new", initialState: .playing)
        )
        guard !state.confirmPause(
            stale,
            sourceIdentifier: "spotify:old",
            observedState: .paused,
            receipt: receipt(for: stale, sourceIdentifier: "spotify:old")
        ) else {
            throw TestFailure("A stale pause callback must be ignored")
        }
        guard state.confirmPause(
            current,
            sourceIdentifier: "spotify:new",
            observedState: .paused,
            receipt: receipt(for: current, sourceIdentifier: "spotify:new")
        ) else {
            throw TestFailure("The current session must remain controllable")
        }
    }

    private static func assertPreparationBudget() throws {
        let start = Date(timeIntervalSinceReferenceDate: 100)
        let deadline = MediaPlaybackPreparationDeadline(startedAt: start)
        guard !deadline.hasExpired(at: start.addingTimeInterval(0.499)) else {
            throw TestFailure("The preparation budget expired too early")
        }
        guard deadline.hasExpired(at: start.addingTimeInterval(0.5)) else {
            throw TestFailure("The preparation budget must expire at 500 ms")
        }
    }

    private static func requireHandle(_ handle: MediaPlaybackSessionHandle?) throws -> MediaPlaybackSessionHandle {
        guard let handle else { throw TestFailure("Expected a media session handle") }
        return handle
    }

    private static func receipt(
        for handle: MediaPlaybackSessionHandle,
        sourceIdentifier: String
    ) -> MediaPlaybackCommandReceipt {
        MediaPlaybackCommandReceipt(
            sessionID: handle.id,
            sourceIdentifier: sourceIdentifier
        )
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
