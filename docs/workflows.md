# Workflows

Blitztext workflows all follow the same broad lifecycle: record audio, stop,
process the recording, emit final text, then let `AppState` handle paste.

## Shared Contract

`Workflow` is defined in `BlitztextMac/Features/Workflows/WorkflowProtocol.swift`.

Every workflow provides:

- `type`
- `phase`
- `isRecording`
- `onOutput`
- `onPhaseChange`
- `start()`
- `stop()`
- `reset()`

`WorkflowPhase` values:

- `idle`
- `running(String)`
- `done(String)`
- `error(String)`

`AppState.configureWorkflowHandlers(_:)` subscribes to output and phase changes.
Workflows should not own menu bar status or paste behavior.

## Workflow Availability

`AppState.isWorkflowAvailable(_:)` controls whether a workflow can run.

| Workflow | Available When |
| --- | --- |
| `transcription` | OpenAI key exists, or secure local mode is enabled and selected local model is installed. |
| `localTranscription` | Selected local model is installed. |
| `textImprover` | Secure local mode is disabled and OpenAI key exists. |
| `dampfAblassen` | Secure local mode is disabled and OpenAI key exists. |
| `emojiText` | Secure local mode is disabled and OpenAI key exists. |

Secure local mode pauses rewrite workflows because local rewriting is not
implemented.

## Hotkeys

`HotkeyService` maps modifier combinations to `WorkflowType`:

| Hotkey | Workflow |
| --- | --- |
| `fn + Shift` | Blitztext transcription |
| `fn + Shift + Control` | Local transcription |
| `fn + Control` | Blitztext+ text improvement |
| `fn + Option` | Blitztext `$%&!` calmer-message rewrite |
| `fn + Command` | Blitztext `:)` emoji text |

`HotkeyMode.hold` starts on modifier down and stops on release.
`HotkeyMode.toggle` starts on modifier down and stops on the same workflow again
or Escape.

## Transcription Workflow

File: `BlitztextMac/Features/Workflows/TranscriptionWorkflow.swift`

Backends:

- `.remote`: `TranscriptionService.transcribe(...)`
- `.local`: `LocalTranscriptionService.shared.transcribe(...)`

The workflow:

1. Starts `AudioRecorder`.
2. Stops recording and rejects recordings shorter than
   `TranscriptionQualityService.minimumRecordingDuration`.
3. Uses custom terms only when recording duration is at least 0.9 s.
4. Runs remote or local transcription.
5. Cleans and artifact-checks the transcript.
6. Emits `.done(cleaned)` and calls `onOutput`.

## Text Improvement Workflow

File: `BlitztextMac/Features/Workflows/TextImprovementWorkflow.swift`

The workflow:

1. Records audio.
2. Transcribes remotely through OpenAI Whisper.
3. Rejects likely short-recording artifacts.
4. Sends transcript to `LLMService.improve(...)`.
5. Emits improved text.

Settings:

- custom system prompt
- custom terms
- context
- tone
- custom display name

Default model: `gpt-4o-mini`.

## Calmer-Message Workflow

File: `BlitztextMac/Features/Workflows/DampfAblassenWorkflow.swift`

The workflow:

1. Records audio.
2. Transcribes remotely.
3. Sends transcript and configured system prompt to
   `LLMService.dampfAblassen(...)`.
4. Treats exact `KEINE_AUFNAHME_ERKANNT` as an error sentinel.
5. Emits the rewritten message.

Default model: `gpt-4o`.

## Emoji Workflow

File: `BlitztextMac/Features/Workflows/EmojiTextWorkflow.swift`

The workflow:

1. Records audio.
2. Transcribes remotely.
3. Sends transcript to `LLMService.addEmojis(...)`.
4. Applies selected emoji density in the system prompt.
5. Treats exact `KEINE_AUFNAHME_ERKANNT` as an error sentinel.
6. Emits emoji-enriched text.

Default model: `gpt-4o-mini`.

## Transcription Quality Filters

`TranscriptionQualityService` rejects:

- empty cleaned transcript
- transcripts with no letters
- recordings shorter than 0.3 s
- suspiciously long text from very short recordings

These filters protect against accidental hotkey taps and Whisper artifacts. Any
threshold change should be manually tested with short accidental recordings and
normal speech.

## Adding A Workflow

Minimum change path:

1. Add a case to `WorkflowType`.
2. Add labels, icon, subtitle, hotkey label, and accent color.
3. Implement a `Workflow` class in `Features/Workflows/`.
4. Wire construction in `AppState.startWorkflow(_:)`.
5. Wire availability in `AppState.isWorkflowAvailable(_:)`.
6. Add menu row or active view in `MenuBarView`.
7. Add settings structs and persistence only if needed.
8. Update this file, `AGENTS.md`, and user-facing docs if behavior changes.

Do not put paste, clipboard, or menu bar status logic inside a workflow. Keep
that behavior centralized in `AppState`.
