# Roadmap

## Goal

Capture 2–3 hour in-room conversations on an iPhone 13 and end up with a
complete, readable transcript, with photos of slides in place, a title and a
summary, saved to Apple Notes with as few taps as possible.

## Milestones

### 1. Foundation ✅
- XcodeGen project, signing via `Config/Local.xcconfig`
- `TranscriptCore` package: data model, paragraph formatting, plain-text and
  Markdown export, file storage, recording coordinator (autosave, gaps,
  photos, speaker markers, crash recovery), diagnostics log, with tests
- CI: core tests on Linux and macOS, app build for Simulator and device

### 2. First usable app
- **Recording and speech** (`App/Engine/`): microphone capture with
  AVAudioEngine, SpeechAnalyzer + SpeechTranscriber (fallback to
  DictationTranscriber if the device lacks it), language model download,
  background recording, automatic resume after interruptions (calls, Siri,
  Camera app), optional audio file per recording run
- **Screens** (`App/Views/`, `App/Camera/`): session list, recording screen with
  a small live caption strip, camera / new speaker / stop buttons, transcript
  view with inline photos, settings, diagnostics
- **Getting text out** (`App/Sharing/`, `App/Intents/`): copy, share
  (text and Markdown + photos), Shortcuts action "Get Dictation Transcript", one-tap
  "Send to Notes", import Camera-app photos taken during the session

### 3. AI
- ✅ Claude API (key stored in the Keychain): title, summary, key points, action
  items, speaker guesses — opt-in per session, included in exports and Notes
- Later: high-quality re-transcription of saved audio with a cloud speech
  service (better Chinese, mixed English/Chinese, voice-based speaker labels)

### 4. Polish
- Lock Screen Live Activity with elapsed time and the latest line
- Battery and storage checks for 3-hour sessions

## How the work is split

The foundation defines the contracts in `TranscriptCore`:
`TranscriptionEngine` / `TranscriptionEvent` (engine ↔ app),
`RecordingCoordinator` (what the UI drives and observes), `SessionStoring`,
`TranscriptExporter`. Parallel work items each own separate folders:

| Work item | Owns |
|---|---|
| Recording and speech | `App/Engine/` |
| Screens and camera | `App/Views/`, `App/Camera/`, `App/DictationApp.swift` |
| Getting text out | `App/Sharing/`, `App/Intents/`, export-related code in `TranscriptCore` |
| AI | `App/AI/`, AI fields in `TranscriptCore` |

Changes to shared contracts are kept additive so parallel work doesn't conflict.

## Testing on the iPhone

Things CI can't check, to try after each milestone:

1. Start a recording, lock the phone for 10 minutes, unlock: captions kept going?
2. While recording, open the **Camera app**, take a photo (Live Photo on, then
   off), come back: did recording continue, or is there a gap?
3. Same with the **in-app camera** button: no gap expected.
4. Receive a phone call or trigger Siri mid-recording: does it resume afterwards?
5. A 2–3 hour recording: battery used, transcript complete, app responsive.
6. Force-quit the app mid-recording, reopen: session recovered up to the last
   few seconds?
7. English and Chinese sessions.

After each test, share Settings → Diagnostics.
