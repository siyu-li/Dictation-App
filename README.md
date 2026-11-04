# Dictation

An iPhone app that live-captions the people talking in a room and keeps the
**whole transcript**, even for 2–3 hour talks. It saves as it goes, so
nothing needs copying out by hand.

- On-device speech recognition (Apple SpeechAnalyzer, iOS 26), English or Chinese
- Keeps recording with the screen locked; resumes by itself after interruptions
  and marks any gap in the transcript
- Take photos of slides from inside the app; they appear in the transcript at
  the moment you took them
- "New speaker" button, paragraphs at pauses, timestamps
- Copy, share, or send to Apple Notes through a Shortcut
- Optional: save the audio (off by default)
- Planned: AI title, summary and speaker guesses (Claude), high-quality
  re-transcription from saved audio

See [docs/ROADMAP.md](docs/ROADMAP.md) for the plan and status.

## Build and install on your iPhone

You need a Mac with **Xcode 26 or later**, and an iPhone on **iOS 26 or later**.

1. Install [Homebrew](https://brew.sh) if you don't have it, then XcodeGen:

   ```bash
   brew install xcodegen
   ```

2. Get the code:

   ```bash
   git clone https://github.com/siyu-li/Dictation-App.git
   cd Dictation-App
   ```

3. Set up signing once. Copy the example file and put your Apple team ID and a
   bundle prefix of your own in it (instructions are inside the file):

   ```bash
   cp Config/Local.xcconfig.example Config/Local.xcconfig
   ```

4. Generate the Xcode project and open it:

   ```bash
   xcodegen generate
   open Dictation.xcodeproj
   ```

5. Plug in your iPhone, choose it as the run destination, and press Run (⌘R).
   The first time:
   - On the iPhone, turn on **Settings → Privacy & Security → Developer Mode**.
   - If iOS says the developer isn't trusted: **Settings → General → VPN & Device
     Management** → your Apple ID → Trust.

With a free Apple account the app stops opening after 7 days; just press Run in
Xcode again. The $99/year Apple Developer Program makes installs last a year.

After pulling new changes, run `xcodegen generate` again before building.

## Project layout

```
App/                      iPhone app (SwiftUI)
  Engine/                 microphone + speech recognition
  Views/                  screens
  Camera/                 in-app camera
  Sharing/                export, Notes shortcut, photo import
  Intents/                Shortcuts actions
Packages/TranscriptCore/  all app logic that doesn't need iOS: data model,
                          formatting, export, storage, recording coordinator
project.yml               XcodeGen spec for the Xcode project
.github/workflows/ci.yml  builds the app and runs tests on every push
```

`TranscriptCore` builds and tests anywhere Swift runs, including Linux:

```bash
swift test --package-path Packages/TranscriptCore
```

## Diagnostics

Settings → Diagnostics shows a log of what the app did (start/stop,
interruptions, errors). After testing on your phone, share that log so problems
can be fixed based on what really happened.
