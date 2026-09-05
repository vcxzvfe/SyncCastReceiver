import Foundation

/// Water-level PI controller that slaves our DAC clock to the sender's ring.
///
/// # Plant
/// The jitter ring fill (`writeEnd − readCursor`, in frames) is the phase
/// detector. The sender fills it at its own clock rate, we drain it at
/// `deviceRate / ratio`, so
/// ```
/// d(fill)/dt = R·(1 + m) − R/ratio ≈ R·(m + u),   u = ratio − 1
/// ```
/// with `m` the fractional clock mismatch (typically ±100 ppm between two
/// consumer crystals). The plant is a pure integrator of gain `R`.
///
/// # Controller
/// `u = −(Kp·e + ∫Ki·e dt)` with `e = filteredFill − target`. Closing the
/// loop gives `ë + R·Kp·ė + R·Ki·e = 0`, i.e. a second-order response with
/// ```
/// ωn = √(R·Ki)          2ζωn = R·Kp
/// ```
/// The defaults place `ωn = 0.2 rad/s`, `ζ = 1.6` — overdamped, within a few
/// ppm of the right trim after about five seconds, so a fresh ±100 ppm
/// crystal error is tracked out well inside ten seconds while the correction
/// itself only ever moves at a few hundred ppm per second (an inaudible
/// pitch sweep).
///
/// The bandwidth is deliberately no higher than that: `Kp` multiplies the
/// measurement noise straight into the pitch, and the level measurement is
/// only as clean as the network. At `Kp = 1.3e-5` a residual ±3 frames of
/// level noise is ±40 ppm of trim — inaudible. Ten times the bandwidth would
/// track a crystal in half a second and wobble the pitch by the full ±200 ppm
/// clamp on any jittery link, which is the wrong trade for a music path.
///
/// # Guards
///  * `|u|` is clamped to ±200 ppm (spec) — 0.35 cent, inaudible, and far
///    more than any real crystal pair needs.
///  * `|Δu|` is slew-limited per second so a step in the level (a burst of
///    late packets) cannot jerk the pitch.
///  * The measured fill goes through a **peak-hold with slow decay** and then
///    an EMA (τ = 1.5 s) before it reaches the controller. Peak-hold is the right filter
///    here because the noise is one-sided: the sender's `play_at_ns` stamps
///    are perfectly regular, so `writeEnd` can only ever be LATE, never
///    early. Taking the running maximum recovers the true level as soon as
///    any packet in the window arrives promptly, with no bias — unlike an
///    average, which would sit permanently below the truth on a jittery
///    link. The decay (a few ms of level per second, two orders above any
///    real crystal drift) lets a genuine drop follow through.
///  * Beyond ±20 ms of level error the loop reports `.reanchorNeeded`: no
///    ±200 ppm trim can walk that back in reasonable time, so the caller
///    jumps the read cursor instead (an audible splice, but only on a real
///    fault: startup, sleep/wake, a network stall).
public struct ClockFollowLoop: Sendable {

    public struct Tuning: Sendable {
        /// Proportional gain, per frame of fill error.
        public var kp: Double
        /// Integral gain, per frame of fill error per second.
        public var ki: Double
        /// Hard clamp on |ratio − 1|, in ppm.
        public var maxRatioPpm: Double
        /// Clamp on |d(ratio)/dt|, in ppm per second.
        public var slewPpmPerSecond: Double
        /// Time constant of the fill EMA, seconds.
        public var fillFilterSeconds: Double
        /// How fast the peak-hold stage is allowed to follow a falling level,
        /// in frames per second.
        public var peakDecayFramesPerSecond: Double
        /// Level error beyond which the caller must hard re-anchor, in ms.
        public var reanchorErrorMs: Double
        /// Nominal device rate, used for the ms ↔ frames conversions.
        public var sampleRate: Double

        public init(sampleRate: Double = WireFormat.sampleRate,
                    naturalFrequency: Double = 0.2,
                    dampingRatio: Double = 1.6,
                    maxRatioPpm: Double = 200,
                    slewPpmPerSecond: Double = 400,
                    fillFilterSeconds: Double = 1.5,
                    peakDecayFramesPerSecond: Double = 20,
                    reanchorErrorMs: Double = 20) {
            precondition(sampleRate > 0)
            self.sampleRate = sampleRate
            self.ki = naturalFrequency * naturalFrequency / sampleRate
            self.kp = 2 * dampingRatio * naturalFrequency / sampleRate
            self.maxRatioPpm = maxRatioPpm
            self.slewPpmPerSecond = slewPpmPerSecond
            self.fillFilterSeconds = fillFilterSeconds
            self.peakDecayFramesPerSecond = peakDecayFramesPerSecond
            self.reanchorErrorMs = reanchorErrorMs
        }
    }

    public enum Outcome: Equatable, Sendable { case tracking, reanchorNeeded }

    public let tuning: Tuning
    /// Current `outFrames / inFrames` trim handed to the resampler.
    public private(set) var ratio: Double = 1.0
    /// EMA-smoothed ring fill, in frames (NaN before the first update).
    public private(set) var filteredFillFrames: Double = .nan
    /// Peak-hold stage feeding the EMA.
    public private(set) var peakFillFrames: Double = .nan
    private var integrator: Double = 0

    public init(tuning: Tuning = Tuning()) { self.tuning = tuning }

    /// Drop all state. Call after a hard re-anchor or a stream restart —
    /// the integrator's wind-up describes a level that no longer exists.
    public mutating func reset(fillFrames: Double? = nil) {
        integrator = 0
        ratio = 1.0
        filteredFillFrames = fillFrames ?? .nan
        peakFillFrames = fillFrames ?? .nan
    }

    /// Advance the controller by `dt` seconds.
    ///
    /// - Parameters:
    ///   - fillFrames: raw `writeEnd − readCursor` measured this tick.
    ///   - targetFrames: setpoint (the negotiated `target_ms` in frames).
    ///   - dt: seconds since the previous update.
    @discardableResult
    public mutating func update(fillFrames: Double, targetFrames: Double, dt: Double) -> Outcome {
        guard dt > 0 else { return .tracking }
        if peakFillFrames.isNaN {
            peakFillFrames = fillFrames
        } else {
            peakFillFrames = max(fillFrames, peakFillFrames - tuning.peakDecayFramesPerSecond * dt)
        }
        if filteredFillFrames.isNaN {
            filteredFillFrames = peakFillFrames
        } else {
            let alpha = 1 - exp(-dt / max(tuning.fillFilterSeconds, 1e-6))
            filteredFillFrames += alpha * (peakFillFrames - filteredFillFrames)
        }
        let error = filteredFillFrames - targetFrames
        let maxRatio = tuning.maxRatioPpm * 1e-6

        let reanchorFrames = tuning.reanchorErrorMs / 1000.0 * tuning.sampleRate
        // A raw fill at or below zero means the read cursor has caught the
        // write head outright: that is real starvation, and waiting for the
        // smoothed level to agree would just prolong the silence.
        if abs(error) > reanchorFrames || fillFrames <= 0 { return .reanchorNeeded }

        integrator += tuning.ki * error * dt
        integrator = min(max(integrator, -maxRatio), maxRatio)   // anti-windup
        var u = -(tuning.kp * error + integrator)
        u = min(max(u, -maxRatio), maxRatio)

        let slew = tuning.slewPpmPerSecond * 1e-6 * dt
        let prevU = ratio - 1.0
        let du = min(max(u - prevU, -slew), slew)
        ratio = 1.0 + (prevU + du)
        return .tracking
    }
}
