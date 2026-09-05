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
/// The defaults place `ωn = 0.3 rad/s`, `ζ = 1.2` — overdamped, poles at
/// −0.74 and −0.12 rad/s, so a ±100 ppm crystal error is tracked to within a
/// few ppm inside ten seconds and a cold start settles fully in under a
/// minute, while the correction itself only ever moves at a few hundred ppm
/// per second (an inaudible pitch sweep).
///
/// The bandwidth is deliberately no higher than that: `Kp` multiplies the
/// measurement noise straight into the pitch, and the level measurement is
/// only as clean as the network. At `Kp = 1.5e-5` a residual ±3 frames of
/// level noise is ±40 ppm of trim — inaudible. Ten times the bandwidth would
/// track a crystal in half a second and wobble the pitch by the full ±200 ppm
/// clamp on any jittery link, which is the wrong trade for a music path.
///
/// # Guards
///  * `|u|` is clamped to ±200 ppm (spec) — 0.35 cent, inaudible, and far
///    more than any real crystal pair needs.
///  * `|Δu|` is slew-limited per second so a step in the level (a burst of
///    late packets) cannot jerk the pitch.
///  * The measured fill goes through an EMA (τ = 1.5 s) before it reaches
///    the controller. The raw number carries two sawtooths — the write head
///    steps by a whole 240-frame packet 200 times a second, and the read
///    cursor drops by a whole IO buffer every callback — plus whatever the
///    network adds. Averaging is the right filter for that: the mean of a
///    sawtooth is the true level. (A peak-hold, which is tempting because
///    delivery jitter is one-sided, latches the TOP of those sawtooths
///    instead and biases the level by the best part of 20 ms.)
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
        /// Level error beyond which the caller must hard re-anchor, in ms.
        public var reanchorErrorMs: Double
        /// Nominal device rate, used for the ms ↔ frames conversions.
        public var sampleRate: Double

        public init(sampleRate: Double = WireFormat.sampleRate,
                    naturalFrequency: Double = 0.3,
                    dampingRatio: Double = 1.2,
                    maxRatioPpm: Double = 200,
                    slewPpmPerSecond: Double = 400,
                    fillFilterSeconds: Double = 1.5,
                    reanchorErrorMs: Double = 20) {
            precondition(sampleRate > 0)
            self.sampleRate = sampleRate
            self.ki = naturalFrequency * naturalFrequency / sampleRate
            self.kp = 2 * dampingRatio * naturalFrequency / sampleRate
            self.maxRatioPpm = maxRatioPpm
            self.slewPpmPerSecond = slewPpmPerSecond
            self.fillFilterSeconds = fillFilterSeconds
            self.reanchorErrorMs = reanchorErrorMs
        }
    }

    public enum Outcome: Equatable, Sendable { case tracking, reanchorNeeded }

    public let tuning: Tuning
    /// Current `outFrames / inFrames` trim handed to the resampler.
    public private(set) var ratio: Double = 1.0
    /// EMA-smoothed ring fill, in frames (NaN before the first update).
    public private(set) var filteredFillFrames: Double = .nan
    private var integrator: Double = 0

    public init(tuning: Tuning = Tuning()) { self.tuning = tuning }

    /// Drop all state. Call after a hard re-anchor or a stream restart —
    /// the integrator's wind-up describes a level that no longer exists.
    public mutating func reset(fillFrames: Double? = nil) {
        integrator = 0
        ratio = 1.0
        filteredFillFrames = fillFrames ?? .nan
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
        if filteredFillFrames.isNaN {
            filteredFillFrames = fillFrames
        } else {
            let alpha = 1 - exp(-dt / max(tuning.fillFilterSeconds, 1e-6))
            filteredFillFrames += alpha * (fillFrames - filteredFillFrames)
        }
        let error = filteredFillFrames - targetFrames
        let maxRatio = tuning.maxRatioPpm * 1e-6

        let reanchorFrames = tuning.reanchorErrorMs / 1000.0 * tuning.sampleRate
        // A raw fill at or below zero means the read cursor has caught the
        // write head outright: that is real starvation, and waiting for the
        // smoothed level to agree would just prolong the silence.
        if abs(error) > reanchorFrames || fillFrames <= 0 { return .reanchorNeeded }

        // Conditional integration (anti-windup). The actuator saturates at
        // ±200 ppm for anything past ~0.3 ms of level error, and a plain
        // clamped integrator would spend that whole excursion winding into
        // the stop — then take just as long to unwind once the error crossed
        // zero, which is exactly the slow, overshooting recovery this loop
        // must not have. So: only integrate when doing so does not push an
        // already-saturated output further into its stop.
        let candidate = min(max(integrator + tuning.ki * error * dt, -maxRatio), maxRatio)
        let uCandidate = -(tuning.kp * error + candidate)
        let uHeld = -(tuning.kp * error + integrator)
        if abs(uCandidate) <= maxRatio || abs(uCandidate) < abs(uHeld) {
            integrator = candidate
        }
        var u = -(tuning.kp * error + integrator)
        u = min(max(u, -maxRatio), maxRatio)

        let slew = tuning.slewPpmPerSecond * 1e-6 * dt
        let prevU = ratio - 1.0
        let du = min(max(u - prevU, -slew), slew)
        ratio = 1.0 + (prevU + du)
        return .tracking
    }
}
