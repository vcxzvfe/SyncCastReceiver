import Foundation

/// The rule that turns the sender's requested `target_ms` into the one this
/// receiver will actually run at.
///
/// The sender picks the target from a slider; it has no idea what the link
/// between the two machines looks like. This side measures that link
/// (`PacketArrivalTracker`), and a target below the measured arrival spread
/// cannot work: the buffer would be asked to hold less audio than the network
/// routinely withholds, so it would run dry, splice, and click — which is
/// exactly what a field run at 90 ms over Wi-Fi did.
///
/// So the requested value is a FLOOR that the receiver may raise, never a
/// ceiling. The floor it raises to is `p95 spread + two render blocks`:
///  * the p95 spread is what the link demonstrably does (see
///    `PacketArrivalTracker` for why a percentile and not a maximum), and
///  * two render blocks is the granularity this side plays audio at — one
///    block to cover the callback that is already in flight, and one so the
///    following callback still has something to read.
///
/// The result is reported back in `hello_ack.buffer_ms` and in `stats`, so
/// the sender's UI can show what is really happening rather than what it
/// asked for.
public enum TargetLatencyPolicy {

    /// Render blocks of headroom added on top of the measured spread.
    public static let blocksOfHeadroom: Int = 2

    /// Never raise the target above this. A link that needs more than a third
    /// of a second is broken in a way more buffer will not fix, and the delay
    /// would be worse than the dropouts.
    public static let maximumMilliseconds: Double = 300

    /// The target this receiver should run at.
    ///
    /// - Parameters:
    ///   - requestedMs: what the sender asked for.
    ///   - p95JitterMs: measured arrival spread, or nil before the window has
    ///     filled — in which case the request is honoured as-is.
    ///   - blockFrames: the output device's render quantum.
    ///   - sampleRate: the output device's rate.
    public static func effectiveMilliseconds(requestedMs: Double,
                                             p95JitterMs: Double?,
                                             maxJitterMs: Double? = nil,
                                             blockFrames: Int,
                                             sampleRate: Double) -> Double {
        guard requestedMs.isFinite else { return 0 }
        guard let p95JitterMs, p95JitterMs.isFinite, p95JitterMs >= 0,
              sampleRate > 0, blockFrames > 0 else {
            return requestedMs
        }
        let blockMs = Double(blockFrames) / sampleRate * 1000
        // The p95 is the link's habit; the maximum is its worst recent stall.
        // A Wi-Fi link that pauses for ~100 ms every few seconds has a small
        // p95 and a large maximum, and it is the maximum that decides whether
        // a stall's worth of packets arrives late and is thrown away. Cover
        // whichever is larger.
        var spread = p95JitterMs
        if let maxJitterMs, maxJitterMs.isFinite, maxJitterMs > spread {
            spread = maxJitterMs
        }
        let floorMs = spread + Double(blocksOfHeadroom) * blockMs
        return min(maximumMilliseconds, max(requestedMs, floorMs))
    }
}
