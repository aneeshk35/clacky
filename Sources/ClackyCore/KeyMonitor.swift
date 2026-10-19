import CoreGraphics
import Foundation

/// Hears every key press system-wide through a listen-only event tap. It never sees or changes
/// what's typed beyond key codes, and macOS blocks it entirely while a password field has focus.
/// Requires Input Monitoring access (System Settings → Privacy & Security → Input Monitoring).
///
/// Reports physical presses only: holding a key gives one `.down` and one `.up`, never the
/// stream of auto-repeat events macOS sends while it's held.
public final class KeyMonitor {
    public typealias Handler = (_ keyCode: Int, _ phase: KeyPhase) -> Void

    public var onKey: Handler?
    public var isRunning: Bool { tap != nil }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var presses = KeyPressFilter()

    public init() {}

    public static var hasPermission: Bool { CGPreflightListenEventAccess() }

    /// Shows the system prompt the first time and adds the app to the Input Monitoring list.
    @discardableResult
    public static func requestPermission() -> Bool { CGRequestListenEventAccess() }

    /// Returns false while Input Monitoring access hasn't been granted.
    @discardableResult
    public func start() -> Bool {
        guard tap == nil else { return true }
        guard Self.hasPermission else { return false }

        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged]
            .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                if let context {
                    Unmanaged<KeyMonitor>.fromOpaque(context).takeUnretainedValue().handle(type, event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        runLoopSource = source
        presses.reset()
        return true
    }

    public func stop() {
        guard let tap, let runLoopSource else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CFMachPortInvalidate(tap)
        self.tap = nil
        self.runLoopSource = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .keyDown:
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            press(keyCode(of: event), isRepeat: isRepeat)
        case .keyUp:
            release(keyCode(of: event))
        case .flagsChanged:
            // Modifiers don't send keyDown/keyUp; work out the direction from their flag bit.
            let code = keyCode(of: event)
            if code == 57 {
                onKey?(code, .down)  // caps lock reports a single event per press
            } else if let bit = Self.modifierBits[code] {
                if event.flags.rawValue & bit != 0 {
                    press(code, isRepeat: false)
                } else {
                    release(code)
                }
            }
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Releases may have been missed while the tap was off; don't leave keys stuck as held.
            presses.reset()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        default:
            break
        }
    }

    private func press(_ code: Int, isRepeat: Bool) {
        if presses.press(code, isRepeat: isRepeat) { onKey?(code, .down) }
    }

    private func release(_ code: Int) {
        if presses.release(code) { onKey?(code, .up) }
    }

    private func keyCode(of event: CGEvent) -> Int {
        Int(event.getIntegerValueField(.keyboardEventKeycode))
    }

    /// Device-specific modifier bits (NX_DEVICE*KEYMASK), so left and right keys are told apart.
    private static let modifierBits: [Int: UInt64] = [
        59: 0x01, 62: 0x2000,  // control
        56: 0x02, 60: 0x04,    // shift
        55: 0x08, 54: 0x10,    // command
        58: 0x20, 61: 0x40,    // option
        63: 0x80_0000,         // fn
    ]
}

/// Turns raw key events into physical presses: one down and one up per press, however long the
/// key is held and whether or not macOS marks its auto-repeat events as repeats.
public struct KeyPressFilter {
    private var held: Set<Int> = []

    public init() {}

    /// True when this is a new press that should sound.
    public mutating func press(_ keyCode: Int, isRepeat: Bool) -> Bool {
        !isRepeat && held.insert(keyCode).inserted
    }

    /// True when this releases a key we heard go down. Keys already held before monitoring
    /// started stay quiet when let go.
    public mutating func release(_ keyCode: Int) -> Bool {
        held.remove(keyCode) != nil
    }

    /// Forget held keys, for when releases may have been missed.
    public mutating func reset() {
        held.removeAll()
    }
}
