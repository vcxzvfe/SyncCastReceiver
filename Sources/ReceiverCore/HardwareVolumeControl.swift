import Foundation
import CoreAudio

/// Hardware level control for one output device.
///
/// Only devices that expose a settable `kAudioDevicePropertyVolumeScalar` on
/// output element 0 get hardware control. Aggregate and multi-output devices,
/// and most DisplayPort/HDMI outputs, expose nothing — those fall back to
/// software gain in the render path, which is why `hello_ack` reports
/// `hw_volume` so the sender can say so in its UI.
public final class HardwareVolumeControl: @unchecked Sendable {

    public let deviceID: AudioDeviceID
    public let hasVolume: Bool
    public let hasMute: Bool
    /// The device's own scalar↔dB law, nil when it has no volume control.
    public let law: VolumeLaw?
    /// True when the driver answers `VolumeDecibelsToScalar`, i.e. we can ask
    /// it to do the conversion instead of assuming the dB-linear curve.
    public let hasDecibelTranslation: Bool

    private static let mainElement = kAudioObjectPropertyElementMain

    public init(deviceID: AudioDeviceID) {
        self.deviceID = deviceID
        let volumeSettable = Self.isSettable(deviceID, kAudioDevicePropertyVolumeScalar)
        self.hasVolume = volumeSettable
        self.hasMute = Self.isSettable(deviceID, kAudioDevicePropertyMute)
        if volumeSettable {
            self.law = Self.readLaw(deviceID) ?? .fallback
            self.hasDecibelTranslation = Self.hasProperty(deviceID, kAudioDevicePropertyVolumeDecibelsToScalar)
        } else {
            self.law = nil
            self.hasDecibelTranslation = false
        }
    }

    /// Convert a linear amplitude (the `gain.linear` field) to the scalar to
    /// write. Prefers the driver's own translation so a device whose curve is
    /// not dB-linear still lands on the right level.
    public func scalar(forAmplitude amplitude: Float) -> Float {
        guard let law else { return 0 }
        guard amplitude > 0 else { return 0 }
        let db = 20 * log10(min(amplitude, 1))
        if hasDecibelTranslation, let translated = translate(kAudioDevicePropertyVolumeDecibelsToScalar, db) {
            return min(max(translated, 0), 1)
        }
        return law.scalar(forDecibels: db)
    }

    @discardableResult
    public func setScalar(_ scalar: Float) -> OSStatus {
        var value = min(max(scalar, 0), 1)
        var address = Self.address(kAudioDevicePropertyVolumeScalar)
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil,
                                          UInt32(MemoryLayout<Float>.size), &value)
    }

    public func currentScalar() -> Float? {
        var address = Self.address(kAudioDevicePropertyVolumeScalar)
        var value: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    @discardableResult
    public func setMuted(_ muted: Bool) -> OSStatus {
        guard hasMute else { return kAudioHardwareUnknownPropertyError }
        var value: UInt32 = muted ? 1 : 0
        var address = Self.address(kAudioDevicePropertyMute)
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil,
                                          UInt32(MemoryLayout<UInt32>.size), &value)
    }

    // MARK: - property plumbing

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeOutput,
                                   mElement: mainElement)
    }

    private static func hasProperty(_ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> Bool {
        var addr = address(selector)
        return AudioObjectHasProperty(deviceID, &addr)
    }

    private static func isSettable(_ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> Bool {
        var addr = address(selector)
        guard AudioObjectHasProperty(deviceID, &addr) else { return false }
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(deviceID, &addr, &settable) == noErr else { return false }
        return settable.boolValue
    }

    private static func readLaw(_ deviceID: AudioDeviceID) -> VolumeLaw? {
        var addr = address(kAudioDevicePropertyVolumeRangeDecibels)
        guard AudioObjectHasProperty(deviceID, &addr) else { return nil }
        var range = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &range) == noErr else { return nil }
        guard range.mMaximum > range.mMinimum else { return nil }
        return VolumeLaw(minDecibels: Float(range.mMinimum), maxDecibels: Float(range.mMaximum))
    }

    /// CoreAudio's translation properties are "get" calls whose input value
    /// is passed in the same buffer that receives the result.
    private func translate(_ selector: AudioObjectPropertySelector, _ input: Float) -> Float? {
        var address = Self.address(selector)
        var value = input
        var size = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}
