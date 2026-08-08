# Conversation

A hands-free iOS translation app for practicing a language solo, on a walk,
with headphones: speak either of two chosen languages, it detects which one,
translates it, and speaks the result back through the headphones — on-device
after first-run setup. See `README.md` for the full pitch and architecture.

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
Everything else (STT, Translation, TTS, Bluetooth audio routing) is
device-dependent and cannot be meaningfully exercised by an automated test —
verify those manually on a real device with headphones, not the simulator.

## Architecture decisions worth knowing before touching this code

- **WhisperKit identifies the language; Apple's `SFSpeechRecognizer`
  transcribes it.** `SFSpeechRecognizer` only supports one active on-device
  recognition task at a time (confirmed, not just suspected — see
  `Speech/LanguageIdentifier.swift`'s doc comment), so guessing a locale and
  retrying the other one live isn't viable. WhisperKit's tiny model runs one
  cheap pass for language-ID only; its transcription output is discarded.
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
- **Min deployment target is iOS 18.0, not 17.4.** The dynamic
  `TranslationSession.Configuration?` API this app needs (swap language
  pairs without tearing down the whole session graph) is 18.0+; 17.4 only
  has the fixed-pair overload.

## Non-obvious bugs already found once — don't reintroduce them

- `TranslationSessionHost` (`Translation/TranslationService.swift`) must
  **never** collapse to a zero-size frame. The system's one-time
  "download language pack" sheet anchors to that view's geometry; a `0×0`
  host gives it nothing to anchor to, and `session.translate()` just hangs
  forever with no error, no timeout, nothing.
- `AudioSessionManager` must be in a playback-capable category
  (`.playAndRecord` or `.playback`) before any `AVSpeechSynthesizer` call.
  The original `.record`-only category (recording-only, no output route)
  let STT work fine while making TTS silently produce zero audio.
- On some real headphone routes (confirmed: AirPods over HFP),
  `SFSpeechRecognizer`'s completion handler never calls back with
  `isFinal`, even after `endAudio()`, even for a complete fixed file — not
  just a live tap. Anything gating further work on `isFinal` alone needs a
  timeout-based self-finalize fallback (see `SpeechRecognizerWrapper.transcribe`
  and `RecognitionConfig.transcriptionFallbackTimeout`), not just a longer wait.
- Earcons must play through `AVAudioPlayer`/the app's own `AVAudioSession`,
  not `AudioServicesPlaySystemSound` — the latter is silenced by the
  physical ring/silent switch; audio routed through the app's session
  (same mechanism as TTS) isn't.

## Repo notes

Public repo, licensed [PolyForm Noncommercial 1.0.0](LICENSE.md) — free for
any noncommercial use, commercial use needs separate arrangement with the
copyright holder. No branch/PR conventions established yet (single
contributor so far).
