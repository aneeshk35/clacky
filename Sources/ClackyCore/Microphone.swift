import CoreAudio
import Foundation

/// Notices when another app is using the microphone (a call, a recording, dictation), so the
/// clicks can pause instead of being heard by everyone on the call. Needs macOS 14 or later.
public final class MicrophoneWatcher {
    /// A process recording from a microphone.
    public struct Recorder: Equatable, Sendable {
        public let pid: pid_t
        public let bundleID: String

        public init(pid: pid_t, bundleID: String) {
            self.pid = pid
            self.bundleID = bundleID
        }
    }

    /// Whether this Mac can tell which apps are recording.
    public static var isSupported: Bool {
        if #available(macOS 14, *) { return true }
        return false
    }

    /// Called on the main queue when the app using the microphone changes (nil once nobody is).
    public var onChange: ((Recorder?) -> Void)?
    public private(set) var recorder: Recorder?

    private var systemListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var deviceListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var timer: Timer?
    private var pendingUpdate: DispatchWorkItem?

    public init() {}

    deinit { stop() }

    public func start() {
        guard Self.isSupported, timer == nil else { return }
        // A microphone turning on shows up as its device starting to run; apps appearing and devices
        // being plugged in are checked too. Looking costs ~20 ms, so it isn't done constantly: the
        // slow timer only catches what the events miss (say, a headset whose speaker was already running).
        guard #available(macOS 14, *) else { return }
        for selector in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDevices] {
            var address = Self.address(selector)
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.updateSoon() }
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
            systemListeners.append((address, listener))
        }
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in self?.update() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        update()
    }

    public func stop() {
        for (address, listener) in systemListeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
        systemListeners = []
        for id in Array(deviceListeners.keys) { unwatch(id) }
        timer?.invalidate()
        timer = nil
        pendingUpdate?.cancel()
        if recorder != nil {
            recorder = nil
            onChange?(nil)
        }
    }

    /// The process that counts as using the microphone: not this app, and not the system's
    /// always-on listeners ("Hey Siri", Sound Recognition), which never stop.
    public static func activeRecorder(among recorders: [Recorder], ownPID: pid_t) -> Recorder? {
        recorders.first { recorder in
            recorder.pid != ownPID && !alwaysListening.contains { recorder.bundleID.hasPrefix($0) }
        }
    }

    static let alwaysListening = ["com.apple.CoreSpeech", "com.apple.corespeechd", "com.apple.accessibility.heard"]

    /// Several events tend to arrive together; look once they've settled.
    private func updateSoon() {
        pendingUpdate?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.update() }
        pendingUpdate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func update() {
        watchInputDevices()
        let now = Self.activeRecorder(among: Self.recorders(), ownPID: getpid())
        if now != recorder {
            recorder = now
            onChange?(now)
        }
    }

    /// Every process recording right now.
    private static func recorders() -> [Recorder] {
        guard #available(macOS 14, *) else { return [] }
        return AudioDevices.objects(kAudioHardwarePropertyProcessObjectList).compactMap { process in
            var running: UInt32 = 0
            guard AudioDevices.scalar(process, kAudioProcessPropertyIsRunningInput, &running) == noErr, running != 0
            else { return nil }
            var pid: pid_t = 0
            _ = AudioDevices.scalar(process, kAudioProcessPropertyPID, &pid)
            return Recorder(pid: pid, bundleID: AudioDevices.string(process, kAudioProcessPropertyBundleID) ?? "")
        }
    }

    private func watchInputDevices() {
        let inputs = Set(AudioDevices.objects(kAudioHardwarePropertyDevices)
            .filter { AudioDevices.hasStreams($0, kAudioObjectPropertyScopeInput) })
        for id in deviceListeners.keys where !inputs.contains(id) { unwatch(id) }
        for id in inputs where deviceListeners[id] == nil {
            var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.updateSoon() }
            if AudioObjectAddPropertyListenerBlock(id, &address, .main, listener) == noErr {
                deviceListeners[id] = listener
            }
        }
    }

    private func unwatch(_ id: AudioObjectID) {
        guard let listener = deviceListeners.removeValue(forKey: id) else { return }
        var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        AudioObjectRemovePropertyListenerBlock(id, &address, .main, listener)
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}
