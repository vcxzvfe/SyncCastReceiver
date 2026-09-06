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
/// The defaults place `ωn = 0.15 rad/s`, `ζ = 1.2` — overdamped, so a ±100 ppm
/// crystal error is tracked to within a few ppm inside twenty-five seconds
/// and the correction itself only ever moves at a few hundred ppm per second
/// (an inaudible pitch sweep).
///
/// The bandwidth is deliberately no higher than that: `Kp` multiplies the
/// measurement noise straight into the pitch, and the level measurement is
/// only as clean as the network. A field run over Wi-Fi showed the trim
/// swinging across 120 ppm within seconds — the loop chasing arrival jitter
/// rather than a crystal — which is why the controller now runs on a 3 s EMA
/// at half the previous natural frequency. Both halve the noise that reaches
/// the pitch; the price is a settling time about twice as long, which nobody
/// can hear and which matters only in the self-test's warm-up budget.
/// (The 3 s filter costs phase margin at the old 0.3 rad/s — about 20° — so
/// the two changes belong together, not separately.)
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
///  * A hard re-anchor is a SPLICE — an audible click — so it is reported
///    only for a fault that no trim can fix, and only once that fault has
///    proved itself:
///      - `.error`: the smoothed level has been more than `reanchorErrorMs`
///        away from the setpoint CONTINUOUSLY for `reanchorHoldSeconds`.
///        A ±200 ppm trim moves the level by 0.2 ms per second, so a 20 ms
///        error really is unrecoverable — but a single burst of late packets
///        also shows a 20 ms error for one tick, and jumping on that is how
///        a link on Wi-Fi ends up clicking several times a second.
///      - `.starved`: the ring ran dry for `starvedBlockLimit` consecutive
///        render blocks AND the smoothed level agrees the buffer is short by
///        at least `starvationConfirmMs`. One empty render is a delivery gap:
///        the correct response is zero-fill plus an `underrun` count, and the
///        audio that is a millisecond away then plays normally. Only a
///        deficit the smoothed level can see is a real one.
///
/// Both thresholds are tuning fields rather than constants, because the right
/// value depends on the link: a wired receiver can be far stricter than one
/// behind two Wi-Fi hops.
public struct ClockFollowLoop: Sendable {

    public struct Tuning: Sendable {
        /// Proportional gain, per frame of fill error.
        public var kp: Double
        /// Integral gain, per frame of fill error per second.
        public var ki: Double
        /// Hard clamp on |ratio − 1|, in ppm.
        public var maxRatioPpm: Double
        /// Level error ignored by the PI (ms each side of the setpoint).
        public var errorDeadbandMs: Double
        /// Clamp on |d(ratio)/dt|, in ppm per second.
        public var slewPpmPerSecond: Double
        /// Time constant of the REPORTED fill EMA, seconds. Fast enough that
        /// a user watching `stats` sees the buffer move.
        public var fillFilterSeconds: Double
        /// Time constant of the EMA the CONTROLLER sees, seconds.
        ///
        /// Longer than the reported one on purpose: `kp` multiplies whatever
        /// noise survives the filter straight into the pitch, and on a Wi-Fi
        /// link the level carries tens of milliseconds of arrival jitter. A
        /// filter this slow costs phase margin, which is why the default
        /// natural frequency below is half what it was when the loop ran on
        /// the fast EMA.
        public var controlFilterSeconds: Double
        /// Level error beyond which the caller must hard re-anchor, in ms.
        public var reanchorErrorMs: Double
        /// How long that error must persist before the re-anchor fires.
        public var reanchorHoldSeconds: Double
        /// Consecutive empty render blocks that count as real starvation.
        public var starvedBlockLimit: Int
        /// How far below the setpoint the SMOOTHED level must sit before a
        /// run of empty blocks is believed, in ms.
        public var starvationConfirmMs: Double
        /// Whether a starvation splice may fire on a render block that
        /// brought no new audio at all.
        ///
        /// False, and the reason is the second half of the same argument as
        /// `starvedBlockLimit`: if nothing has arrived since the previous
        /// block, delivery has stopped, and re-anchoring lands the cursor on
        /// the same empty ring while throwing away loop state that was
        /// tracking the sender's clock correctly. A pause — the programme
        /// stopping, a Wi-Fi scan — is exactly that shape.
        ///
        /// It is a knob only so the self-test can turn the guard OFF and
        /// prove its scenarios still have teeth without it.
        public var spliceWithoutNewAudio: Bool
        /// How long after an anchor the level is allowed to settle before
        /// the loop adopts it as the setpoint it holds. Long enough for the
        /// control filter (`controlFilterSeconds`) to have forgotten the
        /// reset value; the trim sits at unity meanwhile.
        public var settleSeconds: Double
        /// Nominal device rate, used for the ms ↔ frames conversions.
        public var sampleRate: Double

