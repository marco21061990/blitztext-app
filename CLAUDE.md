# Blitztext Agent Guide

This file is the authoritative working guide for coding agents in this repository.
`AGENTS.md` and `CLAUDE.md` must stay byte-for-byte identical. When one changes,
copy the exact same content to the other file and verify with `cmp`.

## Project Summary

Blitztext is an experimental open-source macOS menu bar app written in Swift and
SwiftUI. It records speech, transcribes it, optionally rewrites the text through
OpenAI, then copies or auto-pastes the result into the previously active app.

The app has no hosted Blitztext backend. Remote mode sends data directly from
the user's Mac to OpenAI. Local transcription uses WhisperKit/CoreML models
stored under the user's Application Support directory. Local rewriting is not
implemented.

## Non-Negotiable Boundaries

- Do not commit secrets, API keys, private audio, transcripts, local model files,
  `.env` files, generated `.xcodeproj` folders, build artifacts, or local app
  bundles.
- Do not describe remote OpenAI workflows as local, offline, private, or
  end-to-end encrypted.
- Do not add telemetry, analytics, hosted services, auto-update channels, or new
  network destinations without explicit product and privacy review.
- Treat Accessibility, pasteboard handling, Keychain access, and model download
  logic as security-sensitive.
- Keep macOS preview scope honest: macOS only, developer-built app, no notarized
  public release, no support guarantee.
- Keep code comments and commit messages in English.

## Repository Layout

```text
BlitztextMac/
  App/
    AppState.swift                 Central app state, settings persistence,
                                   workflow orchestration, clipboard and paste.
    BlitztextMacApp.swift          App entry point, NSStatusItem, popover,
                                   hotkey dispatch.
    MenuBarStatusController.swift  Menu bar icon rendering and status animation.
  Features/
    MenuBar/                       Main popover UI and workflow active views.
    Settings/                      Access, API key, install, cleanup, workflow
                                   customization settings.
    Workflows/                     Workflow protocol, workflow types, settings,
                                   transcription and rewrite workflows.
  Services/
    AccessibilityPermissionService.swift
    AppSupportPaths.swift
    AutoPasteService.swift
    AudioRecorder.swift
    BlitztextCleanupService.swift
    BlitztextInstallLocationService.swift
    HotkeyService.swift
    KeychainService.swift
    LLMService.swift
    LaunchAtLoginService.swift
    LocalTranscriptionService.swift
    OpenAIKeyValidationService.swift
    TranscriptionQualityService.swift
    TranscriptionService.swift
  Views/
    WaveformView.swift
  Resources/                       Info.plist, entitlements, app icon, menu icon.
  project.yml                      XcodeGen project definition.
docs/                              User docs plus agent-facing project docs.
build.sh                           XcodeGen + xcodebuild + local signing helper.
```

## Build And Verification

Use the repository root as the working directory.

```bash
./build.sh --debug
```

The script:

1. Verifies full Xcode is available.
2. Generates `BlitztextMac/BlitztextMac.xcodeproj` with XcodeGen.
3. Builds the `BlitztextMac` scheme for macOS.
4. Verifies a universal `arm64 x86_64` binary.
5. Copies resources and signs `Blitztext.app`, preferring a local Apple
   Development codesigning identity and falling back to ad-hoc signing.

There is currently no automated test target. For code changes, run the debug
build at minimum. For behavior changes touching recording, paste, permissions,
Keychain, OpenAI calls, or local models, also perform a manual app smoke test on
macOS.

CI runs `.github/workflows/ci.yml` on `main` and pull requests. It performs a
basic secret-hygiene scan, selects Xcode 16, installs XcodeGen if needed, then
runs `./build.sh --debug`.

## Architecture Map

- `AppDelegate` owns the menu bar item, popover, app activation policy, and
  hotkey event dispatch.
- `AppState` is the main `@Observable @MainActor` state container. It owns the
  active workflow, popover page, app settings, download progress, permission
  status, and output handling.
- Workflows conform to `Workflow` and emit `WorkflowPhase` changes plus final
  text through `onOutput`.
- `AudioRecorder` records temporary `.m4a` files to `FileManager.default
  .temporaryDirectory`.
- `TranscriptionService` sends audio to OpenAI `audio/transcriptions` using
  `whisper-1`.
