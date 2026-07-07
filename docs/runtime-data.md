# Runtime Data, Permissions, And External Calls

This document is for maintainers and coding agents. It records what data the app
stores, what leaves the device, and which macOS permissions affect behavior.

## Local Files

Blitztext uses these user-local paths:

```text
~/Library/Application Support/Blitztext/settings.json
~/Library/Application Support/Blitztext/models/
~/Library/Application Support/Blitztext/models/whisperkit/
~/Library/Application Support/Blitztext/models/downloads/
~/Library/Caches/app.blitztext.mac/
~/Library/Preferences/app.blitztext.mac.plist
~/Library/Saved Application State/app.blitztext.mac.savedState/
```

`AppSupportPaths.swift` is the source of truth for these paths.

## Settings Persistence

`AppState` encodes a private `SettingsContainer` to:

```text
~/Library/Application Support/Blitztext/settings.json
```

The container currently includes:

- `AppSettings`
- `TranscriptionSettings`
- `TextImprovementSettings`
- optional `DampfAblassenSettings`
- optional `EmojiTextSettings`

Prompt customization, custom terms, and context are stored as plain JSON. Do not
ask users to place secrets in those fields.

## Keychain

The OpenAI API key is stored through `KeychainService`:

```text
service: app.blitztext.preview.credentials
account: openAIAPIKey
accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
```

Never print, log, snapshot, or commit this value. UI display intentionally shows
only a short masked prefix.

## Temporary Audio

`AudioRecorder` writes recordings to:

```text
FileManager.default.temporaryDirectory/blitztext-<UUID>.m4a
```

Encoding settings:

- MPEG-4 AAC
- sample rate 16000
- mono
- high encoder quality

Workflows attempt to remove temporary audio after transcription, cancellation,
or reset. This is best-effort cleanup, not a hard security guarantee.

## Clipboard And Auto-Paste

Final generated text may be written to `NSPasteboard.general` so Blitztext can
send a paste command to the previously active app.

`AppState.writeSensitiveTextToPasteboard(_:)` declares:

- `.string`
- `org.nspasteboard.ConcealedType`

The concealed type may help compatible clipboard managers treat the entry as
sensitive, but the text is still present on the system clipboard while paste is
being attempted. When Blitztext successfully dispatches a paste command, it
attempts to restore the previous clipboard contents after a short delay. If
automatic paste cannot be triggered, the generated text intentionally remains on
the clipboard so manual Cmd+V is still possible.

Auto-paste uses Accessibility trust. `AppState` captures the previously
frontmost app before opening the popover or before a background hotkey workflow
starts. `AutoPasteService` writes the result to the general pasteboard, tries to
send Cmd+V through System Events, then falls back to a synthetic Cmd+V through
`CGEvent`, then the target app's Accessibility paste menu item. Direct
`AXSelectedText` insertion remains available in the service code but is no
longer the default auto-paste path.

## macOS Permissions

### Microphone

Required for recording through `AVAudioRecorder`.

### Accessibility

Required for automatic paste into the previously active app. Without
Accessibility, the app can still copy generated text to the clipboard.

### Automation / System Events

May be requested by macOS when Blitztext sends the paste command through System
Events. Without it, Blitztext falls back to the CGEvent and Accessibility paste
paths.

### Full Disk Access

Not required.

### App Sandbox

Currently disabled. This is documented in `SECURITY.md` as a preview trade-off
for global hotkeys, Accessibility paste, and local model paths. Treat any change
to sandboxing or entitlements as security-sensitive.

## External Network Calls

### OpenAI Key Validation

Implemented in `OpenAIKeyValidationService`.

```text
GET https://api.openai.com/v1/models
```

This request is only made when the user clicks **OpenAI Key testen** in the
settings. It sends the stored API key as a bearer token and does not send audio,
transcripts, prompts, or generated text.

### OpenAI Audio Transcription

Implemented in `TranscriptionService`.

```text
POST https://api.openai.com/v1/audio/transcriptions
model: whisper-1
response_format: text
```

Payload includes the recorded audio file. It can also include:

- custom terms as the `prompt` field when recording duration is at least 0.9 s
- language code from `TranscriptionSettings.language`

### OpenAI Text Rewriting

Implemented in `LLMService`.

```text
POST https://api.openai.com/v1/chat/completions
models: gpt-4o-mini, gpt-4o
```

Payload includes system prompt and user text. The app uses:

- `gpt-4o-mini` for text improvement and emoji insertion
- `gpt-4o` for calmer-message rewriting

### Hugging Face Model Download

Implemented in `LocalTranscriptionService` through WhisperKit.

```text
repo: argmaxinc/whisperkit-coreml
```

Supported model folders:

- `openai_whisper-small_216MB`
- `openai_whisper-large-v3-v20240930_turbo_632MB`
- `openai_whisper-large-v3-v20240930_626MB`

The app validates a local model folder by checking for:

- `AudioEncoder.mlmodelc`
- `MelSpectrogram.mlmodelc`
- `TextDecoder.mlmodelc`

## TLS And Trust

The app uses the system TLS trust store. There is no certificate pinning. A
user-installed or managed root certificate can affect HTTPS trust decisions.

## Cleanup

`BlitztextCleanupService` can remove:

- Keychain API key
- settings JSON
- Application Support directory
- caches
- preferences plist
- saved app state
- launch-at-login registration

Cleanup is best effort. It reports failed paths to the UI.
