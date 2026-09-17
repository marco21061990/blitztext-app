# Architecture

Blitztext is a small native macOS app built around one central state object and
a set of workflow classes. The app intentionally avoids a hosted backend:
recording, local model handling, OpenAI calls, and paste behavior all happen
inside the macOS app process.

## High-Level Runtime

```text
User hotkey or menu click
  -> AppDelegate
  -> AppState.startWorkflow
  -> MediaPlaybackCoordinator (bounded, state-aware pause)
  -> Workflow.start
  -> AudioRecorder writes temp m4a
  -> Workflow.stop
  -> TranscriptionService or LocalTranscriptionService
  -> optional LLMService rewrite
  -> WorkflowPhase.done(text)
  -> AppState.handleWorkflowOutput
  -> temporary NSPasteboard + paste command + clipboard restore
```

## App Shell

`BlitztextMac/App/BlitztextMacApp.swift` defines the SwiftUI `@main` app and an
`NSApplicationDelegate`. The delegate creates an `NSStatusItem`, attaches the
menu bar status renderer, builds a transient `NSPopover`, and installs hotkey
callbacks.

The app runs with `.accessory` activation policy, so it behaves like a menu bar
utility instead of a normal Dock app.

## Central State

`BlitztextMac/App/AppState.swift` is the central coordination point. It is
`@Observable` and `@MainActor`, so UI and workflow state changes should stay on
the main actor.

Primary responsibilities:

- current popover page
- active workflow lifecycle
- workflow availability rules
- persisted settings load/save
- local model download progress
- Accessibility permission state
- menu bar status transitions
- capture of the previous frontmost app for auto-paste
- temporary clipboard writes, paste command dispatch, and clipboard restore
- media playback preparation and per-recording pause ownership
- central stop, cancel, retry, paste-completion, and cleanup lifecycle routing

This file is large and security-sensitive. Avoid mixing unrelated refactors with
behavior changes here.

## Media Playback

`BlitztextMac/Services/MediaPlaybackCoordinator.swift` owns the local media
control boundary. `SpotifyMediaPlaybackAdapter` reads and controls Spotify
through Apple Events. `ChromeYouTubeMediaPlaybackAdapter` receives a selection
context captured before Blitztext presents its popover, traverses the selected
Chrome window's Accessibility tree, locates a YouTube `movie_player`, and acts
on one explicit, pressable `Pause` or `Play` button. When no supported app was
frontmost, it may inspect all Chrome windows, but only with a strict YouTube
host allowlist and unique window/document/player/control identity. Both
adapters fail closed for unknown or ambiguous state within their own controls.

`MediaPlaybackSessionStateMachine` is the pure ownership layer. A session is
created only for an initially playing source and only becomes restorable after
the adapter confirms that Blitztext caused the pause. It records source
identity, external changes, and one-time restoration. Polling during processing
detects a user or external playback change; a changed source, unknown state, or
already-playing source prevents restoration.

Adapter inspections run concurrently inside the bounded preparation window. If
Spotify or Chrome is the frontmost supported app, that provider gets priority
and a slow background provider cannot consume the foreground decision window.
When no supported provider is frontmost, selection requires a complete
inspection and explicit source identity for every playing provider. Multiple
fully identified playing providers become one recording session with separate
ownership entries; each pause and restore is confirmed independently. A short,
bounded reconciliation poll ensures an asynchronous player state transition is
not mistaken for a failed or already-owned action.

`AppState` starts a workflow only after the coordinator's preparation callback
or its 500 ms fail-open deadline. All recording workflows share this path.
Recording stop is distinct from cancellation, successful paste completion, and
terminal failure so media restoration happens at the correct lifecycle point.
If a player call completes with a confirmed pause after the deadline, the
coordinator restores it immediately and does not attach it to the recording.
The active media state is exposed in the popover while a source is paused or
being restored, including an explicit message when restoration is skipped or
cannot be confirmed.

## Workflows

Workflow definitions live in `BlitztextMac/Features/Workflows/`.

`WorkflowProtocol.swift` contains:

