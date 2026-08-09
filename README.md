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
no network once initial setup is done. Listening, language-ID, transcription,
and translation all keep running with the screen locked; spoken output while
backgrounded is a known rough edge — see the background note below.

## How it works

1. **Listen continuously.** A voice-activity detector segments your speech
   into turns automatically — no push-to-talk.
2. **Identify the language.** A small on-device WhisperKit model decides
   which of your two chosen languages you just spoke, from the audio itself.
   If it isn't confident, the same clip gets a second opinion — transcribed
   in both candidate locales and compared for which one actually reads as
   plausible text — before committing to an answer.
3. **Transcribe.** Apple's on-device `Speech` framework transcribes that
   clip in the now-known-correct locale.
4. **Translate.** Apple's `Translation` framework translates it to the
   other language.
5. **Speak it back.** `AVSpeechSynthesizer` speaks the translation, with the
   audio session temporarily switched to a playback-optimized config so
   Bluetooth headphones aren't stuck in low-quality call-audio mode for it
   (foreground only — see the background note in Architecture).
6. **Back to listening**, automatically, once the mic is actually capturing
   again.

A manual language chip lets you override a wrong auto-detect guess, and
gets suggested automatically after a couple of consecutive misses.
Everything after first-run setup (WhisperKit model download, Translation
language-pack download) runs fully offline — including relaunching the app
in airplane mode.

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
downloads its language-ID model from Hugging Face on first use, and
Translation downloads the language pack for whichever pair you pick during
onboarding. Both are cached on-device after that, and reused directly from
disk on later launches without needing network again (see `CLAUDE.md` for
why that second part needed an explicit fix). Settings > Language-Detection
Models lets you trigger the WhisperKit download ahead of time (with a real
progress bar and a downloaded/not-downloaded indicator per model), so you
can get both models cached before you actually leave for a walk instead of
finding out you need one mid-conversation.

**Re-run `xcodegen generate` after adding, removing, or renaming any Swift
file** — the project file is a build artifact of `project.yml` + whatever's
on disk at generation time, not a live index.

## Simulator limitations

The simulator can build and run the UI, but can't meaningfully exercise:
mic input quality, on-device STT/WhisperKit accuracy, Bluetooth audio
routing/quality, background/locked-screen behavior, or the
headphone-disconnect/interruption handling. Treat a successful simulator
build as "compiles and the view graph type-checks," not as "works."
Anything involving real audio needs a physical device — all of the fixes
described in this README and `CLAUDE.md` were found and verified that way,
not in the simulator.

## Testing

```bash
xcodebuild -project Conversation.xcodeproj -scheme Conversation \
  -destination 'platform=iOS Simulator,name=iPhone 16' test
```

Unit tests cover `VADSegmenter` (turn-segmentation hysteresis, against
synthetic buffers) and `LanguageIdentifier`'s confidence math (softmax
renormalization + absolute-confidence gating, against fixture
probabilities, including the exact values from a real device log that
exposed a bug — see `CLAUDE.md`) — the pieces of logic that don't need a
device or a loaded model to verify. Everything else is manual, on-device
testing.

## Architecture

```
Conversation/
  App/            App entry, root navigation (Onboarding vs. Conversation), persisted language pair
  Audio/          AVAudioSession state machine, mic capture, VAD, pre-roll buffer, earcons
  Speech/         WhisperKit language-ID, on-device transcription
  Translation/    Apple Translation framework bridge, language-pack checks
  Output/         Text-to-speech
  Conversation/   The central turn state machine
  Models/         LanguagePair, on-device language-support detection
  Permissions/    Mic + speech-recognition auth
  Config/         Tunable thresholds (several live-editable from Settings), timeout helper
  Logging/        AppLog + in-app Debug Log viewer
  UI/             Onboarding, Conversation, Settings screens
```

### Module responsibilities

- **`AudioSessionManager`** — owns two `AVAudioSession` configs, switched at
  turn boundaries: *Listening* (`.playAndRecord`, mic on) and *Speaking*
  (`.playback`, mic off, foreground only — see below). This split exists
  specifically so Bluetooth accessories can renegotiate up to A2DP for TTS
  output instead of staying pinned to HFP (mono, low-bitrate) for the whole
  session — the likely reason similar apps sound bad over AirPods. Also
  tracks headphone connect/disconnect and system interruptions (calls, etc.)
  and pauses the loop for both.
- **`MicrophoneInputManager`** — the mic tap for hands-free listening, plus
  a ~1s rolling pre-roll buffer (always capturing, independent of VAD
  state) so the actual onset of speech isn't lost to VAD's confirmation
  debounce. Deliberately *not* main-actor-isolated: it runs on the
  real-time audio thread and does cheap per-buffer work inline rather than
  hopping actors dozens of times a second. Only the rare start/end events
  cross over to the main actor.
