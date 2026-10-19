import AVFoundation
import AudioToolbox
import ClackyObjC
import CoreAudio

/// Plays keystroke buffers with low latency through a pool of player voices.
public final class SoundEngine {
    public let engine = AVAudioEngine()
    public var bank: SoundBank?

    /// 0 keeps every key centered; 1 spreads keys left to right like the physical keyboard.
    public var stereoWidth: Float = 0.5 {
        didSet { applyPans() }
    }

    public var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    /// False while the output device isn't taking audio (stalled, waking up, or erroring).
    public private(set) var isOutputAvailable = true
    /// Called on the main queue when `isOutputAvailable` changes.
    public var onOutputAvailabilityChange: ((Bool) -> Void)?

    /// The output to play through, by UID. nil follows the Mac's sound output, falling back to
    /// another output when that one can't play (a monitor without speakers, say).
    public var outputChoice: String? {
        didSet { if outputChoice != oldValue { restart() } }
    }
    /// The output sound is going to right now (nil while nothing can play).
    public private(set) var activeOutput: OutputDevice?
    /// Set when following the Mac's output didn't work: the output that couldn't play.
    public private(set) var unplayableOutput: OutputDevice?
    /// Called on the main queue whenever `activeOutput` or `unplayableOutput` may have changed.
    public var onOutputChange: (() -> Void)?

    /// Voices are grouped by fixed stereo position and never re-panned per key: the mixer ramps
    /// pan changes over ~20 ms, which would drag a click across the stereo field from the last key.
    private static let positions = 7
    private static let voicesPerPosition = 3
    private var voices: [[AVAudioPlayerNode]] = []
    /// That ramp only advances while audio flows through the voice, so after a pan change each
    /// voice gets 50 ms of silence to finish ramping before its next click.
    private let rampSilence: AVAudioPCMBuffer = {
        let buffer = AVAudioPCMBuffer(pcmFormat: Synthesizer.format, frameCapacity: 2400)!
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData![0].update(repeating: 0, count: Int(buffer.frameLength))
        return buffer
    }()
    private var nextVoice = [Int](repeating: 0, count: SoundEngine.positions)
    private var configurationObserver: NSObjectProtocol?
    /// Output sample time right after the last start, to tell when audio actually begins flowing.
    private var sampleTimeAtStart: AVAudioFramePosition?
    private var startGeneration = 0
    private var retry: DispatchWorkItem?
    private var retryDelay: TimeInterval = 0.5

    /// Pass `offlineFormat` to render into buffers instead of the speakers (used by the checks).
    public init(offlineFormat: AVAudioFormat? = nil) throws {
        if let offlineFormat {
            try engine.enableManualRenderingMode(.offline, format: offlineFormat, maximumFrameCount: 4096)
        }
        voices = (0..<Self.positions).map { _ in
            (0..<Self.voicesPerPosition).map { _ in
                let voice = AVAudioPlayerNode()
                engine.attach(voice)
                engine.connect(voice, to: engine.mainMixerNode, format: Synthesizer.format)
                return voice
            }
        }
        // Plugging in headphones or switching outputs stops the engine; bring it back.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.startWhenPossible()
        }
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    /// Starts on the first output that will play, trying them in `outputCandidates` order.
    public func start() throws {
        guard !engine.isRunning else { return }
        guard !engine.isInManualRenderingMode else {
            try startEngine()
            return
        }
        let candidates = Self.outputCandidates(choice: outputChoice, defaultID: AudioDevices.defaultOutputID,
                                               devices: AudioDevices.outputs())
        var failure: Error = NSError(domain: "Clacky", code: 1,
                                     userInfo: [NSLocalizedDescriptionKey: "This Mac has no sound output."])
        for (index, device) in candidates.enumerated() {
            guard use(device) else { continue }
            do {
                try startEngine()
                activeOutput = device
                unplayableOutput = index > 0 ? candidates[0] : nil
                return
            } catch {
                failure = error
                engine.stop()
            }
        }
        activeOutput = nil
        unplayableOutput = candidates.first
        throw failure
    }

