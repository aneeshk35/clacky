import AVFoundation

/// Ready-to-play buffers for every key category and phase, with several variants of each
/// so repeated presses of the same key don't sound identical.
public final class SoundBank {
    public enum PackError: LocalizedError {
        case missingStandardDown(pack: String)
        case unreadable(file: String)

        public var errorDescription: String? {
            switch self {
            case .missingStandardDown(let pack):
                return "Sound pack “\(pack)” needs at least one standard-down file, e.g. standard-down-1.wav."
            case .unreadable(let file):
                return "Couldn't read “\(file)”."
            }
        }
    }

    private typealias Shelf = [KeyCategory: [KeyPhase: [[AVAudioPCMBuffer]]]]

    public let name: String

    /// Gives each key its own slightly different pitch and loudness, the way keys at different
    /// spots on a real keyboard don't sound quite the same. A key always keeps its own sound.
    public var variesByKey = false {
        didSet { if variesByKey != oldValue { rebuild() } }
    }

    /// Shapes the sound: -1 is deeper (more body, softer click), 0 is as recorded, 1 is brighter.
    public var tone: Float = 0 {
        didSet { if tone != oldValue { rebuild() } }
    }

    /// The recordings as loaded (or synthesized).
    private var recordings: [KeyCategory: [KeyPhase: [AVAudioPCMBuffer]]] = [:]
    /// Every recording at every voicing, made the first time `variesByKey` is turned on.
    private var voiced: Shelf = [:]
    /// What plays, by voicing: `recordings` (or `voiced`) with the tone applied.
    private var playable: Shelf = [:]

    /// Pitch and level of each voicing; the first is the recording as is. About ±2.5% (under half a
    /// semitone) and up to 1 dB quieter: enough to tell keys apart, not enough to sound like a new switch.
    static let voicings: [(pitch: Double, gain: Float)] = [
        (1, 1), (0.976, 0.94), (1.024, 0.97), (0.988, 0.9), (1.012, 0.95),
    ]

    private init(name: String) {
        self.name = name
    }

    /// Whether any key type has recordings of the key being let go.
    public var hasReleaseSounds: Bool {
        recordings.values.contains { $0[.up]?.isEmpty == false }
    }

    /// A random variant for the key. Categories a bank lacks fall back to `standard`.
    public func buffer(for category: KeyCategory, phase: KeyPhase, keyCode: Int = 0) -> AVAudioPCMBuffer? {
        guard let byVoicing = playable[category]?[phase] ?? playable[.standard]?[phase] else { return nil }
        let voicing = variesByKey ? Self.voicing(for: keyCode) : 0
        return byVoicing[min(voicing, byVoicing.count - 1)].randomElement()
    }

    /// The voicing a key always gets.
    static func voicing(for keyCode: Int) -> Int {
        Int((UInt32(truncatingIfNeeded: keyCode) &* 2_654_435_761) >> 16) % voicings.count
    }

    public static func synthesized(_ profile: SwitchProfile, variants: Int = 6, seed: UInt64 = 1) -> SoundBank {
        let bank = SoundBank(name: profile.name)
        var rng = SplitMix64(seed: seed)
        for category in KeyCategory.allCases {
            for phase in KeyPhase.allCases {
                bank.recordings[category, default: [:]][phase] = (0..<variants).compactMap { _ in
                    Synthesizer.makeBuffer(Synthesizer.render(profile, category: category, phase: phase, rng: &rng))
                }
            }
        }
        bank.rebuild()
        return bank
    }

    /// Loads a folder of recordings named `<category>-<phase>[-anything].<ext>`,
    /// e.g. `standard-down-1.wav`, `standard-up-1.wav`, `space-down.wav`.
    public static func loadPack(at folder: URL) throws -> SoundBank {
        let bank = SoundBank(name: folder.lastPathComponent)
        let audioExtensions: Set<String> = ["wav", "aif", "aiff", "caf", "mp3", "m4a"]
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for file in files {
            let parts = file.deletingPathExtension().lastPathComponent.lowercased().split(separator: "-")
            guard parts.count >= 2,
                  let category = KeyCategory(rawValue: String(parts[0])),
                  let phase = KeyPhase(rawValue: String(parts[1]))
            else { continue }
            let buffer = try trimmingLeadingSilence(loadAudio(file))
            bank.recordings[category, default: [:]][phase, default: []].append(buffer)
        }

        guard bank.recordings[.standard]?[.down]?.isEmpty == false else {
            throw PackError.missingStandardDown(pack: folder.lastPathComponent)
        }
        bank.rebuild()
        return bank
    }

