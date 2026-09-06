import Foundation

/// How far apart packets arrive relative to the schedule they were stamped
/// with — the number that says how big the jitter buffer actually has to be.
///
/// # The measurement
///
/// For every accepted packet we keep `d = arrival − play_at_ns`, a raw
/// subtraction across the two machines' clocks. The absolute value of `d` is
/// meaningless (it carries the whole clock offset), but its SPREAD over a
/// window is exactly what a jitter buffer has to absorb: the offset is a
/// constant inside the window and cancels.
///
/// The reported figure is `p95(d) − min(d)`. `min(d)` is the packet that took
/// the shortest path — the closest thing to "no queueing anywhere" this side
/// can observe — so the difference is how much later than the best case the
/// 95th-percentile packet turned up.
///
/// # What it deliberately does not do
///
/// A percentile is blind to rare events by construction: a stall that hits
/// one packet in two hundred never reaches p95. That is the right trade for
/// choosing a steady-state target (the alternative, a maximum, would size the
/// buffer for the worst hiccup of the day and add its latency to every
/// second), but it does mean p95 is a FLOOR for the target and not a
/// guarantee. Underruns are what report the tail.
///
/// The two clocks also drift against each other inside the window: 100 ppm
/// over 2.5 s is 250 µs of the spread, which is far below anything worth
/// acting on and is ignored.
///
/// # Threading
///
/// `record` is called from the UDP receive thread, `p95SpreadMilliseconds`
/// from the daemon's 1 Hz stats tick. Neither is the render thread, so a
/// plain lock is fine here — nothing real-time can ever be blocked on it.
public final class PacketArrivalTracker: @unchecked Sendable {

    /// 512 packets is about 2.5 s of a 200 packet/s stream: long enough for a
    /// percentile to mean something, short enough to follow a link that got
    /// worse a moment ago.
    public static let windowSize: Int = 512

    private let lock = NSLock()
    private var deltas: [Int64]
    /// Gaps between consecutive arrivals (ns), independent of any schedule —
    /// pure receive-path pacing. Same ring geometry as `deltas`.
    private var gaps: [Int64]
    private var gapCount: Int = 0
    private var gapNext: Int = 0
    private var lastArrival: UInt64 = 0
    private var count: Int = 0
    private var next: Int = 0

    public init(windowSize: Int = PacketArrivalTracker.windowSize) {
        let size = max(8, windowSize)
        self.deltas = [Int64](repeating: 0, count: size)
        self.gaps = [Int64](repeating: 0, count: size)
    }

    /// One accepted packet. Both timestamps are monotonic nanoseconds, from
    /// two different machines; only the difference's spread is used.
    public func record(playAtNanos: UInt64, arrivalNanos: UInt64) {
        let delta = Int64(bitPattern: arrivalNanos &- playAtNanos)
        lock.lock()
        deltas[next] = delta
        next = (next + 1) % deltas.count
        if count < deltas.count { count += 1 }
        if lastArrival != 0 {
            gaps[gapNext] = Int64(bitPattern: arrivalNanos &- lastArrival)
            gapNext = (gapNext + 1) % gaps.count
            if gapCount < gaps.count { gapCount += 1 }
        }
        lastArrival = arrivalNanos
        lock.unlock()
    }

    public func reset() {
        lock.lock()
        count = 0
        next = 0
        gapCount = 0
        gapNext = 0
        lastArrival = 0
        lock.unlock()
    }

    /// p95 and maximum gap between consecutive packet arrivals, ms. With a
    /// 5 ms packet cadence a clean link sits near 5 / 10; a receive path that
    /// stalls shows up here as a max in the tens of ms even when the network
    /// itself is smooth.
    public var arrivalGapMilliseconds: (p95: Double, maximum: Double)? {
        lock.lock()
        let filled = gapCount
        guard filled >= 8 else { lock.unlock(); return nil }
        var window = Array(gaps[0..<filled])
        lock.unlock()
        window.sort()
        let index = min(filled - 1, Int((Double(filled - 1) * 0.95).rounded()))
        return (Double(window[index]) / 1_000_000, Double(window[filled - 1]) / 1_000_000)
    }

    /// `p95 − min` of the window, in milliseconds, or nil until the window
    /// holds enough packets (a tenth of it) to be worth quoting.
    /// How early packets are arriving relative to their own play time, in ms:
    /// the smallest slack and the 5th percentile over the window. A negative
    /// minimum means at least one packet in the window arrived after it was
    /// due — the receiver's `late` counter, but with a magnitude attached, so
    /// "late by 3 ms" and "late by 300 ms" stop looking the same.
    public var slackMilliseconds: (minimum: Double, p05: Double)? {
        lock.lock()
        let filled = count
        guard filled >= 8 else { lock.unlock(); return nil }
        var window = Array(deltas[0..<filled])
        lock.unlock()
        window.sort()   // ascending arrival − playAt == descending slack
        let p05Index = min(filled - 1, Int((Double(filled - 1) * 0.95).rounded()))
        let minimum = Double(-window[filled - 1]) / 1_000_000
        let p05 = Double(-window[p05Index]) / 1_000_000
        return (minimum, p05)
    }

    /// Full spread of the window (latest arrival relative to schedule minus
    /// earliest), ms. This is what a periodic ~100 ms Wi-Fi stall looks like:
    /// it never moves the p95, and it is exactly what the buffer has to cover.
    public var maxSpreadMilliseconds: Double? {
        lock.lock()
        let filled = count
        guard filled >= max(8, deltas.count / 10) else { lock.unlock(); return nil }
        var window = Array(deltas[0..<filled])
        lock.unlock()
        window.sort()
        return Double(max(0, window[filled - 1] - window[0])) / 1_000_000
    }

    public var p95SpreadMilliseconds: Double? {
        lock.lock()
        let filled = count
        guard filled >= max(8, deltas.count / 10) else {
            lock.unlock()
            return nil
        }
        var window = Array(deltas[0..<filled])
        lock.unlock()
        window.sort()
        let index = min(filled - 1, Int((Double(filled - 1) * 0.95).rounded()))
        let spread = window[index] - window[0]
        return Double(max(0, spread)) / 1_000_000
    }
}
