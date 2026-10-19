// Self-checks for ClackyCore, runnable with only the Command Line Tools:
//   swift run clacky-check                  run the checks
//   swift run clacky-check --render <dir>   write a typing demo WAV for every switch
import AVFoundation
import ClackyCore
import ClackyObjC
import CoreAudio
import Foundation

struct CheckError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

var failures = 0

func check(_ passed: Bool, _ message: String) {
    print(passed ? "  ok    \(message)" : "  FAIL  \(message)")
    if !passed { failures += 1 }
}

let stereo = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

/// Renders `seconds` of an offline engine and returns the energy in each channel.
func renderEnergy(_ sound: SoundEngine, seconds: Double) throws -> (left: Double, right: Double) {
    let chunk = AVAudioPCMBuffer(pcmFormat: sound.engine.manualRenderingFormat, frameCapacity: 1024)!
    var left = 0.0, right = 0.0
    var remaining = Int(seconds * 48_000)
    while remaining > 0 {
        let frames = AVAudioFrameCount(min(1024, remaining))
        guard try sound.engine.renderOffline(frames, to: chunk) == .success else { throw CheckError("offline render failed") }
        for n in 0..<Int(chunk.frameLength) {
            left += Double(chunk.floatChannelData![0][n] * chunk.floatChannelData![0][n])
            right += Double(chunk.floatChannelData![1][n] * chunk.floatChannelData![1][n])
        }
        remaining -= Int(frames)
    }
    return (left, right)
}

/// Renders in small passes, like an audio device does, until a click starts, then measures the
/// first `ms` of it. Returns how many frames passed before it started (nil if it never did).
/// (A newly scheduled sound begins at the next render pass, so measuring from the key press
/// with large offline chunks would mostly measure the chunk size.)
func click(_ sound: SoundEngine, ms: Double, limit: Int = 4800) throws -> (onset: Int?, left: Double, right: Double) {
    let slice: AVAudioFrameCount = 64
    let chunk = AVAudioPCMBuffer(pcmFormat: sound.engine.manualRenderingFormat, frameCapacity: slice)!
    var rendered = 0, onset: Int?, left = 0.0, right = 0.0
    let window = Int(ms / 1000 * 48_000)
    while rendered < limit + window {
        guard try sound.engine.renderOffline(slice, to: chunk) == .success else { throw CheckError("offline render failed") }
        for n in 0..<Int(chunk.frameLength) {
            let l = Double(chunk.floatChannelData![0][n]), r = Double(chunk.floatChannelData![1][n])
            if onset == nil, abs(l) + abs(r) > 1e-4 { onset = rendered + n }
            if let start = onset, rendered + n < start + window { left += l * l; right += r * r }
        }
        rendered += Int(slice)
        if let start = onset, rendered >= start + window { break }
        if onset == nil, rendered >= limit { break }
    }
    return (onset, left, right)
}

/// Renders `frames` in 256-frame passes, the steady rhythm a real audio device runs at, so a key
/// pressed next is timed against a device-sized pass rather than a large offline chunk.
func idle(_ sound: SoundEngine, frames: Int = 1024) throws {
    let chunk = AVAudioPCMBuffer(pcmFormat: sound.engine.manualRenderingFormat, frameCapacity: 256)!
    for _ in 0..<(frames / 256) { _ = try sound.engine.renderOffline(256, to: chunk) }
}

/// Energy-weighted average frequency, from how much the signal changes sample to sample.
func brightness(_ samples: [Float]) -> Double {
    var energy = 0.0, change = 0.0
    for n in 1..<samples.count {
        energy += Double(samples[n] * samples[n])
        change += Double((samples[n] - samples[n - 1]) * (samples[n] - samples[n - 1]))
    }
    return asin(min(1, (change / energy).squareRoot() / 2)) * 48_000 / .pi
}

func writeWAV(_ url: URL, sampleRate: Double, channels: AVAudioChannelCount, samples: [Float]) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = buffer.frameCapacity
    for channel in 0..<Int(channels) {
        for (n, sample) in samples.enumerated() { buffer.floatChannelData![channel][n] = sample }
    }
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: buffer)
}

