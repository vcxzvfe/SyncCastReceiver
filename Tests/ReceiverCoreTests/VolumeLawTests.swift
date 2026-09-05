import XCTest
@testable import ReceiverCore

final class VolumeLawTests: XCTestCase {

    func testFallbackLawMatchesApplesMeasuredCurve() {
        let law = VolumeLaw.fallback
        XCTAssertEqual(law.decibels(forScalar: 0), -63.5, accuracy: 0.01)
        XCTAssertEqual(law.decibels(forScalar: 0.5), -31.75, accuracy: 0.01)
        XCTAssertEqual(law.decibels(forScalar: 1), 0, accuracy: 0.01)
    }

    func testScalarAmplitudeRoundTrip() {
        for law in [VolumeLaw.fallback, VolumeLaw(minDecibels: -96), VolumeLaw(minDecibels: -40, maxDecibels: 6)] {
            for scalar in stride(from: Float(0.01), through: 1.0, by: 0.01) {
                let amplitude = law.amplitude(forScalar: scalar)
                // Above unity amplitude the round trip has to clamp; only
                // the 0…1 amplitude range is representable in a gain message.
                guard amplitude <= 1 else { continue }
                XCTAssertEqual(law.scalar(forAmplitude: amplitude), scalar, accuracy: 1e-4)
            }
        }
    }

    func testDecibelRoundTrip() {
        let law = VolumeLaw.fallback
        for db in stride(from: Float(-63.5), through: 0, by: 0.5) {
            XCTAssertEqual(law.decibels(forScalar: law.scalar(forDecibels: db)), db, accuracy: 1e-3)
        }
    }

    func testZeroIsSilentNotMinusSixtyThree() {
        XCTAssertEqual(VolumeLaw.fallback.amplitude(forScalar: 0), 0)
        XCTAssertEqual(VolumeLaw.fallback.scalar(forAmplitude: 0), 0)
    }

    func testHalfAmplitudeIsNotHalfScalar() {
        // The whole point of the law: −6 dB is scalar 0.906 on the built-in
        // speakers, not 0.5. Writing the amplitude straight into the scalar
        // would apply the taper twice.
        let scalar = VolumeLaw.fallback.scalar(forAmplitude: 0.5)
        XCTAssertEqual(scalar, 0.9052, accuracy: 0.001)
    }

    func testDegenerateRangeIsClamped() {
        let law = VolumeLaw(minDecibels: 10, maxDecibels: 0)
        XCTAssertLessThan(law.minDecibels, law.maxDecibels)
        XCTAssertFalse(law.scalar(forAmplitude: 0.5).isNaN)
    }

    func testPlanUsesHardwareWhenTheDeviceHasVolume() {
        let plan = VolumePlan.plan(linear: 0.5, muted: false, law: .fallback)
        XCTAssertEqual(plan.backend, .hardware)
        XCTAssertEqual(plan.hardwareScalar!, 0.9052, accuracy: 0.001)
        XCTAssertNil(plan.softwareAmplitude)
    }

    func testPlanFallsBackToSoftwareGain() {
        let plan = VolumePlan.plan(linear: 0.25, muted: true, law: nil)
        XCTAssertEqual(plan.backend, .software)
        XCTAssertEqual(plan.softwareAmplitude!, 0.25, accuracy: 1e-6)
        XCTAssertTrue(plan.muted)
    }

    func testPlanClampsOutOfRangeGain() {
        XCTAssertEqual(VolumePlan.plan(linear: 4, muted: false, law: nil).softwareAmplitude!, 1)
        XCTAssertEqual(VolumePlan.plan(linear: -1, muted: false, law: nil).softwareAmplitude!, 0)
        XCTAssertEqual(VolumePlan.plan(linear: 2, muted: false, law: .fallback).hardwareScalar!, 1)
    }
}
