import Foundation
import CoreAudio
import AudioToolbox

/// One AUHAL instance rendering `PlayoutEngine` output to a chosen device.
///
/// The client format is fixed at 48 kHz Float32 non-interleaved: the AUHAL
/// itself converts to whatever the device runs at, so a 44.1 kHz or 96 kHz
/// device needs no special handling here (and its clock error is still
/// tracked by the PI loop, because the loop watches the ring level, not the
/// device rate).
public final class AUHALOutput: @unchecked Sendable {

    public enum StartError: Error, CustomStringConvertible {
        case componentUnavailable
        case coreAudio(String, OSStatus)

        public var description: String {
            switch self {
            case .componentUnavailable: return "the HAL output audio component is unavailable"
            case .coreAudio(let what, let status): return "\(what) failed with OSStatus \(status)"
            }
        }
    }

    public let device: AudioOutputDevice
    public let engine: PlayoutEngine
    private var unit: AudioUnit?
    private let clock = MachClock()
    /// Device latency in host-clock nanoseconds, refreshed at start.
    private let latencyNanos = AtomicInt64(0)
    private let running = AtomicBool(false)

    public init(device: AudioOutputDevice, engine: PlayoutEngine) {
        self.device = device
        self.engine = engine
    }

    deinit { stop() }

    public var isRunning: Bool { running.value }
    public var outputLatencyNanos: UInt64 { UInt64(max(0, latencyNanos.value)) }
    public var outputLatencyMilliseconds: Double { Double(outputLatencyNanos) / 1_000_000 }

    public func start() throws {
        guard unit == nil else { return }
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw StartError.componentUnavailable
        }
        var newUnit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &newUnit), "AudioComponentInstanceNew")
        guard let audioUnit = newUnit else { throw StartError.componentUnavailable }
        unit = audioUnit

        do {
            // Output element 0 stays enabled; input element 1 must be off or
            // the unit will try to open the device for capture too.
            var enable: UInt32 = 1
            try check(AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO,
                                           kAudioUnitScope_Output, 0, &enable, UInt32(MemoryLayout<UInt32>.size)),
                      "EnableIO(output)")
            var disable: UInt32 = 0
            try check(AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO,
                                           kAudioUnitScope_Input, 1, &disable, UInt32(MemoryLayout<UInt32>.size)),
                      "EnableIO(input)")
            var deviceID = device.id
            try check(AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                           kAudioUnitScope_Global, 0, &deviceID,
                                           UInt32(MemoryLayout<AudioDeviceID>.size)),
                      "CurrentDevice")

            var format = AudioStreamBasicDescription(
                mSampleRate: engine.sampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                mChannelsPerFrame: UInt32(engine.channelCount),
                mBitsPerChannel: 32, mReserved: 0)
            try check(AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat,
                                           kAudioUnitScope_Input, 0, &format,
                                           UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
                      "StreamFormat")

            var callback = AURenderCallbackStruct(
                inputProc: auhalRenderCallback,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try check(AudioUnitSetProperty(audioUnit, kAudioUnitProperty_SetRenderCallback,
                                           kAudioUnitScope_Input, 0, &callback,
                                           UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                      "SetRenderCallback")

            try check(AudioUnitInitialize(audioUnit), "AudioUnitInitialize")
            refreshLatency()
            try check(AudioOutputUnitStart(audioUnit), "AudioOutputUnitStart")
            running.value = true
        } catch {
            // Never leave a half-configured unit behind: the next retry must
            // start from a clean slate.
            AudioUnitUninitialize(audioUnit)
            AudioComponentInstanceDispose(audioUnit)
            unit = nil
            throw error
        }
    }

    public func stop() {
        guard let audioUnit = unit else { return }
        running.value = false
        AudioOutputUnitStop(audioUnit)
        AudioUnitUninitialize(audioUnit)
        AudioComponentInstanceDispose(audioUnit)
        unit = nil
    }

    /// Re-read the device's latency figures (they change when the device
    /// renegotiates its buffer size, e.g. after wake).
    public func refreshLatency() {
        let rate = device.nominalSampleRate > 0 ? device.nominalSampleRate : engine.sampleRate
        latencyNanos.value = Int64(AudioDevices.outputLatencyNanos(device.id, sampleRate: rate))
    }

    /// Real-time entry point. Runs on the CoreAudio render thread.
    fileprivate func render(frames: Int, timestamp: UnsafePointer<AudioTimeStamp>,
                            ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let ioData else { return noErr }
        let list = UnsafeMutableAudioBufferListPointer(ioData)
        guard list.count >= engine.channelCount else {
            for buffer in list {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            return noErr
        }
        // The AUHAL's host time is when the buffer is handed to the device;
        // add the device's own latency to get the moment it reaches the DAC,
        // which is the instant `play_at_ns` refers to.
        let hostNanos: UInt64
        if timestamp.pointee.mFlags.contains(.hostTimeValid) {
            hostNanos = clock.nanos(fromHostTime: timestamp.pointee.mHostTime)
        } else {
            hostNanos = clock.nowNanos()
        }
        let deadline = hostNanos &+ UInt64(max(0, latencyNanos.value))

        withUnsafeTemporaryAllocation(of: UnsafeMutablePointer<Float>.self, capacity: engine.channelCount) { heads in
            for ch in 0..<engine.channelCount {
                guard let data = list[ch].mData else { return }
                heads[ch] = data.assumingMemoryBound(to: Float.self)
            }
            engine.render(frames: frames, dacDeadlineNanos: deadline,
                          outputs: UnsafePointer(heads.baseAddress!))
        }
        return noErr
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw StartError.coreAudio(what, status) }
    }
}

/// C render callback trampoline. No allocation, no Swift runtime beyond the
/// unmanaged pointer bridge.
private func auhalRenderCallback(inRefCon: UnsafeMutableRawPointer,
                                 ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                 inTimeStamp: UnsafePointer<AudioTimeStamp>,
                                 inBusNumber: UInt32,
                                 inNumberFrames: UInt32,
                                 ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let output = Unmanaged<AUHALOutput>.fromOpaque(inRefCon).takeUnretainedValue()
    return output.render(frames: Int(inNumberFrames), timestamp: inTimeStamp, ioData: ioData)
}
