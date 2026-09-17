# Media Playback During Dictation

Status: IMPLEMENTED - manual runtime acceptance pending
Last updated: 2026-09-17
Decision source: approved grilling session

## Purpose

When a Blitztext voice workflow starts, temporarily pause the active media
source so that music or other playback does not interfere with dictation. The
first release targets Spotify and YouTube in Chrome. The feature is local to
the Mac and must not add a backend, telemetry, or a new network destination.

## Confirmed product decisions

- Apply the feature to every Blitztext workflow that records speech.
- AirPods are not a special trigger or filter. The behavior is identical for
  AirPods, Mac speakers, and other audio devices.
- Pause playback; do not change volume or mute an application.
- Control an active supported media source, not every open application. If no
  supported player is frontmost and multiple supported sources explicitly
  report `playing`, pause each one only after its own state-aware confirmation
  and treat the confirmed pauses as one recording session.
- First-release acceptance is limited to Spotify and YouTube in Chrome. Other
  players remain untouched until separately supported.
- Try to pause before recording starts, with a maximum 500 ms control window.
  The recording must start after that limit even when media control fails.
- If no media is playing, do nothing. Never send Play to start a source that
  was not playing at the beginning of the session.
- If the initial playback state is unknown, do not pause and do not later send
  Play for that session.
- Resume only a source that was confirmed as playing and confirmed as paused by
  Blitztext itself. Each source has independent ownership and restoration
  checks.
- After successful insertion, resume each owned source. For cancellation,
  rejected recordings, or processing errors, restore it once the terminal
  outcome is known.
- If the user or another process starts playback, do not pause it again and do
  not send an additional Play command at the end.
- If the active player changes, protect the original session and do not start
  the new player.
- Each recording/retry gets its own media session and ownership state.
- Add an enabled-by-default setting that the user can turn off.
- If a required permission is missing while the setting is enabled, explain it
  at app start and offer a path to macOS System Settings.
- If permission is denied, keep the feature enabled and fail open: recording
  continues and runtime control failures are written to logs only.
- Do not block dictation because media control is unavailable.

## Non-goals

- Universal control of every installed or open media application.
- AirPods connection detection as a feature condition.
- Volume restoration or application-wide muting.
- Automatic playback when nothing was playing.
- Private framework use or an unverified blind play/pause toggle.
- New services, telemetry, analytics, or network calls.

## Feasibility gate

Do this before implementing the production coordinator:

1. Prove a state-aware Spotify path on the current macOS installation: detect
   playback state, pause, detect the resulting state, and resume only the
   owned session.
2. Prove the equivalent path for YouTube playback in Chrome. Test ordinary
   video and at least one unsupported or non-playing tab.
3. Record the required macOS permission, the user-facing explanation, and the
   behavior when permission is denied.
4. Confirm that the implementation can distinguish an explicit pause from a
   toggle that could accidentally start paused media.

Stop and reopen the scope decision if a player cannot provide a safe,
state-aware path. Do not ship a global toggle that can start media which was
already paused.

### Gate result

The gate passed on 2026-09-16 on the current macOS installation:

- Spotify exposed a readable `player state`. An explicit test sequence observed
  `paused`, sent `play`, observed `playing`, sent `pause`, and observed
  `paused` again. The original paused state was restored after the test.
- YouTube in Chrome exposed the `movie_player` Accessibility container and an
  explicit `Pause` button. Pressing that button changed the exposed control to
  `Play`; pressing `Play` changed it back to `Pause`. This proves explicit
  state-aware controls rather than a blind toggle.
- A paused YouTube video was left paused, and `example.com` exposed no YouTube
  player. Neither case caused a playback command.
- Chrome's Apple Events JavaScript path was not used. The implementation will
  use the visible Accessibility controls, which are also compatible with the
  app's existing Accessibility permission. Spotify requires macOS Automation
  permission for Apple Events; denial is treated as a runtime control failure
  and remains fail-open.

## Implemented architecture

