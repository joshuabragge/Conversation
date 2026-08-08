# Conversation

A hands-free, on-device conversation-translation app for iOS — practice a
language solo, on a walk, with headphones.

Apple Translate's Conversation mode and Google Translate's equivalent both
assume two people talking near one shared phone. Neither is built for one
person, alone, with headphones in: Apple's mode doesn't route well through a
headphone mic, and Google's needs network and handles headphone audio
routing poorly. This app is narrower and more specific: pick two languages
once, then just talk — in either language, in any order — and hear the
translation spoken back through your headphones, with no button presses and
no network once initial setup is done.

## How it works

1. **Listen continuously.** A voice-activity detector segments your speech
   into turns automatically — no push-to-talk.
2. **Identify the language.** A small on-device WhisperKit model decides
   which of your two chosen languages you just spoke, from the audio itself.
3. **Transcribe.** Apple's on-device `Speech` framework transcribes that
   clip in the now-known-correct locale.
4. **Translate.** Apple's `Translation` framework translates it to the
   other language.
5. **Speak it back.** `AVSpeechSynthesizer` speaks the translation, with the
   audio session temporarily switched to a playback-optimized config so
   Bluetooth headphones aren't stuck in low-quality call-audio mode for it.
6. **Back to listening**, automatically.

A manual language chip lets you override a wrong auto-detect guess.
Everything after first-run setup (WhisperKit model download, Translation
language-pack download) runs fully offline.

## Requirements

