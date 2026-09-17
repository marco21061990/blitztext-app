# Runtime Data, Permissions, And External Calls

This document is for maintainers and coding agents. It records what data the app
stores, what leaves the device, and which macOS permissions affect behavior.

## Local Files

Blitztext uses these user-local paths:

```text
~/Library/Application Support/Blitztext/settings.json
~/Library/Application Support/Blitztext/api-usage.json
~/Library/Application Support/Blitztext/models/
~/Library/Application Support/Blitztext/models/whisperkit/
~/Library/Application Support/Blitztext/models/downloads/
~/Library/Caches/app.blitztext.mac/
~/Library/Preferences/app.blitztext.mac.plist
~/Library/Saved Application State/app.blitztext.mac.savedState/
```

`AppSupportPaths.swift` is the source of truth for these paths.

## Local API Usage Log

`OpenAIUsageStore` records one entry per successful, billed OpenAI call to:

```text
~/Library/Application Support/Blitztext/api-usage.json
```

Each record stores only usage metadata:

- a UUID and local timestamp
- kind (`transcription` or `rewrite`)
- exact model string (`whisper-1`, `gpt-4o-mini`, `gpt-4o`)
- billed audio seconds (transcription) or input/output tokens (rewrite)

It never stores audio, transcript text, prompt text, completions, or API keys.
Failed API responses and local WhisperKit transcription are not recorded. A
successfully returned OpenAI call is recorded because it may be billable even if
the workflow later discards its output or is cancelled after the response
arrives. The file is capped at the most recent 10,000 records. A missing or
corrupt file is treated as an empty log and overwritten on the next successful
call.

The settings section `API-Verbrauch` reads this log to show the last action plus
local calendar day and month totals with an estimated USD cost. Cost is
recomputed from the recorded model and raw units against a pricing snapshot in
`OpenAIPricing` (`OpenAIUsage.swift`, snapshot date and official source URLs
annotated in code). All figures are local estimates covering only Blitztext
calls recorded from this feature onward; the OpenAI account billing is
authoritative. The full local-data cleanup also clears the in-memory store and
removes this usage log from disk.

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

`AppSettings` also stores the shortcut configuration as versioned JSON under
`shortcutBindings`. The dictionary key is the workflow raw value; each entry
contains the physical key code (or no standard key for a modifier-only
shortcut), workflow modifier flags, the display label captured from AppKit when
available, and its enabled state.
Missing shortcut data in older settings files migrates to the six historical
defaults. Invalid entries fall back independently to the affected workflow's
default. No shortcut data leaves the device.

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

## Media Playback Coordination

`MediaPlaybackCoordinator` keeps media-control state in memory only. For each
recording or retry it selects a supported frontmost source, or all supported
sources that explicitly report playing when no supported player is frontmost.
It uses an explicit pause or play control only when the preconditions are
confirmed. Spotify is accessed with Apple Events. YouTube in Chrome is
accessed through the focused Chrome window's Accessibility tree and its visible
`movie_player` controls. The coordinator never changes volume or mute state,
never starts a source that was not initially playing, and does not persist
track, URL, browser, or playback data.

Preparation runs off the main thread with a 500 ms budget. Provider inspections
run concurrently; a supported frontmost provider is preferred, while the
fallback path requires a complete inspection and explicit source identity for
every playing provider. Each pause is confirmed and owned independently, so a
failed confirmation for one source does not block a separately confirmed source
or cause an unsafe resume. A timeout, permission denial, unknown state, failed
pause confirmation, or changed player is fail-open: the recording still starts
and no later Play command is sent for that source. If an in-flight control call
returns a confirmed pause after the budget, the coordinator restores that side
effect immediately instead of attaching it to the recording. Runtime
diagnostics contain only provider, state, presence/absence of a source,
decision result, and bounded operation duration. They do not contain track
names, URLs, transcripts, or audio. The popover status is transient in-memory
state and is not persisted.

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

Spotify media control uses the same macOS Automation permission surface. Chrome
media control uses the existing Accessibility permission. The app is not
sandboxed, so this feature adds no new entitlement. If either permission is
denied, media control is skipped and dictation continues.

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
response_format: verbose_json
```

Payload includes the recorded audio file. It can also include:

- custom terms as the `prompt` field when recording duration is at least 0.9 s
- language code from `TranscriptionSettings.language`

The response is requested as `verbose_json` so the app can read the transcript
text and the billed audio `duration`. Only the text and duration are used; the
duration is recorded as usage metadata (see **Local API Usage Log**). No audio or
transcript text is persisted.

### OpenAI Text Rewriting

Implemented in `LLMService`.

```text
POST https://api.openai.com/v1/chat/completions
models: gpt-4o-mini, gpt-4o
```

Payload includes system prompt and user text. The app uses:

- `gpt-4o-mini` for text improvement and emoji insertion
- `gpt-4o` for calmer-message rewriting

On a successful response, the returned `usage` object (prompt and completion
tokens) is recorded as usage metadata (see **Local API Usage Log**). Prompt text
and completions are not persisted.

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
