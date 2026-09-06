import Foundation

/// The two `--selftest` scenarios about what the SENDER does, rather than
/// about what the network does.
///
/// `SelfTest.run` and `runBurstyArrival` both assume a sender that behaves:
/// one packet per 5 ms slot, each stamped from one timeline. A two-machine
/// run found a sender that did neither — it synthesised extra packets from
/// wall clock whenever its capture ring paused between blocks, so a third of
/// everything on the wire overlapped in time with the real audio, and it
/// stopped sending nothing at all when the programme stopped.
///
/// Those are both fixed on the sending side. These scenarios are the
/// receiver's half of the contract: **a pause is not a fault, and a second
/// timeline is refused rather than mixed in.**
extension SelfTest {

    /// How long the simulated sender stops delivering, in the idle scenario.
    public static let idleStallSeconds: Double = 2

    // MARK: - The sender pauses

    /// Steady delivery, a two-second silence, then delivery again.
    ///
    /// What must NOT happen: underruns counted against the silence, a clock
    /// loop chasing a drained buffer, or a re-anchor storm when the programme
    /// comes back. What must happen: silence out of the DAC while there is
    /// nothing to play, and clean, correctly aligned audio afterwards.
    public static func runIdleResume(warmupSeconds: Double = 25,
                                     resumeSeconds: Double = 20,
                                     tuning: ClockFollowLoop.Tuning = ClockFollowLoop.Tuning(),
                                     emit: (String) -> Void = { _ in }) -> Report {
        var report = Report()

        let engine = PlayoutEngine(tuning: tuning)
        let targetMs: Double = 90
        engine.setTargetLatency(milliseconds: targetMs)
        engine.setSoftwareGain(1.0)
        engine.setMuted(false)
        engine.startStream()

        let trueOffset: Int64 = 12_345_678_901
        engine.setClockOffset(nanos: trueOffset)
        let devicePpm = 100.0
        let deviceLatencyNanos: UInt64 = 20_000_000
        engine.setDeviceLatency(
            frames: Int(Double(deviceLatencyNanos) / 1_000_000_000 * WireFormat.sampleRate))
        let blockFrames = 512
        let blockNanosNominal = Double(blockFrames) / WireFormat.sampleRate * 1_000_000_000

        let senderStart: UInt64 = 500_000_000_000
        let targetNanos = UInt64(targetMs * 1_000_000)
        let packetNanos = Double(WireFormat.framesPerPacket) / WireFormat.sampleRate * 1_000_000_000
        func playAt(_ index: Int) -> UInt64 {
            senderStart &+ UInt64((Double(index) * packetNanos).rounded())
        }

        var localNow = UInt64(bitPattern: Int64(bitPattern: playAt(0) &- targetNanos) &+ trueOffset)
        var nextPacket = 0

        let outputA = UnsafeMutablePointer<Float>.allocate(capacity: blockFrames)
        let outputB = UnsafeMutablePointer<Float>.allocate(capacity: blockFrames)
        defer { outputA.deallocate(); outputB.deallocate() }
        var heads = [outputA, outputB]
        var scratch = [Int16](repeating: 0, count: WireFormat.framesPerPacket * WireFormat.channelCount)

        // Three phases on one timeline: warm up, stall, resume. The sender's
        // packet INDEX keeps advancing through the stall — its clock did not
        // stop, it simply had nothing to send — so the audio that comes back
        // is stamped two seconds past where the buffer left off, which is the
        // case the receiver has to absorb without a splice.
        let stallStart = warmupSeconds
        let stallEnd = warmupSeconds + idleStallSeconds
        let totalSeconds = stallEnd + resumeSeconds
        let steps = Int(totalSeconds / (blockNanosNominal / 1_000_000_000))

        // Underruns before idleness is RECOGNISED are honest: the buffer
        // holds 70-odd milliseconds and the idle threshold is half a second,
        // so a real pause always renders some silence the hard way first.
        // What must not happen is underruns continuing to be counted once the
        // receiver knows the link is idle.
        var underrunsAtIdleOnset = -1
        var underrunsAtStallEnd = 0
        var idleBlocksDuringStall = 0
        var reanchorsAtStallStart = 0
        var energySum = 0.0
        var energyCount = 0
        var renderedTail: [Float] = []
        var tailStartDeadline: UInt64 = 0

        for step in 0..<steps {
            let elapsed = Double(step) * blockNanosNominal / 1_000_000_000
            let stalling = elapsed >= stallStart && elapsed < stallEnd

            // 1. Deliver everything due — or, while stalling, drop it on the
            //    floor without sending anything at all, which is precisely
            //    what a sender with nothing to say now does.
            while playAt(nextPacket) &- targetNanos &+ UInt64(bitPattern: trueOffset) <= localNow {
                let index = nextPacket
                nextPacket += 1
                guard !stalling else { continue }
                encodeParseIngest(index: index, senderStart: senderStart,
                                  packetNanos: packetNanos, arrivalNanos: localNow,
                                  scratch: &scratch, engine: engine)
            }

            // 2. One render callback.
            let deadline = localNow &+ deviceLatencyNanos
            heads.withUnsafeMutableBufferPointer { pointers in
                engine.render(frames: blockFrames, dacDeadlineNanos: deadline,
                              outputs: UnsafePointer(pointers.baseAddress!))
            }

            if elapsed >= stallStart && elapsed < stallStart + 0.05 {
                reanchorsAtStallStart = engine.snapshot.reanchors
                engine.resetCounters()
            }
            if stalling {
                let snapshot = engine.snapshot
                if snapshot.isIdle, underrunsAtIdleOnset < 0 {
                    underrunsAtIdleOnset = snapshot.counters.underrun
                }
                underrunsAtStallEnd = snapshot.counters.underrun
                idleBlocksDuringStall = snapshot.idleBlocks
            }
            // Judge the audio only once the resumed stream has re-primed.
            if elapsed >= stallEnd + 1 {
                for f in 0..<blockFrames { energySum += Double(outputA[f]) * Double(outputA[f]) }
                energyCount += blockFrames
            }
            if step >= steps - 10 {
                if renderedTail.isEmpty { tailStartDeadline = deadline }
                renderedTail.append(contentsOf: (0..<blockFrames).map { outputA[$0] })
            }

            localNow &+= UInt64((blockNanosNominal / (1 + devicePpm * 1e-6)).rounded())
        }

        let snapshot = engine.snapshot
        func check(_ name: String, _ passed: Bool, _ detail: String) {
            report.checks.append(Check(name: name, passed: passed, detail: detail))
            emit(String(format: "  %@ %-22@ %@", passed ? "ok  " : "FAIL", name as NSString, detail))
        }

        emit("SyncCastReceiver self-test — sender idles \(Int(idleStallSeconds)) s then resumes "
             + "(\(Int(totalSeconds)) s total, \(reanchorsAtStallStart) re-anchors before the stall)")

        // The silence itself: rendered, and once recognised, not accounted
        // as loss any more.
        let blocksPerIdleThreshold =
            Int(Double(PlayoutEngine.idleThresholdNanos) / blockNanosNominal) + 4
        check("idle recognised", idleBlocksDuringStall > 0,
              "\(idleBlocksDuringStall) blocks rendered idle")
        check("silence stops underruns", underrunsAtStallEnd == underrunsAtIdleOnset,
              "\(underrunsAtIdleOnset) before the link was known idle, "
              + "\(underrunsAtStallEnd) by the end of the stall")
        check("underruns bounded by the threshold",
              underrunsAtIdleOnset >= 0 && underrunsAtIdleOnset <= blocksPerIdleThreshold,
              "\(underrunsAtIdleOnset) blocks before the \(PlayoutEngine.idleThresholdNanos / 1_000_000) ms "
              + "threshold fired (at most \(blocksPerIdleThreshold))")
        check("one silent resume", snapshot.idleResumes == 1, "\(snapshot.idleResumes)")
        // The resumed stream is two seconds past where the buffer stopped;
        // the idle reset has to beat the far-future guard to it.
        check("resume not refused", snapshot.counters.farFuture == 0,
              "\(snapshot.counters.farFuture) far-future rejections")
        check("no hard re-anchors", snapshot.reanchors == 0,
              "\(snapshot.reanchors) after the resume settled")
        check("no underruns after resume",
              snapshot.counters.underrun == underrunsAtStallEnd,
              "\(snapshot.counters.underrun - underrunsAtStallEnd) once audio came back")
        check("no clipping", snapshot.clip == 0, "\(snapshot.clip)")

        let expectedLevelMs = targetMs - Double(deviceLatencyNanos) / 1_000_000
            + Double(WireFormat.framesPerPacket) / 2 / WireFormat.sampleRate * 1_000
        check("buffer back at setpoint", abs(snapshot.levelMilliseconds - expectedLevelMs) < 5,
              String(format: "%.1f ms (setpoint %.1f ms)", snapshot.levelMilliseconds, expectedLevelMs))

        let rms = sqrt(energySum / Double(max(energyCount, 1)))
        let referenceRms = sqrt((0..<48_000).reduce(0.0) { $0 + pow(sample(atFrame: $1), 2) } / 48_000)
        check("output level after resume", abs(rms - referenceRms) < 0.02,
              String(format: "rms %.4f (expected %.4f)", rms, referenceRms))

        check("playout alignment", abs(alignmentLagMs(renderedTail,
                                                      tailStartDeadline: tailStartDeadline,
                                                      trueOffset: trueOffset,
                                                      senderStart: senderStart)) < 1,
              String(format: "%+.2f ms against play_at_ns",
                     alignmentLagMs(renderedTail, tailStartDeadline: tailStartDeadline,
                                    trueOffset: trueOffset, senderStart: senderStart)))
        return report
    }