- Xcode 16.2+ (iOS 18.2 SDK)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) — the `.xcodeproj` is generated from `project.yml`, not checked in
- iOS 18.0+ deployment target (required by the dynamic `TranslationSession.Configuration` API — 17.4 only has a fixed-pair overload)
- A real device with headphones for anything beyond a compile check — see [Simulator limitations](#simulator-limitations) below

## Setup

```bash
xcodegen generate
open Conversation.xcodeproj
```

Or from the command line:

```bash
xcodegen generate
xcodebuild -project Conversation.xcodeproj -scheme Conversation \
  -destination 'platform=iOS Simulator,name=iPhone 16' build
```

First launch needs network twice, regardless of simulator/device: WhisperKit
downloads its tiny language-ID model from Hugging Face on first use, and
Translation downloads the language pack for whichever pair you pick during
onboarding. Both are cached on-device after that.

**Re-run `xcodegen generate` after adding, removing, or renaming any Swift
file** — the project file is a build artifact of `project.yml` + whatever's
on disk at generation time, not a live index.

## Simulator limitations

The simulator can build and run the UI, but can't meaningfully exercise:
mic input quality, on-device STT/WhisperKit accuracy, Bluetooth audio
routing/quality, or the headphone-disconnect/interruption handling. Treat a
successful simulator build as "compiles and the view graph type-checks," not
as "works." Anything involving real audio needs a physical device.

## Testing

```bash
xcodebuild -project Conversation.xcodeproj -scheme Conversation \
  -destination 'platform=iOS Simulator,name=iPhone 16' test
```

Unit tests cover `VADSegmenter` (turn-segmentation hysteresis, against
synthetic buffers) and `LanguageIdentifier`'s confidence-renormalization
math (against fixture probabilities) — the two pieces of logic that don't
need a device or a loaded model to verify. Everything else is manual,
on-device testing.

## Architecture

```
Conversation/
  App/            App entry, root navigation (Onboarding vs. Conversation), persisted language pair
  Audio/          AVAudioSession state machine, mic capture, VAD, earcons
  Speech/         WhisperKit language-ID, on-device transcription
  Translation/    Apple Translation framework bridge, language-pack checks
  Output/         Text-to-speech
  Conversation/   The central turn state machine
  Models/         LanguagePair, on-device language-support detection
  Permissions/    Mic + speech-recognition auth
  Config/         Tunable thresholds, timeout helper
  UI/             Onboarding, Conversation, Settings screens
```

### Module responsibilities

- **`AudioSessionManager`** — owns two `AVAudioSession` configs, switched at
  turn boundaries: *Listening* (`.playAndRecord`, mic on) and *Speaking*
  (`.playback`, mic off). This split exists specifically so Bluetooth
  accessories can renegotiate up to A2DP for TTS output instead of staying
  pinned to HFP (mono, low-bitrate) for the whole session — the likely
  reason similar apps sound bad over AirPods.
- **`MicrophoneInputManager`** — the continuous mic tap for hands-free
  listening. Deliberately *not* main-actor-isolated: it runs on the
  real-time audio thread and does cheap per-buffer work (VAD energy calc,
  optional file write) inline rather than hopping actors dozens of times a
  second. Only the rare start/end events cross over to the main actor.
- **`VADSegmenter`** — streaming energy + hysteresis voice-activity
  detection with an adaptive noise floor, built on WhisperKit's
  `AudioProcessor` energy primitives (not reimplemented RMS math).
  WhisperKit's own `EnergyVAD` is batch-oriented (whole waveform at once);
  this is the streaming/incremental equivalent for a live mic feed.
- **`LanguageIdentifier`** — one WhisperKit `detectLangauge(audioArray:)`
  pass (note: that's the framework's actual, misspelled, public API name)
  per turn, renormalized across just the two chosen languages rather than
  WhisperKit's full ~100-language distribution, since a binary choice is
  all that matters here.
- **`SpeechRecognizerWrapper`** — one-shot on-device transcription via
  `SFSpeechURLRecognitionRequest` once the language is known. Polls with a
  bounded timeout rather than trusting `SFSpeechRecognizer`'s own `isFinal`
  callback alone — some real headphone routes never call it back at all
  (see gotchas in `CLAUDE.md`).
- **`TranslationService`** — bridges Apple's `Translation` framework, whose
  only way to obtain a session is a SwiftUI `.translationTask` view
  modifier, into an async API callable from anywhere. A hidden
  (`TranslationSessionHost`) view stays mounted at the app root for this.
- **`ConversationLoopController`** — the actual turn state machine tying
  everything above together; see `TurnState` for the full state list.

### Why WhisperKit only for language-ID, not transcription

`SFSpeechRecognizer` supports exactly one active on-device recognition task
at a time — confirmed via reproducible testing, not just suspected. That
ruled out the original plan (guess a locale, retry the other one live if
unconfident) as a reasonable design. Instead: one cheap WhisperKit pass
answers "which of these two languages?" definitively, and Apple's own STT —
generally more accurate for actual transcription than Whisper's tiny model —
handles the transcription once the locale is known. This also keeps the
dependency footprint narrow: only a small (~75–150MB) language-ID model is
needed, not a full transcription-quality one.

## Current status

All of M0–M8 are built and compile clean with passing tests:

- [x] M0 — Project scaffold
- [x] M1 — On-device STT (manual trigger)
- [x] M2 — Translation framework wired up
- [x] M3 — TTS output
- [x] M4 — Audio session Listening/Speaking state machine + earcons
- [x] M5 — WhisperKit language identification
- [x] M6 — Confidence-gated accept/reject
- [x] M7 — Hands-free VAD-driven loop (no more push-to-talk)
- [x] M8 — Real onboarding/conversation/settings UI
- [ ] M9 — Hardening: device/firmware matrix, battery/thermal, accessibility, App Store prep

M0–M4 have been confirmed working on a real device (iPhone + AirPods, and
without headphones). M5–M8 compile and pass their unit tests but have not
yet been exercised on a real device — see the manual test checklist below
before trusting them.

## Known simplifications / open risks

- **`SupportedLanguages`** starts from a curated candidate list, then
  filters it against `SFSpeechRecognizer.supportedLocales()` at runtime.
  There's no bulk "list every language" API on the `Translation` side, so
  the candidate list itself isn't derived from anything — it's a
  reasonable starting set, not an exhaustive one.
- **Language-ID confidence threshold (0.6, in `RecognitionConfig`)** is a
  sensible starting default, not a measured value — needs tuning against
  real bilingual speech.
- **VAD thresholds** are unverified outdoors (wind, traffic, walking noise)
  — only tested against synthetic buffers so far.
- **No programmatic way to install a missing on-device STT locale, TTS
  voice, or force a specific Translation pack download** — the app can only
  point the user at Settings for any of these.
- Real Bluetooth HFP↔A2DP switching latency/glitches between turns haven't
  been measured on hardware.

## Manual test checklist (do this before trusting M5–M8)

1. Fresh install, walk through onboarding end-to-end, including the
   language-pack priming step.
2. Say phrases in both languages, several times each — check language-ID
   accuracy and how the 0.6 confidence threshold feels.
3. Full hands-free loop: tap Start, just talk, no buttons — does turn
   segmentation feel natural (cut off mid-sentence? too slow to respond?).
4. Settings: voice picker actually changes the voice, rate slider has an
   audible effect, VAD sensitivity presets change cutoff timing.
5. Pull headphones mid-session and place a call mid-session — should pause
   gracefully, not crash.

## License

[PolyForm Noncommercial 1.0.0](LICENSE.md) — free to use, modify, and share
for any noncommercial purpose. Commercial use requires a separate
arrangement with the copyright holder.
