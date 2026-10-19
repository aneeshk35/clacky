# Clacky

A macOS app that plays mechanical keyboard sounds whenever you type, anywhere on the system, using real recordings of keyboards.

Its colors are "Sorbet, dark": an ink window, a pastel keycap for each switch, and tangerine for everything you can change. They live in `Sources/Clacky/Theme.swift`. Clacky stays dark even when the Mac is in light mode.

## Build and run

Needs macOS 13+ and Swift 5.9+. The Xcode Command Line Tools are enough; full Xcode isn't required.

```bash
./scripts/build-app.sh --open
```

This builds `build/Clacky.app` and launches it. Clacky is a normal app with a Dock icon and a window. The window holds what you'll change most: the on/off switch, a card for each switch sound (click one to hear it), volume and tone. Everything else is under **Settings** (⌘,): stereo width, release sounds and per-key sounds; the sound output; when to stay quiet; launch at login and the sound packs folder. **⌃⌥⌘C** turns Clacky on and off from any app (the Dock icon shows "Off" while it's off). Closing the window keeps it running (click the Dock icon to bring it back); **Quit Clacky** or ⌘Q stops it.

## Input Monitoring permission

Hearing keystrokes in other apps requires **System Settings → Privacy & Security → Input Monitoring**. The first launch asks for it; switch Clacky on and sounds start within a couple of seconds.

Clacky only receives key codes (which physical key, pressed or released). macOS blocks it entirely while you type into password fields.

Rebuilding keeps the permission. Ad-hoc builds are signed with a designated requirement of just the bundle identifier (`com.aneeshkolluri.Clacky`), which stays the same from build to build. The trade-off is that any ad-hoc-signed app claiming that identifier would match it too. To avoid that, sign with a real certificate: `SIGN_IDENTITY="Apple Development: …" ./scripts/build-app.sh`.

If access ever looks switched on but Clacky hears nothing, reset it and grant it again:

```bash
tccutil reset ListenEvent com.aneeshkolluri.Clacky
```

## How keys sound

- **One sound per press.** Holding a key down plays it once, like a real keyboard; macOS's auto-repeat never adds more.
- **Release sounds.** Real switches make a second, softer sound when the key springs back up. Packs that include release recordings play it when you let go; turn it off with **Key release sounds**. The window says when a pack has none.
- **Big keys.** Space, Enter and Delete use deeper versions of the press.
- **Stereo.** With **Stereo width** turned up, keys come from where they sit on the keyboard.
- **Every key sounds a little different.** Like keys in different spots on a real keyboard, each key gets its own slightly different pitch (under half a semitone) and loudness, and keeps it. This matters most for packs with few recordings. It's on by default; turn it off to hear every key exactly as recorded.
- **Tone.** Slides any pack from **Deeper** (more body, softer click) to **Brighter** (crisper click), keeping it about as loud. The middle plays the recordings untouched.

## Staying quiet

- **While the microphone is on.** Clacky pauses whenever another app is recording (a Zoom, FaceTime or Meet call, a voice memo, dictation), so nobody on the other end hears the clicks, and says which app in the window. "Hey Siri" and Sound Recognition, which listen all the time, don't count. Needs macOS 14 or later.
- **In chosen apps.** In Settings → Stay Quiet, **Add App** lists the apps that are open, or **Choose…** picks any app. Clacky is silent while that app is in front, for games, say.

## Sound output

**Sound output** picks where the clicks play. **Automatic** follows the Mac's sound output (System Settings → Sound). When that output can't play (a monitor without speakers, say), Clacky uses the built-in speakers instead, then any other output you'd actually hear, and says so in the window. It never falls back to software-only outputs like Zoom's. Choose a specific output to always use it; if it's unplugged, Clacky goes back to Automatic until it's connected again.

If no output can play yet (at login, after sleep, while switching devices), Clacky keeps retrying and starts as soon as one works. It doesn't freeze or crash.

## Sound packs

