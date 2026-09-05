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
/// The defaults place `ωn = 0.8 rad/s`, `ζ = 1.2` — overdamped, settling in
/// about 4 s, so a fresh ±100 ppm crystal error is tracked out well inside
/// ten seconds while the correction itself only ever moves at a few hundred
/// ppm per second (an inaudible pitch sweep).
///
/// # Guards
///  * `|u|` is clamped to ±200 ppm (spec) — 0.35 cent, inaudible, and far
///    more than any real crystal pair needs.
///  * `|Δu|` is slew-limited per second so a step in the level (a burst of
///    late packets) cannot jerk the pitch.
///  * The measured fill is EMA-smoothed (τ = 0.25 s): raw fill steps by a
///    whole 240-frame packet every 5 ms and carries the network's jitter,
///    and a stiff loop reading it raw would modulate pitch at packet rate.
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
                    naturalFrequency: Double = 0.8,
                    dampingRatio: Double = 1.2,
                    maxRatioPpm: Double = 200,
                    slewPpmPerSecond: Double = 400,
                    fillFilterSeconds: Double = 0.25,
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
        if abs(error) > reanchorFrames { return .reanchorNeeded }

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
