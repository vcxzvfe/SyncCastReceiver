import Foundation

/// Whether an observed device level should be pushed back to what the sender
/// asked for.
///
/// # Why the receiver has to fight for the level at all
///
/// The output device belongs to the whole machine, not to this daemon.
/// Anything else on the second Mac can move it: a remote-desktop session
/// muting the Mac on connect, another app's volume HUD, a keyboard on a
/// shared desk. When that happens the sender's master no longer describes
/// what the listener hears, and nothing tells the sender — its own slider is
/// still where the user left it.
///
/// So the daemon watches `kAudioDevicePropertyVolumeScalar` and
/// `kAudioDevicePropertyMute` and re-applies the sender's last `gain` /
/// `muted` when something else changes them.
///
/// # Why the decision is a pure function
///
/// The dangerous case is the feedback loop: our own write fires the same
/// property listener, which would re-apply, which would fire again. The guard
/// is a suppression window opened at the moment we write. Getting that
/// interaction wrong on real hardware costs an afternoon and a puzzled
/// listener, so the decision lives here, away from CoreAudio, where every
/// combination is a two-line test.
public enum VolumeReassertionDecision: Equatable, Sendable {
    /// The device already carries the requested level.
    case matches
    /// It differs, but we wrote it ourselves moments ago — this is the echo
    /// of our own write, not somebody else's change.
    case suppressed
    /// Something else moved it. Write the requested value back.
    case reassert
}

public enum VolumeReassertionPolicy {

    /// Scalar difference below which two levels are the same level.
    ///
    /// Drivers round what they store, so a written 0.5 can read back as
    /// 0.4999; a tolerance below that noise floor would re-assert forever.
    /// Roughly 0.4 % of full scale, far finer than a listener can hear.
    public static let defaultScalarTolerance: Float = 0.004

    /// How long after our own write the property listener's report is
    /// treated as our own echo. CoreAudio delivers the notification within a
    /// few milliseconds; this is generous by two orders of magnitude and
    /// still far below the interval at which a person turns a knob.
    public static let defaultSuppressionNanos: UInt64 = 300_000_000

    /// When to re-check after our own write. Deliberately just past the
    /// suppression window: an external change that lands DURING the window is
    /// suppressed and generates no further notification, so without this
    /// sweep it would stick.
    public static let verifyDelayNanos: UInt64 = 350_000_000

    /// Coalescing delay between a property notification and acting on it, so
    /// a device that reports a slider drag as twenty changes produces one
    /// write. Keeps the whole react-and-restore path inside ~200 ms.
    public static let coalesceDelayNanos: UInt64 = 60_000_000

    public static func decideScalar(
        observed: Float,
        desired: Float,
        tolerance: Float = defaultScalarTolerance,
        nowNanos: UInt64,
        suppressedUntilNanos: UInt64?
    ) -> VolumeReassertionDecision {
        // A desired level we do not have (no sender, or a device with no
        // hardware volume) is nothing to assert.
        guard desired.isFinite else { return .matches }
        // An unreadable device value cannot be compared, but it also cannot
        // be trusted to be right — write ours back, outside the window.
        guard observed.isFinite else {
            return isSuppressed(nowNanos: nowNanos, until: suppressedUntilNanos)
                ? .suppressed : .reassert
        }
        if abs(observed - desired) <= tolerance { return .matches }
        return isSuppressed(nowNanos: nowNanos, until: suppressedUntilNanos)
            ? .suppressed : .reassert
    }

    public static func decideMute(
        observed: Bool,
        desired: Bool,
        nowNanos: UInt64,
        suppressedUntilNanos: UInt64?
    ) -> VolumeReassertionDecision {
        if observed == desired { return .matches }
        return isSuppressed(nowNanos: nowNanos, until: suppressedUntilNanos)
            ? .suppressed : .reassert
    }

    /// Monotonic-clock comparison, written with wrapping arithmetic so it is
    /// correct for a `mach_absolute_time`-derived value near the wrap point
    /// and for a window that has already expired.
    static func isSuppressed(nowNanos: UInt64, until: UInt64?) -> Bool {
        guard let until else { return false }
        return nowNanos < until
    }

    /// The instant a suppression window opened now should close.
    public static func suppressionDeadline(
        nowNanos: UInt64,
        windowNanos: UInt64 = defaultSuppressionNanos
    ) -> UInt64 {
        nowNanos &+ windowNanos
    }
}
