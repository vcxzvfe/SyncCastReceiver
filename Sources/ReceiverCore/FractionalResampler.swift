import Foundation

/// Near-unity, continuously variable fractional resampler (4-tap cubic
/// Hermite / Catmull-Rom), the same structure SyncCast's local AirPlay bridge
/// uses for its clock-following stage.
///
/// The ratio the caller passes is `outFrames / inFrames` and stays within a
/// couple hundred ppm of 1.0 (the PI loop clamps it). At those corrections a
/// cubic interpolator is inaudible — a steady 100 ppm trim is a 0.17-cent
/// pitch shift, far below the ~5-10 cent JND — while avoiding both the HF
/// droop of linear interpolation and the clicks of sample drop/duplicate.
///
/// The 4-tap history and the fractional read phase persist across calls, so
/// feeding one block at a time yields a continuous stream. `reset()` is for
/// genuine stream discontinuities only; a steady-state ratio change must NOT
/// reset (it would click).
public final class FractionalResampler: @unchecked Sendable {
    public let channelCount: Int
    private var h0: [Float]
    private var h1: [Float]
    private var h2: [Float]
    private var h3: [Float]
    /// Fractional position inside the current `[h1, h2)` input interval.
    private var phase: Double

    public init(channelCount: Int) {
        precondition(channelCount > 0)
        self.channelCount = channelCount
        self.h0 = [Float](repeating: 0, count: channelCount)
        self.h1 = [Float](repeating: 0, count: channelCount)
        self.h2 = [Float](repeating: 0, count: channelCount)
        self.h3 = [Float](repeating: 0, count: channelCount)
        self.phase = 0
    }

    public func reset() {
        for ch in 0..<channelCount { h0[ch] = 0; h1[ch] = 0; h2[ch] = 0; h3[ch] = 0 }
        phase = 0
    }

    /// Resample one block of non-interleaved Float32.
    ///
    /// - Returns: frames written to each output channel. Production stops at
    ///   `outCapacity`, so the caller must size the staging buffer for the
    ///   worst case at the clamped ratio.
    public func process(
        inputs: UnsafePointer<UnsafeMutablePointer<Float>>,
        inFrames: Int,
        ratio: Double,
        outputs: UnsafePointer<UnsafeMutablePointer<Float>>,
        outCapacity: Int
    ) -> Int {
        guard inFrames > 0, ratio > 0, outCapacity > 0 else { return 0 }
        // `step` = input frames advanced per output frame. ratio < 1 (fewer
        // outputs than inputs) ⇒ step > 1 ⇒ phase crosses 1.0 sooner.
        let step = 1.0 / ratio
        var phase = self.phase
        var outCount = 0
        let ch = channelCount
        for i in 0..<inFrames {
            for c in 0..<ch {
                h0[c] = h1[c]; h1[c] = h2[c]; h2[c] = h3[c]; h3[c] = inputs[c][i]
            }
            while phase < 1.0 {
                if outCount >= outCapacity { break }
                let x = Float(phase)
                for c in 0..<ch {
                    let p0 = h0[c], p1 = h1[c], p2 = h2[c], p3 = h3[c]
                    let c0 = p1
                    let c1 = 0.5 * (p2 - p0)
                    let c2 = p0 - 2.5 * p1 + 2.0 * p2 - 0.5 * p3
                    let c3 = 0.5 * (p3 - p0) + 1.5 * (p1 - p2)
                    outputs[c][outCount] = ((c3 * x + c2) * x + c1) * x + c0
                }
                outCount += 1
                phase += step
            }
            phase -= 1.0
            // If capacity was hit mid-interval the phase would keep sliding
            // negative across later inputs; re-floor to stay in the valid
            // [0, 1) admission cadence.
            if phase < 0 { phase += 1.0 }
        }
        self.phase = phase
        return outCount
    }

    /// How many input frames are needed to be sure of producing at least
    /// `outFrames` output frames at `ratio`, plus the interpolator's one
    /// sample of lookahead.
    public func inputFramesNeeded(forOutput outFrames: Int, ratio: Double) -> Int {
        guard outFrames > 0, ratio > 0 else { return 0 }
        return Int((Double(outFrames) / ratio).rounded(.up)) + 2
    }
}
