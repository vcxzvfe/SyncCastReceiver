import Foundation
import CoreAudio

/// Watches one output device's volume and mute properties and reports when
/// they move.
///
/// The CoreAudio half of `VolumeReassertionPolicy`: this only observes and
/// notifies, so the decision — and the loop-prevention that goes with it —
/// stays in the pure code where it is tested.
///
/// Notifications arrive on the caller's queue, which is the daemon queue, so
/// the handler may touch daemon state directly. Nothing here runs on the
/// render thread.
public final class DeviceVolumeObserver: @unchecked Sendable {

    public enum Property: Equatable, Sendable {
        case volume
        case mute
    }

    public let deviceID: AudioDeviceID

    private let queue: DispatchQueue
    private let onChange: @Sendable (Property) -> Void
    /// The registered blocks, kept because removal requires the SAME block
    /// object that was added — a freshly made closure will not match and the
    /// listener would leak past the device's lifetime.
    private var registrations: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var running = false

    public init(deviceID: AudioDeviceID,
                queue: DispatchQueue,
                onChange: @escaping @Sendable (Property) -> Void) {
        self.deviceID = deviceID
        self.queue = queue
        self.onChange = onChange
    }

    deinit { stopLocked() }

    /// Register both listeners. Safe to call twice; the second is a no-op.
    public func start() {
        guard !running else { return }
        running = true
        add(kAudioDevicePropertyVolumeScalar, .volume)
        add(kAudioDevicePropertyMute, .mute)
    }

    public func stop() { stopLocked() }

    private func stopLocked() {
        guard running else { return }
        running = false
        for (address, block) in registrations {
            var copy = address
            AudioObjectRemovePropertyListenerBlock(deviceID, &copy, queue, block)
        }
        registrations.removeAll()
    }

    private func add(_ selector: AudioObjectPropertySelector, _ property: Property) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(deviceID, &address) else { return }
        let handler = onChange
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler(property) }
        guard AudioObjectAddPropertyListenerBlock(deviceID, &address, queue, block) == noErr else {
            return
        }
        registrations.append((address, block))
    }

    /// Whether anything is actually being watched. False on a device that
    /// exposes neither property (an aggregate, most DisplayPort outputs), in
    /// which case the level lives in the render path's software gain and
    /// nothing external can move it.
    public var isObserving: Bool { !registrations.isEmpty }
}

extension HardwareVolumeControl {
    /// Current mute flag, or nil when the device has none or it cannot be
    /// read. Needed by the re-assertion sweep, which has to compare against
    /// what the device says rather than what we last wrote.
    public func currentMuted() -> Bool? {
        guard hasMute else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value != 0
    }
}