Introduce a local media-control boundary, for example:

- `MediaPlaybackAdapter`: player-specific capability, state inspection, pause,
  and resume operations.
- `MediaPlaybackCoordinator`: selects the active supported adapter or adapters,
  owns the per-recording session, applies the 500 ms deadline, and handles
  fail-open behavior.
- `MediaPlaybackSession`: records the source identity, initial playing state,
  confirmed pause ownership, external changes, and whether restoration already
  happened.

The coordinator must be idempotent. A stale workflow callback must not restore
or alter a newer session.

## Workflow integration

`AppState` remains the lifecycle owner. All relevant paths route through
AppState-owned methods instead of calling concrete workflow lifecycle methods
directly from the UI or delegate:

- menu and hotkey starts
- hold-mode key-up stops
- toggle-mode stops
- Escape/cancel
- active workflow stop buttons
- retry reset/start
- delayed cleanup

The implementation needs separate lifecycle points for:

1. recording start,
2. recording stop or cancellation,
3. successful output and paste completion,
4. terminal workflow failure.

Workflow completion is not the same event as recording completion because
transcription and rewriting continue after the microphone stops.

## Settings and privacy

Add the feature flag to `AppSettings` so existing JSON settings continue to
decode with the default enabled value. Add the toggle to the customization
settings. Keep the setting and runtime state separate from the API key and
local model state.

The gate identified two existing macOS permission surfaces: Accessibility for
Chrome's visible controls and Automation for Spotify Apple Events. The app is
not sandboxed, so no new entitlement is required. The Apple Events usage text
must be updated to describe both text insertion and supported media control.

Update the relevant user and agent documentation after behavior is implemented:

- `README.md`
- `docs/privacy.md`
- `docs/runtime-data.md`
- `docs/architecture.md`
- `docs/workflows.md`
- `docs/development.md`

## Acceptance scenarios

The implementation is not accepted until these scenarios are evidenced on
macOS:

- Spotify is playing: pause before recording and resume after successful paste.
- YouTube is playing in Chrome: same pause and safe-resume behavior.
- Spotify and YouTube both report `playing`: pause and restore each confirmed
  source independently instead of treating the combination as a no-op.
- The source is already paused: it stays paused; no Play is sent.
- No source is playing: nothing starts later.
- The initial state is unknown: recording proceeds without media control.
- Pause or resume permission is denied: recording still works and no unsafe
  Play is sent.
- Pause cannot be confirmed: no later Play is sent.
- The user manually starts or pauses playback during the workflow: the user
  wins and Blitztext does not fight the change.
- The active player changes: the new player is untouched.
- Cancel, too-short recording, transcription error, rewrite error, paste
  failure, and retry all restore only the session-owned pause according to the
  rules above.
- Both hold and toggle hotkey modes exercise the same lifecycle path.
- All current recording workflows use the same coordinator behavior.

## Verification

- [x] Add focused tests for the coordinator/session state machine, including
  multi-source pause/restore, partial confirmation, stale callbacks, duplicate
  restoration, unknown state, external changes, and timeout behavior.
- [x] Run `git diff --check`.
- [x] Run `./build.sh --debug` from the repository root with full Xcode.
- [ ] Perform the manual macOS scenarios above with Spotify and Chrome.
- [x] Keep local build products, generated Xcode project files, private media, and
  runtime settings outside the commit.

## Evidence log

- 2026-09-16: repository baseline checked at `main`, commit `61d2445`; working
  tree was clean before this planning file was added.
- 2026-09-16: no existing media-control service or audio-device abstraction
  was found. `AudioRecorder` only handles microphone recording.
- 2026-09-16: workflow creation is centralized in `AppState.startWorkflow`,
  but direct stop/reset/start calls also exist in `BlitztextMacApp.swift` and
  `MenuBarView.swift`; those paths must be unified for correct ownership.
- 2026-09-16: Apple's public `MPRemoteCommandCenter` documentation describes
  remote media commands for the active or most recent player; it does not by
  itself establish a universal, state-readable caller-side control path.