- **`VADSegmenter`** — streaming energy + hysteresis voice-activity
  detection with an adaptive noise floor, built on WhisperKit's
  `AudioProcessor` energy primitives (not reimplemented RMS math).
  WhisperKit's own `EnergyVAD` is batch-oriented (whole waveform at once);
  this is the streaming/incremental equivalent for a live mic feed.
- **`LanguageIdentifier`** — one WhisperKit `detectLangauge(audioArray:)`
  pass (note: that's the framework's actual, misspelled, public API name)
  per turn, renormalized across just the two chosen languages via softmax
  over their raw log-probabilities — not WhisperKit's full ~100-language
  distribution, since a binary choice is all that matters here. Delegates
  model loading to `WhisperModelManager` rather than caching a model folder
  itself.
- **`WhisperModelManager`** — the single owner of "is this WhisperKit model
  downloaded, and where." Wraps `WhisperKit.download(variant:progressCallback:)`
  to expose real fractional download progress (`@Published downloadProgress`/
  `isDownloading`, keyed by `WhisperModelOption`) and caches the resolved
  model folder per model name in `UserDefaults` so a later load skips
  `download()`'s network call entirely. Used both by `LanguageIdentifier`
  (lazy load on first real use) and Settings' model rows (explicit
  predownload with a progress bar) — one code path either way, so there's
  no risk of the two disagreeing about what's actually on disk.
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
  everything above together (see `TurnState` for the full state list),
  including the cross-check fallback when WhisperKit's absolute confidence
  in its own pick is mediocre (transcribes the same clip in both candidate
  locales via Apple's STT and picks whichever reads as more plausible text
  in its own language, via `NLLanguageRecognizer`).
- **`AppLog`/`LogStore`** — every module logs its state transitions and
  failures through this, mirrored to both Xcode's console and an in-app
  viewer (Settings > Debug Log, or a link on the Welcome screen). This is
  how essentially every fix in `CLAUDE.md` past the first few was actually
  diagnosed — real device behavior that can't be reproduced in the
  simulator needs a way to get evidence back from a device that isn't
  tethered to Xcode.

### Why WhisperKit only for language-ID, not transcription

`SFSpeechRecognizer` supports exactly one active on-device recognition task
at a time — confirmed via reproducible testing, not just suspected. That
ruled out the original plan (guess a locale, retry the other one live if
unconfident) as a reasonable design. Instead: one cheap WhisperKit pass
answers "which of these two languages?" definitively (or triggers a
sequential cross-check against Apple's STT when it isn't sure), and Apple's
own STT — generally more accurate for actual transcription than Whisper's
tiny model — handles the transcription once the locale is known. This also
keeps the dependency footprint narrow: only a small (~75–150MB) language-ID
model is needed, not a full transcription-quality one.

### Why background/locked-screen operation needed care, not just an Info.plist entry

`UIBackgroundModes: audio` is the standard mechanism that lets an active
`AVAudioSession` (and therefore the mic, WhisperKit, Translation, and TTS)
keep running with the screen locked, and it does: mic capture, language-ID,
transcription, translation, and earcon playback are all confirmed working
locked. **Spoken output specifically (`AVSpeechSynthesizer`) is not** —
it goes silent while backgrounded regardless of audio session category, a
long-standing, still-unresolved issue reported by other developers against
this exact framework going back to iOS 13, not something specific to this
app's setup. Two targeted fixes (keeping `.playAndRecord` instead of
switching to `.playback` while backgrounded; rendering to a file played
back via `AVAudioPlayer` instead of `speak()`'s live output) both failed to
resolve it on real-device testing. Current state: a documented community
workaround (`SpeechOutputService.startKeepAliveTone`, a second unrelated
`AVAudioPlayer` tone playing concurrently during synthesis) is applied but
not yet confirmed to work, and a 15s timeout wraps every `speak()` call
regardless (`RecognitionConfig.speechOutputTimeout`) so a stuck synthesis
can't wedge the hands-free loop. If the workaround doesn't pan out, the
plan is to scope spoken output to foreground-only rather than keep chasing
a platform bug. See `CLAUDE.md` for the full isolation story.

## Current status

M0 through M8 are built, and — past the point of just "compiles with
passing unit tests" — have been through multiple rounds of real-device
testing (iPhone, both with AirPods and without) that surfaced and fixed
real bugs no amount of code review alone would have caught: a log-probability
math error that made language auto-detection silently coin-flip since it
was introduced, an `AVAudioSession` category-switch race that produced a
cryptic OSStatus failure and silent TTS, a WhisperKit behavior that required
network on every launch instead of just the first, VAD dropping the onset of
fast speech, and more — see `CLAUDE.md`'s "non-obvious bugs" section for the
full, still-growing list with root causes.