- `LocalTranscriptionService` loads or downloads WhisperKit/CoreML models and
  transcribes audio on device.
- `LLMService` sends rewrite requests to OpenAI Chat Completions using
  `gpt-4o-mini` or `gpt-4o`.
- `OpenAIKeyValidationService` checks the stored OpenAI API key against
  OpenAI's models endpoint when the user explicitly clicks the test button.
- `AppState` restores the target app and delegates insertion to
  `AutoPasteService`. It first tries to insert into the focused Accessibility
  text element, then falls back to the pasteboard plus the target app's
  Accessibility paste menu item or a synthetic Cmd+V event.

Detailed references:

- `docs/architecture.md`
- `docs/runtime-data.md`
- `docs/workflows.md`
- `docs/development.md`

## Runtime Data And Privacy

Local user data lives outside the repo:

```text
~/Library/Application Support/Blitztext/settings.json
~/Library/Application Support/Blitztext/models/whisperkit/
~/Library/Caches/app.blitztext.mac/
~/Library/Preferences/app.blitztext.mac.plist
~/Library/Saved Application State/app.blitztext.mac.savedState/
```

The OpenAI API key is stored in the user's macOS Keychain under service
`app.blitztext.preview.credentials`.

Temporary recordings are written to the system temp directory as
`blitztext-<UUID>.m4a` and are removed after processing or cancellation on best
effort. Final generated text remains on the clipboard as a fallback when
auto-paste fails.

## Common Change Paths

### Add Or Change A Workflow

1. Update `WorkflowType` in `BlitztextMac/Features/Workflows/WorkflowProtocol.swift`.
2. Add or update the workflow class in `BlitztextMac/Features/Workflows/`.
3. Wire availability and construction in `AppState.startWorkflow(_:)` and
   `AppState.isWorkflowAvailable(_:)`.
4. Add UI in `MenuBarView` and settings in `SettingsContentView` if needed.
5. Add persistence fields to `SettingsContainer` only when user-configurable
   state is required.
6. Update `docs/workflows.md` and `README.md` if behavior changes for users.

### Change OpenAI Behavior

1. Update `TranscriptionService` for audio transcription changes.
2. Update `LLMService` for rewrite model, prompt, temperature, or response
   parsing changes.
3. Verify `docs/privacy.md`, `docs/runtime-data.md`, and `README.md` still
   accurately state what leaves the device.
4. Never log API keys, raw audio, raw prompts, or generated private content.

### Change Local Model Behavior

1. Update `LocalTranscriptionService` model constants, validation, download, or
   pipeline loading logic.
2. Update `docs/local-models.md` and `docs/runtime-data.md`.
3. Treat Hugging Face model download paths and model validation as
   supply-chain-sensitive.

### Change Build Settings

1. Update `BlitztextMac/project.yml`.
2. Regenerate via `./build.sh --debug` or `xcodegen generate` from
   `BlitztextMac/`.
3. Do not commit generated `.xcodeproj` contents unless the repo policy changes.
4. Update `docs/development.md` if commands or requirements change.

## Current Risk Areas

- No automated unit test target exists yet.
- Remote workflows depend on legacy OpenAI Chat Completions request code.
- The app currently runs without App Sandbox. Hardened Runtime is enabled, but
  Accessibility paste and global hotkeys are broad permissions.
- The app does not pin TLS certificates for OpenAI or Hugging Face.
- Local model downloads trust the configured Hugging Face repository and validate
  only expected compiled model folder names.
- Generated text intentionally stays on the clipboard after auto-paste.

When touching these areas, update docs and explain the risk trade-off in the PR
or commit notes.

## Documentation Expectations

Keep these files current when behavior changes:

- `README.md`: user-facing overview and build instructions.
- `docs/setup.md`: step-by-step setup and troubleshooting.
- `docs/privacy.md`: user-facing data handling.
- `docs/local-models.md`: local WhisperKit model details.
- `docs/architecture.md`: code structure and ownership.
- `docs/runtime-data.md`: local storage, external calls, permissions.
- `docs/workflows.md`: workflow behavior and extension points.
- `docs/development.md`: build, CI, verification, contribution mechanics.

After changing this file, run:

```bash
cmp -s AGENTS.md CLAUDE.md
```