- `WorkflowType`
- `WorkflowPhase`
- `WorkflowLaunchSource`
- the `Workflow` protocol
- app and workflow settings models

Concrete workflows:

- `TranscriptionWorkflow`: audio to text, using remote OpenAI or local
  WhisperKit depending on selected backend.
- `TextImprovementWorkflow`: remote transcription, then OpenAI text improvement.
- `TranslateENWorkflow`: remote transcription, then conservative German to
  English prompt translation.
- `DampfAblassenWorkflow`: remote transcription, then calmer-message rewrite.
- `EmojiTextWorkflow`: remote transcription, then emoji insertion rewrite.

Each workflow owns its own `AudioRecorder` and emits final text through
`onOutput`. `AppState` owns paste behavior, so workflows should not write to the
clipboard directly.

## Services

Services are mostly static or actor-based boundaries around system or external
APIs.

| File | Responsibility |
| --- | --- |
| `AudioRecorder.swift` | AVAudioRecorder setup, temporary `.m4a` files, metering. |
| `TranscriptionService.swift` | OpenAI audio transcription request. |
| `LLMService.swift` | OpenAI chat completion rewrite requests. |
| `LocalTranscriptionService.swift` | WhisperKit model discovery, download, load, local transcription. |
| `KeychainService.swift` | API key storage in macOS Keychain. |
| `OpenAIKeyValidationService.swift` | Explicit user-triggered OpenAI API key validation request. |
| `HotkeyService.swift` | Global and local modifier/key monitors, configurable shortcut matching, and Escape cancellation. |
| `AccessibilityPermissionService.swift` | AX trust checks and System Settings deep link. |
| `AutoPasteService.swift` | Temporary clipboard paste, System Events and CGEvent Cmd+V dispatch, paste menu fallback, and clipboard restore. |
| `LaunchAtLoginService.swift` | `SMAppService.mainApp` registration. |
| `AppSupportPaths.swift` | Local user data paths. |
| `BlitztextCleanupService.swift` | Best-effort cleanup of local data and login item. |
| `BlitztextInstallLocationService.swift` | Detect and copy app bundle to `/Applications`. |

## UI

`Features/MenuBar/MenuBarView.swift` contains the main popover UI, onboarding,
mode panel, workflow list, settings entry, and active workflow views. It is a
large SwiftUI file. Prefer small, focused edits unless a deliberate view split
is part of the task.

`Features/Settings/SettingsContentView.swift` provides a native AppKit-backed
shortcut recorder. It delegates validation and persistence to `AppState`; it
does not maintain a second shortcut map. While a row records, the hotkey
service ignores new triggers so recording the new combination cannot start a
workflow accidentally. Each workflow is shown as a two-line card with one
canonical keycap display, a labeled active switch, explicit change/cancel and
reset actions, and reserved space for validation errors. The menu bar popover
uses a 430-point content width so the full workflow and shortcut labels remain
readable.

`Features/Settings/SettingsContentView.swift` contains two settings tabs:

- `Anpassen`: workflow customization, local mode, model selection.
- `Zugang`: Accessibility, API key, install location, launch at login, cleanup.

`Views/WaveformView.swift` is a reusable waveform display with a timer-backed
state object.

## Build System

`BlitztextMac/project.yml` is the source of truth for the Xcode project.
`build.sh` runs XcodeGen and builds the generated project. Generated
`.xcodeproj` files are ignored and should normally not be committed.

Important build settings:

- macOS deployment target: 14.0
- Swift: 5.10
- Xcode target version: 16.0
- product bundle identifier: `app.blitztext.mac`
- dependency: `argmax-oss-swift` exact `0.18.0`, product `WhisperKit`
- hardened runtime enabled
- sandbox disabled in entitlements
- audio input and network client entitlements enabled

## Design Constraints

Keep workflows independent from paste behavior. Keep external provider calls
inside services. Keep user-facing privacy claims synchronized with actual code.
When a change affects data flow, update `docs/privacy.md` and
`docs/runtime-data.md` in the same change.

Do not call concrete workflow `start()`, `stop()`, or `reset()` methods from
views or the app delegate. Route those actions through `AppState` so media
ownership remains synchronized.
