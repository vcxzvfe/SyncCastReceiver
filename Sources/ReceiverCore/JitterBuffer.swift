import Foundation
import CReceiverAtomics

/// Playout ring keyed by the sender's `play_at_ns`.
///
/// # Indexing
/// The first accepted packet of a stream defines the anchor
/// `(anchorPlayAtNanos → frame 0)`. Every later packet lands at
/// ```
/// index = round((play_at_ns − anchorPlayAtNanos) · rate / 1e9)
/// ```
/// computed entirely in the SENDER's timestamp domain, so reordering and
/// clock-offset noise cannot move a packet's slot: a packet always occupies
/// the frames it was stamped for. The offset estimate is applied once, when
/// the render thread anchors its read cursor, not per packet.
///
/// # Threading
/// Single producer (the UDP receive thread, `ingest`) and single consumer
/// (the CoreAudio render thread, `read`). Cursors are published with C11
/// release/acquire ordering; no Darwin lock is ever taken, so the render
/// thread cannot be priority-inverted by the network thread.
public final class JitterBuffer: @unchecked Sendable {

    public struct Counters: Equatable, Sendable {
        public var accepted: Int = 0
        /// Packets dropped because their frames were already played out.
        public var late: Int = 0
        /// Packets never delivered, inferred from gaps in the play-out
        /// timeline (counted in packets, zero-filled in the ring).
        public var lost: Int = 0
        /// Packets received twice (same stream, same sequence number).
        public var duplicate: Int = 0
        /// Packets that arrived out of order but still ahead of the read
        /// cursor — they were dropped into their hole, nothing was lost.
        public var reordered: Int = 0
        /// Render calls that ran past the newest written frame and got
        /// silence.
        public var underrun: Int = 0
        /// Packets whose frames overlapped audio the ring already holds.
        ///
        /// A correct sender cannot produce one: every packet comes from a
        /// distinct span of its capture ring. Two packets claiming the same
        /// playout frames means the sender is running two timelines at once
        /// — which is exactly the fault a two-machine run found, and which
        /// sounded like two copies of the music playing over each other. The
        /// second copy is refused rather than written over the first.
        public var overlap: Int = 0
        /// Packets stamped more than `farFutureNanos` beyond the newest
        /// frame the ring holds.
        ///
        /// Not the same as a discontinuity: a sender that restarts its clock
        /// lands within one ring and is re-anchored onto. This is a
        /// timestamp no schedule can absorb, and accepting it would park the
        /// stream seconds in the future.
        public var farFuture: Int = 0
    }

    /// How far ahead of the newest buffered frame a packet may be stamped
    /// before it is refused outright.
    ///
    /// Two seconds is far beyond any jitter buffer this receiver will ever
    /// run (the target tops out at 300 ms) and beyond the ring itself, so
    /// nothing legitimate reaches it. A genuine restart after a long silence
    /// does not: `PlayoutEngine` resets the stream on the idle edge, so the
    /// first packet back anchors from scratch rather than being measured
    /// against a schedule that stopped seconds ago.
    public static let farFutureNanos: Double = 2_000_000_000

    /// `farFutureNanos` in frames at a given rate.
    public static func farFutureFrames(sampleRate: Double) -> Int64 {
        Int64((farFutureNanos / 1_000_000_000 * sampleRate).rounded())
    }

    public let channelCount: Int
    public let capacityFrames: Int
    public let sampleRate: Double

    private let storage: [UnsafeMutablePointer<Float>]
    private let writeEnd: UnsafeMutablePointer<SCRAtomicI64>
    private let readCursor: UnsafeMutablePointer<SCRAtomicI64>
    private let counters: UnsafeMutablePointer<SCRAtomicI64>   // 6 slots, see CounterSlot
    private let anchorNanos: UnsafeMutablePointer<SCRAtomicI64>
    private let anchorGeneration: UnsafeMutablePointer<SCRAtomicI64>
    /// Incremented every time `anchorNanos` is (re)defined — the first packet
    /// of a stream, a stream-ID change, a timestamp discontinuity. The render
    /// side compares it with the epoch it anchored its cursor under: a cursor
    /// placed under an older epoch is meaningless against the new frame
    /// numbering and has to be placed again.
    private let anchorEpoch: UnsafeMutablePointer<SCRAtomicI64>