    private func rebuild() {
        if variesByKey && voiced.isEmpty {
            voiced = recordings.mapValues { phases in
                phases.mapValues { buffers in
                    Self.voicings.map { voicing in
                        buffers.map { Self.repitched($0, by: voicing.pitch, gain: voicing.gain) ?? $0 }
                    }
                }
            }
        }
        let source: Shelf = variesByKey ? voiced : recordings.mapValues { $0.mapValues { [$0] } }
        playable = tone == 0 ? source : source.mapValues { phases in
            phases.mapValues { byVoicing in byVoicing.map { $0.map { Self.shaped($0, tone: tone) } } }
        }
    }

    /// Reads any audio file and converts it to the engine's mono 48 kHz format.
    static func loadAudio(_ url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw PackError.unreadable(file: url.lastPathComponent)
        }
        try file.read(into: input)
        if input.format.isEqual(Synthesizer.format) { return input }
        guard let output = try convert(input, to: Synthesizer.format) else {
            throw PackError.unreadable(file: url.lastPathComponent)
        }
        return output
    }

    /// Converts between sample rates and channel layouts. nil if the formats can't be converted.
    static func convert(_ input: AVAudioPCMBuffer, to target: AVAudioFormat) throws -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(Double(input.frameLength) * target.sampleRate / input.format.sampleRate) + 1024
        guard let converter = AVAudioConverter(from: input.format, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)
        else { return nil }
        converter.downmix = true
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        var delivered = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if delivered {
                inputStatus.pointee = .endOfStream
                return nil
            }
            delivered = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error { throw conversionError ?? CocoaError(.fileReadCorruptFile) }
        return output
    }

    /// The buffer played `pitch` times higher (and that much shorter), at `gain`.
    static func repitched(_ buffer: AVAudioPCMBuffer, by pitch: Double, gain: Float) -> AVAudioPCMBuffer? {
        if pitch == 1 && gain == 1 { return buffer }
        // Label the samples as recorded at a different rate, then convert back to the real one.
        let format = buffer.format
        guard let relabeled = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate * pitch,
                                            channels: 1, interleaved: false),
              let source = AVAudioPCMBuffer(pcmFormat: relabeled, frameCapacity: buffer.frameLength)
        else { return nil }
        source.frameLength = buffer.frameLength
        source.floatChannelData![0].update(from: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        guard let output = try? convert(source, to: format) else { return nil }
        let samples = output.floatChannelData![0]
        for n in 0..<Int(output.frameLength) { samples[n] *= gain }
        return trimmingLeadingSilence(output)
    }

    /// The buffer with `tone` applied: a low shelf and a high shelf, then brought back to the
    /// original loudness (without clipping) so the tone doesn't double as a volume control.
    static func shaped(_ buffer: AVAudioPCMBuffer, tone: Float) -> AVAudioPCMBuffer {
        let t = Double(max(-1, min(1, tone)))
        let rate = buffer.format.sampleRate
        // Deeper: more body and much less click. Brighter: less body, more click.
        var low = Biquad.lowShelf(frequency: 250, gainDB: t < 0 ? -6 * t : -4 * t, sampleRate: rate)
        var high = Biquad.highShelf(frequency: 2500, gainDB: t < 0 ? 12 * t : 6 * t, sampleRate: rate)
        guard let shaped = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return buffer }
        shaped.frameLength = buffer.frameLength
        let input = buffer.floatChannelData![0], output = shaped.floatChannelData![0]
        let count = Int(buffer.frameLength)
        var inputEnergy = 0.0, outputEnergy = 0.0
        var peak: Float = 0
        for n in 0..<count {
            let y = Float(high.process(low.process(Double(input[n]))))
            output[n] = y
            inputEnergy += Double(input[n] * input[n])
            outputEnergy += Double(y * y)
            peak = max(peak, abs(y))
        }
        guard outputEnergy > 0, peak > 0 else { return shaped }
        let gain = min(Float((inputEnergy / outputEnergy).squareRoot()), 0.98 / peak)
        // The filters can leave the end of the sound slightly above zero; fade the last 2 ms so it doesn't pop.
        let fade = min(count, Int(rate / 500))
        for n in 0..<count {
            let remaining = count - n
            output[n] *= remaining < fade ? gain * Float(remaining) / Float(fade) : gain
        }
        return shaped
    }

    /// Drops the quiet lead-in most recordings have, which would otherwise feel like latency.
    static func trimmingLeadingSilence(_ buffer: AVAudioPCMBuffer, threshold: Float = 0.003) -> AVAudioPCMBuffer {
        guard let data = buffer.floatChannelData?[0] else { return buffer }
        let count = Int(buffer.frameLength)
        var onset = 0
        while onset < count && abs(data[onset]) < threshold { onset += 1 }
        guard onset < count else { return buffer }
        let start = max(0, onset - Int(buffer.format.sampleRate / 1000))  // keep 1 ms before the onset
        guard start > 0, let trimmed = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(count - start))
        else { return buffer }
        trimmed.frameLength = trimmed.frameCapacity
        trimmed.floatChannelData![0].update(from: data + start, count: count - start)
        return trimmed
    }
}