    // MARK: - The sender stamps two timelines

    /// A well-behaved stream with a second one interleaved into it: packets
    /// stamped for slots the ring already holds, carrying different audio.
    ///
    /// This is the fault a two-machine run heard as two copies of the music
    /// playing over each other. The receiver's job is to refuse the second
    /// copy, count it, and be otherwise unaffected — same level, same
    /// alignment, no splices.
    public static func runOverlappingTimeline(seconds: Double = 60,
                                              warmupSeconds: Double = 25,
                                              tuning: ClockFollowLoop.Tuning = ClockFollowLoop.Tuning(),
                                              emit: (String) -> Void = { _ in }) -> Report {
        var report = Report()

        let engine = PlayoutEngine(tuning: tuning)
        let targetMs: Double = 90
        engine.setTargetLatency(milliseconds: targetMs)
        engine.setSoftwareGain(1.0)
        engine.setMuted(false)
        engine.startStream()

        let trueOffset: Int64 = 12_345_678_901
        engine.setClockOffset(nanos: trueOffset)
        let devicePpm = 100.0
        let deviceLatencyNanos: UInt64 = 20_000_000
        engine.setDeviceLatency(
            frames: Int(Double(deviceLatencyNanos) / 1_000_000_000 * WireFormat.sampleRate))
        let blockFrames = 512
        let blockNanosNominal = Double(blockFrames) / WireFormat.sampleRate * 1_000_000_000

        let senderStart: UInt64 = 500_000_000_000
        let targetNanos = UInt64(targetMs * 1_000_000)
        let packetNanos = Double(WireFormat.framesPerPacket) / WireFormat.sampleRate * 1_000_000_000
        func playAt(_ index: Int) -> UInt64 {
            senderStart &+ UInt64((Double(index) * packetNanos).rounded())
        }

        var localNow = UInt64(bitPattern: Int64(bitPattern: playAt(0) &- targetNanos) &+ trueOffset)
        var nextPacket = 0
        var injectedOverlaps = 0
        // Sequence numbers the duplicate filter has never seen, so the packet
        // reaches the overlap test rather than being caught one step earlier.
        var intruderSeq: UInt32 = 0x8000_0000

        let outputA = UnsafeMutablePointer<Float>.allocate(capacity: blockFrames)
        let outputB = UnsafeMutablePointer<Float>.allocate(capacity: blockFrames)
        defer { outputA.deallocate(); outputB.deallocate() }
        var heads = [outputA, outputB]
        var scratch = [Int16](repeating: 0, count: WireFormat.framesPerPacket * WireFormat.channelCount)

        var energySum = 0.0
        var energyCount = 0
        var warmupDone = false
        var renderedTail: [Float] = []
        var tailStartDeadline: UInt64 = 0
        let steps = Int(seconds / (blockNanosNominal / 1_000_000_000))

        for step in 0..<steps {
            while playAt(nextPacket) &- targetNanos &+ UInt64(bitPattern: trueOffset) <= localNow {
                let index = nextPacket
                nextPacket += 1
                encodeParseIngest(index: index, senderStart: senderStart,
                                  packetNanos: packetNanos, arrivalNanos: localNow,
                                  scratch: &scratch, engine: engine)
                // Every 200th slot, a second timeline claims a slot four
                // packets back — still ahead of the read cursor, so it is not
                // merely late — with entirely different audio in it.
                if index % 200 == 100, index >= 8 {
                    encodeParseIngest(index: index - 4, senderStart: senderStart,
                                      packetNanos: packetNanos, arrivalNanos: localNow,
                                      scratch: &scratch, engine: engine,
                                      payloadIndex: index + 100_000, seq: intruderSeq)
                    intruderSeq &+= 1
                    if warmupDone { injectedOverlaps += 1 }
                }
            }

            let deadline = localNow &+ deviceLatencyNanos
            heads.withUnsafeMutableBufferPointer { pointers in
                engine.render(frames: blockFrames, dacDeadlineNanos: deadline,
                              outputs: UnsafePointer(pointers.baseAddress!))
            }

            let elapsed = Double(step) * blockNanosNominal / 1_000_000_000
            if !warmupDone && elapsed >= warmupSeconds {
                engine.resetCounters()
                warmupDone = true
                injectedOverlaps = 0
            }
            if warmupDone {
                for f in 0..<blockFrames { energySum += Double(outputA[f]) * Double(outputA[f]) }
                energyCount += blockFrames
            }
            if step >= steps - 10 {
                if renderedTail.isEmpty { tailStartDeadline = deadline }
                renderedTail.append(contentsOf: (0..<blockFrames).map { outputA[$0] })
            }

            localNow &+= UInt64((blockNanosNominal / (1 + devicePpm * 1e-6)).rounded())
        }

        let snapshot = engine.snapshot
        func check(_ name: String, _ passed: Bool, _ detail: String) {
            report.checks.append(Check(name: name, passed: passed, detail: detail))
            emit(String(format: "  %@ %-22@ %@", passed ? "ok  " : "FAIL", name as NSString, detail))
        }

        emit("SyncCastReceiver self-test — a second timeline interleaved: "
             + "\(injectedOverlaps) overlapping packets injected after warm-up")

        check("overlaps counted", snapshot.counters.overlap == injectedOverlaps,
              "counted \(snapshot.counters.overlap), injected \(injectedOverlaps)")
        check("overlaps really injected", injectedOverlaps > 0, "\(injectedOverlaps)")
        check("no hard re-anchors", snapshot.reanchors == 0, "\(snapshot.reanchors)")
        check("no underruns", snapshot.counters.underrun == 0, "\(snapshot.counters.underrun)")
        check("no clipping", snapshot.clip == 0, "\(snapshot.clip)")

        // The refused audio never reached the DAC: level and alignment are
        // exactly those of a clean stream.
        let rms = sqrt(energySum / Double(max(energyCount, 1)))
        let referenceRms = sqrt((0..<48_000).reduce(0.0) { $0 + pow(sample(atFrame: $1), 2) } / 48_000)
        check("output level", abs(rms - referenceRms) < 0.02,
              String(format: "rms %.4f (expected %.4f)", rms, referenceRms))
        let lagMs = alignmentLagMs(renderedTail, tailStartDeadline: tailStartDeadline,
                                   trueOffset: trueOffset, senderStart: senderStart)
        check("playout alignment", abs(lagMs) < 1,
              String(format: "%+.2f ms against play_at_ns", lagMs))
        return report
    }

    // MARK: - Shared

    /// Where the rendered tail actually came from in the source stream,
    /// against where `play_at_ns` said it should be, in milliseconds.
    static func alignmentLagMs(_ tail: [Float],
                               tailStartDeadline: UInt64,
                               trueOffset: Int64,
                               senderStart: UInt64) -> Double {
        guard !tail.isEmpty else { return .infinity }
        let expectedFrame = Int((Double(Int64(bitPattern: tailStartDeadline) &- trueOffset
                                        &- Int64(bitPattern: senderStart)) / 1_000_000_000
                                 * WireFormat.sampleRate).rounded())
        var bestLag = 0
        var bestScore = -Double.infinity
        for lag in -480...480 {
            var score = 0.0
            for i in stride(from: 0, to: tail.count, by: 2) {
                score += Double(tail[i]) * sample(atFrame: expectedFrame + lag + i)
            }
            if score > bestScore { bestScore = score; bestLag = lag }
        }
        return Double(bestLag) / WireFormat.sampleRate * 1_000
    }
}