Nine switches ship inside the app (`Resources/Sound Packs/`, copied into `Clacky.app` by `build-app.sh`). Your own go in `~/Library/Application Support/Clacky/Sound Packs/`, one folder per pack; the **Add Your Own** card opens it. A pack of yours with the same name as a shipped one replaces it. New, removed or renamed packs show up when you switch back to Clacky. After changing the recordings inside a pack, choose **Reload** in Settings → General.

| Pack | Sound | Release sounds |
| --- | --- | --- |
| Clicky (Real) | Crisp clicks | No |
| Creamy Linear | Muted, smooth linear switches (Gateron Yellows); the cleanest recording | Yes |
| Creamy Thock | Very deep, muffled thock (Wobkey Rainy 75) | Yes |
| Hako Violet | Tactile: a soft bump, a muted clack (WhiteFox) | Yes |
| MX Blue | Loud, crisp clicks (Cherry MX Blue) | Yes |
| MX Brown | Light tactile (Cherry MX Brown, Corsair K95) | Yes |
| MX Clear | Heavy tactile (Cherry MX Clear) | Yes |
| MX Red | Smooth, light linear (Cherry MX Red) | Yes |
| Thocky | Medium-deep thock with a little more resonance | Yes |

All of them are cut from public-domain (CC0) recordings on Freesound.org; `Resources/Sound Packs/CREDITS.md` lists each source.

### Making your own

Name files `<key type>-<down|up>[-anything].wav`:

- Key types: `standard`, `modifier`, `enter`, `backspace`, `space`
- Several files for the same slot (`standard-down-1.wav`, `standard-down-2.wav`, …) are picked at random
- Only `standard-down` is required; missing key types fall back to `standard`, and no `up` files means no release sound
- WAV, AIFF, CAF, MP3 and M4A all work; silence at the start of a file is trimmed automatically
- An optional `description.txt` is shown under the pack's name in the window

## App icon

A white keycap with a tangerine "c" on a tangerine tile. `scripts/make-icon.swift` draws it at every size macOS uses and writes `Resources/AppIcon.icns`, which `build-app.sh` puts in the app:

```bash
swift scripts/make-icon.swift                  # rebuild the icon
swift scripts/make-icon.swift --color 2B2D33   # try another tile color (this is the old graphite)
```

The artwork is a full square, because macOS 26 cuts the rounded shape itself and shrinks old-style rounded artwork into an extra frame. macOS 15 and earlier don't round icons, so build with `--framed` for those. If the Mac's icon style (System Settings → Appearance) is Clear or Tinted, macOS shows every icon without its color, Clacky's included.

## Checks

```bash
swift run clacky-check
```

Checks key mapping, held keys and auto-repeat, recovery from audio device errors, output fallback, stereo placement, click latency, tone, per-key sounds, the microphone rules, sound-pack loading and every shipped switch, rendering the audio engine offline. It needs no permissions and makes no sound.

## Layout

```
Sources/ClackyCore/     everything but the UI
  KeyMonitor.swift        system-wide key events (listen-only CGEventTap); one press per key
  KeyLayout.swift         key code → key type and stereo position
  SoundBank.swift         loads sound packs; tone and per-key pitch
  SoundEngine.swift       low-latency playback (AVAudioEngine); picks and falls back between outputs
  AudioDevices.swift      lists the Mac's sound outputs and watches for changes
  Microphone.swift        notices when another app is recording
  SwitchProfile.swift,    synthesized sounds (no built-in profiles at the moment)
  Synthesizer.swift
Sources/ClackyObjC/     catches Objective-C exceptions AVFoundation raises for device problems
Sources/Clacky/         the app: ContentView (main window), SettingsView (Settings tabs), Theme (colors),
                        HotKey (⌃⌥⌘C)
Sources/ClackyCheck/    self-checks
Resources/Info.plist
Resources/AppIcon.icns  made by scripts/make-icon.swift
Resources/Sound Packs/  the switches that ship in the app, and their credits
scripts/build-app.sh
```
