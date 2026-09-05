import Foundation

/// The second `--selftest` scenario: a link that delivers in BURSTS.
///
/// The steady scenario in `SelfTest.run` hands the engine one packet every
/// 5 ms, which is what a wired LAN looks like and what the control loop was
/// originally tuned against. A Wi-Fi link does not do that. It aggregates:
/// several packets arrive back to back after a gap of tens of milliseconds,
/// and now and then a retransmission or a scan pauses delivery outright.
///
/// A field run over exactly such a link was the reason this scenario exists.
/// The receiver was hard re-anchoring about three times a second — one
/// audible splice each — because a single empty render block was treated as
/// starvation, and burst delivery empties the ring for a block at the end of
/// almost every gap. Nothing was wrong with the audio; the buffer was
/// spliced for arriving the way this network arrives.
///
/// So the contract this scenario pins is: **no hard re-anchors at all after
/// warm-up**, with underruns bounded by the stalls that were actually
/// injected. Underruns are honest here — an 80 ms delivery stall against a
/// buffer holding less than that WILL play silence — but silence for a block
/// and a click are very different things, and only one of them is a bug.
extension SelfTest {

    /// Packets delivered per burst in steady state: 6 packets is 30 ms of
    /// audio, matching the burst period, so the mean rate is exactly right.
    public static let burstPackets: Int = 6
    /// Gap between bursts.
    public static let burstPeriodNanos: UInt64 = 30_000_000
    /// An occasional stall: delivery pauses outright for this long, then the
    /// whole backlog lands at once.
    public static let stallNanos: UInt64 = 80_000_000

