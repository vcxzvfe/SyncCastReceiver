import Foundation

/// Everything that happens between "a packet arrived" and "Float32 frames go
/// to the DAC": the jitter ring, the clock-following PI loop, the fractional
/// resampler and the software gain stage.
///
/// It is deliberately free of CoreAudio and of the network: the AUHAL render
/// callback and `--selftest` drive exactly the same code, so the offline
/// self-test exercises the real scheduler rather than a mock of it.
///
/// Threading: `ingest` runs on the UDP receive thread, `render` on the
/// CoreAudio real-time thread, and the setters on the control-channel queue.
/// Everything crossing those boundaries is atomic; `render` allocates
/// nothing and takes no lock.
public final class PlayoutEngine: @unchecked Sendable {

    public struct Snapshot: Sendable {
        public var counters: JitterBuffer.Counters
        public var clip: Int
        public var reanchors: Int
        /// Hard re-anchors broken down by what caused them. The sum is
        /// `reanchors`.
        public var reanchorsByReason: [ClockFollowLoop.ReanchorReason: Int]
        /// The most recent re-anchor, for the log line that explains it.
        public var lastReanchor: ReanchorEvent?
        /// EMA-smoothed buffer level, the number worth showing a user.
        public var levelMilliseconds: Double
        /// Instantaneous ring fill at the moment of the snapshot.
        public var fillMilliseconds: Double
        /// Arrival spread of the last few seconds of packets, in ms, or nil
        /// before enough have arrived. See `PacketArrivalTracker`.
        public var p95JitterMilliseconds: Double?
        public var ratio: Double
        public var isPlaying: Bool
    }

    /// One hard re-anchor, with the numbers that explain it.
    public struct ReanchorEvent: Equatable, Sendable {
        /// Monotonically increasing; a reader can tell a new event from a
        /// repeat of the one it already logged.
        public var sequence: Int
        public var reason: ClockFollowLoop.ReanchorReason
        /// Smoothed level error against the setpoint when it fired.
        public var errorMilliseconds: Double
        /// Instantaneous ring fill when it fired.
        public var fillMilliseconds: Double
        /// Render blocks in a row that had found the ring empty.
        public var starvedBlocks: Int
    }

    public let buffer: JitterBuffer
    public let sampleRate: Double
    public let channelCount: Int

    private let resampler: FractionalResampler
    /// PI loop state lives on the render thread only; `ratioPublished` is the
    /// copy the stats thread reads.
    private var loop: ClockFollowLoop
    private let ratioPublished = AtomicDouble(1.0)
    private let levelPublished = AtomicDouble(.nan)

    private let offsetNanosBox = AtomicInt64(0)
    private let offsetValid = AtomicBool(false)
    private let targetFramesBox = AtomicInt64(0)
    private let deviceLatencyFramesBox = AtomicInt64(0)
    private let softwareGainBox = AtomicDouble(1.0)
    private let mutedBox = AtomicBool(false)
    private let clipBox = AtomicInt64(0)
    private let reanchorBox = AtomicInt64(0)
    private let reanchorStarvedBox = AtomicInt64(0)
    private let reanchorErrorBox = AtomicInt64(0)
    private let reanchorTargetBox = AtomicInt64(0)
    private let playingBox = AtomicBool(false)
    private let anchoredBox = AtomicBool(false)
    /// The target moved under a running stream, so the level has to jump.
    private let targetMovedBox = AtomicBool(false)

    // The last re-anchor, published field by field because the render thread
    // may not allocate. `lastReanchorSequence` is written LAST, so a reader
    // that sees a new sequence number also sees the numbers that go with it.
    private let lastReanchorReasonBox = AtomicInt64(0)
    private let lastReanchorErrorBox = AtomicDouble(0)
    private let lastReanchorFillBox = AtomicDouble(0)
    private let lastReanchorStarvedBox = AtomicInt64(0)
    private let lastReanchorSequenceBox = AtomicInt64(0)

    /// Arrival-jitter measurement, fed from the UDP thread.
    public let arrivalTracker = PacketArrivalTracker()
    private let clock = MachClock()

    /// Render-thread scratch. Sized for a very large AUHAL buffer (8192
    /// frames is 170 ms at 48 kHz; no output device asks for more) plus the
    /// resampler's slop.
    private static let scratchCapacityFrames = 8_192 + 64
    private let inputScratch: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private let stagingBuffer: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    /// Per-call view of `stagingBuffer` offset by `stagingCount`, kept as a
    /// preallocated array so the render thread never allocates.
    private let stagingWriteHeads: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
    private var stagingCount = 0
    private var smoothedGain: Float = 1.0