struct ScriptedKey {
    let time: Double
    let keyCode: Int
    let phase: KeyPhase
}

/// A human-ish typing run: letters, a typo fixed with backspace, shifted capitals, returns.
func typingScript() -> [ScriptedKey] {
    let codes: [Character: Int] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38,
        "k": 40, "n": 45, "m": 46, ",": 43, ".": 47, " ": 49, "\n": 36, "<": 51,
    ]
    var rng = SplitMix64(seed: 7)
    var keys: [ScriptedKey] = []
    var time = 0.2
    var shifted = false
    for character in "^the quick brown fox jumps over teh<<he lazy dog.\n^pack my box with five dozen liquor jugs.\n" {
        if character == "^" {
            keys.append(ScriptedKey(time: time, keyCode: 56, phase: .down))
            time += 0.09
            shifted = true
            continue
        }
        guard let code = codes[character] else { continue }
        let hold = Double.random(in: 0.055...0.095, using: &rng)
        keys.append(ScriptedKey(time: time, keyCode: code, phase: .down))
        keys.append(ScriptedKey(time: time + hold, keyCode: code, phase: .up))
        if shifted {
            keys.append(ScriptedKey(time: time + hold + 0.03, keyCode: 56, phase: .up))
            shifted = false
        }
        time += Double.random(in: 0.08...0.16, using: &rng)
        if character == " " { time += 0.04 }
        if character == "\n" { time += 0.5 }
    }
    return keys.sorted { $0.time < $1.time }
}

func renderDemos(to folder: URL) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let script = typingScript()
    let step: AVAudioFrameCount = 240  // 5 ms, so keys land close to their scripted time
    for profile in SwitchProfile.all {
        let sound = try SoundEngine(offlineFormat: stereo)
        sound.bank = .synthesized(profile)
        sound.volume = 0.8  // headroom for overlapping keys, like the app's default volume
        try sound.start()
        let url = folder.appendingPathComponent("\(profile.id).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = AVAudioPCMBuffer(pcmFormat: sound.engine.manualRenderingFormat, frameCapacity: step)!
        let totalFrames = Int((script.last!.time + 0.6) * 48_000)
        var frame = 0, next = 0
        while frame < totalFrames {
            while next < script.count, Int(script[next].time * 48_000) <= frame {
                sound.play(keyCode: script[next].keyCode, phase: script[next].phase)
                next += 1
            }
            guard try sound.engine.renderOffline(step, to: chunk) == .success else { throw CheckError("offline render failed") }
            try file.write(from: chunk)
            frame += Int(step)
        }
        print("wrote \(url.path)")
    }
}

/// A recipe not shipped in the app, used only to exercise the synthesis and playback machinery
/// independently of whatever's in the real catalog (which may be empty).
let testProfile = SwitchProfile(
    id: "test", name: "Test Switch", summary: "",
    down: [.noise(5000, q: 3, decay: 3, gain: 0.8), .tone(3800, decay: 5, gain: 0.3),
           .noise(2200, q: 1.2, at: 8, decay: 12, gain: 0.5), .tone(600, at: 8, decay: 20, gain: 0.3)],
    up: [.noise(4600, q: 3, decay: 3, gain: 0.5), .noise(2500, q: 1.2, at: 5, decay: 9, gain: 0.25)],
    rattle: 0.7)

// MARK: - Entry

let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--render") {
    let path = flag + 1 < arguments.count ? arguments[flag + 1] : "build/demos"
    try renderDemos(to: URL(fileURLWithPath: path, isDirectory: true))
    exit(0)
}