    /// - Parameters:
    ///   - seconds: total simulated time.
    ///   - warmupSeconds: cold start plus the window in which the target is
    ///     allowed to settle. Counters are reset at the end of it.
    ///   - stallsPerSecond: how often delivery pauses for `stallNanos`.
    public static func runBurstyArrival(seconds: Double = 90,
                                        warmupSeconds: Double = 40,
                                        stallsPerSecond: Double = 1,
                                        tuning: ClockFollowLoop.Tuning = ClockFollowLoop.Tuning(),
                                        emit: (String) -> Void = { _ in }) -> Report {
        var report = Report()

        let engine = PlayoutEngine(tuning: tuning)
        let requestedTargetMs: Double = 90
        engine.setTargetLatency(milliseconds: requestedTargetMs)
        engine.setSoftwareGain(1.0)
        engine.setMuted(false)
        engine.startStream()

        let trueOffset: Int64 = 12_345_678_901
        engine.setClockOffset(nanos: trueOffset)
        let devicePpm = 100.0
        let deviceLatencyNanos: UInt64 = 20_000_000
        let blockFrames = 512
        engine.setDeviceLatency(
            frames: Int(Double(deviceLatencyNanos) / 1_000_000_000 * WireFormat.sampleRate))
        let blockNanosNominal = Double(blockFrames) / WireFormat.sampleRate * 1_000_000_000

        let senderStart: UInt64 = 500_000_000_000
        let targetNanos = UInt64(requestedTargetMs * 1_000_000)
        let packetNanos = Double(WireFormat.framesPerPacket) / WireFormat.sampleRate * 1_000_000_000
        func sendableAt(_ index: Int) -> UInt64 {
            // When the sender would have put packet `index` on the wire, in
            // OUR clock: one target ahead of its play time.
            UInt64(bitPattern: Int64(bitPattern: senderStart
                &+ UInt64((Double(index) * packetNanos).rounded()) &- targetNanos) &+ trueOffset)
        }

        var localNow = sendableAt(0)
        var nextPacket = 0
        var pending: [Int] = []
        var nextBurstAt = localNow
        var stallUntil: UInt64 = 0
        var random = LCG()
        var stallsInjected = 0
        var burstsDelivered = 0
        var largestBurst = 0

        let outputA = UnsafeMutablePointer<Float>.allocate(capacity: blockFrames)
        let outputB = UnsafeMutablePointer<Float>.allocate(capacity: blockFrames)
        defer { outputA.deallocate(); outputB.deallocate() }
        var heads = [outputA, outputB]
        var scratch = [Int16](repeating: 0, count: WireFormat.framesPerPacket * WireFormat.channelCount)

        // One stall per `1/stallsPerSecond` seconds, expressed as a chance per
        // burst so the stalls are not on a period that could beat with the
        // render block.
        let burstsPerSecond = 1_000_000_000.0 / Double(burstPeriodNanos)
        let stallOdds = UInt64(max(1, (burstsPerSecond / max(stallsPerSecond, 0.001)).rounded()))

        var energySum = 0.0
        var energyCount = 0
        var trimWorst = 0.0
        var warmupDone = false
        var stallsAfterWarmup = 0
        var targetApplied = requestedTargetMs
        let steps = Int(seconds / (blockNanosNominal / 1_000_000_000))

        for step in 0..<steps {
            // 1. Whatever the sender has produced by now joins the queue —
            //    but nothing leaves it until a burst instant.
            while sendableAt(nextPacket) <= localNow {
                pending.append(nextPacket)
                nextPacket += 1
            }
            if localNow >= nextBurstAt && localNow >= stallUntil {
                largestBurst = max(largestBurst, pending.count)
                for index in pending {
                    encodeParseIngest(index: index, senderStart: senderStart,
                                      packetNanos: packetNanos, arrivalNanos: localNow,
                                      scratch: &scratch, engine: engine)
                }
                pending.removeAll(keepingCapacity: true)
                burstsDelivered += 1
                nextBurstAt = localNow &+ burstPeriodNanos
                if random.chance(oneIn: stallOdds) {
                    stallUntil = localNow &+ stallNanos
                    stallsInjected += 1
                    if warmupDone { stallsAfterWarmup += 1 }
                }
            }

            // 2. One render callback.
            let deadline = localNow &+ deviceLatencyNanos
            heads.withUnsafeMutableBufferPointer { pointers in
                engine.render(frames: blockFrames, dacDeadlineNanos: deadline,
                              outputs: UnsafePointer(pointers.baseAddress!))
            }

            let elapsed = Double(step) * blockNanosNominal / 1_000_000_000
            // 3. While warming up, do what the daemon does once a second:
            //    raise the target to whatever this link's measured jitter
            //    needs. It is deliberately frozen at the end of warm-up, so
            //    every re-anchor in the measured window is a real fault and
            //    not the target moving under the loop.
            if !warmupDone, step % 100 == 0 {
                let wanted = TargetLatencyPolicy.effectiveMilliseconds(
                    requestedMs: requestedTargetMs,
                    p95JitterMs: engine.snapshot.p95JitterMilliseconds,
                    blockFrames: blockFrames,
                    sampleRate: WireFormat.sampleRate)
                if abs(wanted - targetApplied) >= 5 {
                    targetApplied = wanted
                    engine.setTargetLatency(milliseconds: wanted)
                }
            }
            if !warmupDone && elapsed >= warmupSeconds {
                engine.resetCounters()
                warmupDone = true
                stallsAfterWarmup = 0
            }
            if warmupDone {
                for f in 0..<blockFrames { energySum += Double(outputA[f]) * Double(outputA[f]) }
                energyCount += blockFrames
                trimWorst = max(trimWorst, abs((engine.snapshot.ratio - 1) * 1e6))
            }

            localNow &+= UInt64((blockNanosNominal / (1 + devicePpm * 1e-6)).rounded())
        }

        let snapshot = engine.snapshot
        let counters = snapshot.counters

        func check(_ name: String, _ passed: Bool, _ detail: String) {
            report.checks.append(Check(name: name, passed: passed, detail: detail))
            emit(String(format: "  %@ %-22@ %@", passed ? "ok  " : "FAIL", name as NSString, detail))
        }

        emit("SyncCastReceiver self-test — bursty arrival: \(Int(seconds)) s, "
             + "\(burstsDelivered) bursts of up to \(largestBurst) packets, "
             + "\(stallsInjected) stalls of \(stallNanos / 1_000_000) ms")

        check("packets accepted", counters.accepted > 0, "\(counters.accepted)")
        // Every packet IS delivered here; nothing is dropped by the harness.
        // What the counters do report is the aftermath of a stall: once the
        // read cursor has run past the write head, the backlogged packets it
        // has already passed are late, and the hole they leave is lost. Both
        // are consequences of the injected stalls, so they are budgeted
        // against those rather than required to be zero.
        let gapBudget = stallsAfterWarmup * 16 + 8
        check("gaps follow the stalls", counters.lost + counters.late <= gapBudget,
              "lost \(counters.lost) + late \(counters.late) for "
              + "\(stallsAfterWarmup) stalls (budget \(gapBudget))")
        check("no hard re-anchors", snapshot.reanchors == 0,
              "\(snapshot.reanchors) (starved \(snapshot.reanchorsByReason[.starved] ?? 0), "
              + "error \(snapshot.reanchorsByReason[.error] ?? 0), "
              + "target \(snapshot.reanchorsByReason[.target] ?? 0))")
        // An 80 ms stall against a buffer holding less than 80 ms plays
        // silence, and honestly says so. What must not happen is silence
        // WITHOUT a stall to explain it.
        let underrunBudget = stallsAfterWarmup * 8 + 4
        check("underruns bounded", counters.underrun <= underrunBudget,
              "\(counters.underrun) blocks for \(stallsAfterWarmup) stalls (budget \(underrunBudget))")
        check("no clipping", snapshot.clip == 0, "\(snapshot.clip)")
        check("arrival really was bursty", largestBurst >= burstPackets,
              "largest burst \(largestBurst) packets (steady state \(burstPackets))")
        check("trim within ±200 ppm", trimWorst <= 200, String(format: "worst %.1f ppm", trimWorst))

        let p95 = snapshot.p95JitterMilliseconds ?? 0
        check("jitter measured", p95 > 0,
              String(format: "p95 %.1f ms, target settled at %.0f ms", p95, targetApplied))

        // The audio still has to be audio: burst delivery must not have
        // turned it into a stream of holes.
        let rms = sqrt(energySum / Double(max(energyCount, 1)))
        let referenceRms = sqrt((0..<48_000).reduce(0.0) { $0 + pow(sample(atFrame: $1), 2) } / 48_000)
        check("output level", rms > referenceRms * 0.9,
              String(format: "rms %.4f (reference %.4f)", rms, referenceRms))

        return report
    }
}