- [x] M0 — Project scaffold
- [x] M1 — On-device STT (manual trigger)
- [x] M2 — Translation framework wired up
- [x] M3 — TTS output
- [x] M4 — Audio session Listening/Speaking state machine + earcons
- [x] M5 — WhisperKit language identification
- [x] M6 — Confidence-gated accept/reject, with a cross-check fallback
- [x] M7 — Hands-free VAD-driven loop (no more push-to-talk)
- [x] M8 — Real onboarding/conversation/settings UI
- [ ] M9 — Hardening: device/firmware matrix, battery/thermal, accessibility, App Store prep

The core loop (listen → identify → transcribe → translate → speak → back to
listening) has been confirmed working end-to-end on a real device in the
foreground, with both the `tiny` and `base` WhisperKit models. Spoken output
while backgrounded/locked is currently unreliable (see the background note
above) and is being actively tested; extended-session battery/thermal
behavior and outdoor VAD performance (wind, traffic) are also still needing
real-world verification — see the checklist below.

## Known simplifications / open risks

- **`SupportedLanguages`** starts from a curated candidate list, then
  filters it against `SFSpeechRecognizer.supportedLocales()` at runtime
  (retrying for a few seconds within one call, since on-device readiness
  has been observed to lag rather than be instantly accurate). There's no
  bulk "list every language" API on the `Translation` side, so the
  candidate list itself isn't derived from anything — it's a reasonable
  starting set, not an exhaustive one.
- **Language-ID confidence threshold and model choice (tiny vs. base) are
  both live-editable in Settings**, not fixed constants — real tuning
  needs real device iteration, which is ongoing. There's no single
  "correct" value yet.
- **The cross-check fallback (`ConversationLoopController.crossCheckLanguage`)
  is a heuristic**, not a guarantee — `NLLanguageRecognizer` is itself
  known to be less reliable on short phrases. It's a second, differently-
  biased opinion, not a solved problem.
- **VAD thresholds** are tuned from real testing but not from extended
  outdoor sessions (wind, traffic, walking noise) — the original synthetic-
  buffer-only defaults have already been adjusted once based on real usage
  (see `RecognitionConfig`/`VADSensitivityPreset`), and will likely need
  more.
- **No programmatic way to install a missing on-device STT locale, TTS
  voice, or force a specific Translation pack download** — the app can only
  point the user at Settings for any of these.
- Real Bluetooth HFP↔A2DP switching latency/glitches between turns haven't
  been formally measured, though nothing in testing so far has flagged it
  as a problem.
- **Background/locked-screen operation** works for everything except spoken
  output: mic, language-ID, transcription, and translation are all confirmed
  running with the screen locked, but `AVSpeechSynthesizer` output is
  currently unreliable while backgrounded (see the background note above) —
  under active investigation, with foreground-only spoken output as the
  fallback plan if the current workaround doesn't hold up. Extended-session
  behavior — memory pressure, CoreML inference speed while backgrounded over
  a long walk, and battery drain — is also still unverified.

## Manual test checklist

1. Fresh install, walk through onboarding end-to-end, including both the
   Translation pack and WhisperKit model priming steps.
2. Auto-detect several turns in each language, switching back and forth —
   check how the confidence threshold and cross-check fallback feel; adjust
   the Settings sliders if it's guessing wrong too often or rejecting too
   eagerly.
3. A/B the `tiny` vs. `base` model in Settings (Advanced) over the same set
   of test phrases — no verified answer yet on whether `base`'s accuracy
   is worth its extra size/latency.
4. Full hands-free loop outdoors, walking, with some wind/ambient noise —
   the main untested condition for VAD.
5. Lock the screen mid-session for an extended period (several minutes,
   several turns) — check the core loop keeps working, and watch for
   battery/thermal effects over a longer walk.
6. Pull headphones mid-session and place a call mid-session — should pause
   gracefully, not crash.
7. Settings: voice picker actually changes the voice (try downloading a new
   one via "Manage voices in Settings" and confirm it shows up without
   relaunching), rate slider has an audible effect, VAD sensitivity presets
   change cutoff timing.
8. Settings > Language-Detection Models: download a model that isn't cached
   yet and confirm the progress bar actually moves and the row flips to
   "Downloaded"; relaunch (or toggle airplane mode) and confirm it loads
   from disk with no network needed.
9. Settings > Languages: change the language pair without going through
   onboarding, including while a conversation is actively running (should
   stop, apply the new pair, and resume) — then use "Refresh available
   languages" after enabling a new dictation language in system Settings and
   confirm it shows up without relaunching the app.

## Debugging

Every module logs its state transitions and failures through `AppLog`,
viewable in-app without a Mac nearby: Settings > Debug Log, or a "Debug
Log" link on the Welcome screen (reachable even mid-onboarding). Use the
Share button there to export the log as text. This is how essentially
every bug in `CLAUDE.md` past the first few was actually root-caused —
default to grabbing a log capture before guessing at a fix for anything
that only shows up on a real device.

## License

[PolyForm Noncommercial 1.0.0](LICENSE.md) — free to use, modify, and share
for any noncommercial purpose. Commercial use requires a separate
arrangement with the copyright holder.
