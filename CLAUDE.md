# Conversation

A hands-free iOS translation app for practicing a language solo, on a walk,
with headphones: speak either of two chosen languages, it detects which one,
translates it, and speaks the result back through the headphones — on-device
after first-run setup. Deliberately foreground-only (see the Audio session &
background section below for why): the app disables the idle timer while a
session is running instead of trying to keep working with the screen locked.
See `README.md` for the full pitch and architecture.

## Commands

```bash
xcodegen generate                                                    # regenerate Conversation.xcodeproj from project.yml — see IMPORTANT below
xcodebuild -project Conversation.xcodeproj -scheme Conversation \
  -destination 'platform=iOS Simulator,name=iPhone 16' build         # build
xcodebuild -project Conversation.xcodeproj -scheme Conversation \
  -destination 'platform=iOS Simulator,name=iPhone 16' test          # run all tests
```

**IMPORTANT**: `Conversation.xcodeproj` is generated and gitignored. After
adding, removing, or renaming any `.swift` file, run `xcodegen generate`
*before* building — a stale `.xcodeproj` will fail with "cannot find type
in scope" for symbols that are actually defined and correct.

**IMPORTANT**: the bundled WhisperKit `tiny` model
(`Conversation/Resources/WhisperModels/openai_whisper-tiny/`) is tracked via
**Git LFS**, not plain git. On a fresh clone without `git lfs install` run
first, that folder contains tiny LFS pointer text files instead of the real
~75MB of Core ML weights — `xcodegen generate` and the build both succeed
regardless (they're still real files at the right paths), but WhisperKit
fails to load the model at runtime with a Core ML error that gives no hint
the actual cause is a missing `git lfs pull`. If language-ID mysteriously
fails only in a fresh checkout, check this first.

## Testing

Run the full suite (`xcodebuild ... test`) rather than filtering to one file
— it's under a second, covers `VADSegmenter` and `LanguageIdentifier`'s
confidence math against fixtures, and needs no device or simulator input.
Everything else (STT, Translation, TTS, Bluetooth audio routing, background
behavior) is device-dependent and cannot be meaningfully exercised by an
automated test or the simulator — verify those manually on a real device
with headphones. **Default to pulling a Debug Log capture (Settings > Debug
Log, or the link on the Welcome screen) before guessing at a fix for
anything that only shows up on-device** — nearly every entry below was
root-caused from a real log, not from reasoning about the code alone.

## Architecture decisions worth knowing before touching this code

- **WhisperKit identifies the language; Apple's `SFSpeechRecognizer`
  transcribes it.** `SFSpeechRecognizer` only supports one active on-device
  recognition task at a time (confirmed, not just suspected — see
  `Speech/LanguageIdentifier.swift`'s doc comment), so guessing a locale and
  retrying the other one live isn't viable. WhisperKit's tiny model runs one
  cheap pass for language-ID only; its transcription output is discarded.
  When its absolute confidence is mediocre, `ConversationLoopController.crossCheckLanguage`
  transcribes the same clip with Apple's STT in *both* candidate locales
  (sequentially, same one-task-at-a-time constraint) and picks whichever
  reads as more plausible in its own language.
- **Record-then-process, not live-streaming STT.** Utterances are captured
  to a temp file (`Audio/MicrophoneInputManager.swift`) and processed after
  the fact (LID → transcribe → translate → speak), not streamed live into
  `SFSpeechRecognizer` — required so WhisperKit and Apple's STT can both run
  against the same fixed clip, in sequence.
- **`AudioSessionManager` switches category between turns, not once per
  session.** Listening (`.playAndRecord`) and Speaking (`.playback`) are
  distinct configs, switched at each turn boundary. This is deliberate, not
  incidental: holding `.playAndRecord` the whole time pins Bluetooth
  accessories to low-quality HFP even during TTS playback — the actual
  reason this kind of app tends to sound bad over AirPods.
- **The app is deliberately foreground-only — no `UIBackgroundModes: audio`.**
  It used to declare this to keep listening/translating with the screen
  locked, but `AVSpeechSynthesizer` going silent while backgrounded turned
  out to be a long-standing, unresolved Apple platform bug (see "Audio
  session & background" below) — the app could listen and translate locked,
  it just couldn't ever speak the result back, which defeats the point.
  Removed rather than continuing to chase it. Instead,
  `ConversationLoopController.updateIdleTimer` sets
  `UIApplication.shared.isIdleTimerDisabled = true` for as long as a session
  is running, so the screen just doesn't auto-lock in the first place — the
  existing audio-interruption handling (`handleInterruptionBegan`) already
  pauses the loop gracefully if the app *does* get backgrounded (a call, the
  user switching apps, etc.), requiring a manual restart rather than trying
  to silently recover. Don't re-add the background mode reflexively because
  "walking app" sounds like it needs it — it doesn't fix the actual TTS
  problem, see below.
- **Min deployment target is iOS 18.0, not 17.4.** The dynamic
  `TranslationSession.Configuration?` API this app needs (swap language
  pairs without tearing down the whole session graph) is 18.0+; 17.4 only
  has the fixed-pair overload.
- **Several recognition constants are UserDefaults-backed, not `static let`**
  (`RecognitionConfig.languageIDRejectThreshold`, `.whisperModel`) so
  Settings can expose them as live experiment knobs. Real tuning needs real
  device iteration — don't "fix" these back to hardcoded values without a
  reason.
- **`WhisperModelManager` is the single owner of WhisperKit model
  download/cache state.** `LanguageIdentifier` (lazy, on first real use) and
  Settings' `WhisperModelRowView` (explicit predownload with a progress bar)
  both go through it rather than each keeping their own
  downloaded/not-downloaded bookkeeping — two independent caches for the
  same on-disk fact would drift (e.g. Settings shows "not downloaded" right
  after a conversation turn silently triggered a download). If you need to
  know whether a model is on disk, or want to trigger its download, go
  through `WhisperModelManager.shared`, not a new UserDefaults key.
- **The `tiny` WhisperKit model ships inside the app bundle; `base` doesn't.**
  `WhisperKitConfig(modelFolder:)` works identically whether the folder is a
  previously-downloaded cache dir or one shipped in the app itself — see
  `WhisperModelManager.bundledFolder`, checked before the cache/download
  path. It's added in `project.yml` as a `type: folder` source (a plain
  group would flatten the three `.mlmodelc` dirs' identically-named internal
  files — `coremldata.bin`, `model.mil`, etc. — into colliding top-level
  resources instead of preserving them as real nested folders, which
  WhisperKit requires at load time). Only `tiny` is bundled (~75MB is a
  reasonable permanent app-size cost for zero-network language-ID out of the
  box); `base` (~150MB) stays a Settings-triggered download since most users
  won't switch to it. The model files themselves are tracked via Git LFS —
  see the IMPORTANT note above.
- **Changing the language pair no longer restarts onboarding.**
  `AppState.updateLanguagePair(_:)` (Settings' `LanguagePairEditorView`)
  changes it in place; `AppState.completeOnboarding(with:)` is only for the
  first-run path. See the `@StateObject`/`.onChange(of: pair)` gotcha below
  for why `ConversationView` needs explicit handling of this.

## Non-obvious bugs already found once — don't reintroduce them

Grouped by area; each was found on a real device, most from a Debug Log
capture, not from code review.

### Audio session & background

- `AudioSessionManager` must be in a playback-capable category
  (`.playAndRecord` or `.playback`) before any `AVSpeechSynthesizer` call.
  The original `.record`-only category (recording-only, no output route)
  let STT work fine while making TTS silently produce zero audio.
- **`MicrophoneInputManager`'s engine must be fully stopped before
  `AudioSessionManager` switches category, and restarted after switching
  back.** The hands-free rewrite left the engine running continuously (so
  VAD never stops listening) but kept the category-switch-per-turn logic,
  which assumed the engine was always torn down between turns. The
  mismatch produced a real on-device `OSStatus '561017449'` (`'!pri'`,
  `AVAudioSessionErrorInsufficientPriority`) failure when switching to the
  Speaking config while the input node was still live — silent/broken TTS
  with a cryptic OSStatus error, not a missing-voice problem. Fixed in
  `ConversationLoopController.process`: `mic.stopEngine()` before
  `activateSpeaking()`, `mic.restartEngine()` after `activateListening()`.
- **TTS being silent whenever the app isn't in the foreground was chased
  for three rounds, then the feature was retired instead of fixed — don't
  redo this work.** `AVSpeechSynthesizer` produces no audio while
  backgrounded (locked screen, another app active) regardless of audio
  session config — a long-standing, still-unresolved Apple platform issue,
  confirmed by multiple independent developer forum threads going back to
  iOS 13, not something specific to this app. Three independent things
  were tried and **all failed to fix it**, which is itself the useful
  signal from all that effort, not a wasted one: (1) keeping
  `AudioSessionManager` in `.playAndRecord` instead of switching to
  `.playback` while backgrounded ruled out session category as the cause;
  (2) rendering via `write(_:toBufferCallback:)` to a file played back with
  `AVAudioPlayer` instead of `speak()`'s live output ruled out "live
  playback path specifically"; (3) a community-reported workaround —
  keeping a second, unrelated `AVAudioPlayer` tone playing *during*
  synthesis, on the theory that concurrent `AVAudioPlayer` activity keeps
  the shared audio render path "trusted" by iOS while backgrounded — also
  didn't hold up on real-device testing. Mic capture and
  `AVAudioPlayer`-based earcons keep working fine under the exact same
  backgrounded conditions throughout, so this was never background audio
  being blocked in general — it's specific to `AVSpeechSynthesizer`
  needing *something*, still not understood, and apparently not fixable
  from application code. **Resolution: stopped fighting it.** The app no
  longer declares `UIBackgroundModes: audio` at all (see the architecture
  bullet above) — `SpeechOutputService` no longer has the keep-alive-tone
  workaround, and `AudioSessionManager.activateSpeaking()` no longer has a
  backgrounded-vs-foreground branch, since the app never runs backgrounded
  anymore. `RecognitionConfig.speechOutputTimeout` (15s) remains as a
  general safety net around any hung `speak()` call, background-related or
  not — cheap insurance, not specific to this bug. If background TTS ever
  needs revisiting, start by re-reading this entry before trying anything
  "new" — all three obvious approaches are already ruled out.
- Earcons must play through `AVAudioPlayer`/the app's own `AVAudioSession`,
  not `AudioServicesPlaySystemSound` — the latter is silenced by the
  physical ring/silent switch; audio routed through the app's session
  (same mechanism as TTS) isn't.
- Any error caught during a turn must go through `showErrorThenResumeListening`
  (or an equivalent visible delay), never a bare `state = .error(...)`
  immediately followed by `state = .listening` — two synchronous
  `@Published` writes with no suspension between them are indistinguishable
  from silent failure to the UI. This exact pattern is why the `'!pri'`
  error above was invisible until the delay was added.

### Language identification

- **WhisperKit's `detectLangauge` returns log-probabilities, not linear
  probabilities.** A real device log caught the original renormalization
  math treating them as linear (summing directly, `total > 0` as the "do
  we have signal" check) — since log-probs are ≤ 0, that guard was false
  on effectively every real call, silently falling back to an arbitrary
  50/50 tie-break every single time. This meant auto-detect was never
  really detecting anything since it was introduced, not stalling. Fixed
  via softmax (exponentiate, subtract max first for stability, normalize)
  in `LanguageIdentifier.pickWinner`. A missing candidate in WhisperKit's
  dictionary must map to `-Double.infinity` (effectively impossible), not
  `0` — `0` in log-space means *certainty*, the opposite of "absent."
- **WhisperKit's tiny model can be confidently wrong, not just uncertain**
  — it has a documented English bias on short/ambiguous phrases. A real
  device log: German audio ("heute die sonnenschein") got tagged "en" at
  relative confidence 1.0 (since "de" never appeared in WhisperKit's
  output to compete against it) but absolute log-prob only -0.78 (~46%
  linear) — genuinely weak, just uncontested. `LanguageIdentificationResult.needsCrossCheck`
  gates on the *absolute* log-prob (`RecognitionConfig.languageIDHighConfidenceLogProb`,
  -0.3), independent of the relative `confidence` score, specifically to
  catch this and trigger the cross-check fallback described above.
- **WhisperKit needed network on every launch, not just the first —
  confirmed by reading its source, not guessed.** Its default
  model-resolution path (used whenever `modelFolder` isn't explicitly
  passed) unconditionally calls the Hugging Face Hub API to list filenames
  *before* ever checking a local cache, even when the model is already
  fully downloaded. Fixed in `LanguageIdentifier.loadedWhisperKit`: after a
  successful load, the resolved `WhisperKit.modelFolder` is saved per model
  name in `UserDefaults`; next load passes that path back in as
  `modelFolder`, which makes WhisperKit skip `download()` (and its network
  call) entirely. Falls back to normal resolution once if the cached
  folder is missing or fails to load. If "works online, breaks offline"
  ever resurfaces elsewhere, suspect a similar "network call before cache
  check" pattern in whatever framework is involved, not necessarily this
  exact code path again.

### VAD & capture

- **VAD needs a grace period after the mic engine (re)starts.** A device
  log showed WhisperKit confidently "identifying" a language for a clip
  that Apple's `SFSpeechRecognizer` then correctly found *no actual speech*
  in — the turn got rejected safely, but it was a wasted cycle (and risks
  eating the first syllable of what the user meant to say). Most likely
  cause: a transient pop from the audio hardware re-engaging, or (without
  headphones) residual TTS echo, right as listening resumes. `ConversationLoopController`
  now ignores VAD input for `vadGracePeriod` (0.4s) after every mic
  engine (re)start via `armVADGracePeriod()` — call it anywhere the engine
  starts or restarts, or this class of false-positive comes back.
- **VAD-gated recording drops the onset of speech without a pre-roll
  buffer.** By the time `VADSegmenter` confirms speech is happening
  (`minSpeechDuration` debounce, plus the grace period above), the actual
  onset already occurred — "first few words dropping when speaking
  quickly" was users hitting exactly this, a textbook VAD pitfall.
  `MicrophoneInputManager` now keeps a ~1s rolling `preRollBuffers` ring,
  filled unconditionally on every tap callback regardless of VAD/grace
  state, and `beginUtteranceFile()` writes it out before switching to live
  writes. This needed its own lock (`preRollLock`), unlike the
  `audioFile`/`utteranceFileURL` benign-race trade-off noted in
  `MicrophoneInputManager`'s own doc comment — it's a Swift `Array`
  mutated on the audio thread while read from the main actor, and
  concurrent unsynchronized array mutation is a real memory-corruption
  risk, not just a stale-value one. Also: buffers handed to an
  `AVAudioNodeTapBlock` are only valid for that call's duration — anything
  retained past it (like this buffer) must be deep-copied first
  (`MicrophoneInputManager.copyBuffer`).
- On some real headphone routes (confirmed: AirPods over HFP),
  `SFSpeechRecognizer`'s completion handler never calls back with
  `isFinal`, even after `endAudio()`, even for a complete fixed file — not
  just a live tap. Anything gating further work on `isFinal` alone needs a
  timeout-based self-finalize fallback (see `SpeechRecognizerWrapper.transcribe`
  and `RecognitionConfig.transcriptionFallbackTimeout`), not just a longer wait.

### Set iteration order is not stable across launches

- **`SupportedLanguages` picked a different, effectively random regional
  locale variant every launch, because it iterated a `Set`.**
  `SFSpeechRecognizer.supportedLocales()` returns `Set<Locale>`, and Swift
  deliberately randomizes `Set`/`Dictionary` iteration order per process
  (hash-flooding resistance) — the original `.first(where: { $0.identifier.hasPrefix(identifier) })`
  therefore checked a different variant of each language every single
  launch. A real device log proved it: run 1 landed on `de-AT`, `zh-HK`,
  `es-419` (mostly not on-device-capable) and found only `["fr"]`; a
  relaunch of the exact same app on the exact same device, nothing else
  changed, landed on different variants and found `["en", "de"]` instead.
  This looked like (and was originally misdiagnosed as) an on-device
  readiness *timing* issue — it wasn't; the retry loop in
  `availableOnThisDevice()` was solving the wrong problem, though it's kept
  as cheap insurance. The actual fix in `checkOnce()`: check a known-
  standard region per language first (`preferredRegion`), then
  deterministically try every other matching variant in *sorted* order,
  never raw `Set` order. **Any other code that calls `.first(where:)` (or
  otherwise depends on element order) on a `Set` — including future uses
  of `SFSpeechRecognizer.supportedLocales()` or similar Set-returning
  system APIs — has the same latent bug.**

### SwiftUI / system state going stale

- **`TranslationSessionHost` (`Translation/TranslationService.swift`) must
  never collapse to a zero-size frame.** The system's one-time "download
  language pack" sheet anchors to that view's geometry; a `0×0` host gives
  it nothing to anchor to, and `session.translate()` just hangs forever
  with no error, no timeout, nothing.
- **SwiftUI doesn't know when external system state (e.g. installed TTS
  voices) changes underneath it.** The voice picker kept showing stale data
  after downloading a new voice via Settings > Accessibility > Spoken
  Content > Voices, because backgrounding the app to get there and coming
  back doesn't trigger any `@Published` change on its own. Fixed by
  bumping a `.id()` refresh token off `scenePhase` becoming `.active`. If a
  picker/list ever looks stale after the user does something in system
  Settings and comes back, this is probably why.
- **A `@StateObject` survives a parent's re-render even when the value that
  constructed it changes.** `ConversationView(pair:)` used to be the only
  way to change the active language pair — the whole view (and its
  `ConversationLoopController` `@StateObject`) got torn down and rebuilt via
  a full onboarding restart, so the controller was always freshly
  constructed with the current pair. Once Settings' `LanguagePairEditorView`
  started updating `AppState.languagePair` in place (no more restart), the
  same `ConversationView` instance stuck around with the *same* controller,
  which does not automatically notice its constructor argument would now be
  different — it keeps using whatever pair it was originally built with.
  Fixed with an explicit `.onChange(of: pair)` in `ConversationView` that
  calls `controller.updateLanguagePair(newPair)` (stopping and restarting
  the loop around it if it was running). Any other `@StateObject` built from
  a `let` property in `init` has the same latent gap if that property can
  now change out from under an already-alive view.

## Logging

`AppLog` (Logging/AppLog.swift) mirrors every log line to both `os.Logger`
(Xcode console / Console.app when tethered) and an in-memory ring buffer
viewable in-app via Settings > Debug Log, or from a link on the Welcome
screen (reachable even mid-onboarding, before Settings exists). Use
`AppLog.{debug,info,error}(_ category:, _ message:)` — safe to call from
any thread, including the real-time audio thread. When adding a new
module, add log lines at its state transitions and failure points, not
just its happy path — the whole point is diagnosing real-device behavior
that can't be reproduced in the simulator.

## Repo notes

Public repo, licensed [PolyForm Noncommercial 1.0.0](LICENSE.md) — free for
any noncommercial use, commercial use needs separate arrangement with the
copyright holder. No branch/PR conventions established yet (single
contributor so far).