        public init(sampleRate: Double = WireFormat.sampleRate,
                    naturalFrequency: Double = 0.15,
                    dampingRatio: Double = 1.2,
                    maxRatioPpm: Double = 200,
                    errorDeadbandMs: Double = 0,
                    slewPpmPerSecond: Double = 400,
                    fillFilterSeconds: Double = 1.5,
                    controlFilterSeconds: Double = 3.0,
                    reanchorErrorMs: Double = 20,
                    reanchorHoldSeconds: Double = 0.5,
                    starvedBlockLimit: Int = 2,
                    starvationConfirmMs: Double = 10,
                    spliceWithoutNewAudio: Bool = false,
                    settleSeconds: Double = 3.0) {
            precondition(sampleRate > 0)
            self.sampleRate = sampleRate
            self.settleSeconds = max(0, settleSeconds)
            self.ki = naturalFrequency * naturalFrequency / sampleRate
            self.kp = 2 * dampingRatio * naturalFrequency / sampleRate
            self.maxRatioPpm = maxRatioPpm
            self.errorDeadbandMs = errorDeadbandMs
            self.slewPpmPerSecond = slewPpmPerSecond
            self.fillFilterSeconds = fillFilterSeconds
            self.controlFilterSeconds = controlFilterSeconds
            self.reanchorErrorMs = reanchorErrorMs
            self.reanchorHoldSeconds = reanchorHoldSeconds
            self.starvedBlockLimit = max(1, starvedBlockLimit)
            self.starvationConfirmMs = starvationConfirmMs
            self.spliceWithoutNewAudio = spliceWithoutNewAudio
        }
    }

    /// Why the caller was told to splice. Reported in `stats` so the reason a
    /// link clicks can be read off a log instead of guessed at.
    public enum ReanchorReason: String, Equatable, Sendable {
        /// The ring ran dry for several consecutive render blocks and the
        /// smoothed level agrees the buffer is short.
        case starved
        /// The smoothed level sat past `reanchorErrorMs` for
        /// `reanchorHoldSeconds`.
        case error
        /// The playout target itself moved; the level has to jump because a
        /// ±200 ppm trim would take minutes to walk it there.
        case target
    }

    public enum Outcome: Equatable, Sendable {
        case tracking
        case reanchorNeeded(ClockFollowLoop.ReanchorReason)
    }

    public let tuning: Tuning
    /// Current `outFrames / inFrames` trim handed to the resampler.
    public private(set) var ratio: Double = 1.0
    /// EMA-smoothed ring fill, in frames (NaN before the first update). This
    /// is the fast one, and it is what `stats` reports.
    public private(set) var filteredFillFrames: Double = .nan
    /// The slower EMA the PI loop and the re-anchor thresholds run on.
    public private(set) var controlFillFrames: Double = .nan
    /// Render blocks in a row that found the ring empty.
    public private(set) var consecutiveStarvedBlocks: Int = 0
    /// How long the smoothed error has been past `reanchorErrorMs`, seconds.
    public private(set) var errorHoldSeconds: Double = 0
    private var integrator: Double = 0

    public init(tuning: Tuning = Tuning()) { self.tuning = tuning }

    /// Drop all state. Call after a hard re-anchor or a stream restart —
    /// the integrator's wind-up describes a level that no longer exists.
    public mutating func reset(fillFrames: Double? = nil) {
        integrator = 0
        ratio = 1.0
        filteredFillFrames = fillFrames ?? .nan
        controlFillFrames = fillFrames ?? .nan
        consecutiveStarvedBlocks = 0
        errorHoldSeconds = 0
    }

    /// Smoothed level error against `targetFrames`, in milliseconds. For the
    /// log line that explains a re-anchor.
    public func errorMilliseconds(targetFrames: Double) -> Double {
        guard !controlFillFrames.isNaN else { return 0 }
        return (controlFillFrames - targetFrames) / tuning.sampleRate * 1000
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
            controlFillFrames = fillFrames
        } else {
            let alpha = 1 - exp(-dt / max(tuning.fillFilterSeconds, 1e-6))
            filteredFillFrames += alpha * (fillFrames - filteredFillFrames)
            let beta = 1 - exp(-dt / max(tuning.controlFilterSeconds, 1e-6))
            controlFillFrames += beta * (fillFrames - controlFillFrames)
        }
        // Deadband: a Wi-Fi link swings the level by ±10–20 ms every few
        // seconds no matter what the DAC rate does. Chasing that with a
        // ±200 ppm actuator only winds the integrator into a stop; the loop's
        // job is the slow clock drift, so ignore level error inside the band.
        let rawError = controlFillFrames - targetFrames
        let deadbandFrames = tuning.errorDeadbandMs / 1000.0 * tuning.sampleRate
        let error: Double
        if abs(rawError) <= deadbandFrames {
            error = 0
        } else {
            error = rawError > 0 ? rawError - deadbandFrames : rawError + deadbandFrames
        }
        let maxRatio = tuning.maxRatioPpm * 1e-6

        let reanchorFrames = tuning.reanchorErrorMs / 1000.0 * tuning.sampleRate
        let confirmFrames = tuning.starvationConfirmMs / 1000.0 * tuning.sampleRate
        // A block is starved when the ring holds less than this callback is
        // about to consume — `dt · rate` IS the block, so the loop can tell
        // without being told. (Testing `fill <= 0` instead misses the common
        // case entirely: a ring holding 200 frames when the callback wants
        // 512 renders silence for most of the block and reports an underrun,
        // yet its fill never went negative.)
        //
        // A starved block is not a fault on its own. It renders silence and
        // counts an underrun, and the audio that was a millisecond away then
        // plays normally. A burst-delivered link empties the ring at the end
        // of most burst gaps; splicing on that is what makes it click.
        let blockFrames = dt * tuning.sampleRate
        if fillFrames < blockFrames {
            consecutiveStarvedBlocks += 1
        } else {
            consecutiveStarvedBlocks = 0
        }
        if abs(error) > reanchorFrames {
            errorHoldSeconds += dt
        } else {
            errorHoldSeconds = 0
        }
        if consecutiveStarvedBlocks >= tuning.starvedBlockLimit, error < -confirmFrames {
            return .reanchorNeeded(.starved)
        }
        if errorHoldSeconds >= tuning.reanchorHoldSeconds {
            return .reanchorNeeded(.error)
        }

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
