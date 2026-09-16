# Development

This document captures the practical development workflow for this repository.

## Requirements

- macOS 14 or newer
- full Xcode, not only Command Line Tools
- Xcode 16 or newer
- Swift 5.10
- XcodeGen
- optional OpenAI API key for remote workflows
- optional WhisperKit/CoreML model for local transcription

Install XcodeGen:

```bash
brew install xcodegen
```

If `xcodebuild` points to Command Line Tools only:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

## Build

From the repository root:

```bash
./build.sh --debug
```

Run after building:

```bash
./build.sh --debug --run
```

Install into `/Applications` and run:

```bash
./build.sh --install --run
```

The build output app is signed locally and not notarized. `build.sh` prefers a
local `Apple Development` codesigning identity, which keeps macOS privacy
permissions more stable across rebuilds. Set `BLITZTEXT_CODESIGN_IDENTITY` to
choose a specific identity. If no matching identity is available, the script
falls back to ad-hoc signing.

## Project Generation

`BlitztextMac/project.yml` is the source file for XcodeGen. The generated
`BlitztextMac/BlitztextMac.xcodeproj` is ignored by git.

Regenerate manually if needed:

```bash
cd BlitztextMac
xcodegen generate
```

Usually `./build.sh --debug` is enough because it runs XcodeGen first.

## Tests

There is no unit or UI test target. A few focused, dependency-light checks live
in `Tests/` as standalone `@main` executables. Compile a test together with the
source files it exercises and run it:

```bash
swiftc -o /tmp/blitztext-usage-test \
  Tests/OpenAIUsageTests.swift \
  BlitztextMac/Services/OpenAIUsage.swift \
  BlitztextMac/Services/OpenAIUsageStore.swift \
  BlitztextMac/Services/AppSupportPaths.swift
/tmp/blitztext-usage-test

swiftc -o /tmp/blitztext-overlay-test \
  Tests/RecordingOverlayStateTests.swift \
  BlitztextMac/App/RecordingOverlayState.swift
/tmp/blitztext-overlay-test

swiftc -o /tmp/blitztext-keyvalidation-test \
  Tests/OpenAIKeyValidationServiceTests.swift \
  BlitztextMac/Services/OpenAIKeyValidationService.swift \
  BlitztextMac/Services/KeychainService.swift
/tmp/blitztext-keyvalidation-test

swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk \
  -target arm64-apple-macosx14.0 \
  -o /tmp/blitztext-media-session-test \
  Tests/MediaPlaybackSessionTests.swift \
  BlitztextMac/Services/MediaPlaybackSession.swift
/tmp/blitztext-media-session-test

swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk \
  -target arm64-apple-macosx14.0 \
  -o /tmp/blitztext-media-coordinator-test \
  Tests/MediaPlaybackCoordinatorTests.swift \
  BlitztextMac/Services/MediaPlaybackSession.swift \
  BlitztextMac/Services/MediaPlaybackCoordinator.swift
/tmp/blitztext-media-coordinator-test
```

Each prints on success and exits non-zero on failure. `OpenAIUsageTests` covers
cost calculation, calendar day/month aggregation, usage persistence round-trip,
and API usage response decoding. The media-session and coordinator tests cover
pause ownership, restoration rules, fail-open behavior, and the preparation
deadline without using a real player.

Minimum verification for code changes is still:

```bash
./build.sh --debug
```

Recommended future test seams:

- `TranscriptionQualityService` thresholds and artifact rejection.
- `LLMService` prompt construction, after extracting prompt builders from
  private static functions or testing through a narrower boundary.
- settings decoding migration behavior in `AppSettings`.
- local model option ordering and usable-model validation.
- workflow phase transitions with provider protocols or injected services.

Do not mock away the behavior under review just to create a green test. If a
test uses a fake provider, state exactly which real behavior is still covered.

## Manual Smoke Test

For behavior changes, build and launch the app, then check the relevant path:

1. Open the menu bar popover.
2. Confirm onboarding or settings state is sensible.
3. Add an OpenAI API key only through the app UI.
4. Grant microphone permission.
5. Grant Accessibility only when testing auto-paste.
6. Focus a text field in another app.
7. Run the changed workflow by menu click and by hotkey when applicable.
8. Confirm text is copied or pasted. If auto-paste fails, confirm the app shows
   a copied fallback message instead of claiming the text was inserted.
9. With media playback enabled, verify a playing Spotify or YouTube-in-Chrome
   source pauses before recording and resumes only after successful paste.
10. Verify an already-paused, unsupported, permission-denied, changed, or
    externally resumed source is left alone and that recording still starts.
11. Confirm temporary recordings are removed on best effort.
12. Confirm errors are user-readable and do not expose secrets.

For local transcription changes, also test with a missing model and an installed
model.

For shortcut changes, additionally verify the six migrated defaults, a custom
modifier-plus-key combination from another app, hold and toggle mode, duplicate
and reserved-key rejection, disabling and re-enabling a row, per-row and global
reset, and changing a shortcut while a hold-mode recording is active. A changed
shortcut must not stop that recording before the old combination is released.

## CI

`.github/workflows/ci.yml` runs on pushes to `main` and pull requests.

Steps:

1. Checkout.
2. Run a grep-based secret hygiene scan using
   `.github/secret-scan-patterns.txt`.
3. Select Xcode 16.2 if present, otherwise default Xcode.
4. Install XcodeGen if missing.
5. Run `./build.sh --debug`.

Keep CI read-only unless there is a clear reason to expand permissions.

## Generated And Local Files

Do not commit:

- `BlitztextMac/*.xcodeproj/`
- `.derivedData*/`
- `DerivedData/`
- `build/`
- `Blitztext.app`
- `dist/`
- model files and model directories
- `.env*`
- `Secrets.swift`
- `*.xcconfig`
- user-local Xcode data

The `.gitignore` already covers these.

## Dependency Policy

The only Swift package dependency is WhisperKit through:

```text
https://github.com/argmaxinc/argmax-oss-swift.git
exactVersion: 0.18.0
product: WhisperKit
```

Adding dependencies increases supply-chain and maintenance risk. Prefer standard
Apple frameworks unless the new dependency is clearly justified.

## Documentation Update Rules

When code changes alter user-visible behavior, update:

- `README.md`
- `docs/setup.md`
- relevant focused docs under `docs/`

When code changes alter data flow, update:

- `docs/privacy.md`
- `docs/runtime-data.md`
- `SECURITY.md` if risk posture changes

When agent workflow changes, update both byte-identical files:

- `AGENTS.md`
- `CLAUDE.md`

Verify:

```bash
cmp -s AGENTS.md CLAUDE.md
```
