# Blitztext App

Blitztext App is an experimental open-source macOS menubar app for turning speech into text.

It is intentionally small and unfinished. The goal is to make a real workflow visible and hackable: press a hotkey, speak, get text back, optionally rewrite it, and paste it into the app you were using.

This is a learning and experimentation project, not a polished product.

> Preview status: bring your own OpenAI API key, no hosted backend, no warranty, no support guarantee.

## What It Does

- **Blitztext**: record speech and transcribe it.
- **Blitztext+**: record speech, transcribe it, then turn the rough draft into cleaner writing.
- **Translate EN**: dictate in German and paste a close English translation for coding prompts.
- **Blitztext $%&!**: turn frustrated speech into a calmer message.
- **Blitztext :)**: add fitting emojis to dictated text.
- **Media playback**: optionally pause active Spotify or YouTube playback in
  Chrome while dictating, then restore only a pause owned by Blitztext. The
  popover shows the pause/restoration state. If Spotify and YouTube both
  explicitly report active playback, Blitztext pauses each confirmed source
  and restores only those owned pauses. It fails open when ownership or
  permission cannot be confirmed.

## Important Preview Notes

- macOS only.
- Bring your own OpenAI API key.
- No hosted Blitztext backend is included or provided.
- In online mode, audio and text are sent directly from the app to the OpenAI API.
- Optional local transcription via WhisperKit/CoreML if you install a compatible model locally.
- Media playback control is limited to Spotify and YouTube in Chrome, is
  state-aware, and fails open when macOS cannot verify or control the source.
- `./build.sh` creates a locally signed development app. No notarized release binary is provided.
- Not production ready.
- No warranty and no support guarantee.

You are welcome to use, fork, adapt, and share this project under the license terms.

The intent is not to ship a one-click finished app. The intent is to make a real AI workflow understandable: clone it, build it, read the code, change it, break it, fix it, and suggest improvements. If you only want to download something and never look inside, this preview will probably feel rough. If you want to learn how a small native macOS AI app is put together, you are in the right place.

## Screenshots

<table>
  <tr>
    <td><img src="docs/screenshots/online-mode.png" alt="Blitztext online transcription mode" width="420"></td>
    <td><img src="docs/screenshots/local-mode.png" alt="Blitztext secure local transcription mode" width="420"></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/local-model-picker.png" alt="Blitztext local model picker" width="420"></td>
    <td><img src="docs/screenshots/settings-customize.png" alt="Blitztext settings and customization view" width="420"></td>
  </tr>
</table>

## Requirements

- macOS 14 or newer
- Xcode 16 or newer (Swift 5.10), with Command Line Tools installed and selected for `xcodebuild`
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the Xcode project
- For online transcription and rewriting: an OpenAI API key with access to:
  - `whisper-1` for transcription
  - `gpt-4o-mini` and optionally `gpt-4o` for rewriting
- For local-only transcription: a WhisperKit CoreML model in:
  `~/Library/Application Support/Blitztext/models/whisperkit/`

The build also pulls one Swift Package dependency automatically:

