import Foundation

/// Turns the sender's linear master amplitude into something a CoreAudio
/// output device understands.
///
/// A HAL `kAudioDevicePropertyVolumeScalar` is a *perceptual* 0…1 knob, not
/// linear amplitude. Apple's built-in curve is linear in decibels,
/// `dB(s) = minDb · (1 − s)`, over a device-reported range (the built-in
/// speakers report −63.5…0 dB). Writing a linear amplitude straight into the
/// scalar would apply the taper twice and everything would be far too quiet
/// — the classic mistake with virtual devices.
///
/// So: amplitude → dB → scalar, using the device's own range when it reports
/// one, and preferring the device's `VolumeScalarToDecibels` translation
/// property when it has one (some drivers are not dB-linear).
public struct VolumeLaw: Equatable, Sendable {
    /// Attenuation at scalar 0, in dB. Always negative.
    public let minDecibels: Float
    /// Level at scalar 1, in dB. Normally 0.
    public let maxDecibels: Float

    /// Apple's measured built-in-speaker range, used when a device reports
    /// no dB metadata at all.
    public static let fallback = VolumeLaw(minDecibels: -63.5, maxDecibels: 0)

    public init(minDecibels: Float, maxDecibels: Float = 0) {
        // A non-attenuating or inverted range would make the mapping
        // degenerate (division by zero below), so clamp a driver's claim
        // into something usable instead of trusting it.
        let hi = maxDecibels
        let lo = min(minDecibels, hi - 1)
        self.minDecibels = lo
        self.maxDecibels = hi
    }

    public var spanDecibels: Float { maxDecibels - minDecibels }

    public func decibels(forScalar scalar: Float) -> Float {
        let s = clamp01(scalar)
        return minDecibels + spanDecibels * s
    }

    public func scalar(forDecibels db: Float) -> Float {
        clamp01((db - minDecibels) / spanDecibels)
    }

    public func amplitude(forScalar scalar: Float) -> Float {
        let s = clamp01(scalar)
        // Scalar 0 is silence, not −63.5 dB: macOS's own slider at the
        // bottom is silent, and a "zero" volume that is still faintly
        // audible reads as a bug.
        guard s > 0 else { return 0 }
        return pow(10, decibels(forScalar: s) / 20)
    }

    /// The mapping the `gain` control message needs: linear amplitude in
    /// 0…1 → the scalar to write to the device.
    public func scalar(forAmplitude amplitude: Float) -> Float {
        guard amplitude > 0 else { return 0 }
        let a = min(amplitude, 1)
        return scalar(forDecibels: 20 * log10(a))
    }

    private func clamp01(_ v: Float) -> Float { min(max(v, 0), 1) }
}

/// How the level for this leg is actually carried.
public enum VolumeBackend: String, Equatable, Sendable {
    /// Device exposes a writable `kAudioDevicePropertyVolumeScalar`.
    case hardware
    /// Nothing controllable — attenuate the samples we render instead.
    case software
}

/// What to apply for one `gain` message.
public struct VolumePlan: Equatable, Sendable {
    public let backend: VolumeBackend
    /// `.hardware`: the scalar to write.
    public let hardwareScalar: Float?
    /// `.software`: the linear amplitude for the render path.
    public let softwareAmplitude: Float?
    public let muted: Bool

    public init(backend: VolumeBackend, hardwareScalar: Float?, softwareAmplitude: Float?, muted: Bool) {
        self.backend = backend
        self.hardwareScalar = hardwareScalar
        self.softwareAmplitude = softwareAmplitude
        self.muted = muted
    }

    /// Decide what to do with a `gain` message.
    ///
    /// - Parameters:
    ///   - linear: the sender's master amplitude, 0…1 (already through the
    ///     system's own dB law on that side).
    ///   - muted: the sender's mute flag.
    ///   - law: the target device's scalar↔dB law, or nil if it has no
    ///     hardware volume control.
    public static func plan(linear: Double, muted: Bool, law: VolumeLaw?) -> VolumePlan {
        let amplitude = Float(min(max(linear, 0), 1))
        if let law {
            return VolumePlan(backend: .hardware,
                              hardwareScalar: law.scalar(forAmplitude: amplitude),
                              softwareAmplitude: nil,
                              muted: muted)
        }
        return VolumePlan(backend: .software,
                          hardwareScalar: nil,
                          softwareAmplitude: amplitude,
                          muted: muted)
    }
}
