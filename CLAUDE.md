# Conversation

A hands-free iOS translation app for practicing a language solo, on a walk,
with headphones: speak either of two chosen languages, it detects which one,
translates it, and speaks the result back through the headphones — on-device
after first-run setup (the one exception is opt-in and off by default: see
`RecognitionConfig.allowServerBasedRecognition`, for languages iOS has no
usable offline dictation model for). Deliberately foreground-only (see the
Audio session & background section below for why): the app disables the idle
timer while a session is running instead of trying to keep working with the
screen locked. See `README.md` for the full pitch and architecture.

## Commands

```bash
xcodegen generate                                                    # regenerate Conversation.xcodeproj from project.yml — see IMPORTANT below
xcodebuild -project Conversation.xcodeproj -scheme Conversation \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skipPackagePluginValidation build                                 # build — see IMPORTANT below for the plugin flag
xcodebuild -project Conversation.xcodeproj -scheme Conversation \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skipPackagePluginValidation test                                  # run all tests
```

**IMPORTANT**: `Conversation.xcodeproj` is generated and gitignored. After
adding, removing, or renaming any `.swift` file, run `xcodegen generate`
*before* building — a stale `.xcodeproj` will fail with "cannot find type
in scope" for symbols that are actually defined and correct.

**IMPORTANT**: every build/test command needs `-skipPackagePluginValidation`
now that `mlx-swift-lm` (the AI Feedback coach's dependency, see below) is
in the dependency graph — its `mlx-swift` dependency declares a build-tool
plugin (`CudaBuild`, irrelevant to iOS/macOS, presumably meant only for
Linux/CUDA builds) that `xcodebuild` otherwise refuses to run without
explicit trust, failing the whole build with "Validate plug-in 'CudaBuild'
in package 'mlx-swift'" before a single line of app code even compiles.
This isn't specific to anything in this repo — same flag needed building
mlx-swift-lm standalone.

**IMPORTANT**: the bundled WhisperKit `tiny` model
(`Conversation/Resources/WhisperModels/openai_whisper-tiny/`) is tracked via
**Git LFS**, not plain git. On a fresh clone without `git lfs install` run
first, that folder contains tiny LFS pointer text files instead of the real
~75MB of Core ML weights — `xcodegen generate` and the build both succeed
regardless (they're still real files at the right paths), but WhisperKit
fails to load the model at runtime with a Core ML error that gives no hint
the actual cause is a missing `git lfs pull`. If language-ID mysteriously
fails only in a fresh checkout, check this first. The same applies to
`Conversation/Resources/LLMModels/gemma-3-270m-it-4bit/` (the AI Feedback
coach's bundled model, see below) if the "Coach my speaking" flag is on.

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
  (`RecognitionConfig.languageIDRejectThreshold`, `.whisperModel`,
  `.vadSensitivity`, `.vadSpeechThreshold`, `.vadMinSpeechDuration`) so
  Settings can expose them as live experiment knobs. Real tuning needs real
  device iteration — don't "fix" these back to hardcoded values without a
  reason. The VAD-related three specifically must be applied to `vad` in
  `ConversationLoopController.init` (not just wired to a live `.onChange` in
  Settings) — see the "persisted VAD settings" bug entry below for what
  happens if a new one skips this.
- **`WhisperModelOption` covers WhisperKit's full multilingual size lineup**
  (`tiny` through `large-v3`), not just `tiny`/`base` — but deliberately
  *excludes* WhisperKit's English-only `.en` variants (`tiny.en`, etc.) even
  though they're smaller/faster, because this app's whole job is picking
  *which* of two chosen languages was spoken; an English-only model can't
  identify non-English audio at all, so adding one would silently break
  language-ID for any pair that isn't English-only. Don't add `.en` variants
  even as an "advanced" option. `.modelName` (WhisperKit's `download(variant:)`
  string, e.g. `"large-v2"`) and `.rawValue` (this enum's own
  `UserDefaults` persistence key, e.g. `"largev2"`) are deliberately
  different strings — don't assume they're interchangeable if extending
  this enum further.
- **`WhisperModelManager` is the single owner of WhisperKit model
  download/cache state.** `LanguageIdentifier` (lazy, on first real use) and
  Settings' `WhisperModelRowView` (explicit predownload with a progress bar)
  both go through it rather than each keeping their own
  downloaded/not-downloaded bookkeeping — two independent caches for the
  same on-disk fact would drift (e.g. Settings shows "not downloaded" right
  after a conversation turn silently triggered a download). If you need to
  know whether a model is on disk, or want to trigger its download, go
  through `WhisperModelManager.shared`, not a new UserDefaults key.
  `delete(_:)`/`deleteAllDownloaded()` are the same idea in reverse — they
  throw `.cannotDeleteBundledModel` for `tiny` rather than silently no-op-ing
  (so a "delete everything" loop notices tiny wasn't covered instead of
  assuming it was), and reset `RecognitionConfig.whisperModel` back to
  `.tiny` if the model being deleted was the active selection, so Settings
  never points at a model with nothing left on disk — that would otherwise
  silently redownload it (needing network) the next time `LanguageIdentifier`
  actually needs it, mid-walk.
- **The `tiny` WhisperKit model ships inside the app bundle; nothing else
  does.** `WhisperKitConfig(modelFolder:)` works identically whether the
  folder is a previously-downloaded cache dir or one shipped in the app
  itself — see `WhisperModelManager.bundledFolder`, checked before the
  cache/download path. It's added in `project.yml` as a `type: folder`
  source (a plain group would flatten the three `.mlmodelc` dirs'
  identically-named internal files — `coremldata.bin`, `model.mil`, etc. —
  into colliding top-level resources instead of preserving them as real
  nested folders, which WhisperKit requires at load time). Only `tiny` is
  bundled (~75MB is a reasonable permanent app-size cost for zero-network
  language-ID out of the box); every other option (`base` ~150MB up to
  `large-v2`/`large-v3` at ~3.1GB) stays a Settings-triggered download since
  most users won't switch to them, and the largest ones would be a
  questionable permanent install-size cost even if they did. The model
  files themselves are tracked via Git LFS — see the IMPORTANT note above
  (only applies to the bundled `tiny` model; downloaded models are plain
  WhisperKit cache files, not part of the repo at all).
- **Changing the language pair no longer restarts onboarding.**
  `AppState.updateLanguagePair(_:)` (Settings' `LanguagePairEditorView`)
  changes it in place; `AppState.completeOnboarding(with:)` is only for the
  first-run path. See the `@StateObject`/`.onChange(of: pair)` gotcha below
  for why `ConversationView` needs explicit handling of this.
- **Chat history is persisted turn-by-turn, not once at `stop()`.**
  `ConversationLoopController.persistCurrentSession()` calls
  `ConversationHistoryStore.shared.upsert(_:)` right after every
  `history.append(...)`, keyed by a session ID generated in `start()`. This
  is deliberate, not just "call it wherever's convenient": for a hands-free
  walking app, swiping the app away mid-walk instead of tapping Stop is a
  completely normal way a session ends, and only persisting at `stop()`
  would silently lose everything since the last one. `ConversationTurn`
  reuses `LanguagePair`'s pattern for `Locale.Language` (not stably
  `Codable` across OS versions — encode/decode via `minimalIdentifier`
  strings instead) — if a future model adds another `Locale.Language`
  field, follow the same pattern rather than trying default `Codable`
  synthesis on it directly.
- **The AI Feedback coach (`FeedbackConfig.isEnabled`, off by default,
  Settings > AI Feedback) is a second, independent local LLM
  (Gemma 3 270M via MLX Swift) — not part of the WhisperKit/Apple
  STT/Translation pipeline, and deliberately kept from touching it.**
  `Conversation/Feedback/FeedbackModelManager.swift` owns loading the
  bundled model (`ModelConfiguration(directory:)`/`LLMModelFactory`
  loading straight from a local app-bundle folder, no `Downloader` or
  network involved — see `project.yml`'s `type: folder` entry for
  `Resources/LLMModels/gemma-3-270m-it-4bit`, same reasoning as the
  bundled WhisperKit `tiny` model above); `LanguageCoachService.swift`
  owns the actual coach persona/prompt. `ConversationLoopController.
  requestFeedback(for:)` fires this as a non-blocking background `Task`
  right after a turn is appended to `history` — never awaited inline, and
  deliberately never touches `TurnState`/`state` (that machine models the
  one live in-flight turn, not a per-history-item background annotation;
  see `ConversationTurn.feedback`'s doc comment). `MLXLMCommon`
  deliberately ships no tokenizer implementation of its own — apps bridge
  their own `TokenizerLoader`, which is why
  `FeedbackModelManager.swift` adapts swift-transformers' `Tokenizers`
  module (already a transitive WhisperKit dependency, now also declared
  directly in `project.yml` since a target can't `import` a product it
  doesn't directly depend on) rather than something being missing/broken
  upstream. `FeedbackModelManager` is its own `actor`, not `@MainActor`
  like `WhisperModelManager` — unlike that class (pure download
  bookkeeping), this one drives real multi-second MLX generation directly
  and needs to stay off the main actor to avoid UI jank. Requires a
  physical Apple Silicon device — MLX has no Simulator support, so this
  can only be verified on-device, same as the rest of the pipeline. The
  model is bundled *temporarily*, purely to speed up POC iteration (see
  `README.md`'s "AI Feedback coach (POC)" section) — revisit moving it to
  an optional `WhisperModelManager`-style Settings download if the feature
  sticks, and resolve the Gemma-license redistribution question (see
  `README.md`'s License section) before it leaves POC status.

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
- **`MicrophoneInputManager.installTapAndStart` must pass `nil` for
  `installTap`'s `format:` parameter, never a format queried via
  `outputFormat(forBus:)` moments earlier — doing the latter crashed the
  app on a real device.** Sequence from the crash log: AirPods connect
  (still in A2DP), `start()` calls `activateListening()`, which switches
  the session to `.playAndRecord` and kicks the accessory into HFP for
  recording — and *before* that Bluetooth codec renegotiation actually
  finished, `installTapAndStart` queried `outputFormat(forBus:)` and got
  a stale 48kHz reading. By the time `installTap`'s internal validation
  ran a beat later, the real hardware format had already settled to
  HFP's 24kHz; the two didn't match, and passing an explicit format to
  `installTap` makes a mismatch a hard, Swift-uncatchable
  `com.apple.coreaudio.avfaudio` exception ("Failed to create tap due to
  format mismatch") instead of a recoverable error — an instant crash on
  connecting headphones and tapping Start, not a graceful failure a
  `do`/`catch` could ever have caught. A longer or differently-timed
  query doesn't close this race reliably; it's inherent to querying and
  using the format in two separate calls while the accessory is still
  renegotiating. Fixed by passing `nil` instead — Apple's own recommended
  pattern for exactly this crash — which makes `AVAudioEngine` resolve
  the tap's format itself, atomically, against whatever the hardware
  actually is at that instant. The real per-buffer format is read from
  `buffer.format` inside the tap callback and cached in `currentFormat`
  for `beginUtteranceFile` to reuse, rather than that method doing its
  own separate (and similarly race-prone) `outputFormat(forBus:)` query.
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
- **The detection model used to only load lazily, on the first real
  conversation turn — a real device log showed a fresh "small" model
  download only starting *after* the user had already spoken, several
  seconds of dead air before language-ID even began.** `AssetCheckView`'s
  onboarding prewarm doesn't cover this: it warms its own separate
  `LanguageIdentifier` instance, scoped to that view, which isn't the one
  `ConversationLoopController` actually uses — and onboarding only runs
  once, not on every later launch or after switching models in Settings.
  Fixed with `ConversationLoopController.prewarmLanguageModel()`: fires a
  background (non-blocking) load of the currently configured model from
  `init` — so it starts the moment the controller exists, before the user
  has even picked up their headphones — and again from Settings whenever
  `whisperModelRaw` changes. `identify(fileURL:candidates:)` still calls
  `loadedWhisperKit()` itself regardless of whether prewarming finished
  (or started); this is a head start, not a requirement, so a slow/failed
  prewarm just means falling back to the original lazy-load behavior
  rather than breaking anything.
- **A confidently-identified language whose Apple STT transcript comes
  back empty must be rejected, not retried in the other candidate
  locale — confirmed by a real device log after briefly trying the
  retry and watching it produce a wrong translation with no error
  shown.** `SFSpeechRecognizer` can complete normally (`isFinal` fires,
  no error) with an empty `bestTranscription` for genuine speech that
  WhisperKit was highly confident about — a known Apple STT limitation
  on short/unclear audio, not evidence the language was misidentified.
  A tempting fix is to retry transcription in the *other* candidate
  locale when this happens (mirroring `crossCheckLanguage`'s handling of
  one-empty-one-not), but forcing a recognizer to transcribe audio in
  the wrong language doesn't fail the same way — it hallucinates
  fluent-sounding nonsense in its own language instead of coming back
  empty. Real device log: WhisperKit picked "de" with English literally
  absent from its own candidate distribution (`en=missing`, as close to
  zero probability as the model expresses) at raw log-prob -0.02 (so no
  `needsCrossCheck` either); German STT correctly came back empty;
  forcing English STT on the same clip confidently produced "Khasan
  heist Tak Hota" — real English words, no error, silently translated
  into equally nonsensical German. An occasional honest "didn't catch
  that" is a better failure mode than a translation that's silently
  wrong, so `ConversationLoopController.process`'s high-confidence
  (`needsCrossCheck == false`) path rejects outright on an empty
  transcript rather than trying the alternate locale. This is
  deliberately *not* the same situation as `crossCheckLanguage`
  (previous bullet): that only runs when WhisperKit's own confidence was
  already mediocre, so weighing two real candidates against each other
  makes sense there in a way it doesn't once WhisperKit has essentially
  ruled the other language out. `Debug/CaptureRecord.swift`'s capture
  page (Settings > Captures, Debug builds only) is what actually
  surfaced the bad translation here — it logs every candidate locale's
  raw transcript per turn, not just the winner, specifically so this
  class of "which locale said what" question doesn't need re-deriving
  from log lines next time.
- **Update to the above: at least some of those "Apple STT limitation"
  empty transcripts were actually `SpeechRecognizerWrapper.transcribe`
  asking for the wrong locale, not a genuine STT failure.** Every call
  site constructed `SFSpeechRecognizer`'s locale from a bare language
  code — `Locale(identifier: "de")` — reconstructed fresh from
  `Locale.Language.minimalIdentifier` every turn, relying on
  `SFSpeechRecognizer`'s own undocumented internal matching to resolve
  that to an actual regional model. Meanwhile `SupportedLanguages.
  checkOnce()` (previous section) already does this properly elsewhere
  in the app: it explicitly matches each language to a real regional
  locale (`preferredRegion`, e.g. "de" -> "de-DE") and confirms
  `supportsOnDeviceRecognition` against *that specific variant* — but
  discarded the resolved locale and returned only the bare
  `Locale.Language`, so transcription never benefited from it. Two
  independent real-device captures (Settings > Captures) showed the
  same signature: WhisperKit confidently right about German, Apple's
  STT completing normally (not timing out) in well under half a second
  with nothing — too fast to be a genuine attempt at real speech, and
  consistent with the bare code resolving to a locale variant without a
  working on-device model. Fixed via `SupportedLanguages.sttLocale(for:)`,
  which returns the actual validated regional locale (cached from
  `checkOnce()` this run, falling back to `preferredRegion`) — every
  `recognizer.transcribe(fileURL:locale:)` call site in
  `ConversationLoopController` now goes through it instead of
  constructing `Locale(identifier:)` directly. If empty-transcript
  captures keep showing up after this, especially for a language other
  than English, that's evidence for a genuine STT-quality issue rather
  than this locale bug — but check `sttLocale(for:)` resolved to the
  expected regional variant first.
- **RESOLVED — the empty transcripts above were a missing on-device
  recognition asset, and `supportsOnDeviceRecognition` reporting `true`
  does not mean one is actually usable.** The locale fix and the
  oversized-pre-roll fix in the two entries above were both real bugs
  worth keeping, but neither was the cause. Confirmed by A/B on a real
  device: with `requiresOnDeviceRecognition` dropped, the *same* speech
  in the *same* language transcribed fine every time; restricted to
  on-device it came back empty, completing normally in well under half a
  second — the recognizer wasn't failing to understand the audio, it had
  nothing to run. Two things made this hard to see and are the actual
  lesson: (1) `supportsOnDeviceRecognition` returned `true` for the
  locale throughout, so there is **no reliable way to detect this case up
  front** and adapt automatically; and (2) it fails identically to "the
  user said nothing" — an empty transcript, no error, no timeout. The
  misleading comparison, worth not repeating: iOS's own keyboard
  dictation transcribed the same speech every time, which *looks* like
  proof the audio was fine and the app was at fault, but the keyboard may
  use Apple's servers and follows the user's selected dictation language
  — it was never running the same code path. Resolution:
  `RecognitionConfig.allowServerBasedRecognition` (Settings >
  Transcription > "Allow Apple's servers"), **off by default**, lets the
  user opt into server-based recognition when a language has no working
  offline model. Deliberately not on by default and deliberately not an
  automatic retry after an empty on-device result — either would quietly
  send recordings off-device for a user who chose this app precisely
  because it doesn't. The better fix where it's available is installing
  the offline asset (Settings > General > Keyboard > Dictation Languages,
  plus Language & Region), which the Settings copy points at. When
  diagnosing any future "clearly-spoken audio, empty transcript" report,
  check this first — it's cheap to test with the toggle and was the
  answer once already.

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
  A real device capture (Settings > Captures) showed exactly this
  ambiguity from the outside: both candidate locales came back with an
  empty transcript for clearly audible, correctly-identified speech, with
  no way to tell whether Apple's STT genuinely found nothing or just
  never got the chance to before the fallback timeout kicked in.
  `transcribe` now returns a `TranscriptionResult` (`finishedNormally`,
  `error`, `elapsed`, not just bare text) instead of `String?`, and
  `CaptureRecord`'s per-locale attempts carry the same fields — so this
  question is answerable straight from a capture's detail view instead of
  needing a fresh Debug Log capture to re-diagnose it live.
- **Pure energy-based VAD has no concept of "speech" — any sufficiently
  loud sound opens a turn.** User-reported: loud non-speech noise (traffic,
  wind, a dog bark, a door slam) was getting picked up and sent through the
  whole identify→transcribe→translate→speak pipeline, same as real speech,
  since `VADSegmenter` only measures relative energy against an adaptive
  noise floor — it has no actual speech/non-speech classification. Low-cost
  fix: `RecognitionConfig.vadSpeechThreshold` (gates how loud) and
  `.vadMinSpeechDuration` (gates how sustained, filtering brief transients
  like a clap or door slam) are now live Settings sliders instead of
  hardcoded `VADSegmenter.Config` defaults, so this can be tuned per
  environment instead of guessed once. If that's not enough: the real fix
  is a dedicated speech/non-speech classifier ahead of (or replacing) the
  energy gate — `SoundAnalysis`'s `SNClassifySoundRequest` with the
  built-in `SNClassifierIdentifier.version1` model has a "speech" class
  among its ~300 on-device categories, no training/download needed, and is
  the natural next tier before reaching for a dedicated neural VAD (e.g.
  Silero VAD converted to CoreML, shipped like the WhisperKit models) —
  which would be a genuinely bigger lift and shouldn't be the first thing
  tried.
- **Persisted VAD settings only took effect via a live Settings
  `.onChange`, not at launch.** `ConversationLoopController.init` built
  `vad` from `VADSegmenter.Config.default` and never applied whatever was
  already saved in `UserDefaults` from a previous session — a value only
  actually reached `vad` if the user revisited Settings and nudged the
  slider again, so a preference set last session was silently ignored on
  the next cold launch. Fixed by applying `RecognitionConfig.vadSensitivity`
  /`.vadSpeechThreshold`/`.vadMinSpeechDuration` to `vad` right in `init`,
  before `start()` can ever run. Any *new* VAD-related Settings knob needs
  the same treatment — a `set*` method wired to `.onChange` alone isn't
  enough, `init` has to read the persisted value too.

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

### Text-to-speech voice selection

- **Siri's voice can never appear in the voice picker — this is a platform
  restriction, not a bug in `VoicePickerView`/`SpeechOutputService`, and
  isn't fixable from application code.** `SpeechOutputService.availableVoices(for:)`
  already returns everything `AVSpeechSynthesisVoice.speechVoices()` hands
  back with no extra filtering, so if a Siri-branded voice were actually
  present it would already show up. It never does, because Apple
  deliberately withholds Siri's own voice from `AVSpeechSynthesizer` for
  every third-party app — confirmed across multiple Apple Developer Forum
  threads spanning 2021 through the current (2026) iOS cycle, explicitly to
  stop an app impersonating Siri — and confirmed against this app
  specifically via `SpeechOutputService.logAvailableVoiceInventory()`'s
  on-device Debug Log dump (no `com.apple.ttsbundle.siri_*`-style identifier
  present, even with a Siri voice selected in system Settings). If this
  ever needs revisiting, start by pulling a fresh voice inventory dump on
  the device in question rather than assuming the filtering logic is at
  fault — it never has been. The closest available substitute is steering
  users toward an Enhanced/Premium-quality regular voice (already
  distinguished in the picker via `AVSpeechSynthesisVoice.qualityLabel`),
  not chasing Siri's voice itself again.

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
