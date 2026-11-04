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

**Intel Mac?** The App Store only offers the newest Xcode (27), which runs on
Apple silicon only. Download **Xcode 26.6** instead (needs macOS Tahoe 26.2 or
later): sign in at [developer.apple.com/download/all](https://developer.apple.com/download/all)
with your Apple ID, search "Xcode 26", download the `.xip`, double-click it and
drag Xcode into Applications. Xcode 26 installs on iPhones up to iOS 26; for an
iPhone on iOS 27, use the sideloading option below.

**No suitable Xcode?** Every CI run builds an installable app file: open the
repo's **Actions** tab → latest **CI** run → **Artifacts** →
*Dictation-unsigned-ipa*, and install it with a sideloading tool such as
Sideloadly using your Apple ID (with a free Apple ID it must be re-installed
every 7 days).

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

## Save to Apple Notes

Apps can't write into Apple Notes directly, so Dictation hands the transcript
to a Shortcut. Create it once:

1. Open the **Shortcuts** app → **+** (new shortcut). Name it exactly
   **Dictation to Notes** (or another name, and enter that name in
   Dictation's Settings).
2. Add the action **Get Dictation Transcript**. Tap its **Session ID** field and
   choose **Shortcut Input**.
3. Add the Notes action **Create Note**, with the body set to the result of
   *Get Dictation Transcript*. Pick a folder if you like.

Then in Dictation:

- Tap **Send to Notes** on a transcript; the Shortcut runs and creates the note.
  The first line of the transcript (its title) becomes the note's title.
- Or turn on **Send to Notes after stopping** in Settings to do it
  automatically each time you stop a recording.

Running the Shortcut by hand (without a Session ID) uses your most recent
finished recording. "Hey Siri, get transcript from Dictation" works too.

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
