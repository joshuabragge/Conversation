# Conversation

A hands-free iOS translation app for practicing a language solo, on a walk,
with headphones: speak either of two chosen languages, it detects which one,
translates it, and speaks the result back through the headphones — on-device
after first-run setup, including with the screen locked. See `README.md`
for the full pitch and architecture.

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
  reason this kind of app tends to sound bad over AirPods. **Except while
  backgrounded** — see the Background section below.
- **Min deployment target is iOS 18.0, not 17.4.** The dynamic
  `TranslationSession.Configuration?` API this app needs (swap language
  pairs without tearing down the whole session graph) is 18.0+; 17.4 only
  has the fixed-pair overload.
- **Several recognition constants are UserDefaults-backed, not `static let`**
  (`RecognitionConfig.languageIDRejectThreshold`, `.whisperModel`) so
  Settings can expose them as live experiment knobs. Real tuning needs real
  device iteration — don't "fix" these back to hardcoded values without a
  reason.

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
- **TTS was silent whenever the app wasn't in the foreground (locked
  screen, another app active), even though mic capture and earcons both
  worked, and even after avoiding the `.playAndRecord`→`.playback`
  category switch in that case.** That second fact ruled out audio-session
  category as the cause entirely: mic capture and `AVAudioPlayer`-based
  earcons kept working under the identical session config that produced
  silent TTS. What's actually different is the *playback mechanism* —
  `AVSpeechSynthesizer.speak()`'s live output path is unreliable while
  backgrounded, a limitation of that specific API, not something an audio
  session config can fix (informally documented by other developers
  hitting the same thing). Fixed in `SpeechOutputService` by not using
  `speak()` at all: `AVSpeechSynthesizer.write(_:toBufferCallback:)`
  renders the utterance to a temp file instead (a different, non-live code
  path), and that file is played back with `AVAudioPlayer` — the same
  mechanism already confirmed working in the background for earcons. The
  `.playback`-vs-`.playAndRecord` foreground/background branching in
  `AudioSessionManager.activateSpeaking()` is still worth keeping for its
  original Bluetooth-quality reason (that's a route/category property, not
  tied to which playback API is used) — just wasn't the fix for *this* bug.
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