    /// Starts now if it can; otherwise keeps trying in the background. At login, after sleep and
    /// while outputs are being switched, the audio hardware can take a while to come up.
    public func startWhenPossible() {
        retry?.cancel()
        retry = nil
        do {
            try start()
            retryDelay = 0.5
        } catch {
            setOutputAvailable(false)
            let work = DispatchWorkItem { [weak self] in self?.startWhenPossible() }
            retry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: work)
            retryDelay = min(retryDelay * 2, 5)
        }
        onOutputChange?()
    }

    /// Stops and starts again, re-picking the output.
    public func restart() {
        guard !engine.isInManualRenderingMode else { return }
        engine.stop()
        retryDelay = 0.5
        startWhenPossible()
    }

    /// Call when outputs are plugged in or removed, or the Mac's sound output changes.
    public func outputsChanged() {
        let candidates = Self.outputCandidates(choice: outputChoice, defaultID: AudioDevices.defaultOutputID,
                                               devices: AudioDevices.outputs())
        // Already on the output we'd pick first? Leave it alone rather than interrupt the sound.
        if engine.isRunning, unplayableOutput == nil, candidates.first == activeOutput { return }
        restart()
    }

    /// Outputs to try, in order. A chosen output that's plugged in is used on its own. Otherwise:
    /// the Mac's sound output, then the built-in speakers, then any other output that plays out
    /// loud. Software-only outputs (Zoom, Krisp) are never fallbacks, since nobody would hear them.
    public static func outputCandidates(choice: String?, defaultID: AudioDeviceID?,
                                        devices: [OutputDevice]) -> [OutputDevice] {
        if let choice, let chosen = devices.first(where: { $0.uid == choice }) { return [chosen] }
        var ordered: [OutputDevice] = []
        if let system = devices.first(where: { $0.id == defaultID }) { ordered.append(system) }
        ordered += devices.filter { $0.isBuiltIn && !ordered.contains($0) }
        ordered += devices.filter { !$0.isVirtual && !ordered.contains($0) }
        return ordered
    }

    private func startEngine() throws {
        requestSmallIOBuffer()
        engine.prepare()
        applyPans(force: true)
        try engine.start()
        sampleTimeAtStart = currentSampleTime
        startGeneration += 1
        startVoicesWhenOutputRuns(generation: startGeneration, attempt: 0)
    }

    /// Points the engine's output at `device`. Only while stopped.
    private func use(_ device: OutputDevice) -> Bool {
        guard let unit = engine.outputNode.audioUnit else { return false }
        var id = device.id
        return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                    &id, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
    }

    public func play(keyCode: Int, phase: KeyPhase) {
        guard engine.isRunning,
              let buffer = bank?.buffer(for: KeyLayout.category(for: keyCode), phase: phase, keyCode: keyCode)
        else { return }
        let position = Int(((KeyLayout.pan(for: keyCode) + 1) / 2 * Float(Self.positions - 1)).rounded())
        let voice = voices[position][nextVoice[position]]
        nextVoice[position] = (nextVoice[position] + 1) % Self.voicesPerPosition
        let played = catchingExceptions {
            // When keys pile up, the oldest sound at that spot is cut off rather than delaying the new one.
            voice.scheduleBuffer(buffer, at: nil, options: .interrupts)
            if !voice.isPlaying && outputIsRunning { voice.play() }
        }
        if !played {
            // Something went wrong with the device; keep trying to get the voices going again.
            startGeneration += 1
            startVoicesWhenOutputRuns(generation: startGeneration, attempt: 0)
        }
    }

    private var currentSampleTime: AVAudioFramePosition? {
        guard let time = engine.outputNode.lastRenderTime, time.isSampleTimeValid else { return nil }
        return time.sampleTime
    }

    /// Whether the output device has pulled audio since the last start. Starting a player before
    /// it has blocks the calling thread for ~5 s and then raises, so nothing calls `play()` until then.
    private var outputIsRunning: Bool {
        if engine.isInManualRenderingMode { return true }
        guard engine.isRunning, let now = currentSampleTime else { return false }
        return now != sampleTimeAtStart
    }

    private func startVoicesWhenOutputRuns(generation: Int, attempt: Int) {
        guard generation == startGeneration, engine.isRunning else { return }
        if outputIsRunning {
            let started = voices.joined().allSatisfy { voice in
                voice.isPlaying || catchingExceptions { voice.play() }
            }
            if started {
                setOutputAvailable(true)
                return
            }
        }
        if attempt == 60 { setOutputAvailable(false) }  // ~3 s and still nothing coming out
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt < 60 ? 0.05 : 0.5)) { [weak self] in
            self?.startVoicesWhenOutputRuns(generation: generation, attempt: attempt + 1)
        }
    }

    /// Runs AVFoundation calls that report device trouble by raising. Returns false instead of crashing.
    @discardableResult
    private func catchingExceptions(_ body: () -> Void) -> Bool {
        var error: NSError?
        if ClackyCatchException(body, &error) { return true }
        setOutputAvailable(false)
        return false
    }

    private func setOutputAvailable(_ available: Bool) {
        guard available != isOutputAvailable else { return }
        isOutputAvailable = available
        onOutputAvailabilityChange?(available)
    }

    /// The mixer drops pans set before the engine is prepared, and the node skips re-setting a pan
    /// equal to the one it remembers — so after preparing, `force` nudges each pan to make it stick.
    private func applyPans(force: Bool = false) {
        for (position, group) in voices.enumerated() {
            let pan = (Float(position) / Float(Self.positions - 1) * 2 - 1) * stereoWidth
            for voice in group {
                if force { voice.pan = pan == 0 ? 0.5 : 0 }
                voice.pan = pan
                // While stopped there's nothing to ramp; start() applies pans and queues this itself.
                if force || engine.isRunning {
                    catchingExceptions { voice.scheduleBuffer(rampSilence, at: nil) }
                }
            }
        }
    }

    /// Asks the output device for ~5 ms buffers instead of the ~11 ms default, so clicks land with the key.
    private func requestSmallIOBuffer() {
        guard !engine.isInManualRenderingMode, let unit = engine.outputNode.audioUnit else { return }
        var frames: UInt32 = 256
        AudioUnitSetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0,
                             &frames, UInt32(MemoryLayout<UInt32>.size))
    }
}
