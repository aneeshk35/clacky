/// One component of a keystroke: a burst of filtered noise or a decaying tone.
public struct Layer: Sendable {
    public enum Source: Sendable {
        /// Band-passed white noise — plastic clacks and click-jacket snaps.
        case noise(center: Double, q: Double)
        /// Exponentially decaying sine — housing, plate and spring resonances.
        case tone(frequency: Double)
    }

    public var source: Source
    /// Milliseconds after the key event.
    public var delay: Double
    /// Decay time constant in milliseconds.
    public var decay: Double
    /// Peak amplitude, 0...1.
    public var gain: Double

    public static func noise(_ center: Double, q: Double, at delay: Double = 0, decay: Double, gain: Double) -> Layer {
        Layer(source: .noise(center: center, q: q), delay: delay, decay: decay, gain: gain)
    }

    public static func tone(_ frequency: Double, at delay: Double = 0, decay: Double, gain: Double) -> Layer {
        Layer(source: .tone(frequency: frequency), delay: delay, decay: decay, gain: gain)
    }
}

/// Recipe for how one kind of switch sounds on press and release.
public struct SwitchProfile: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let summary: String
    public let down: [Layer]
    public let up: [Layer]
    /// How much stabilizer rattle the big keys add, 0...1.
    public let rattle: Double

    public init(id: String, name: String, summary: String, down: [Layer], up: [Layer], rattle: Double) {
        self.id = id
        self.name = name
        self.summary = summary
        self.down = down
        self.up = up
        self.rattle = rattle
    }

    public static func named(_ id: String) -> SwitchProfile? {
        all.first { $0.id == id }
    }

    public static let all: [SwitchProfile] = []
}

/// How a key's size shapes its sound: bigger keys are lower, ring longer, and rattle.
struct Voicing {
    var pitch: Double
    var decay: Double
    var gain: Double
    var rattle: Double
}

extension KeyCategory {
    var voicing: Voicing {
        switch self {
        case .standard: return Voicing(pitch: 1, decay: 1, gain: 1, rattle: 0)
        case .modifier: return Voicing(pitch: 0.92, decay: 1.1, gain: 0.95, rattle: 0)
        case .enter, .backspace: return Voicing(pitch: 0.82, decay: 1.3, gain: 1.05, rattle: 0.6)
        case .space: return Voicing(pitch: 0.68, decay: 1.6, gain: 1.1, rattle: 1)
        }
    }
}
