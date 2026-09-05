import Foundation
import Darwin

/// Monotonic nanosecond clock. The wire protocol timestamps
/// (`play_at_ns`, `ping.t1`) are `mach_absolute_time` converted to
/// nanoseconds on both ends — never wall clock, which steps on NTP
/// adjustments and would jump the playout schedule.
public protocol MonotonicClock: Sendable {
    func nowNanos() -> UInt64
}

/// The real clock: `mach_absolute_time()` scaled by the machine's timebase.
/// On Apple silicon the timebase is 125/3, so the raw ticks are NOT
/// nanoseconds and the conversion is mandatory.
public struct MachClock: MonotonicClock {
    private let numer: UInt64
    private let denom: UInt64

    public init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        self.numer = UInt64(info.numer == 0 ? 1 : info.numer)
        self.denom = UInt64(info.denom == 0 ? 1 : info.denom)
    }

    public func nowNanos() -> UInt64 {
        Self.nanos(fromHostTime: mach_absolute_time(), numer: numer, denom: denom)
    }

    /// Convert a CoreAudio `AudioTimeStamp.mHostTime` (same units as
    /// `mach_absolute_time`) to nanoseconds.
    public func nanos(fromHostTime host: UInt64) -> UInt64 {
        Self.nanos(fromHostTime: host, numer: numer, denom: denom)
    }

    private static func nanos(fromHostTime host: UInt64, numer: UInt64, denom: UInt64) -> UInt64 {
        // Split to avoid overflowing 64 bits on long uptimes: at numer/denom
        // = 125/3 a raw multiply overflows after ~4.6 years of uptime.
        let whole = host / denom
        let rest = host % denom
        return whole &* numer &+ (rest &* numer) / denom
    }
}

/// Deterministic clock for tests and `--selftest`. Time only moves when the
/// caller advances it, so a ten-second control-loop experiment runs in
/// microseconds and never flakes on CI load.
public final class SimulatedClock: MonotonicClock, @unchecked Sendable {
    private var value: UInt64
    private let lock = NSLock()

    public init(startNanos: UInt64 = 1_000_000_000) {
        self.value = startNanos
    }

    public func nowNanos() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    public func advance(nanos: UInt64) {
        lock.lock(); defer { lock.unlock() }
        value &+= nanos
    }

    public func advance(seconds: Double) {
        advance(nanos: UInt64((seconds * 1_000_000_000).rounded()))
    }
}
