import AVFoundation

/// Builds keystroke sounds from a `SwitchProfile`, so the app works without any audio files.
public enum Synthesizer {
    public static let sampleRate = 48_000.0
    /// Mono float format for every buffer the app plays; the mixer converts to the output device.
    public static let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

    /// Renders one keystroke. Every call varies timing, pitch and level a little, like real presses.
    public static func render<R: RandomNumberGenerator>(
        _ profile: SwitchProfile, category: KeyCategory, phase: KeyPhase, rng: inout R
    ) -> [Float] {
        let voicing = category.voicing
        var layers = phase == .down ? profile.down : profile.up
        if phase == .down, let loudest = layers.map(\.gain).max() {
            // Every switch has a hard plastic-on-plastic contact underneath its character —
            // a very brief broadband tick that sharpens the attack regardless of switch type.
            layers.append(.noise(6400, q: 2, decay: 1.2, gain: loudest * 0.3))
        }
        if voicing.rattle > 0, profile.rattle > 0, let lastHit = layers.map(\.delay).max() {
            // The stabilizer wire knocking around just after the key lands.
            let gain = 0.22 * voicing.rattle * profile.rattle * (phase == .down ? 1 : 0.6)
            layers.append(.noise(3400, q: 2.5, at: lastHit + 4, decay: 3, gain: gain))
            layers.append(.noise(2900, q: 2.5, at: lastHit + 11, decay: 4, gain: gain * 0.6))
        }

        let pitch = voicing.pitch * vary(0.03, &rng)
        var output: [Float] = []
        for layer in layers {
            let start = Int(layer.delay * vary(0.15, &rng) / 1000 * sampleRate)
            let tau = layer.decay * voicing.decay * vary(0.1, &rng) / 1000 * sampleRate
            let samples = renderLayer(layer.source, pitch: pitch, tau: tau, rng: &rng)
            let gain = layer.gain * voicing.gain * vary(0.12, &rng)
            if output.count < start + samples.count {
                output += [Float](repeating: 0, count: start + samples.count - output.count)
            }
            for (n, sample) in samples.enumerated() {
                output[start + n] += Float(sample * gain)
            }
        }

        let peak = output.lazy.map(abs).max() ?? 0
        if peak > 0.95 {
            for n in output.indices { output[n] *= 0.95 / peak }
        }
        return output
    }

    public static func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        return buffer
    }

    /// One enveloped layer, peak-normalized to 1. `tau` is the decay time constant in frames.
    private static func renderLayer<R: RandomNumberGenerator>(
        _ source: Layer.Source, pitch: Double, tau: Double, rng: inout R
    ) -> [Double] {
        let length = min(Int(tau * 7), Int(sampleRate))
        guard length > 0 else { return [] }
        let ceiling = sampleRate * 0.45
        var samples = [Double](repeating: 0, count: length)
        switch source {
        case .tone(let frequency):
            let step = 2 * Double.pi * min(frequency * pitch, ceiling) / sampleRate
            let phase = Double.random(in: 0..<(2 * .pi), using: &rng)
            for n in 0..<length { samples[n] = sin(step * Double(n) + phase) }
        case .noise(let center, let q):
            // Two passes of the same bandpass narrow the texture from a flat hiss into
            // something with more body — closer to plastic knocking than pure static.
            var filter1 = Biquad.bandpass(center: min(center * pitch, ceiling), q: q, sampleRate: sampleRate)
            var filter2 = Biquad.bandpass(center: min(center * pitch, ceiling), q: q, sampleRate: sampleRate)
            for n in 0..<length {
                samples[n] = filter2.process(filter1.process(Double.random(in: -1...1, using: &rng)))
            }
        }

        let attack = 0.0005 * sampleRate
        // A short, sharp "crack" riding on top of the smoother decay — real switch and
        // housing resonances lose energy fast at first, then ring out more slowly.
        let crackTau = tau / 5
        var peak = 0.0
        for n in 0..<length {
            let t = Double(n)
            let envelope = exp(-t / tau) * (1 + 0.55 * exp(-t / crackTau))
            samples[n] *= min(1, t / attack) * envelope
            peak = max(peak, abs(samples[n]))
        }
        guard peak > 0 else { return [] }

        // Gentle soft-clip saturation for a touch of analog warmth, re-normalized to the
        // same peak of 1 so callers' gain math is unaffected.
        let drive = 1.6
        let ceilingGain = tanh(drive)
        return samples.map { tanh($0 / peak * drive) / ceilingGain }
    }

    private static func vary<R: RandomNumberGenerator>(_ amount: Double, _ rng: inout R) -> Double {
        Double.random(in: (1 - amount)...(1 + amount), using: &rng)
    }
}

/// RBJ cookbook biquad filters.
struct Biquad {
    var b0, b1, b2, a1, a2: Double
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        (self.b0, self.b1, self.b2, self.a1, self.a2) = (b0, b1, b2, a1, a2)
    }

    /// Band-pass with a constant 0 dB peak gain.
    static func bandpass(center: Double, q: Double, sampleRate: Double) -> Biquad {
        let w0 = 2 * Double.pi * center / sampleRate
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        return Biquad(b0: alpha / a0, b1: 0, b2: -alpha / a0, a1: -2 * cos(w0) / a0, a2: (1 - alpha) / a0)
    }

    /// Boosts (positive `gainDB`) or cuts everything below `frequency`.
    static func lowShelf(frequency: Double, gainDB: Double, sampleRate: Double) -> Biquad {
        shelf(low: true, frequency: frequency, gainDB: gainDB, sampleRate: sampleRate)
    }

    /// Boosts (positive `gainDB`) or cuts everything above `frequency`.
    static func highShelf(frequency: Double, gainDB: Double, sampleRate: Double) -> Biquad {
        shelf(low: false, frequency: frequency, gainDB: gainDB, sampleRate: sampleRate)
    }

    private static func shelf(low: Bool, frequency: Double, gainDB: Double, sampleRate: Double) -> Biquad {
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let c = cos(w0)
        let k = (2 * a).squareRoot() * sin(w0)  // 2·√A·alpha, for a shelf slope of 1
        let sign: Double = low ? 1 : -1
        let a0 = (a + 1) + sign * (a - 1) * c + k
        return Biquad(b0: a * ((a + 1) - sign * (a - 1) * c + k) / a0,
                      b1: sign * 2 * a * ((a - 1) - sign * (a + 1) * c) / a0,
                      b2: a * ((a + 1) - sign * (a - 1) * c - k) / a0,
                      a1: -sign * 2 * ((a - 1) + sign * (a + 1) * c) / a0,
                      a2: ((a + 1) + sign * (a - 1) * c - k) / a0)
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        (x2, x1, y2, y1) = (x1, x, y1, y)
        return y
    }
}

/// Small, fast, seedable generator so renders are reproducible.
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
