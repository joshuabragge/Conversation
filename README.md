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
no network once initial setup is done (with one opt-in exception, off by
default — see [Allowing Apple's servers](#allowing-apples-servers)). The app is deliberately
foreground-only — see "Why the app is foreground-only" below — so instead of
trying to keep working with the screen locked, it just keeps the screen
awake for as long as a session is running.

## How it works

1. **Listen continuously.** A voice-activity detector segments your speech
   into turns automatically — no push-to-talk.
2. **Identify the language.** A small on-device WhisperKit model decides
   which of your two chosen languages you just spoke, from the audio itself.
   If it isn't confident, the same clip gets a second opinion — transcribed
   in both candidate locales and compared for which one actually reads as
   plausible text — before committing to an answer.
3. **Transcribe.** Apple's on-device `Speech` framework transcribes that
   clip in the now-known-correct locale. If iOS has no usable offline
   dictation model for one of your languages, this silently produces
   nothing — see "Allowing Apple's servers" below for the opt-in fallback.
4. **Translate.** Apple's `Translation` framework translates it to the
   other language.
5. **Speak it back.** `AVSpeechSynthesizer` speaks the translation, with the
   audio session temporarily switched to a playback-optimized config so
   Bluetooth headphones aren't stuck in low-quality call-audio mode for it.
6. **Back to listening**, automatically, once the mic is actually capturing
   again.

The screen stays awake (but not locked with the side button) for as long as
a session is running, so the loop above doesn't get interrupted by the
device's own auto-lock timeout mid-walk — see "Why the app is
foreground-only" below.

A manual language chip lets you override a wrong auto-detect guess, and
gets suggested automatically after a couple of consecutive misses.
The default (`tiny`) WhisperKit language-ID model ships inside the app, so
it needs no network at all; the only first-run network dependency is
Apple's Translation framework downloading the language pack for whichever
pair you pick during onboarding. Everything after that runs fully offline —
including relaunching the app in airplane mode.

If loud non-speech noise (traffic, wind, a dog bark) keeps starting a turn
by itself, Settings > Advanced (Experimental) has two VAD sliders for it —
"Noise rejection" (how loud, relative to background, a sound has to be) and
"Minimum sound duration" (filters brief transients like a door slam) — see
`CLAUDE.md` for the reasoning and what a bigger fix would look like if
these aren't enough.

Every session with at least one completed exchange is saved automatically,
accessible from the hamburger button (top left) as a sliding history
drawer — copy a whole past conversation to the clipboard, copy just a
subset of turns via a select mode, or delete individual sessions or all of
them at once.

## Chat history

Tapping the hamburger icon (top left of the main screen) slides in a
history drawer listing every past session, newest first. A session is
whatever happened between one tap of Start and the next — it's saved the
moment it has at least one completed exchange (Start-then-immediately-Stop
with nothing said isn't kept), and kept up to date turn-by-turn while it's
still running, not just once you tap Stop, so swiping the app away mid-walk
doesn't lose it.

- **Swipe a session** in the drawer to copy its whole transcript to the
  clipboard or delete just that one.
- **Delete All** (top right of the drawer) clears every saved session, with
  a confirmation first since it can't be undone.
- **Tap a session** to open its full transcript. "Copy All" copies the
  whole conversation; "Select" enters a mode where tapping individual
  exchanges (each heard/translated pair is one selectable block) toggles a
  checkmark, and "Copy Selected" copies just those.

History is stored as a JSON file in the app's Application Support
directory (`ConversationHistoryStore`), not iCloud/synced anywhere — it's
local to the device.

## Requirements

- Xcode 16.2+ (iOS 18.2 SDK)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) — the `.xcodeproj` is generated from `project.yml`, not checked in
- [Git LFS](https://git-lfs.com) (`brew install git-lfs && git lfs install`) — the bundled WhisperKit `tiny` model (~75MB, see below) is stored via LFS, not as plain git blobs, to keep a normal clone fast. The feature-flagged, off-by-default local-feedback-coach model (~190MB, see "AI Feedback coach (POC)" below) is bundled the same way
- iOS 18.0+ deployment target (required by the dynamic `TranslationSession.Configuration` API — 17.4 only has a fixed-pair overload)
- A real device with headphones for anything beyond a compile check — see [Simulator limitations](#simulator-limitations) below

## Setup

```bash
git lfs install        # once per machine, if you haven't already
git lfs pull            # fetches the actual model binary — see the warning below
xcodegen generate
open Conversation.xcodeproj
```

Or from the command line:

```bash
git lfs install
git lfs pull
xcodegen generate
xcodebuild -project Conversation.xcodeproj -scheme Conversation \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skipPackagePluginValidation build
```

**`-skipPackagePluginValidation` is required**, not optional, once the AI
Feedback coach's `mlx-swift-lm` dependency is in the graph — its own
`mlx-swift` dependency declares a `CudaBuild` build-tool plugin (unused on
iOS/macOS, presumably Linux/CUDA-only) that `xcodebuild` otherwise refuses
to run untrusted, failing the build before any app code compiles. Not
specific to this repo — same flag needed building `mlx-swift-lm` standalone.

**If Git LFS wasn't installed before you cloned**, `Conversation/Resources/WhisperModels/openai_whisper-tiny/` will contain tiny LFS *pointer* text files instead of the real model — the build will still succeed (they're still files at the right paths), but WhisperKit will fail to load the model at runtime with a confusing Core ML error, not an obviously-missing-file one. Run `git lfs install && git lfs pull` and rebuild if language-ID doesn't work in a fresh checkout. The same failure mode applies to `Conversation/Resources/LLMModels/gemma-3-270m-it-4bit/` if you turn on the AI Feedback coach flag without having pulled LFS first.

The WhisperKit `tiny` language-ID model ships inside the app itself (see
"Why the WhisperKit tiny model is bundled" below), so it needs no network at
all, even on a fresh install. Translation still downloads its language pack
for whichever pair you pick during onboarding — that's a one-time,
Apple-controlled system download with no bundling option — and WhisperKit's
larger models (`base`, `small`, `medium`, `large-v2`, `large-v3`) are all
optional downloads from Settings if you want to A/B them, cached after that
and reused directly from disk on later launches without needing network
again (see `CLAUDE.md` for why that used to not be true even after the
first download). Settings > Language-Detection Models lets you trigger any
of those downloads ahead of time (with a real progress bar and a
downloaded/not-downloaded indicator per model), so you can get one cached
before you actually leave for a walk instead of finding out you need it
mid-conversation — though `small` and up are untested in this app so far;
they're built for full transcription quality, not a single quick
language-ID pass, and may just be too slow on a phone to be worth it. Swipe
a downloaded model to delete just that one, or use "Delete Downloaded
Models" to clear all of them at once — the bundled `tiny` model is never
affected either way, and deleting the currently-selected model resets the
selection back to `tiny` automatically rather than leaving Settings pointed
at something no longer on disk.

**Re-run `xcodegen generate` after adding, removing, or renaming any Swift
file** — the project file is a build artifact of `project.yml` + whatever's
on disk at generation time, not a live index.

## Simulator limitations

The simulator can build and run the UI, but can't meaningfully exercise:
mic input quality, on-device STT/WhisperKit accuracy, Bluetooth audio
routing/quality, the idle-timer/backgrounding pause behavior, or the
headphone-disconnect/interruption handling. Treat a successful simulator
build as "compiles and the view graph type-checks," not as "works."
Anything involving real audio needs a physical device — all of the fixes
described in this README and `CLAUDE.md` were found and verified that way,
not in the simulator.

## Testing

```bash
xcodebuild -project Conversation.xcodeproj -scheme Conversation \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skipPackagePluginValidation test
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
  Feedback/       Feature-flagged local-LLM speaking-feedback coach (POC)
  History/        Persisted chat history store
  Models/         LanguagePair, ChatSession, on-device language-support detection
  Permissions/    Mic + speech-recognition auth
  Config/         Tunable thresholds (several live-editable from Settings), timeout helper
  Logging/        AppLog + in-app Debug Log viewer
  UI/             Onboarding, Conversation, History, Settings screens
```

### Module responsibilities

- **`AudioSessionManager`** — owns two `AVAudioSession` configs, switched at
  turn boundaries: *Listening* (`.playAndRecord`, mic on) and *Speaking*
  (`.playback`, mic off). This split exists specifically so Bluetooth
  accessories can renegotiate up to A2DP for TTS output instead of staying
  pinned to HFP (mono, low-bitrate) for the whole session — the likely
  reason similar apps sound bad over AirPods. Also tracks headphone
  connect/disconnect and system interruptions (calls, the app being
  backgrounded, etc.) and pauses the loop for both.
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
  available, and where." Checks three places in order: bundled in the app
  itself (`.tiny` only — see below), then a previously-cached download
  folder, then falls through to actually downloading via
  `WhisperKit.download(variant:progressCallback:)`, which exposes real
  fractional progress (`@Published downloadProgress`/`isDownloading`, keyed
  by `WhisperModelOption`) and caches the resolved folder per model name in
  `UserDefaults` so a later load skips the network call entirely. Used both
  by `LanguageIdentifier` (lazy load on first real use) and Settings' model
  rows (explicit predownload with a progress bar) — one code path either
  way, so there's no risk of the two disagreeing about what's actually
  available.
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
  in its own language, via `NLLanguageRecognizer`). Also disables the idle
  timer (`UIApplication.shared.isIdleTimerDisabled`) for as long as a
  session is running, so the screen doesn't auto-lock mid-walk — see "Why
  the app is foreground-only" below for why that's the mechanism instead of
  locked-screen operation. Persists the running session to
  `ConversationHistoryStore` after every turn (not just at `stop()`) — see
  below.
- **`ConversationHistoryStore`** — the single owner of persisted chat
  history, one JSON file in Application Support rather than UserDefaults
  (meant to grow across many walks, unlike the small settings values
  UserDefaults already backs elsewhere). `ConversationLoopController` calls
  `upsert(_:)` after every completed turn, keyed by a session ID generated
  in `start()`, so a session is saved incrementally as it happens rather
  than only once at `stop()` — swiping the app away mid-walk instead of
  tapping Stop is a normal way to end a session for this kind of app, not
  an edge case to shrug off.
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

### Why the WhisperKit `tiny` model is bundled, not just downloaded

WhisperKit explicitly supports pointing at a local model folder
(`WhisperKitConfig(modelFolder:)`) instead of downloading — the same
parameter `WhisperModelManager` already used to skip re-downloading a
*cached* model turns out to work just as well pointed at a folder shipped
inside the app bundle itself, with no download ever happening for it. The
`tiny` model's compiled Core ML files (~75MB, MIT-licensed, from Argmax's
`argmaxinc/whisperkit-coreml` on Hugging Face) are added to the Xcode
project as a folder reference (`project.yml`'s `type: folder` source entry
— a plain group would flatten and rename-collide the three `.mlmodelc`
directories' identically-named internal files instead of preserving them as
real nested folders, which WhisperKit requires) and checked first by
`WhisperModelManager.bundledFolder`. Only `tiny` — every other multilingual
size WhisperKit offers (`base` through `large-v3`, several GB at the top
end) stays an optional Settings download, since permanently growing the
app's install size for models most people won't switch to isn't worth it by
default. `WhisperModelOption` deliberately excludes WhisperKit's
English-only `.en` variants (`tiny.en`, etc.) even as a download option —
they can't identify non-English audio at all, which would silently break
language-ID for any pair that isn't English-only. The binary model files
themselves are tracked via **Git LFS**, not plain git blobs — see Setup
above.

### AI Feedback coach (POC)

**Settings > AI Feedback > "Coach my speaking" — off by default.** A
feature-flagged proof of concept, unrelated to the WhisperKit/Apple
STT/Translation pipeline that actually drives the conversation: a second,
much smaller on-device LLM ([Gemma 3
270M](https://developers.googleblog.com/en/introducing-gemma-3-270m/),
4-bit-quantized MLX build from
[`mlx-community/gemma-3-270m-it-4bit`](https://huggingface.co/mlx-community/gemma-3-270m-it-4bit),
~190MB) silently reviews what you just said and attaches a short
grammar/naturalness note under that turn's chat bubble a moment later —
entirely offline, and entirely optional. Runs via [MLX
Swift](https://github.com/ml-explore/mlx-swift-lm) (`MLXLLM`/`MLXLMCommon`),
Apple's own native Swift ML stack — chosen over binding llama.cpp's C++
library directly (what [PocketPal
AI](https://github.com/a-ghorbani/pocketpal-ai) does, from React Native)
since it's the natural fit for a pure Swift/SwiftUI app. **Requires a
physical Apple Silicon device — no simulator support**, same class of
constraint as the rest of the device-dependent pipeline. See
`Conversation/Feedback/` (`FeedbackModelManager`, `LanguageCoachService`)
and `FeedbackConfig`.

The model is bundled the same way as WhisperKit's `tiny` model (a
`project.yml` folder-reference resource, tracked via Git LFS) — but
*temporarily*, specifically to speed up POC iteration, not a settled
decision. Since the feature defaults off, this permanently adds ~190MB to
every install regardless of whether anyone ever turns it on; if it sticks
around, revisit moving it to a `WhisperModelManager`-style optional
Settings download instead. The model itself is only loaded into memory
(and only then does it cost CPU/GPU/RAM) once the flag is switched on —
bundling only affects on-disk size.

MLXLMCommon deliberately doesn't ship a tokenizer implementation —
`Conversation/Feedback/FeedbackModelManager.swift` bridges it to
[swift-transformers](https://github.com/huggingface/swift-transformers)'
`Tokenizers` module, which was already a transitive WhisperKit dependency
and is now also a direct one.

### Allowing Apple's servers

**Settings > Transcription > "Allow Apple's servers" — off by default.**
Everything else in this app runs on-device; this is the one setting that
can send your recordings off it, and it exists because the offline path
isn't always actually available.

Apple's `Speech` framework can be restricted to on-device recognition
(`requiresOnDeviceRecognition`), which is what this app does by default.
But a language can be listed as supported, report
`supportsOnDeviceRecognition == true`, and still have no usable offline
model installed — in which case transcription returns an **empty string,
with no error and no timeout**, indistinguishable from the user not
having said anything. This was confirmed on a real device: the same
German speech transcribed perfectly with server-based recognition
allowed, and came back empty every time when restricted to on-device,
completing in well under half a second. Because `supportsOnDeviceRecognition`
lies about it, there's no reliable way for the app to detect this and
adapt on its own.

So it's a user-facing toggle rather than an automatic fallback. It's
deliberately **not** on by default, and deliberately **not** an automatic
retry after an empty on-device result — either would quietly send audio
off-device for someone who picked this app specifically because it
doesn't. Turning it on also means transcription needs a network
connection, which undercuts the offline-on-a-walk premise.

Where it's available, the better fix is installing the offline model
instead: **Settings > General > Keyboard > Dictation Languages**, and add
the language under **Language & Region**. Then turn the setting back off.

### Why the app is foreground-only

An earlier version declared `UIBackgroundModes: audio` so the mic,
WhisperKit, Translation, and TTS could all keep running with the screen
locked — and everything except TTS did work locked. **Spoken output
specifically (`AVSpeechSynthesizer`) never did**: it produces no audio at
all while backgrounded regardless of audio session category, a
long-standing, still-unresolved issue reported by other developers against
this exact framework going back to iOS 13, not something specific to this
app's setup. Three independent fixes were tried on real hardware and all
failed to resolve it: keeping `.playAndRecord` instead of switching to
`.playback` while backgrounded, rendering to a file played back via
`AVAudioPlayer` instead of `speak()`'s live output, and a documented
community workaround (a second unrelated `AVAudioPlayer` tone playing
concurrently during synthesis). A pipeline that can listen and translate
locked but can never speak the result back defeats the point, so rather
than keep chasing an apparently-unfixable platform bug, the background mode
was removed entirely.

The app is now foreground-only by design, with two consequences:

- **The screen is kept awake instead of trying to keep running locked** —
  `ConversationLoopController` sets `UIApplication.shared.isIdleTimerDisabled
  = true` for as long as a session is running, so the device's own
  auto-lock timeout never fires mid-walk. This only suppresses the
  *automatic* lock — pressing the side button still locks the phone
  immediately, same as any app.
- **Getting backgrounded anyway (a call, switching apps, manually locking)
  pauses the loop, not crashes it** — the existing audio-interruption
  handling (`AudioSessionManager.onInterruptionBegan`, already needed for
  phone calls) already covers this: the system automatically deactivates an
  active audio session for an app without the background mode, which
  triggers the same interruption path. The loop stops cleanly and shows
  "Paused — tap start to resume" rather than trying to guess whether it's
  safe to auto-resume.

`RecognitionConfig.speechOutputTimeout` (15s), wrapping every `speak()`
call, stays in place regardless — general insurance against a hung
synthesis call, not specific to the background bug. See `CLAUDE.md` for the
full isolation story if this ever needs revisiting.

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
listening) has been confirmed working end-to-end on a real device, with the
`tiny` and `base` WhisperKit models (the rest of the size lineup, `small`
through `large-v3`, is now downloadable from Settings but unverified). The
app is deliberately
foreground-only (see "Why the app is foreground-only" above); extended-session
battery/thermal behavior with the screen kept awake, and outdoor VAD
performance (wind, traffic), are still needing real-world verification — see
the checklist below.

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
  more. It's still pure energy + hysteresis with no actual speech/non-speech
  classification, so a sufficiently loud non-speech sound (traffic, wind, a
  dog bark) can still open a turn — Settings > Advanced (Experimental) now
  exposes the two thresholds that control this (noise rejection level,
  minimum sound duration) as live knobs, but the real fix if that's not
  enough is a dedicated sound classifier ahead of VAD (see `CLAUDE.md`).
- **A language can report on-device STT support it doesn't actually have.**
  `supportsOnDeviceRecognition` returning `true` doesn't guarantee a usable
  offline model exists; when one doesn't, transcription returns an empty
  string with no error, indistinguishable from silence. There's no API to
  detect this up front, so the only mitigation is the opt-in
  [Allow Apple's servers](#allowing-apples-servers) setting — which trades
  away both the offline and the on-device properties. Confirmed on a real
  device for German.
- **No programmatic way to install a missing on-device STT locale, TTS
  voice, or force a specific Translation pack download** — the app can only
  point the user at Settings for any of these. Siri's own voice specifically
  can never appear in the voice picker no matter what — Apple deliberately
  withholds it from `AVSpeechSynthesizer` for every third-party app, to stop
  an app impersonating Siri; confirmed against this app's own device via
  `SpeechOutputService.logAvailableVoiceInventory()`'s Debug Log dump, not
  just Apple's forum threads. Not something to keep trying to fix.
- Real Bluetooth HFP↔A2DP switching latency/glitches between turns haven't
  been formally measured, though nothing in testing so far has flagged it
  as a problem.
- **The app is foreground-only, by design** (see "Why the app is
  foreground-only" above) — locking the screen or switching apps mid-session
  pauses the loop rather than continuing in the background. The idle timer
  is disabled while a session runs instead, so the screen shouldn't
  auto-lock on its own during normal use. Extended-session behavior with the
  screen kept awake — battery drain and thermal effects over a long walk —
  is still unverified.

## Manual test checklist

1. Fresh install, walk through onboarding end-to-end, including both the
   Translation pack and WhisperKit model priming steps.
2. Auto-detect several turns in each language, switching back and forth —
   check how the confidence threshold and cross-check fallback feel; adjust
   the Settings sliders if it's guessing wrong too often or rejecting too
   eagerly.
3. A/B `tiny` vs. the larger models (`base` through `large-v3`) in Settings
   (Advanced) over the same set of test phrases — no verified answer yet on
   whether any of them are worth their extra size/latency for a single
   quick language-ID pass, especially `medium` and up.
4. Full hands-free loop outdoors, walking, with some wind/ambient noise —
   the main untested condition for VAD. Also: deliberately trigger loud
   non-speech noise (traffic, a door slam, a dog bark, clapping) and confirm
   it doesn't start a turn; adjust the new "Noise rejection"/"Minimum sound
   duration" sliders (Settings > Advanced) and confirm the effect is
   audible in behavior, not just in the number shown.
5. Start a session and leave the phone untouched past the device's normal
   auto-lock timeout — confirm the screen stays on (idle timer disabled)
   for as long as several turns take, and watch for battery/thermal effects
   over a longer walk.
6. Pull headphones mid-session, place a call mid-session, and manually lock
   the screen (side button) mid-session — all three should pause the loop
   gracefully with a "tap start to resume" message, not crash or silently
   keep trying to run.
7. Settings: voice picker actually changes the voice (try downloading a new
   one via "Manage voices in Settings" and confirm it shows up without
   relaunching), rate slider has an audible effect, VAD sensitivity presets
   change cutoff timing.
8. Settings > Language-Detection Models: confirm `tiny` shows "Included"
   with no download button (fresh install, airplane mode is fine). Download
   one of the other models and confirm the progress bar actually moves and
   the row flips to "Downloaded"; relaunch (or toggle airplane mode) and
   confirm it loads from disk with no network needed afterward. Then swipe
   that model to delete it (row flips back to showing a Download button;
   confirm `tiny`'s row has no swipe action at all). Download two non-tiny
   models, select one of them as the active "Detection Model," then use
   "Delete Downloaded Models" and confirm both are gone, the picker snaps
   back to Tiny, and a subsequent turn still works using the bundled model.
9. Settings > Languages: change the language pair without going through
   onboarding, including while a conversation is actively running (should
   stop, apply the new pair, and resume) — then use "Refresh available
   languages" after enabling a new dictation language in system Settings and
   confirm it shows up without relaunching the app.
10. Chat history: complete a few turns, open the hamburger drawer, and
    confirm the session appears immediately (not just after tapping Stop).
    Force-quit the app mid-session (not Stop) and relaunch — confirm the
    turns up to the last completed one are still there. Swipe a session to
    copy and to delete; use Delete All and confirm the confirmation dialog
    actually blocks an accidental tap. Open a session, use Select mode to
    pick a subset of turns, Copy Selected, and paste somewhere to confirm
    it's only those turns, not the whole conversation.

## Debugging

Every module logs its state transitions and failures through `AppLog`,
viewable in-app without a Mac nearby: Settings > Debug Log, or a "Debug
Log" link on the Welcome screen (reachable even mid-onboarding). Use the
Share button there to export the log as text. This is how essentially
every bug in `CLAUDE.md` past the first few was actually root-caused —
default to grabbing a log capture before guessing at a fix for anything
that only shows up on a real device.

Debug builds additionally get **Settings > Debugging > Captures**: the last
20 recorded utterances, each replayable in-app alongside everything the
pipeline concluded about it — the measured audio (duration, sample rate,
channels), WhisperKit's language-ID verdict and confidence, every candidate
locale Apple's STT was actually asked to transcribe and what each returned
(including whether it finished normally or hit the fallback timeout, and
whether it ran on-device), and the final outcome. Being able to hear a clip
while looking at what each locale made of it is what separated "our audio is
broken" from "the offline recognition model is missing" — see `CLAUDE.md`.

If clearly-spoken audio produces an empty transcript, check
[Allowing Apple's servers](#allowing-apples-servers) first — a missing
offline dictation model is silent, gives no error, and has been the answer
before.

## License

[PolyForm Noncommercial 1.0.0](LICENSE.md) — free to use, modify, and share
for any noncommercial purpose. Commercial use requires a separate
arrangement with the copyright holder.

The bundled WhisperKit `tiny` model weights
(`Conversation/Resources/WhisperModels/`) are third-party, MIT-licensed
Core ML conversions from Argmax's
[`argmaxinc/whisperkit-coreml`](https://huggingface.co/argmaxinc/whisperkit-coreml),
derived from OpenAI's (also MIT-licensed) Whisper — not covered by this
repo's own license above, and not the copyright of this project.

The bundled AI Feedback coach model weights
(`Conversation/Resources/LLMModels/gemma-3-270m-it-4bit/`, see "AI Feedback
coach (POC)" above) are Google's Gemma 3 270M, distributed under the
[Gemma Terms of Use](https://ai.google.dev/gemma/terms) — **not MIT, and
not covered by this repo's PolyForm license above.** Unlike Whisper's MIT
license, Gemma's terms impose their own redistribution/use conditions
(including a Prohibited Use Policy); this hasn't had a real legal review
for redistribution via this bundling approach, since the feature is still
a POC. Worth resolving properly (or reconsidering permanent bundling in
favor of an on-demand download) before this feature leaves POC status.