- [`argmax-oss-swift`](https://github.com/argmaxinc/argmax-oss-swift) (WhisperKit) — used for local on-device transcription.

Install XcodeGen if needed:

```bash
brew install xcodegen
```

## Build And Run

```bash
git clone https://github.com/cmagnussen/blitztext-app.git
cd blitztext-app
./build.sh --run
```

For a local install into `/Applications`:

```bash
./build.sh --install --run
```

The generated `.app` is signed for local development only. The build script
prefers a local Apple Development identity and falls back to ad-hoc signing. Do
not treat it as a trusted redistributable binary. A public binary release would
need Developer ID signing and notarization.

On first launch, either paste your own OpenAI API key for online workflows or install a WhisperKit CoreML model for local transcription. Rewriting workflows still require OpenAI.

For fully local transcription, install a WhisperKit CoreML model and enable **Sicherer Lokaler Modus** in the app.

For a slower, more explicit walkthrough, see [docs/setup.md](docs/setup.md).

## Permissions

Blitztext asks for:

- **Microphone**: to record your voice.
- **Accessibility**: to paste the result back into the app you were using and
  to control YouTube's visible player controls in Chrome.
- **Automation / System Events**: macOS may ask for this when Blitztext sends
  the paste command through System Events or reads and controls Spotify.

If you do not grant Accessibility permission, you can still copy results manually.

Full Disk Access is not required. If auto-paste does not work even though transcription succeeds, open **System Settings -> Privacy & Security -> Accessibility**, enable Blitztext there, restart Blitztext, and try again with the cursor focused in a text field. If macOS prompts for Automation access to System Events, allow it so Blitztext can send the paste command. If macOS shows multiple Blitztext entries, remove or disable the old ones and grant the permission to the app you just built or installed.

For Spotify playback control, allow Blitztext under **System Settings -> Privacy & Security -> Automation** when macOS asks. YouTube in Chrome uses the Accessibility permission. If media control is unavailable, dictation continues and no playback is started automatically.

## Shortcuts

All six workflows have configurable global shortcuts. Open **Einstellungen -> Anpassen**, choose a workflow card, and click **Ändern** or its keycap field. Press the desired combination to save it. A shortcut may use `Fn`, `Shift`, `Ctrl`, `Option`, or `Cmd` plus one letter, number, Space, or F-key. Single ordinary keys, Escape, and media keys are not accepted. Existing defaults remain available through the reset controls.

The **Halten** mode records while the shortcut is held and stops on release. The **Drücken** mode starts and stops with repeated presses; Escape remains the fixed cancellation key. The switch or the clear button disables a workflow without discarding its saved shortcut. Shortcut changes take effect immediately and do not interrupt an ongoing recording.

## Data Flow

The preview has no custom backend.

```text
Online transcription: Your Mac -> OpenAI Audio Transcriptions API
Text rewriting:       Your Mac -> OpenAI Chat Completions API
Local transcription:  Your Mac -> WhisperKit/CoreML on device
Media playback:       Your Mac -> local Spotify/Chrome controls
```

Media playback state is inspected and controlled locally. It does not send
audio, track data, or browser data to a Blitztext service, and it adds no
network destination. See [docs/media-playback-during-dictation.md](docs/media-playback-during-dictation.md)
for the exact safety and scope rules.

The app stores your OpenAI API key in the user's macOS Keychain.

The settings section **API-Verbrauch** shows the last successful OpenAI action plus today's and this month's usage with an estimated USD cost. These figures are local estimates recorded on your Mac from this feature onward and cover only Blitztext calls. Your OpenAI [usage dashboard](https://platform.openai.com/usage) remains authoritative for billing. See [docs/runtime-data.md](docs/runtime-data.md) for the local usage file.

Read [docs/privacy.md](docs/privacy.md) before using the preview with sensitive content.

## Project Structure

```text
BlitztextMac/
  App/          App lifecycle and paste handling
  Features/     Workflows, menu bar UI, settings
  Services/     Recording, OpenAI calls, hotkeys, local storage
  Views/        Shared SwiftUI views
build.sh        Local build script
docs/           Setup, privacy, roadmap, preflight, landing page notes
```

## Local Models

Local transcription is available as an experimental WhisperKit/CoreML path. The app does not bundle a model; choose one in the app, click install, and then switch on **Sicherer Lokaler Modus** from the menu bar or settings.

See [docs/local-models.md](docs/local-models.md).

## Contributing

Contributions are welcome, especially if they make the preview easier to build, understand, or fork.

Please read [CONTRIBUTING.md](CONTRIBUTING.md) first.

## Support And Roadmap

This preview has no formal support promise. See [SUPPORT.md](SUPPORT.md) for how to ask for help without sharing secrets.

The current direction is documented in [ROADMAP.md](ROADMAP.md). Maintainer-facing release checks live in [docs/open-source-preflight.md](docs/open-source-preflight.md).

## License

Code is released under the MIT License. See [LICENSE](LICENSE).

Project names, logos, and app icons are not automatically granted as trademarks or brand assets. See [TRADEMARKS.md](TRADEMARKS.md).

## Legal / Impressum & Datenschutz

This is an experimental, non-commercial open-source project, provided as-is under the MIT License without warranty or support. Nothing is sold here and no installation or operation is performed on your behalf.

The companion website (blitztext.de) is operated by Blackboat Internet GmbH:

- Impressum: https://www.blackboat.com/impressum
- Datenschutz / Privacy: https://www.blackboat.com/datenschutz
