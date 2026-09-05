import Foundation

/// NTP-style offset estimator between the sender's monotonic clock and ours.
///
/// `offsetNanos` is defined so that
/// ```
/// local_time = sender_time + offset
/// ```
/// which is exactly what the playout scheduler needs to turn a packet's
/// `play_at_ns` (sender domain) into a local DAC deadline.
///
/// Two feed modes:
///
///  * **Round trip** — the full four timestamps `t1` (sender send),
///    `t2` (our receive), `t3` (our send), `t4` (sender receive). This is the
///    classic NTP estimator, `θ = ((t2−t1) + (t3−t4)) / 2`, whose error is
///    half the path *asymmetry*, not half the RTT. The sender feeds us its
///    `t4` for the previous exchange in the next `ping` (`prev_t4`).
///  * **One way** — only `t1` and `t2` are known (a v1 sender that does not
///    send `prev_t4`). `t2 − t1` equals the offset plus the one-way delay,
///    so the minimum over the window is the offset plus the *minimum* one-way
///    delay: on a LAN a sub-millisecond, one-signed bias. Documented in the
///    README; it shifts playout, it does not destabilise it, because the
///    rate lock is driven by the buffer level and not by this number.
///
/// Both modes keep a sliding window (16 by default) and pick the sample with
/// the smallest delay metric — a packet that was not queued anywhere carries
/// the least-corrupted offset — then smooth the chosen offset with an EMA so
/// a single lucky/unlucky sample cannot step the schedule.
public struct ClockOffsetEstimator: Sendable {
    public enum Mode: Equatable, Sendable { case none, oneWay, roundTrip }

    private struct Sample {
        var offset: Int64
        var metric: Int64   // RTT, or raw one-way delay proxy
    }

    public let windowSize: Int
    public let smoothing: Double

    private var samples: [Sample] = []
    private var smoothed: Double?
    private(set) public var mode: Mode = .none

    public init(windowSize: Int = 16, smoothing: Double = 0.25) {
        precondition(windowSize > 0)
        precondition(smoothing > 0 && smoothing <= 1)
        self.windowSize = windowSize
        self.smoothing = smoothing
        self.samples.reserveCapacity(windowSize)
    }

    /// Offset in nanoseconds such that `local = sender + offset`, or nil
    /// before the first sample.
    public var offsetNanos: Int64? {
        guard let smoothed else { return nil }
        return Int64(smoothed.rounded())
    }

    /// Minimum round-trip time in the current window (round-trip mode only).
    public var roundTripNanos: Int64? {
        guard mode == .roundTrip, let best = bestSample() else { return nil }
        return best.metric
    }

    public var sampleCount: Int { samples.count }

    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        smoothed = nil
        mode = .none
    }

    public mutating func addRoundTrip(t1: UInt64, t2: UInt64, t3: UInt64, t4: UInt64) {
        if mode != .roundTrip { samples.removeAll(keepingCapacity: true) }
        mode = .roundTrip
        let d21 = signedDelta(t2, t1)
        let d34 = signedDelta(t3, t4)
        let rtt = signedDelta(t4, t1) - signedDelta(t3, t2)
        // A negative RTT means the peer's timestamps are nonsense (or the
        // pong was matched to the wrong ping); ignore rather than poison
        // the window.
        guard rtt >= 0 else { return }
        push(Sample(offset: (d21 + d34) / 2, metric: rtt))
    }

    public mutating func addOneWay(t1: UInt64, t2: UInt64) {
        if mode != .oneWay {
            // A round-trip window is strictly better; never downgrade.
            if mode == .roundTrip { return }
            samples.removeAll(keepingCapacity: true)
        }
        mode = .oneWay
        let d = signedDelta(t2, t1)
        push(Sample(offset: d, metric: d))
    }

    private mutating func push(_ sample: Sample) {
        samples.append(sample)
        if samples.count > windowSize { samples.removeFirst(samples.count - windowSize) }
        guard let best = bestSample() else { return }
        if let current = smoothed {
            smoothed = current + smoothing * (Double(best.offset) - current)
        } else {
            smoothed = Double(best.offset)
        }
    }

    private func bestSample() -> Sample? {
        samples.min(by: { $0.metric < $1.metric })
    }

    /// `a − b` for two monotonic timestamps whose absolute values may be
    /// arbitrarily large (uptime based) but whose difference fits in Int64.
    private func signedDelta(_ a: UInt64, _ b: UInt64) -> Int64 {
        Int64(bitPattern: a &- b)
    }
}