print("Key layout")
check(KeyLayout.category(for: 49) == .space, "space bar is a space key")
check(KeyLayout.category(for: 36) == .enter && KeyLayout.category(for: 76) == .enter, "return and keypad enter are enter keys")
check(KeyLayout.category(for: 51) == .backspace, "delete is a backspace key")
check([54, 55, 56, 57, 58, 59, 60, 61, 62, 63].allSatisfy { KeyLayout.category(for: $0) == .modifier }, "all modifiers are modifier keys")
check(KeyLayout.category(for: 0) == .standard, "letters are standard keys")
check(KeyLayout.pan(for: 0) < -0.5, "A pans left (\(KeyLayout.pan(for: 0)))")
check(KeyLayout.pan(for: 41) > 0.3, "; pans right (\(KeyLayout.pan(for: 41)))")
check(abs(KeyLayout.pan(for: 49)) < 0.1, "space pans center")
check(KeyLayout.pan(for: 9999) == 0, "unknown keys pan center")

print("Audio device errors")
var caught: NSError?
let survived = ClackyCatchException({
    NSException(name: .genericException, reason: "player did not see an IO cycle.", userInfo: nil).raise()
}, &caught)
check(!survived && caught?.localizedDescription == "player did not see an IO cycle.",
      "an exception from AVFoundation is caught instead of crashing the app")
check(ClackyCatchException({}, &caught), "normal calls pass straight through")

print("Choosing a sound output")
let dell = OutputDevice(id: 1, uid: "dell", name: "DELL U2417H", transport: kAudioDeviceTransportTypeHDMI)
let speakers = OutputDevice(id: 2, uid: "speakers", name: "MacBook Pro Speakers", transport: kAudioDeviceTransportTypeBuiltIn)
let zoom = OutputDevice(id: 3, uid: "zoom", name: "ZoomAudioDevice", transport: kAudioDeviceTransportTypeVirtual)
let airpods = OutputDevice(id: 4, uid: "airpods", name: "AirPods", transport: kAudioDeviceTransportTypeBluetooth)
let all = [dell, speakers, zoom, airpods]
check(SoundEngine.outputCandidates(choice: nil, defaultID: 1, devices: all) == [dell, speakers, airpods],
      "Automatic tries the Mac's output first, then the built-in speakers, then other real outputs")
check(!SoundEngine.outputCandidates(choice: nil, defaultID: 1, devices: all).contains(zoom),
      "software-only outputs like Zoom's are never a fallback")
check(SoundEngine.outputCandidates(choice: nil, defaultID: 3, devices: all).first == zoom,
      "a software output the Mac itself is set to is still respected")
check(SoundEngine.outputCandidates(choice: "airpods", defaultID: 1, devices: all) == [airpods],
      "a chosen output is used on its own while it's connected")
check(SoundEngine.outputCandidates(choice: "gone", defaultID: 1, devices: all) == [dell, speakers, airpods],
      "an unplugged chosen output falls back to Automatic")
check(SoundEngine.outputCandidates(choice: nil, defaultID: nil, devices: []).isEmpty,
      "no outputs at all means nothing to try (and no crash)")

print("Holding keys")
var filter = KeyPressFilter()
check(filter.press(0, isRepeat: false), "a new press sounds")
check(!filter.press(0, isRepeat: true), "flagged auto-repeat is silent")
check(!filter.press(0, isRepeat: false), "unflagged repeats of a held key are silent too")
check(filter.press(1, isRepeat: false), "another key pressed while one is held still sounds")
check(filter.release(0), "letting go of a held key sounds once")
check(!filter.release(0), "a second release of the same key is silent")
check(filter.press(0, isRepeat: false), "the key sounds again on its next press")
check(!filter.release(42), "releasing a key held since before Clacky started is silent")
filter.reset()
check(filter.press(1, isRepeat: false), "after a reset, a key whose release was missed sounds again")

