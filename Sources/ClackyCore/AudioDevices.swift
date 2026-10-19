import CoreAudio
import Foundation

/// A sound output the Mac knows about (speakers, headphones, a monitor, a virtual device…).
public struct OutputDevice: Equatable, Sendable {
    public let id: AudioDeviceID
    /// Stable across restarts and replugging, unlike `id`; this is what gets saved.
    public let uid: String
    public let name: String
    public let transport: UInt32

    public init(id: AudioDeviceID, uid: String, name: String, transport: UInt32) {
        self.id = id
        self.uid = uid
        self.name = name
        self.transport = transport
    }

    public var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }

    /// Software-only outputs (Zoom, Krisp, aggregates) accept sound but don't play it out loud.
    public var isVirtual: Bool {
        [kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate,
         kAudioDeviceTransportTypeAutoAggregate].contains(transport)
    }
}

public enum AudioDevices {
    /// Every device that can play sound.
    public static func outputs() -> [OutputDevice] {
        objects(kAudioHardwarePropertyDevices).compactMap { id in
            guard hasStreams(id, kAudioObjectPropertyScopeOutput), let uid = string(id, kAudioDevicePropertyDeviceUID)
            else { return nil }
            var transport: UInt32 = 0
            _ = scalar(id, kAudioDevicePropertyTransportType, &transport)
            return OutputDevice(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? "Unknown output",
                                transport: transport)
        }
    }

    /// The Mac's current sound output (System Settings → Sound → Output).
    public static var defaultOutputID: AudioDeviceID? {
        var id: AudioDeviceID = 0
        let status = scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &id)
        return status == noErr && id != 0 ? id : nil
    }

    /// Calls `handler` on the main queue whenever outputs are plugged in or removed, or the Mac's
    /// sound output changes. Lasts for the life of the process.
    public static func observeChanges(_ handler: @escaping () -> Void) {
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in
                handler()
            }
        }
    }

    /// A list of audio objects the system keeps (devices, processes…).
    static func objects(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// Whether the device has inputs (`kAudioObjectPropertyScopeInput`) or outputs.
    static func hasStreams(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    static func scalar<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> OSStatus {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
