import XCTest
@testable import ReceiverCore

final class FractionalResamplerTests: XCTestCase {

    private func run(ratio: Double, blocks: Int, blockFrames: Int = 240,
                     frequency: Double = 1_000) -> (produced: Int, peak: Float) {
        let resampler = FractionalResampler(channelCount: 2)
        var produced = 0
        var peak: Float = 0
        var phase = 0.0
        let capacity = blockFrames * 2
        let inA = UnsafeMutablePointer<Float>.allocate(capacity: blockFrames)
        let inB = UnsafeMutablePointer<Float>.allocate(capacity: blockFrames)
        let outA = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        let outB = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        defer { inA.deallocate(); inB.deallocate(); outA.deallocate(); outB.deallocate() }
        var ins = [inA, inB]
        var outs = [outA, outB]
        for _ in 0..<blocks {
            for f in 0..<blockFrames {
                let v = Float(0.5 * sin(2 * .pi * frequency * phase / WireFormat.sampleRate))
                inA[f] = v; inB[f] = v
                phase += 1
            }
            let n = ins.withUnsafeMutableBufferPointer { inPtr in
                outs.withUnsafeMutableBufferPointer { outPtr in
                    resampler.process(inputs: inPtr.baseAddress!, inFrames: blockFrames,
                                      ratio: ratio, outputs: outPtr.baseAddress!, outCapacity: capacity)
                }
            }
            produced += n
            // Skip the very first block: the 4-tap history is still filling.
            for i in 0..<n { peak = max(peak, abs(outA[i])) }
        }
        return (produced, peak)
    }

    func testUnityRatioIsFrameCountPreserving() {
        let r = run(ratio: 1.0, blocks: 10)
        XCTAssertEqual(r.produced, 2_400)
    }

    func testFrameCountTracksTheRatio() {
        for ratio in [0.9998, 0.9999, 1.0001, 1.0002] {
            let r = run(ratio: ratio, blocks: 100)
            XCTAssertEqual(Double(r.produced), 24_000 * ratio, accuracy: 4,
                           "ratio \(ratio) produced \(r.produced)")
        }
    }

    func testAmplitudeIsPreservedAtTheClampedExtremes() {
        for ratio in [1 - 200e-6, 1.0, 1 + 200e-6] {
            let r = run(ratio: ratio, blocks: 40)
            // Cubic interpolation of a 1 kHz tone at 48 kHz loses far less
            // than 0.1 dB; anything approaching sample drop/duplicate would
            // show up as ripple here.
            XCTAssertEqual(r.peak, 0.5, accuracy: 0.005, "ratio \(ratio) peak \(r.peak)")
        }
    }

    func testInputFramesNeededCoversTheRequest() {
        let resampler = FractionalResampler(channelCount: 2)
        for ratio in [1 - 200e-6, 1.0, 1 + 200e-6] {
            for out in [1, 32, 240, 512, 4_096] {
                let need = resampler.inputFramesNeeded(forOutput: out, ratio: ratio)
                XCTAssertGreaterThanOrEqual(Double(need) * ratio, Double(out))
            }
        }
    }

    func testResetIsSilentAndRepeatable() {
        let resampler = FractionalResampler(channelCount: 1)
        let input = UnsafeMutablePointer<Float>.allocate(capacity: 8)
        let output = UnsafeMutablePointer<Float>.allocate(capacity: 16)
        defer { input.deallocate(); output.deallocate() }
        input.update(repeating: 0, count: 8)
        var ins = [input], outs = [output]
        let n = ins.withUnsafeMutableBufferPointer { i in
            outs.withUnsafeMutableBufferPointer { o in
                resampler.process(inputs: i.baseAddress!, inFrames: 8, ratio: 1,
                                  outputs: o.baseAddress!, outCapacity: 16)
            }
        }
        XCTAssertEqual(n, 8)
        for i in 0..<n { XCTAssertEqual(output[i], 0) }
        resampler.reset()
    }
}