print("Synthesizer")
var rng = SplitMix64(seed: 42)
// Always tests the fixture, plus every profile actually shipped in the catalog (currently none).
for profile in [testProfile] + SwitchProfile.all {
    var problems: [String] = []
    for category in KeyCategory.allCases {
        for phase in KeyPhase.allCases {
            let samples = Synthesizer.render(profile, category: category, phase: phase, rng: &rng)
            let peak = samples.lazy.map(abs).max() ?? 0
            let seconds = Double(samples.count) / Synthesizer.sampleRate
            if samples.isEmpty || !samples.allSatisfy(\.isFinite) || peak < 0.05 || peak > 1 || seconds > 1 {
                problems.append("\(category)-\(phase) peak \(peak) length \(seconds)s")
            }
        }
    }
    check(problems.isEmpty, "\(profile.name) renders every key type" + (problems.isEmpty ? "" : ": " + problems.joined(separator: ", ")))
    let presses = (0..<6).map { _ in Synthesizer.render(profile, category: .standard, phase: .down, rng: &rng) }
    check(Set(presses.map(\.count)).count > 1 || presses[0] != presses[1], "\(profile.name) presses vary")
}
if SwitchProfile.all.isEmpty {
    print("        (catalog is empty — only the test fixture above was checked)")
}
var spaceRNG = SplitMix64(seed: 3), letterRNG = SplitMix64(seed: 3)
let spacePress = Synthesizer.render(testProfile, category: .space, phase: .down, rng: &spaceRNG)
let letterPress = Synthesizer.render(testProfile, category: .standard, phase: .down, rng: &letterRNG)
check(brightness(spacePress) < brightness(letterPress), "space bar is lower than a letter")
check(spacePress.count > letterPress.count, "space bar rings longer than a letter")

print("Playback")
let sound = try SoundEngine(offlineFormat: stereo)
sound.bank = .synthesized(testProfile, variants: 1)  // one variant: no randomness in these checks
sound.stereoWidth = 1  // set before start on purpose: pans must survive the engine starting
try sound.start()
let silence = try renderEnergy(sound, seconds: 0.05)
check(silence.left + silence.right == 0, "silent until a key is pressed")
sound.play(keyCode: 0, phase: .down)  // A, left side
let leftKey = try renderEnergy(sound, seconds: 0.3)
check(leftKey.left + leftKey.right > 1, "a key press is audible")
check(leftKey.left > leftKey.right * 4, "left-hand keys come from the left")
// The click itself (first 20 ms) must already be on the right, not drifting over from the last key.
try idle(sound)
sound.play(keyCode: 41, phase: .down)  // ;, right side
let rightClick = try click(sound, ms: 20)
check(rightClick.onset != nil && rightClick.right > rightClick.left * 4,
      "a right-hand click starts on the right right after a left-hand key")
_ = try renderEnergy(sound, seconds: 0.3)
sound.stereoWidth = 0
_ = try renderEnergy(sound, seconds: 0.1)
sound.play(keyCode: 0, phase: .down)
let centered = try renderEnergy(sound, seconds: 0.3)
check(abs(centered.left - centered.right) < centered.left * 0.01, "stereo width 0 centers every key")
sound.stereoWidth = 1
try idle(sound, frames: 3072)  // past the 50 ms the voices spend settling into their new pans
sound.play(keyCode: 0, phase: .down)
let prompt = try click(sound, ms: 3)
check((prompt.onset ?? .max) <= 256 && prompt.left + prompt.right > 0.01,
      "a click starts within one audio buffer (≈5 ms) of the key"
      + (prompt.onset.map { $0 > 256 ? " (took \($0) frames)" : "" } ?? " (never started)"))
_ = try renderEnergy(sound, seconds: 0.3)
for step in 0..<20 { sound.stereoWidth = Float(step) / 19 }  // dragging the slider
try idle(sound)
sound.play(keyCode: 0, phase: .down)
let midDrag = try click(sound, ms: 3)
check((midDrag.onset ?? .max) <= 1300,
      "right after dragging the stereo slider, a click is still never more than ~25 ms late"
      + (midDrag.onset.map { $0 > 1300 ? " (took \($0) frames)" : "" } ?? " (never started)"))