    private enum CounterSlot: Int, CaseIterable {
        case accepted, late, lost, duplicate, reordered, underrun, overlap, farFuture
    }

    /// One byte per ring frame: 1 when that frame holds audio a packet
    /// actually delivered, 0 when it is a zero-filled hole or has never been
    /// written. Producer-owned, so no atomics — the render thread never looks
    /// at it, it only reads samples.
    ///
    /// This is what makes the overlap test exact. Without it "a packet landed
    /// below the write head" cannot be told apart from "a reordered packet
    /// arrived to fill the hole left for it", and those two need opposite
    /// answers.
    private let occupancy: UnsafeMutablePointer<UInt8>

    /// Producer-owned state (UDP thread only).
    private var streamID: UInt32?
    private var recentSeq: [Int64]
    private static let recentSeqSlots = 1024

    /// Read cursor before the render thread has anchored: any packet is
    /// "ahead of playback" until then.
    private static let unanchoredCursor = Int64.min / 4

    public init(channelCount: Int = WireFormat.channelCount,
                capacityFrames: Int = 1 << 16,          // 1.365 s at 48 kHz
                sampleRate: Double = WireFormat.sampleRate) {
        precondition(channelCount > 0)
        precondition(capacityFrames > 0 && (capacityFrames & (capacityFrames - 1)) == 0,
                     "capacityFrames must be a power of two")
        self.channelCount = channelCount
        self.capacityFrames = capacityFrames
        self.sampleRate = sampleRate
        self.storage = (0..<channelCount).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: capacityFrames)
            p.initialize(repeating: 0, count: capacityFrames)
            return p
        }
        func makeAtoms(_ n: Int, _ initial: Int64) -> UnsafeMutablePointer<SCRAtomicI64> {
            let p = UnsafeMutablePointer<SCRAtomicI64>.allocate(capacity: n)
            for i in 0..<n { scr_atomic_init(p.advanced(by: i), initial) }
            return p
        }
        self.writeEnd = makeAtoms(1, 0)
        self.readCursor = makeAtoms(1, Self.unanchoredCursor)
        self.counters = makeAtoms(CounterSlot.allCases.count, 0)
        self.anchorNanos = makeAtoms(1, 0)
        self.anchorGeneration = makeAtoms(1, 0)
        self.anchorEpoch = makeAtoms(1, 0)
        self.recentSeq = [Int64](repeating: -1, count: Self.recentSeqSlots)
        let marks = UnsafeMutablePointer<UInt8>.allocate(capacity: capacityFrames)
        marks.initialize(repeating: 0, count: capacityFrames)
        self.occupancy = marks
    }

    deinit {
        for p in storage { p.deinitialize(count: capacityFrames); p.deallocate() }
        writeEnd.deallocate(); readCursor.deallocate(); counters.deallocate()
        anchorNanos.deallocate(); anchorGeneration.deallocate(); anchorEpoch.deallocate()
        occupancy.deinitialize(count: capacityFrames)
        occupancy.deallocate()
    }

    // MARK: - Observation

    public var counterSnapshot: Counters {
        var c = Counters()
        c.accepted = Int(load(.accepted))
        c.late = Int(load(.late))
        c.lost = Int(load(.lost))
        c.duplicate = Int(load(.duplicate))
        c.reordered = Int(load(.reordered))
        c.underrun = Int(load(.underrun))
        c.overlap = Int(load(.overlap))
        c.farFuture = Int(load(.farFuture))
        return c
    }

    public var writeEndFrame: Int64 { scr_atomic_load_acquire(writeEnd) }
    public var readCursorFrame: Int64 { scr_atomic_load_acquire(readCursor) }
    public var isAnchored: Bool { scr_atomic_load_acquire(anchorGeneration) != 0 }
    /// How many times the frame numbering has been (re)defined. See
    /// `anchorEpoch` above; zero before the first packet.
    public var anchorEpochValue: Int64 { scr_atomic_load_acquire(anchorEpoch) }
    /// Sender-domain nanoseconds that map to frame 0, or nil before the
    /// first packet.
    public var anchorPlayAtNanos: UInt64? {
        guard isAnchored else { return nil }
        return UInt64(bitPattern: scr_atomic_load_acquire(anchorNanos))
    }
    /// Frames currently buffered ahead of the read cursor. Meaningless (and
    /// enormous) before the render thread has anchored.
    public var fillFrames: Int64 {
        let r = readCursorFrame
        guard r != Self.unanchoredCursor else { return 0 }
        return writeEndFrame - r
    }
    public var fillMilliseconds: Double { Double(fillFrames) / sampleRate * 1000 }

    // MARK: - Producer side (UDP thread)

    public enum IngestOutcome: Equatable, Sendable {
        case accepted(index: Int64)
        case reordered(index: Int64)
        case late
        case duplicate
        case restarted(index: Int64)
        /// Refused: its frames overlap audio the ring already holds.
        case overlap
        /// Refused: stamped further than `farFutureNanos` ahead of the ring.
        case farFuture
    }

    /// Write one decoded packet into the ring.
    ///
    /// `samples` is interleaved Int16 (`frames * channelCount` values), as it
    /// comes off the wire; de-interleaving happens here so the render thread
    /// only ever does a planar copy.
    @discardableResult
    public func ingest(header: AudioPacketHeader,
                       samples: UnsafePointer<Int16>) -> IngestOutcome {
        let frames = Int(header.frames)
        var restarted = false

        if streamID != header.streamID {
            resetStreamState(streamID: header.streamID)
            restarted = true
        }

        // Anchor on the first packet of the stream.
        if scr_atomic_load_acquire(anchorGeneration) == 0 {
            scr_atomic_store_release(anchorNanos, Int64(bitPattern: header.playAtNanos))
            scr_atomic_store_release(writeEnd, 0)
            scr_atomic_add_relaxed(anchorEpoch, 1)
            scr_atomic_store_release(anchorGeneration, 1)
        }

        let index = frameIndex(forPlayAtNanos: header.playAtNanos)
        let end = index + Int64(frames)
        let currentEnd = scr_atomic_load_acquire(writeEnd)

        // A timestamp this far ahead is not a discontinuity to recover from,
        // it is a number no schedule can hold. Refuse it before the re-anchor
        // path below can park the whole stream seconds in the future.
        if index > currentEnd + Self.farFutureFrames(sampleRate: sampleRate) {
            bump(.farFuture)
            return .farFuture
        }

        // A timestamp further than one ring away from what we already hold
        // is not reordering, it is a discontinuity (sender restarted its
        // clock stamping, or we slept). Re-anchor on it.
        if index < currentEnd - Int64(capacityFrames) || index > currentEnd + Int64(capacityFrames) {
            resetStreamState(streamID: header.streamID)
            scr_atomic_store_release(anchorNanos, Int64(bitPattern: header.playAtNanos))
            scr_atomic_store_release(writeEnd, 0)
            scr_atomic_add_relaxed(anchorEpoch, 1)
            scr_atomic_store_release(anchorGeneration, 1)
            writeFrames(at: 0, frames: frames, samples: samples)
            scr_atomic_store_release(writeEnd, Int64(frames))
            bump(.accepted)
            return .restarted(index: 0)
        }

        if isDuplicate(seq: header.seq) {
            bump(.duplicate)
            return .duplicate
        }
        markSeen(seq: header.seq)

        let cursor = scr_atomic_load_acquire(readCursor)
        if end <= cursor {
            bump(.late)
            return .late
        }

        // Two packets may never claim the same playout frames. A packet that
        // lands below the write head is legitimate ONLY when it is filling a
        // hole that was zero-filled for it; anything else is a second
        // timeline, and writing it would mix two copies of the programme.
        if index < currentEnd,
           holdsAudio(from: max(index, cursor), to: min(end, currentEnd)) {
            bump(.overlap)
            return .overlap
        }

        if index > currentEnd {
            // Hole: the packets that should have filled [currentEnd, index)
            // never arrived. Zero them so the render thread reads silence
            // rather than the ring's stale contents.
            zeroFrames(from: currentEnd, to: index)
            let missingFrames = index - currentEnd
            let per = Int64(max(frames, 1))
            addCounter(.lost, by: max(1, (missingFrames + per - 1) / per))
        }

        let fillsHole = index < currentEnd
        if fillsHole {
            // This packet was already counted lost when the hole opened;
            // it arrived after all, so take the count back. Single-producer,
            // so the read-modify-write needs no CAS.
            let current = load(.lost)
            if current > 0 { scr_atomic_store_release(counters.advanced(by: CounterSlot.lost.rawValue), current - 1) }
        }
        writeFrames(at: index, frames: frames, samples: samples)
        if end > currentEnd { scr_atomic_store_release(writeEnd, end) }
        bump(.accepted)
        if restarted { return .restarted(index: index) }
        if fillsHole { bump(.reordered); return .reordered(index: index) }
        return .accepted(index: index)
    }

    /// Frame index for a sender-domain timestamp under the current anchor.
    public func frameIndex(forPlayAtNanos playAt: UInt64) -> Int64 {
        let anchor = scr_atomic_load_acquire(anchorNanos)
        let delta = Int64(bitPattern: playAt) &- anchor
        return Int64((Double(delta) * sampleRate / 1_000_000_000).rounded())
    }

    /// Sender-domain timestamp of a frame index.
    public func playAtNanos(forFrameIndex index: Int64) -> UInt64 {
        let anchor = scr_atomic_load_acquire(anchorNanos)
        return UInt64(bitPattern: anchor &+ Int64((Double(index) / sampleRate * 1_000_000_000).rounded()))
    }

    // MARK: - Consumer side (render thread)

    /// Point the read cursor at the frame that should be leaving the DAC at
    /// `senderNanos` (the local DAC deadline already converted into the
    /// sender's clock domain).
    public func anchorReadCursor(toSenderNanos senderNanos: UInt64) {
        scr_atomic_store_release(readCursor, frameIndex(forPlayAtNanos: senderNanos))
    }

    /// Hard re-anchor: place the cursor `levelFrames` behind the newest
    /// written frame. Used when the level error is past the point a ±200 ppm
    /// trim can recover.
    public func reanchorReadCursor(toLevelFrames levelFrames: Int64) {
        scr_atomic_store_release(readCursor, scr_atomic_load_acquire(writeEnd) - levelFrames)
    }

    /// Read `frames` planar Float32 frames at the cursor and advance it.
    /// Frames outside the written window are zeroed. Returns the number of
    /// frames genuinely backed by received audio.
    ///
    /// Real-time safe: no allocation, no locks, no Swift runtime calls
    /// beyond the pointer arithmetic.
    @discardableResult
    public func read(frames: Int, into out: UnsafePointer<UnsafeMutablePointer<Float>>) -> Int {
        guard frames > 0 else { return 0 }
        let cap = capacityFrames
        let start = scr_atomic_load_acquire(readCursor)
        // A cursor that has not been placed under the current anchor is not a
        // position, and advancing it from `Int64.min / 4` is how a whole
        // stream once played nine seconds of silence with a "fill" of 2⁶¹
        // frames. Silence, no count, no advance — the owner re-anchors.
        guard start != Self.unanchoredCursor else {
            for ch in 0..<channelCount { out[ch].update(repeating: 0, count: frames) }
            return 0
        }
        let end = scr_atomic_load_acquire(writeEnd)
        // Frame indices below 0 predate the stream and were never written;
        // frames older than one ring have been overwritten. Both are silence.
        let lowerValid = max(0, end - Int64(cap))
        let validStart = max(start, lowerValid)
        let validEnd = min(start &+ Int64(frames), end)

        let leadingZeros = min(frames, Int(max(0, validStart - start)))
        let validFrames = min(max(0, Int(validEnd - validStart)), frames - leadingZeros)
        let trailingZeros = max(0, frames - leadingZeros - validFrames)

        if leadingZeros > 0 {
            for ch in 0..<channelCount { out[ch].update(repeating: 0, count: leadingZeros) }
        }
        if validFrames > 0 {
            let bufStart = Int(validStart & Int64(cap - 1))
            let firstChunk = min(validFrames, cap - bufStart)
            for ch in 0..<channelCount {
                out[ch].advanced(by: leadingZeros)
                    .update(from: storage[ch].advanced(by: bufStart), count: firstChunk)
                if validFrames > firstChunk {
                    out[ch].advanced(by: leadingZeros + firstChunk)
                        .update(from: storage[ch], count: validFrames - firstChunk)
                }
            }
        }
        if trailingZeros > 0 {
            for ch in 0..<channelCount {
                out[ch].advanced(by: leadingZeros + validFrames).update(repeating: 0, count: trailingZeros)
            }
        }
        if trailingZeros > 0 { bump(.underrun) }
        scr_atomic_store_release(readCursor, start &+ Int64(frames))
        return validFrames
    }

    // MARK: - Lifecycle

    /// Forget the current stream. The next packet re-anchors.
    public func resetStream() { resetStreamState(streamID: nil) }

    private func resetStreamState(streamID newID: UInt32?) {
        streamID = newID
        for i in 0..<recentSeq.count { recentSeq[i] = -1 }
        scr_atomic_store_release(anchorGeneration, 0)
        scr_atomic_store_release(writeEnd, 0)
        scr_atomic_store_release(readCursor, Self.unanchoredCursor)
        for ch in 0..<channelCount { storage[ch].update(repeating: 0, count: capacityFrames) }
        occupancy.update(repeating: 0, count: capacityFrames)
    }

    public func resetCounters() {
        for slot in CounterSlot.allCases {
            scr_atomic_store_release(counters.advanced(by: slot.rawValue), 0)
        }
    }

    // MARK: - Internals

    private func writeFrames(at index: Int64, frames: Int, samples: UnsafePointer<Int16>) {
        let cap = capacityFrames
        let base = Int(index & Int64(cap - 1))
        let scale = Float(1.0 / 32768.0)
        for f in 0..<frames {
            let slot = (base + f) & (cap - 1)
            for ch in 0..<channelCount {
                storage[ch][slot] = Float(samples[f * channelCount + ch]) * scale
            }
            occupancy[slot] = 1
        }
    }

    /// Whether any frame in `[from, to)` already holds delivered audio.
    private func holdsAudio(from: Int64, to: Int64) -> Bool {
        let cap = Int64(capacityFrames)
        guard to > from else { return false }
        // A span longer than the ring cannot be reasoned about; the callers
        // above have already rejected those, but clamp rather than run off.
        let start = max(from, to - cap)
        var frame = start
        while frame < to {
            if occupancy[Int(frame & (cap - 1))] != 0 { return true }
            frame += 1
        }
        return false
    }

    private func zeroFrames(from: Int64, to: Int64) {
        let cap = Int64(capacityFrames)
        let span = min(to - from, cap)
        guard span > 0 else { return }
        let start = to - span
        for f in 0..<Int(span) {
            let slot = Int((start &+ Int64(f)) & (cap - 1))
            for ch in 0..<channelCount { storage[ch][slot] = 0 }
            // A hole is NOT audio: a packet that turns up late may still
            // fill it, and must not be mistaken for an overlap.
            occupancy[slot] = 0
        }
    }

    private func isDuplicate(seq: UInt32) -> Bool {
        recentSeq[Int(seq) & (Self.recentSeqSlots - 1)] == Int64(seq)
    }

    private func markSeen(seq: UInt32) {
        recentSeq[Int(seq) & (Self.recentSeqSlots - 1)] = Int64(seq)
    }

    private func bump(_ slot: CounterSlot) { addCounter(slot, by: 1) }

    private func addCounter(_ slot: CounterSlot, by n: Int64) {
        scr_atomic_add_relaxed(counters.advanced(by: slot.rawValue), n)
    }

    private func load(_ slot: CounterSlot) -> Int64 {
        scr_atomic_load_acquire(counters.advanced(by: slot.rawValue))
    }
}
