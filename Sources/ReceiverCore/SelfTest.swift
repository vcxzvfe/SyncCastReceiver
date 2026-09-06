import Foundation

/// Offline end-to-end exercise of the receive path: build real packets,
/// parse them with the real parser, run them through the real jitter buffer,
/// clock-following loop and resampler, and check what comes out of the
/// render callback — with no network, no CoreAudio and no wall clock.
///
/// It is the answer to "is this binary healthy on this machine?" and it is
/// the same code the daemon runs, not a mock of it.
public enum SelfTest {

    public struct Check {
        public let name: String
        public let passed: Bool
        public let detail: String
    }

    public struct Report {
        public var checks: [Check] = []
        public var passed: Bool { checks.allSatisfy(\.passed) }
    }

    /// Deterministic pseudo-random source, so a failure is reproducible.
    struct LCG {
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 11
        }
        mutating func chance(oneIn n: UInt64) -> Bool { next() % n == 0 }
    }

    /// Build one packet, put it on the wire, take it off again and hand it
    /// to the engine — the real encoder, the real parser, the real ring.
    ///
    /// Shared by every scenario so they all exercise the same path; only the
    /// delivery SCHEDULE differs between them.
    /// - Parameters:
    ///   - index: the packet's slot on the sender's timeline; it decides
    ///     `play_at_ns`.
    ///   - payloadIndex: which audio to put in it, when that must differ from
    ///     `index`. Only the overlapping-timeline scenario uses it — a packet
    ///     carrying the WRONG audio for the slot it claims is the whole point
    ///     there, because identical audio would sound fine even if the guard
    ///     failed.
    ///   - seq: sequence number, when the default (derived from `index`)
    ///     would be caught by the duplicate filter.
    @discardableResult
    static func encodeParseIngest(index: Int,
                                  senderStart: UInt64,
                                  packetNanos: Double,
                                  arrivalNanos: UInt64,
                                  scratch: inout [Int16],
                                  engine: PlayoutEngine,
                                  payloadIndex: Int? = nil,
                                  seq: UInt32? = nil) -> Bool {
        var samples = [Int16](repeating: 0, count: WireFormat.framesPerPacket * WireFormat.channelCount)
        let audioIndex = payloadIndex ?? index
        for f in 0..<WireFormat.framesPerPacket {
            let v = sample(atFrame: audioIndex * WireFormat.framesPerPacket + f)
            let s = Int16(max(-32_767, min(32_767, (v * 32_767).rounded())))
            samples[f * 2] = s
            samples[f * 2 + 1] = s
        }
        let header = AudioPacketHeader(streamID: 0x5157_3A01,
                                       seq: seq ?? UInt32(truncatingIfNeeded: index),
                                       playAtNanos: senderStart &+ UInt64((Double(index) * packetNanos).rounded()),
                                       frames: UInt32(WireFormat.framesPerPacket))
        let bytes = buildAudioPacket(header: header, samples: samples)
        guard let parsed = try? bytes.withUnsafeBytes({ raw -> AudioPacketHeader in
            let h = try AudioPacketHeader.decode(raw)
            try scratch.withUnsafeMutableBufferPointer { out in
                _ = try decodeInt16Payload(raw, offset: WireFormat.headerByteCount,
                                           sampleCount: WireFormat.framesPerPacket * WireFormat.channelCount,
                                           into: out.baseAddress!)
            }
            return h
        }) else { return false }
        _ = scratch.withUnsafeBufferPointer {
            engine.ingest(header: parsed, samples: $0.baseAddress!, arrivalNanos: arrivalNanos)
        }
        return true
    }

    /// Test signal: a 30 Hz fundamental (period 1600 frames, so the timing
    /// correlation below is unambiguous over ±10 ms) plus a 1 kHz tone that
    /// would show up as ripple if the resampler were dropping samples.
    static func sample(atFrame frame: Int) -> Double {
        let t = Double(frame) / WireFormat.sampleRate
        return 0.4 * sin(2 * .pi * 30 * t) + 0.1 * sin(2 * .pi * 1_000 * t)
    }

    /// 70 s of simulated audio, of which the first 20 s are warmup: the cold
    /// start pushes the trim into its ±200 ppm stop while the level walks to
    /// the setpoint, and it is the steady state after that which is worth
    /// measuring. It still runs in a few seconds of real time.
    /// - Parameter transitNanos: how long every packet takes to get here after
    ///   the sender put it on the wire. The steady scenario uses zero; a real
    ///   link has some, and the point of `transitNanos > 0` is to prove that
    ///   transit changes the ring LEVEL and not the playout TIME — the loop
    ///   must hold the level the schedule produces, not walk it up to the
    ///   nominal setpoint and drag playout late by one transit delay.
    public static func run(seconds: Double = 70,
                           warmupSeconds: Double = 20,
                           tuning: ClockFollowLoop.Tuning = ClockFollowLoop.Tuning(),
                           transitNanos: UInt64 = 0,
                           emit: (String) -> Void = { _ in }) -> Report {
        var report = Report()

        let engine = PlayoutEngine(tuning: tuning)
        let targetMs: Double = 90
        engine.setTargetLatency(milliseconds: targetMs)
        engine.setSoftwareGain(1.0)
        engine.setMuted(false)
        engine.startStream()

        // Two clocks: the sender's, and ours running 100 ppm fast (a typical
        // consumer crystal pair). `local = sender + offset`.
        let trueOffset: Int64 = 12_345_678_901
        engine.setClockOffset(nanos: trueOffset)
        let devicePpm = 100.0
        let deviceLatencyNanos: UInt64 = 20_000_000        // 20 ms, like real hardware
        engine.setDeviceLatency(frames: Int(Double(deviceLatencyNanos) / 1_000_000_000 * WireFormat.sampleRate))
        let blockFrames = 512
        let blockNanosNominal = Double(blockFrames) / WireFormat.sampleRate * 1_000_000_000

        let senderStart: UInt64 = 500_000_000_000
        let targetNanos = UInt64(targetMs * 1_000_000)
        let packetNanos = Double(WireFormat.framesPerPacket) / WireFormat.sampleRate * 1_000_000_000

        func playAt(_ index: Int) -> UInt64 { senderStart &+ UInt64((Double(index) * packetNanos).rounded()) }

        var localNow = UInt64(bitPattern: Int64(bitPattern: playAt(0) &- targetNanos) &+ trueOffset)
        var nextPacket = 0
        var delayed: [(dueAt: UInt64, index: Int)] = []
        var random = LCG()
        var injectedDrops = 0, injectedDuplicates = 0, injectedReorders = 0
        var sent = 0

        let outputA = UnsafeMutablePointer<Float>.allocate(capacity: blockFrames)
        let outputB = UnsafeMutablePointer<Float>.allocate(capacity: blockFrames)
        defer { outputA.deallocate(); outputB.deallocate() }
        var heads = [outputA, outputB]
        var scratch = [Int16](repeating: 0, count: WireFormat.framesPerPacket * WireFormat.channelCount)

        /// Encode → wire bytes → decode → ingest, exactly as the UDP thread does.
        func deliver(index: Int, duplicate: Bool = false) {
            guard encodeParseIngest(index: index, senderStart: senderStart,
                                    packetNanos: packetNanos, arrivalNanos: localNow,
                                    scratch: &scratch, engine: engine) else { return }
            if !duplicate { sent += 1 }
        }

        var energySum = 0.0
        var energyCount = 0
        var trimSum = 0.0
        var trimCount = 0
        var trimWorst = 0.0
        var renderedTail: [Float] = []
        var tailStartDeadline: UInt64 = 0
        var warmupDone = false
        let steps = Int(seconds / (blockNanosNominal / 1_000_000_000))

        for step in 0..<steps {
            // 1. Everything the sender would have transmitted by now.
            while playAt(nextPacket) &- targetNanos &+ UInt64(bitPattern: trueOffset) &+ transitNanos <= localNow {
                let index = nextPacket
                nextPacket += 1
                if random.chance(oneIn: 400) { injectedDrops += 1; continue }         // packet loss
                if random.chance(oneIn: 300) {                                        // reordering
                    delayed.append((dueAt: localNow &+ 15_000_000, index: index))
                    injectedReorders += 1
                    continue
                }
                deliver(index: index)
                if random.chance(oneIn: 500) { deliver(index: index, duplicate: true); injectedDuplicates += 1 }
            }
            for pending in delayed where pending.dueAt <= localNow { deliver(index: pending.index) }
            delayed.removeAll { $0.dueAt <= localNow }

            // 2. One render callback.
            let deadline = localNow &+ deviceLatencyNanos
            heads.withUnsafeMutableBufferPointer { pointers in
                engine.render(frames: blockFrames, dacDeadlineNanos: deadline,
                              outputs: UnsafePointer(pointers.baseAddress!))
            }

            let elapsedWarmup = Double(step) * blockNanosNominal / 1_000_000_000
            if !warmupDone && elapsedWarmup >= warmupSeconds {
                // Cold start (pre-roll silence, the first anchor) is not what
                // this test is about; measure the steady state.
                engine.resetCounters()
                warmupDone = true
                injectedDrops = 0; injectedDuplicates = 0; injectedReorders = 0
            }
            if warmupDone {
                for f in 0..<blockFrames { energySum += Double(outputA[f]) * Double(outputA[f]) }
                energyCount += blockFrames
                // The trim ripples by a few tens of ppm around its
                // equilibrium (the level measurement carries a packet-rate
                // sawtooth), so judge the mean, and the worst excursion
                // separately against the ±200 ppm clamp.
                let ppm = (engine.snapshot.ratio - 1) * 1e6
                trimSum += ppm
                trimCount += 1
                trimWorst = max(trimWorst, abs(ppm))
            }
            // Capture the last ~100 ms for the alignment correlation: three
            // full periods of the 30 Hz fundamental, so the correlation peak
            // is sharp and unambiguous over the ±10 ms search.
            if step >= steps - 10 {
                if renderedTail.isEmpty { tailStartDeadline = deadline }
                renderedTail.append(contentsOf: (0..<blockFrames).map { outputA[$0] })
            }

            // 3. Advance our (slightly fast) device clock.
            localNow &+= UInt64((blockNanosNominal / (1 + devicePpm * 1e-6)).rounded())
        }

        let snapshot = engine.snapshot
        let counters = snapshot.counters

        func check(_ name: String, _ passed: Bool, _ detail: String) {
            report.checks.append(Check(name: name, passed: passed, detail: detail))
            emit(String(format: "  %@ %-22@ %@", passed ? "ok  " : "FAIL", name as NSString, detail))
        }

        emit("SyncCastReceiver self-test — \(Int(seconds)) s of simulated audio, "
             + "\(sent) packets, device clock \(Int(devicePpm)) ppm fast")

        check("packets accepted", counters.accepted > 0, "\(counters.accepted)")
        check("loss accounting", counters.lost == injectedDrops,
              "reported \(counters.lost), injected \(injectedDrops)")
        check("duplicate rejection", counters.duplicate == injectedDuplicates,
              "reported \(counters.duplicate), injected \(injectedDuplicates)")
        check("reordering absorbed", counters.reordered >= injectedReorders - 1 && counters.late == 0,
              "reordered \(counters.reordered) (injected \(injectedReorders)), late \(counters.late)")
        check("no underruns", counters.underrun == 0, "\(counters.underrun)")
        check("no clipping", snapshot.clip == 0, "\(snapshot.clip)")
        check("no hard re-anchors", snapshot.reanchors == 0, "\(snapshot.reanchors)")

        // Steady-state level is the target minus the device latency: the
        // read cursor runs one device latency ahead of the DAC.
        let expectedLevelMs = targetMs - Double(deviceLatencyNanos) / 1_000_000
            + Double(WireFormat.framesPerPacket) / 2 / WireFormat.sampleRate * 1_000
            - Double(transitNanos) / 1_000_000
        let bufferMs = snapshot.levelMilliseconds
        check("buffer at setpoint", abs(bufferMs - expectedLevelMs) < 5,
              String(format: "%.1f ms (setpoint %.1f ms = target %.0f − device %.0f + half a packet − transit %.0f)",
                     bufferMs, expectedLevelMs, targetMs, Double(deviceLatencyNanos) / 1_000_000,
                     Double(transitNanos) / 1_000_000))

        let meanPpm = trimSum / Double(max(trimCount, 1))
        check("trim within ±200 ppm", trimWorst <= 200, String(format: "worst %.1f ppm", trimWorst))
        check("trim tracks the clock", abs(meanPpm - devicePpm) < 25,
              String(format: "mean %+.1f ppm (device %+.0f ppm)", meanPpm, devicePpm))

        // Signal checks on the last full block: level, and where in the
        // stream it actually came from.
        let rms = sqrt(energySum / Double(max(energyCount, 1)))
        let referenceRms = sqrt((0..<48_000).reduce(0.0) { $0 + pow(sample(atFrame: $1), 2) } / 48_000)
        check("output level", abs(rms - referenceRms) < 0.02,
              String(format: "rms %.4f (expected %.4f)", rms, referenceRms))

        let expectedFrame = Int((Double(Int64(bitPattern: tailStartDeadline) &- trueOffset
                                        &- Int64(bitPattern: senderStart)) / 1_000_000_000
                                 * WireFormat.sampleRate).rounded())
        var bestLag = 0
        var bestScore = -Double.infinity
        for lag in -480...480 {
            var score = 0.0
            for i in stride(from: 0, to: renderedTail.count, by: 2) {
                score += Double(renderedTail[i]) * sample(atFrame: expectedFrame + lag + i)
            }
            if score > bestScore { bestScore = score; bestLag = lag }
        }
        let lagMs = Double(bestLag) / WireFormat.sampleRate * 1_000
        check("playout alignment", abs(lagMs) < 1,
              String(format: "%+.2f ms against play_at_ns", lagMs))

        return report
    }
}
