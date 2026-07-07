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

This file is large and security-sensitive. Avoid mixing unrelated refactors with
behavior changes here.

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
| `HotkeyService.swift` | Global and local modifier-key monitors. |
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