- 2026-09-16: feasibility gate passed. Spotify state-aware AppleScript control
  observed `paused -> playing -> paused`; the original paused state was
  restored after the test.
- 2026-09-16: feasibility gate passed for YouTube in Chrome. The Accessibility
  tree exposed `movie_player` with explicit `Pause`/`Play` controls; an
  unsupported `example.com` tab exposed no player and a paused video exposed
  only `Play`.
- 2026-09-16: local implementation completed. `MediaPlaybackCoordinator` uses
  concurrent provider inspection with frontmost-provider priority, serialized
  control actions, a separate 500 ms timeout path, explicit Spotify Apple
  Events and Chrome Accessibility adapters, bounded state reconciliation,
  per-recording ownership, and fail-open restoration rules. All workflow
  lifecycle calls now route through `AppState`.
- 2026-09-16: `MediaPlaybackSessionTests` and
  `MediaPlaybackCoordinatorTests` passed with the Command Line Tools SDK.
  AppState, workflow, service, and view dependencies type-checked in Swift 5
  mode with a temporary WhisperKit API stub; the changed SwiftUI files also
  passed parse.
- 2026-09-16: A separate smoke build of the real adapters read Spotify as
  `paused` with a source ID and a Chrome foreground without a YouTube player
  as `unknown`; the temporary YouTube tab was closed afterwards.
- 2026-09-16: The real Spotify adapter was exercised against the current
  paused track; `pause(...)` returned `paused` without issuing a control action
  and the final state remained `paused`.
- 2026-09-16: The coordinator test suite also covers a confirmed pause that
  returns after the 500 ms deadline; it is restored immediately and is not
  adopted as a recording session.
- 2026-09-16: A fresh Swift 5 typecheck of all app sources except the real
  WhisperKit-backed local service passed with a temporary API-compatible stub;
  a parse-only pass also covered that service. The only diagnostic was the
  existing macOS 14 deprecation warning in paste activation.
- 2026-09-16: an all-source Swift typecheck exceeded the 180-second limit on
  the Command Line Tools host without a diagnostic; the focused partitions
  above completed successfully.
- 2026-09-16: `xcodegen generate` passed. At that time `./build.sh --debug`
  was blocked because the host had only
  `/Library/Developer/CommandLineTools` selected and no full Xcode installation
  was found.
- 2026-09-17: the current worktree built successfully with full Xcode at
  `/Users/marcoschmeikal/Xcode.app`; the resulting app is universal
  (`arm64`, `x86_64`) and locally Development-signed. This proves build and
  packaging readiness only, not the manual player acceptance below.
- 2026-09-17: live Chrome Accessibility inspection showed a playing YouTube
  `movie_player` with an explicit `Pause` control at the current foreground
  tab. The coordinator's real end-to-end pause/restore sequence remains
  pending manual app acceptance.
- 2026-09-17: the running app reproduced the simultaneous-source edge case:
  Spotify and YouTube both logged as `playing`, after which the previous
  exactly-one-source rule intentionally issued no pause. The coordinator was
  changed to pause and independently own every fully identified playing source
  when no supported player is frontmost; a failed confirmation remains
  fail-open for that source.

## Resuming after context compression

When this task resumes after context compression:

1. Read the repository `AGENTS.md` and this file completely.
2. Check `git status --short --branch` and the current commit.
3. Treat the `Status`, `Feasibility gate`, and `Evidence log` as authoritative.
4. Do not repeat completed investigation or assume that a green build proves
   runtime media behavior.
5. Update this file's status and evidence after each meaningful gate.
6. Do not mark the feature complete until the manual Spotify and Chrome
   scenarios and the failure cases are evidenced.

## Next action

Install or select full Xcode, rerun `./build.sh --debug`, then perform the
manual Spotify and Chrome acceptance scenarios plus the documented failure and
hotkey lifecycle cases. Do not mark the feature complete from local tests or a
successful build alone.