for keyCode in 0..<40 { sound.play(keyCode: keyCode, phase: .down) }
let burst = try renderEnergy(sound, seconds: 0.3)
check(burst.left.isFinite && burst.right.isFinite && burst.left + burst.right > 1, "40 simultaneous keys play without breaking")
sound.bank = nil
sound.play(keyCode: 0, phase: .down)
let noBank = try renderEnergy(sound, seconds: 0.3)
check(noBank.left + noBank.right == 0, "nothing plays without a sound bank")

print("Tone")
func samples(_ buffer: AVAudioPCMBuffer?) -> [Float] {
    guard let buffer else { return [] }
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}
func rms(_ x: [Float]) -> Double { (x.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(1, x.count))).squareRoot() }
/// Frames until the sound first gets going.
func onset(_ x: [Float]) -> Int { x.firstIndex { abs($0) > 0.003 } ?? x.count }
let toneBank = SoundBank.synthesized(testProfile, variants: 1)
let asRecorded = samples(toneBank.buffer(for: .standard, phase: .down))
toneBank.tone = -1
let deeper = samples(toneBank.buffer(for: .standard, phase: .down))
toneBank.tone = 1
let brighter = samples(toneBank.buffer(for: .standard, phase: .down))
toneBank.tone = 0
check(samples(toneBank.buffer(for: .standard, phase: .down)) == asRecorded, "the middle of the tone slider plays the recording untouched")
check(brightness(deeper) < brightness(asRecorded) * 0.8,
      "Deeper sounds lower (\(Int(brightness(asRecorded))) → \(Int(brightness(deeper))) Hz)")
check(brightness(brighter) > brightness(asRecorded) * 1.05,
      "Brighter sounds higher (\(Int(brightness(asRecorded))) → \(Int(brightness(brighter))) Hz)")
check([deeper, brighter].allSatisfy { abs(20 * log10(rms($0) / rms(asRecorded))) < 3 && $0.allSatisfy { abs($0) < 1 } },
      "changing the tone keeps the loudness about the same, without clipping")
check(onset(deeper) <= onset(asRecorded) + 24 && onset(brighter) <= onset(asRecorded) + 24,
      "changing the tone doesn't delay the click")

print("Every key sounds a little different")
let keyBank = SoundBank.synthesized(testProfile, variants: 1)
let letters = Array(0...50).filter { KeyLayout.category(for: $0) == .standard }
let sameEverywhere = Set(letters.map { keyBank.buffer(for: .standard, phase: .down, keyCode: $0)?.frameLength ?? 0 })
check(sameEverywhere.count == 1, "when off, every key plays the same recording")
let started = Date()
keyBank.variesByKey = true
let voicingTime = Date().timeIntervalSince(started)
let lengths = letters.map { keyBank.buffer(for: .standard, phase: .down, keyCode: $0)?.frameLength ?? 0 }
check(Set(lengths).count >= 4, "when on, keys get different voicings (\(Set(lengths).count) across the letters)")
check(letters.allSatisfy { keyBank.buffer(for: .standard, phase: .down, keyCode: $0)?.frameLength
          == keyBank.buffer(for: .standard, phase: .down, keyCode: $0)?.frameLength },
      "each key keeps its own sound from press to press")
let original = Double(asRecorded.count)
check(lengths.allSatisfy { abs(Double($0) / original - 1) < 0.035 }, "pitch changes stay under half a semitone")
let voiced = letters.map { samples(keyBank.buffer(for: .standard, phase: .down, keyCode: $0)) }
check(voiced.allSatisfy { onset($0) <= onset(asRecorded) + 24 && $0.allSatisfy { abs($0) < 1 } },
      "re-pitched keys start just as promptly, without clipping")
keyBank.tone = -1
check(brightness(samples(keyBank.buffer(for: .standard, phase: .down, keyCode: 12))) < brightness(asRecorded) * 0.8,
      "tone and per-key sounds work together")
check(voicingTime < 1, "preparing the per-key sounds is quick (\(Int(voicingTime * 1000)) ms)")