    public init(channelCount: Int = WireFormat.channelCount,
                sampleRate: Double = WireFormat.sampleRate,
                capacityFrames: Int = 1 << 16,
                tuning: ClockFollowLoop.Tuning = ClockFollowLoop.Tuning()) {
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.buffer = JitterBuffer(channelCount: channelCount,
                                   capacityFrames: capacityFrames,
                                   sampleRate: sampleRate)
        self.resampler = FractionalResampler(channelCount: channelCount)
        self.loop = ClockFollowLoop(tuning: tuning)
        func alloc() -> UnsafeMutablePointer<UnsafeMutablePointer<Float>> {
            let table = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: channelCount)
            for ch in 0..<channelCount {
                let p = UnsafeMutablePointer<Float>.allocate(capacity: Self.scratchCapacityFrames)
                p.initialize(repeating: 0, count: Self.scratchCapacityFrames)
                table[ch] = p
            }
            return table
        }
        self.inputScratch = alloc()
        self.stagingBuffer = alloc()
        self.stagingWriteHeads =
            UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: channelCount)
        for ch in 0..<channelCount { self.stagingWriteHeads[ch] = self.stagingBuffer[ch] }
        self.targetFramesBox.value = Int64(0.090 * sampleRate)   // spec default 90 ms
    }

    deinit {
        for ch in 0..<channelCount {
            inputScratch[ch].deinitialize(count: Self.scratchCapacityFrames)
            inputScratch[ch].deallocate()
            stagingBuffer[ch].deinitialize(count: Self.scratchCapacityFrames)
            stagingBuffer[ch].deallocate()
        }
        inputScratch.deallocate()
        stagingBuffer.deallocate()
        stagingWriteHeads.deallocate()
    }

    // MARK: - Control-thread setters

    /// `local = sender + offset`, from the NTP estimator.
    public func setClockOffset(nanos: Int64) {
        offsetNanosBox.value = nanos
        offsetValid.value = true
    }

    public func clearClockOffset() {
        offsetValid.value = false
        anchoredBox.value = false
    }

    /// Set the playout target.
    ///
    /// Moving it moves the water level's setpoint, and the trim can only walk
    /// the level at ±200 ppm — 0.2 ms per second, so a 30 ms change would take
    /// two and a half minutes. A target change is a deliberate, known event
    /// (the user moved a slider, or this side raised the floor to match the
    /// link), so the level JUMPS to the new setpoint instead: one splice at a
    /// moment the listener is expecting a change, rather than minutes of
    /// playing at the wrong latency.
    ///
    /// A change smaller than half a packet is not worth a splice.
    public func setTargetLatency(milliseconds: Double) {
        let clamped = min(max(milliseconds, 10), 1_000)
        let frames = Int64(clamped / 1000 * sampleRate)
        let previous = targetFramesBox.value
        targetFramesBox.value = frames
        if anchoredBox.value, abs(frames - previous) > Int64(WireFormat.framesPerPacket / 2) {
            targetMovedBox.value = true
        }
    }

    public var targetLatencyMilliseconds: Double {
        Double(targetFramesBox.value) / sampleRate * 1000
    }

    /// Output-device latency in frames (`kAudioDevicePropertyLatency` +
    /// safety offset + buffer size + stream latency).
    ///
    /// It comes straight off the water level: `play_at_ns` is the moment the
    /// audio must leave the DAC, and the read cursor runs one device latency
    /// AHEAD of the DAC, so the frames queued behind the cursor in steady
    /// state are `target − deviceLatency`, not `target`. Setting the loop's
    /// setpoint to the target itself would ask the buffer to hold audio it
    /// has not received yet, saturate the trim, and drag playout late.
    public func setDeviceLatency(frames: Int) {
        deviceLatencyFramesBox.value = Int64(max(0, frames))
    }

    /// The PI loop's setpoint: what the ring should hold ahead of the read
    /// cursor when playout is correctly aligned.
    ///
    /// `target − deviceLatency` for the reason above, plus HALF A PACKET:
    /// the write head only moves in 240-frame steps, so a sample of it taken
    /// at an arbitrary moment sits on average half a packet above the
    /// continuous position the sender is really at. Without that term the
    /// loop would quietly drag playout 2.5 ms early to make the measured
    /// level match a setpoint the stream can never sit at.
    ///
    /// Never below one packet, so a device whose latency exceeds the
    /// requested target still has something to render from.
    public var levelSetpointFrames: Int64 {
        let compensated = targetFramesBox.value - deviceLatencyFramesBox.value
            + Int64(WireFormat.framesPerPacket / 2)
        return max(Int64(WireFormat.framesPerPacket), compensated)
    }

    /// Linear amplitude applied in the render path. Left at 1.0 when the
    /// device carries the level in hardware.
    public func setSoftwareGain(_ gain: Double) {
        softwareGainBox.value = min(max(gain, 0), 4)
    }

    public func setMuted(_ muted: Bool) { mutedBox.value = muted }

    /// Arm playback. The next render anchors the cursor from the clock.
    public func startStream() {
        anchoredBox.value = false
        playingBox.value = true
    }

    /// Stop and mute: no more audio leaves the DAC until a new stream starts.
    public func stopStream() {
        playingBox.value = false
        anchoredBox.value = false
        buffer.resetStream()
    }

    public func resetCounters() {
        buffer.resetCounters()
        clipBox.value = 0
        reanchorBox.value = 0
        reanchorStarvedBox.value = 0
        reanchorErrorBox.value = 0
        reanchorTargetBox.value = 0
    }

    public var snapshot: Snapshot {
        let level = levelPublished.value
        return Snapshot(counters: buffer.counterSnapshot,
                 clip: Int(clipBox.value),
                 reanchors: Int(reanchorBox.value),
                 reanchorsByReason: [
                    .starved: Int(reanchorStarvedBox.value),
                    .error: Int(reanchorErrorBox.value),
                    .target: Int(reanchorTargetBox.value),
                 ],
                 lastReanchor: lastReanchor,
                 levelMilliseconds: level.isNaN ? buffer.fillMilliseconds : level / sampleRate * 1000,
                 fillMilliseconds: buffer.fillMilliseconds,
                 p95JitterMilliseconds: arrivalTracker.p95SpreadMilliseconds,
                 ratio: ratioPublished.value,
                 isPlaying: playingBox.value)
    }

    /// The most recent hard re-anchor, or nil if there has not been one.
    public var lastReanchor: ReanchorEvent? {
        let sequence = Int(lastReanchorSequenceBox.value)
        guard sequence > 0,
              let reason = Self.reason(fromCode: lastReanchorReasonBox.value) else { return nil }
        return ReanchorEvent(sequence: sequence,
                             reason: reason,
                             errorMilliseconds: lastReanchorErrorBox.value,
                             fillMilliseconds: lastReanchorFillBox.value,
                             starvedBlocks: Int(lastReanchorStarvedBox.value))
    }

    private static func code(for reason: ClockFollowLoop.ReanchorReason) -> Int64 {
        switch reason {
        case .starved: return 1
        case .error: return 2
        case .target: return 3
        }
    }

    private static func reason(fromCode code: Int64) -> ClockFollowLoop.ReanchorReason? {
        switch code {
        case 1: return .starved
        case 2: return .error
        case 3: return .target
        default: return nil
        }
    }

    // MARK: - UDP thread

    @discardableResult
    public func ingest(header: AudioPacketHeader, samples: UnsafePointer<Int16>) -> JitterBuffer.IngestOutcome {
        ingest(header: header, samples: samples, arrivalNanos: clock.nowNanos())
    }

    /// Ingest with an explicit arrival timestamp, so the offline self-test can
    /// drive the same arrival-jitter measurement from its simulated clock.
    @discardableResult
    public func ingest(header: AudioPacketHeader,
                       samples: UnsafePointer<Int16>,
                       arrivalNanos: UInt64) -> JitterBuffer.IngestOutcome {
        let outcome = buffer.ingest(header: header, samples: samples)
        switch outcome {
        case .accepted, .reordered, .restarted:
            arrivalTracker.record(playAtNanos: header.playAtNanos, arrivalNanos: arrivalNanos)
        case .late, .duplicate:
            // A duplicate says nothing new about the link, and a late packet's
            // delay is already past the point the buffer could have used it.
            break
        }
        return outcome
    }

    // MARK: - Render thread

    /// Fill `outputs` with `frames` of planar Float32.
    ///
    /// - Parameter dacDeadlineNanos: local monotonic ns at which the FIRST
    ///   frame of this block leaves the DAC — i.e. the AUHAL timestamp plus
    ///   the device's own output latency.
    public func render(frames: Int,
                       dacDeadlineNanos: UInt64,
                       outputs: UnsafePointer<UnsafeMutablePointer<Float>>) {
        guard frames > 0 else { return }
        guard frames <= Self.scratchCapacityFrames else { silence(frames: frames, outputs: outputs); return }
        guard playingBox.value, offsetValid.value, buffer.isAnchored else {
            silence(frames: frames, outputs: outputs)
            return
        }

        let targetFrames = levelSetpointFrames
        if !anchoredBox.value {
            // Map the DAC deadline into the sender's clock and start playing
            // exactly the frame that was stamped for it.
            let senderNanos = UInt64(bitPattern: Int64(bitPattern: dacDeadlineNanos) &- offsetNanosBox.value)
            buffer.anchorReadCursor(toSenderNanos: senderNanos)
            resampler.reset()
            loop.reset(fillFrames: Double(buffer.fillFrames))
            stagingCount = 0
            anchoredBox.value = true
            // The cold-start anchor already put the cursor where the new
            // target says; there is nothing left for a target jump to do.
            targetMovedBox.value = false
        }

        let fillFrames = Double(buffer.fillFrames)
        let dt = Double(frames) / sampleRate
        let outcome = loop.update(fillFrames: fillFrames,
                                  targetFrames: Double(targetFrames),
                                  dt: dt)
        var reanchorReason: ClockFollowLoop.ReanchorReason?
        if case .reanchorNeeded(let reason) = outcome { reanchorReason = reason }
        if targetMovedBox.value {
            targetMovedBox.value = false
            reanchorReason = .target
        }
        if let reason = reanchorReason {
            let errorMs = loop.errorMilliseconds(targetFrames: Double(targetFrames))
            let starved = loop.consecutiveStarvedBlocks
            buffer.reanchorReadCursor(toLevelFrames: targetFrames)
            resampler.reset()
            loop.reset(fillFrames: Double(targetFrames))
            stagingCount = 0
            reanchorBox.add(1)
            switch reason {
            case .starved: reanchorStarvedBox.add(1)
            case .error: reanchorErrorBox.add(1)
            case .target: reanchorTargetBox.add(1)
            }
            lastReanchorReasonBox.value = Self.code(for: reason)
            lastReanchorErrorBox.value = errorMs
            lastReanchorFillBox.value = fillFrames / sampleRate * 1000
            lastReanchorStarvedBox.value = Int64(starved)
            // Published last: a reader that sees this also sees the rest.
            lastReanchorSequenceBox.add(1)
        }
        let ratio = loop.ratio
        ratioPublished.value = ratio
        levelPublished.value = loop.filteredFillFrames

        var guardCounter = 0
        while stagingCount < frames && guardCounter < 8 {
            guardCounter += 1
            let missing = frames - stagingCount
            var need = resampler.inputFramesNeeded(forOutput: missing, ratio: ratio)
            need = min(need, Self.scratchCapacityFrames)
            buffer.read(frames: need, into: UnsafePointer(inputScratch))
            for ch in 0..<channelCount {
                stagingWriteHeads[ch] = stagingBuffer[ch].advanced(by: stagingCount)
            }
            let produced = resampler.process(
                inputs: UnsafePointer(inputScratch),
                inFrames: need,
                ratio: ratio,
                outputs: UnsafePointer(stagingWriteHeads),
                outCapacity: Self.scratchCapacityFrames - stagingCount)
            if produced == 0 { break }
            stagingCount += produced
        }
        if stagingCount < frames {
            for ch in 0..<channelCount {
                stagingBuffer[ch].advanced(by: stagingCount)
                    .update(repeating: 0, count: frames - stagingCount)
            }
            stagingCount = frames
        }
        emit(frames: frames, from: UnsafePointer(stagingBuffer), to: outputs)
        let remainder = stagingCount - frames
        if remainder > 0 {
            for ch in 0..<channelCount {
                stagingBuffer[ch].update(from: stagingBuffer[ch].advanced(by: frames), count: remainder)
            }
        }
        stagingCount = remainder
    }

    private func emit(frames: Int,
                      from staging: UnsafePointer<UnsafeMutablePointer<Float>>,
                      to outputs: UnsafePointer<UnsafeMutablePointer<Float>>) {
        let target: Float = mutedBox.value ? 0 : Float(softwareGainBox.value)
        let start = smoothedGain
        // One-block linear ramp: a step in the master would otherwise click.
        let stepGain = (target - start) / Float(frames)
        var clips: Int64 = 0
        for ch in 0..<channelCount {
            var g = start
            let src = staging[ch]
            let dst = outputs[ch]
            for f in 0..<frames {
                var v = src[f] * g
                if v > 1.0 { v = 1.0; clips += 1 } else if v < -1.0 { v = -1.0; clips += 1 }
                dst[f] = v
                g += stepGain
            }
        }
        smoothedGain = target
        if clips > 0 { clipBox.add(clips) }
    }

    private func silence(frames: Int, outputs: UnsafePointer<UnsafeMutablePointer<Float>>) {
        for ch in 0..<channelCount { outputs[ch].update(repeating: 0, count: frames) }
        smoothedGain = mutedBox.value ? 0 : Float(softwareGainBox.value)
    }
}