print("Staying quiet while the microphone is on")
let zoomCall = MicrophoneWatcher.Recorder(pid: 500, bundleID: "us.zoom.xos")
let heySiri = MicrophoneWatcher.Recorder(pid: 810, bundleID: "com.apple.CoreSpeech")
let soundRecognition = MicrophoneWatcher.Recorder(pid: 94001, bundleID: "com.apple.accessibility.heard")
let itself = MicrophoneWatcher.Recorder(pid: 42, bundleID: "com.aneeshkolluri.Clacky")
check(MicrophoneWatcher.activeRecorder(among: [heySiri, soundRecognition], ownPID: 42) == nil,
      "\"Hey Siri\" and Sound Recognition, which always listen, don't count")
check(MicrophoneWatcher.activeRecorder(among: [heySiri, zoomCall], ownPID: 42) == zoomCall, "a call does")
check(MicrophoneWatcher.activeRecorder(among: [itself], ownPID: 42) == nil, "Clacky itself doesn't")
check(MicrophoneWatcher.activeRecorder(among: [], ownPID: 42) == nil, "nobody recording means no pause")

print("Sound packs")
let packFolder = FileManager.default.temporaryDirectory.appendingPathComponent("clacky-check-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: packFolder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: packFolder) }
// 44.1 kHz stereo with 100 ms of silence up front, to exercise conversion and trimming.
let recording: [Float] = [Float](repeating: 0, count: 4410) + (0..<6615).map { n in
    let t = Double(n) / 44_100
    return Float(sin(2 * .pi * 1000 * t) * exp(-t / 0.03) * 0.8)
}
try writeWAV(packFolder.appendingPathComponent("standard-down-1.wav"), sampleRate: 44_100, channels: 2, samples: recording)
try writeWAV(packFolder.appendingPathComponent("standard-down-2.wav"), sampleRate: 44_100, channels: 2, samples: recording)
try writeWAV(packFolder.appendingPathComponent("space-down.wav"), sampleRate: 48_000, channels: 1, samples: recording)
try "not audio".write(to: packFolder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
try "not audio either".write(to: packFolder.appendingPathComponent("readme-down.txt"), atomically: true, encoding: .utf8)
do {
    let pack = try SoundBank.loadPack(at: packFolder)
    let loaded = pack.buffer(for: .standard, phase: .down)
    check(loaded?.format.sampleRate == 48_000 && loaded?.format.channelCount == 1, "recordings convert to 48 kHz mono")
    let seconds = Double(loaded?.frameLength ?? 0) / 48_000
    check(abs(seconds - 0.151) < 0.01, "leading silence is trimmed (\(String(format: "%.3f", seconds))s left of 0.25s)")
    check(pack.buffer(for: .enter, phase: .down) != nil, "missing categories fall back to standard")
    check(pack.buffer(for: .space, phase: .down)?.frameLength != loaded?.frameLength, "category-specific files are used when present")
    check(pack.buffer(for: .standard, phase: .up) == nil, "a pack without release sounds stays silent on release")
} catch {
    check(false, "pack loads: \(error)")
}
let emptyPack = packFolder.appendingPathComponent("Empty")
try FileManager.default.createDirectory(at: emptyPack, withIntermediateDirectories: true)
do {
    _ = try SoundBank.loadPack(at: emptyPack)
    check(false, "a pack without standard-down sounds is rejected")
} catch {
    check(error is SoundBank.PackError, "a pack without standard-down sounds is rejected")
}

print("Shipped switches")
let shippedPacks = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Resources/Sound Packs")
let shipped = ((try? FileManager.default.contentsOfDirectory(at: shippedPacks, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
    .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
check(!shipped.isEmpty, "the app ships with sound packs")
for folder in shipped {
    let name = folder.lastPathComponent
    do {
        let pack = try SoundBank.loadPack(at: folder)
        let described = FileManager.default.fileExists(atPath: folder.appendingPathComponent("description.txt").path)
        check(pack.buffer(for: .standard, phase: .down) != nil && described, "\(name) loads and describes itself")
    } catch {
        check(false, "\(name) loads: \(error)")
    }
}

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
